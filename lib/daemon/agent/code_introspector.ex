defmodule Daemon.Agent.CodeIntrospector do
  @moduledoc """
  Code-first investigation topic generator with closed-loop resolution tracking.

  Analyzes the daemon's own runtime behavior — error rates, latency spikes,
  DLQ growth, circuit breaker trips, cost overruns, crash patterns, and learner
  degradation — to generate targeted investigation topics.

  Instead of random academic topic selection (~10% codebase relevance),
  CodeIntrospector inverts the pipeline: every investigation starts from a real
  observed anomaly, targeting ~80%+ hit rate.

  ## Resolution Tracking (closed-loop)

  After an investigation completes, CodeIntrospector tracks whether the anomaly
  that triggered it resolves or persists:

  - **Resolved** (anomaly not seen for `@resolution_window_polls` consecutive polls):
    Super-rewards the `:introspection` Thompson arm — the research actually helped.
  - **Persists** (same anomaly type fires again):
    Enriches the next investigation's steering with previous findings, so the system
    digs deeper instead of repeating surface-level research.

  This closes the loop between "detect problem → research solution → measure impact."

  ## Anomaly Correlation

  Co-occurring anomalies (e.g. circuit breaker trip + error spike + latency spike from
  the same root cause) are grouped into a single incident. One composite investigation
  is spawned instead of three redundant ones.

  ## Integration

  - Spawns investigations directly via `Investigate.execute/1` (same pattern as SelfDiagnosis)
  - Writes prediction records to ActiveLearner's `:active_learner_outcomes` ETS
  - ActiveLearner's `record_outcome_if_ours` updates the `:introspection` Thompson arm
  - The bandit naturally learns whether code-derived topics outperform other sources

  ## Safety

  - 2-minute initial delay (services must stabilize)
  - Cold-start suppression: no anomaly detection until baseline has >= 3 data points
  - 2-hour cooldown per anomaly hash
  - Max 3 topics per poll, 10 per day, 2 concurrent investigations
  - Consecutive failure backoff: disables spawning after 3 consecutive investigation failures
  - All signal collection guarded with try/rescue/catch :exit
  - SelfDiagnosis overlap prevention for crash patterns
  - `investigated_anomalies` auto-pruned to entries within cooldown window
  """
  use GenServer
  require Logger

  @poll_interval_ms          600_000       # 10 min
  @initial_delay_ms          120_000       # 2 min
  @cooldown_seconds          7_200         # 2 hours per anomaly hash
  @max_topics_per_cycle      3
  @max_topics_per_day        10
  @max_concurrent            2
  @baseline_window           30            # Rolling window size
  @anomaly_z_threshold       2.0           # Std devs for anomaly detection
  @cold_start_min_samples    3             # Min baseline samples before detecting anomalies
  @seen_table                :code_introspector_seen
  @seen_ttl_seconds          48 * 3600
  @persistence_file          "code_introspector_state.json"
  @outcomes_table            :active_learner_outcomes
  @max_findings              50
  @max_consecutive_failures  3             # Disable after N consecutive investigation failures
  @resolution_window_polls   6             # ~1 hour (6 * 10min) of no recurrence = resolved

  # Architectural diagnostic thresholds
  @mailbox_threshold 500
  @wiener_min_subscribers 1  # Bridge.PubSub registers 1 broadcast handler per type;
                             # event types with ONLY the bridge = no real consumer = open loop
  @ashby_min_occurrences 3   # crash patterns must recur 3+ times
  @arch_cooldown_seconds 86_400  # 24 hours — much longer than metric cooldown (2hr)
  @self_modification_blocked ["code_introspector.ex", "insight_actuator.ex", "investigate.ex"]

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats: baselines, anomaly counts, topics generated, active tasks, resolutions."
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{status: :not_running}
    catch
      :exit, _ -> %{status: :not_running}
    end
  end

  @doc "Manually trigger a poll cycle for debugging."
  def force_poll do
    GenServer.cast(__MODULE__, :force_poll)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_ets_table(@seen_table)
    persisted = load_persisted_state()

    Process.send_after(self(), :first_poll, @initial_delay_ms)
    Logger.info("[CodeIntrospector] Started")
    Logger.info("[CodeIntrospector] First poll in #{div(@initial_delay_ms, 1000)}s")

    {:ok, %{
      baselines: Map.get(persisted, "baselines", %{
        "error_rates" => %{},
        "avg_latencies" => %{},
        "dlq_depths" => [],
        "cost_daily" => []
      }),
      investigated_anomalies: restore_investigated(persisted),
      active_tasks: [],
      topics_today: 0,
      last_day_reset: Date.utc_today(),
      total_topics: Map.get(persisted, "total_topics", 0),
      findings: [],
      consecutive_failures: 0,
      # Resolution tracking: anomaly_type => %{findings_summary, investigated_at, polls_absent, anomaly_hash}
      resolution_map: restore_resolution_map(persisted),
      resolutions_total: Map.get(persisted, "resolutions_total", 0)
    }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    reply = %{
      status: :running,
      baselines: summarize_baselines(state.baselines),
      investigated_count: map_size(state.investigated_anomalies),
      active_tasks: length(state.active_tasks),
      topics_today: state.topics_today,
      total_topics: state.total_topics,
      findings_count: length(state.findings),
      recent_findings: Enum.take(state.findings, 5),
      consecutive_failures: state.consecutive_failures,
      disabled: state.consecutive_failures >= @max_consecutive_failures,
      resolution_map: Map.new(state.resolution_map, fn {k, v} -> {k, Map.delete(v, :findings_summary)} end),
      resolutions_total: state.resolutions_total
    }
    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:force_poll, state) do
    Logger.info("[CodeIntrospector] Force poll triggered")
    state = run_poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:first_poll, state) do
    state = run_poll(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    state = run_poll(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:introspection_complete, hash, anomaly_type, result}, state) do
    state = handle_investigation_result(state, hash, anomaly_type, result)
    active = Enum.reject(state.active_tasks, fn {_ref, h, _started, _type} -> h == hash end)
    {:noreply, %{state | active_tasks: active}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    active = Enum.reject(state.active_tasks, fn {r, _h, _s, _t} -> r == ref end)
    {:noreply, %{state | active_tasks: active}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    persist_state(state)
    :ok
  end

  # ── Core Poll Logic ─────────────────────────────────────────────────

  defp run_poll(state) do
    state = maybe_reset_daily(state)
    signals = collect_signals()
    anomalies = detect_anomalies(signals, state.baselines)
    baselines = update_baselines(state.baselines, signals)
    state = %{state | baselines: baselines}

    # Correlate co-occurring anomalies into incidents
    {incidents, standalone} = correlate_anomalies(anomalies)

    total_raw = length(anomalies)
    total_after = length(incidents) + length(standalone)
    Logger.info("[CodeIntrospector] Poll: #{map_size(signals)} signals, #{total_raw} raw anomalies → #{total_after} after correlation")

    # Resolution tracking: check which previously-investigated anomaly types are still firing
    current_types = MapSet.new(Enum.map(anomalies, & &1.type))
    state = update_resolution_tracking(state, current_types)

    # All actionable items (incidents become single composite investigations)
    all_actionable = incidents ++ standalone

    # Filter: cooldown, dedup, daily cap, self-protection
    now = DateTime.utc_now()
    actionable = all_actionable
      |> Enum.reject(fn a -> recently_investigated?(state, a.hash, now) end)
      |> Enum.reject(fn a -> seen_fresh?(a.hash) end)
      |> Enum.sort_by(fn a -> severity_rank(a.severity) end, :desc)
      |> Enum.take(@max_topics_per_cycle)

    remaining = @max_topics_per_day - state.topics_today
    actionable = Enum.take(actionable, max(0, remaining))

    # Self-protection: don't spawn if consecutive failures hit limit
    actionable = if state.consecutive_failures >= @max_consecutive_failures do
      if actionable != [] do
        Logger.warning("[CodeIntrospector] Self-disabled after #{state.consecutive_failures} consecutive failures, skipping #{length(actionable)} anomalies")
      end
      []
    else
      actionable
    end

    if actionable != [] do
      Logger.info("[CodeIntrospector] #{length(actionable)} actionable anomalies (#{remaining} daily slots remaining)")
    end

    state = Enum.reduce(actionable, state, fn anomaly, acc ->
      spawn_if_capacity(acc, anomaly)
    end)

    # Prune investigated_anomalies older than cooldown
    state = prune_investigated(state, now)

    # Architectural diagnostics — fast path (no investigation needed)
    arch_anomalies = detect_architectural_anomalies(signals)

    Logger.info("[CodeIntrospector] Architectural scan: #{length(arch_anomalies)} findings " <>
      "(mailbox_depths=#{length(signals.mailbox_depths)}, " <>
      "bus_types=#{length(signals.bus_event_types)}, " <>
      "bus_handlers=#{map_size(signals.bus_handlers)})")

    arch_anomalies
    |> Enum.reject(fn a -> arch_recently_emitted?(a.hash, state) end)
    |> Enum.reject(fn a -> self_modification_target?(a) end)
    |> Enum.take(2)
    |> Enum.each(fn anomaly ->
      payload = %{
        source_module: "code_introspector",
        diagnostic_type: anomaly.diagnostic_type,
        severity: anomaly.severity,
        topic: anomaly.topic,
        direction: "for",
        grounded_for_count: 1,
        fraudulent_citations: 0,
        supporting: [%{
          source_type: :sourced,
          verification: :verified,
          claim: anomaly.evidence_summary,
          source_title: "CodeIntrospector architectural diagnostic (#{anomaly.diagnostic_type})"
        }],
        opposing: [],
        evidence_summary: anomaly.evidence_summary,
        suggested_fix: anomaly.suggested_fix,
        target_files: anomaly.target_files
      }

      Logger.info("[CodeIntrospector] Emitting architectural finding: #{anomaly.diagnostic_type}")
      Daemon.Events.Bus.emit(:architectural_finding, payload)
      mark_seen(anomaly.hash)
    end)

    persist_state(state)
    state
  end

  defp maybe_reset_daily(state) do
    today = Date.utc_today()
    if state.last_day_reset != today do
      # Reset daily counter AND clear consecutive failures (new day, fresh start)
      %{state | topics_today: 0, last_day_reset: today, consecutive_failures: 0}
    else
      state
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  # ── Signal Collection ───────────────────────────────────────────────

  defp collect_signals do
    %{
      health: safe_call(fn -> Daemon.Agent.HealthTracker.all() end, []),
      crashes: safe_call(fn ->
        case Vaos.Ledger.ML.CrashLearner.get_pitfalls(:daemon_crash_learner) do
          {:ok, pitfalls} -> pitfalls
          _ -> []
        end
      end, []),
      dlq_depth: safe_call(fn -> Daemon.Events.DLQ.depth() end, 0),
      dlq_entries: safe_call(fn -> Daemon.Events.DLQ.entries() end, []),
      circuit_breakers: safe_call(fn -> :ets.tab2list(:daemon_circuit_breakers) end, []),
      cost: safe_call(fn -> Daemon.Agent.CostTracker.get_summary() end, %{}),
      self_diagnosis: safe_call(fn -> Daemon.Investigation.SelfDiagnosis.get_findings() end, []),
      active_learner: safe_call(fn -> Daemon.Agent.ActiveLearner.stats() end, %{}),
      mailbox_depths: safe_call(fn -> collect_mailbox_depths() end, []),
      bus_event_types: safe_call(fn -> Daemon.Events.Bus.event_types() end, []),
      bus_handlers: safe_call(fn -> collect_bus_handlers() end, %{})
    }
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end

  defp collect_mailbox_depths do
    supervisors = [
      Daemon.Supervisors.Infrastructure,
      Daemon.Supervisors.AgentServices
    ]

    for sup <- supervisors,
        {name, pid, _type, _modules} <- safe_call(fn -> Supervisor.which_children(sup) end, []),
        is_pid(pid) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} -> {name, len}
        _ -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp collect_bus_handlers do
    try do
      :ets.tab2list(:daemon_event_handlers)
      |> Enum.group_by(fn
        {event_type, _ref, _fn} -> event_type
        {event_type, _fn} -> event_type
      end)
      |> Map.new(fn {k, v} -> {k, length(v)} end)
    rescue
      _ -> %{}
    end
  end

  # ── Anomaly Correlation ─────────────────────────────────────────────
  # Group co-occurring anomalies that likely share a root cause into single
  # composite investigations. E.g. circuit_tripped + high_error_rate + latency_spike
  # from the same sidecar = one investigation, not three.

  defp correlate_anomalies(anomalies) do
    # Group anomalies by the agent/sidecar they reference
    {grouped, ungroupable} = Enum.split_with(anomalies, fn a ->
      details = a.details
      Map.has_key?(details, :agent) or Map.has_key?(details, :sidecar)
    end)

    by_entity = Enum.group_by(grouped, fn a ->
      Map.get(a.details, :agent) || Map.get(a.details, :sidecar) || "unknown"
    end)

    # Entities with 2+ anomalies become incidents; singletons stay standalone
    {incidents, singletons} = Enum.split_with(by_entity, fn {_entity, group} ->
      length(group) >= 2
    end)

    composite = Enum.map(incidents, fn {entity, group} ->
      build_composite_anomaly(entity, group)
    end)

    standalone = Enum.flat_map(singletons, fn {_entity, group} -> group end)

    {composite, standalone ++ ungroupable}
  end

  defp build_composite_anomaly(entity, anomalies) do
    types = Enum.map(anomalies, & &1.type) |> Enum.uniq()
    max_severity = anomalies |> Enum.map(& &1.severity) |> Enum.max_by(&severity_rank/1)

    details_summary = anomalies
      |> Enum.map(fn a ->
        case a.type do
          :high_error_rate -> "#{Float.round(a.details.error_rate * 100, 1)}% error rate"
          :latency_spike -> "#{Float.round(a.details.avg_latency_ms, 0)}ms avg latency"
          :circuit_tripped -> "circuit breaker open (#{a.details.failures} failures)"
          _ -> to_string(a.type)
        end
      end)
      |> Enum.join(", ")

    types_str = Enum.map_join(types, " + ", &to_string/1)

    %{
      type: :correlated_incident,
      severity: max_severity,
      hash: anomaly_hash(:correlated, entity),
      details: %{entity: entity, types: types, anomaly_count: length(anomalies)},
      topic: "What is the root cause when multiple failure modes co-occur in an Elixir/OTP agent? Entity '#{entity}' shows: #{details_summary}.",
      steering: "Focus on ROOT CAUSE analysis, not individual symptoms. The daemon entity '#{entity}' has simultaneous #{types_str}. These are likely caused by one underlying issue. Look for papers about cascading failure analysis, multi-symptom root cause identification in distributed systems, and correlated failure diagnosis in actor-model architectures."
    }
  end

  # ── Anomaly Detection ───────────────────────────────────────────────

  defp detect_anomalies(signals, baselines) do
    []
    |> detect_high_error_rate(signals, baselines)
    |> detect_latency_spike(signals, baselines)
    |> detect_dlq_growth(signals, baselines)
    |> detect_circuit_tripped(signals)
    |> detect_cost_spike(signals, baselines)
    |> detect_crash_pattern(signals)
    |> detect_learner_degradation(signals)
  end

  # 1. High error rate — per-agent baseline comparison
  defp detect_high_error_rate(acc, signals, baselines) do
    agents = Map.get(signals, :health, [])
    per_agent = Map.get(baselines, "error_rates", %{})

    new_anomalies = Enum.flat_map(agents, fn agent ->
      rate = Map.get(agent, :error_rate, 0.0)
      calls = Map.get(agent, :total_calls, 0)
      name = Map.get(agent, :agent, "unknown")
      agent_window = Map.get(per_agent, name, [])

      if rate > 0.15 and calls > 5 and z_anomalous?(rate, agent_window) do
        severity = if rate > 0.30, do: :high, else: :medium
        [%{
          type: :high_error_rate,
          severity: severity,
          hash: anomaly_hash(:high_error_rate, name),
          details: %{agent: name, error_rate: rate, total_calls: calls},
          topic: "How can error recovery strategies be improved for high-failure-rate agents in distributed Elixir/OTP systems? Agent '#{name}' has a #{Float.round(rate * 100, 1)}% error rate across #{calls} calls.",
          steering: "Focus on Elixir/OTP patterns. The daemon uses GenServer-based agents with supervised restarts. Look for papers about fault tolerance in actor-model systems, adaptive retry strategies, error classification for selective recovery, and graceful degradation patterns."
        }]
      else
        []
      end
    end)

    acc ++ new_anomalies
  end

  # 2. Latency spike — per-agent baseline comparison
  defp detect_latency_spike(acc, signals, baselines) do
    agents = Map.get(signals, :health, [])
    per_agent = Map.get(baselines, "avg_latencies", %{})

    new = Enum.flat_map(agents, fn agent ->
      latency = Map.get(agent, :avg_latency_ms, 0.0) || 0.0
      calls = Map.get(agent, :total_calls, 0)
      name = Map.get(agent, :agent, "unknown")
      agent_window = Map.get(per_agent, name, [])

      if calls > 10 and z_anomalous?(latency, agent_window) do
        severity = if latency > 5000, do: :high, else: :medium
        [%{
          type: :latency_spike,
          severity: severity,
          hash: anomaly_hash(:latency_spike, name),
          details: %{agent: name, avg_latency_ms: latency, total_calls: calls},
          topic: "What causes GenServer response latency spikes in Elixir/OTP systems? Agent '#{name}' averages #{Float.round(latency, 0)}ms per call.",
          steering: "Focus on Elixir/OTP GenServer bottlenecks. The daemon uses ETS for caching, GenServers for stateful services, and Task for async work. Look for papers about message queue congestion, ETS vs process-state performance, and BEAM scheduler optimization."
        }]
      else
        []
      end
    end)

    acc ++ new
  end

  # 3. DLQ growth — stable hash (type only, not depth value)
  defp detect_dlq_growth(acc, signals, baselines) do
    depth = Map.get(signals, :dlq_depth, 0)

    if depth > 5 and z_anomalous?(depth * 1.0, Map.get(baselines, "dlq_depths", [])) do
      severity = if depth > 20, do: :high, else: :medium
      entries = Map.get(signals, :dlq_entries, [])
      event_types = entries |> Enum.map(& Map.get(&1, :event_type, "unknown")) |> Enum.uniq() |> Enum.take(3) |> Enum.join(", ")

      acc ++ [%{
        type: :dlq_growth,
        severity: severity,
        hash: anomaly_hash(:dlq_growth, "active"),
        details: %{depth: depth, event_types: event_types},
        topic: "How can dead letter queue reliability be improved in event-driven Elixir systems? DLQ depth is #{depth} with event types: #{event_types}.",
        steering: "Focus on event bus reliability patterns. The daemon uses goldrush-compiled event bus with DLQ for failed handlers. Look for papers about event-driven architecture reliability, retry strategies with exponential backoff, event poisoning detection, and DLQ processing patterns."
      }]
    else
      acc
    end
  end

  # 4. Circuit breaker tripped
  defp detect_circuit_tripped(acc, signals) do
    breakers = Map.get(signals, :circuit_breakers, [])

    new = Enum.flat_map(breakers, fn
      {name, :open, failures, _ts} ->
        severity = if failures > 10, do: :high, else: :medium
        name_str = inspect(name)
        [%{
          type: :circuit_tripped,
          severity: severity,
          hash: anomaly_hash(:circuit_tripped, name_str),
          details: %{sidecar: name_str, failures: failures, state: :open},
          topic: "How can circuit breaker recovery strategies be optimized in distributed Elixir systems? Sidecar '#{name_str}' has tripped with #{failures} consecutive failures.",
          steering: "Focus on Elixir/OTP patterns. The daemon uses a per-sidecar circuit breaker (closed->open->half_open) backed by ETS. Look for papers about adaptive circuit breaker thresholds, cascading failure prevention, and self-healing distributed systems."
        }]
      _ -> []
    end)

    acc ++ new
  end

  # 5. Cost spike
  defp detect_cost_spike(acc, signals, baselines) do
    cost = Map.get(signals, :cost, %{})
    daily = Map.get(cost, :daily_spent_cents, 0)
    limit = Map.get(cost, :daily_limit_cents, 1)
    pct = if limit > 0, do: daily / limit, else: 0.0

    if (pct > 0.80 or z_anomalous?(daily * 1.0, Map.get(baselines, "cost_daily", []))) and daily > 0 do
      severity = if pct > 0.90, do: :high, else: :medium
      acc ++ [%{
        type: :cost_spike,
        severity: severity,
        hash: anomaly_hash(:cost_spike, "daily_#{Date.utc_today()}"),
        details: %{daily_spent_cents: daily, daily_limit_cents: limit, pct: Float.round(pct * 100, 1)},
        topic: "How can LLM API costs be optimized in autonomous agent systems? Daily spend is at #{Float.round(pct * 100, 1)}% of the limit (#{daily} cents / #{limit} cents).",
        steering: "Focus on practical cost optimization. The daemon uses 7+ LLM providers with per-provider token cost tracking. Look for papers about model cascade selection (cheap models first, escalate to expensive), prompt compression, caching strategies for LLM calls, and token budget allocation."
      }]
    else
      acc
    end
  end

  # 6. Crash pattern (not already in SelfDiagnosis)
  defp detect_crash_pattern(acc, signals) do
    crashes = Map.get(signals, :crashes, [])
    diagnosis_findings = Map.get(signals, :self_diagnosis, [])

    diagnosed_hashes = MapSet.new(
      Enum.map(diagnosis_findings, fn f -> Map.get(f, :pattern_hash) end)
    )

    new = Enum.flat_map(crashes, fn pitfall ->
      count = Map.get(pitfall, :count, 0)
      summary = Map.get(pitfall, :summary, "")
      p_hash = :erlang.phash2(Map.get(pitfall, :pattern, summary))

      if count >= 5 and not MapSet.member?(diagnosed_hashes, p_hash) do
        severity = if count >= 10, do: :high, else: :medium
        [%{
          type: :crash_pattern,
          severity: severity,
          hash: anomaly_hash(:crash_pattern, summary),
          details: %{count: count, summary: summary},
          topic: "What causes recurring '#{String.slice(summary, 0, 80)}' crashes in Elixir/OTP applications? This pattern has occurred #{count} times.",
          steering: "Focus on BEAM/OTP crash analysis. The daemon uses supervised GenServers, Task.async, and process monitoring. Look for papers about systematic crash diagnosis in actor-model systems, supervision tree optimization, and crash-resistant process patterns."
        }]
      else
        []
      end
    end)

    acc ++ new
  end

  # 7. Learner degradation
  defp detect_learner_degradation(acc, signals) do
    learner = Map.get(signals, :active_learner, %{})
    skips = Map.get(learner, :consecutive_skips, 0)
    arms = Map.get(learner, :arms, %{})

    anomalies = []

    anomalies = if skips >= 4 do
      severity = if skips >= 8, do: :high, else: :medium
      anomalies ++ [%{
        type: :learner_degradation,
        severity: severity,
        hash: anomaly_hash(:learner_degradation, "skips_#{div(skips, 4) * 4}"),
        details: %{consecutive_skips: skips},
        topic: "How can autonomous investigation topic quality be improved when consecutive investigations are being rejected? #{skips} consecutive investigations fell below the adaptive quality threshold.",
        steering: "Focus on research quality improvement in autonomous systems. The daemon uses Thompson Sampling with quality-based arm updates. Look for papers about adaptive quality thresholds, topic selection diversity, and exploration-exploitation in research automation."
      }]
    else
      anomalies
    end

    anomalies = Enum.reduce(arms, anomalies, fn {arm_name, arm}, inner_acc ->
      alpha = Map.get(arm, :alpha, 1.0)
      beta = Map.get(arm, :beta, 1.0)
      mean = alpha / (alpha + beta)

      if mean < 0.15 and (alpha + beta) > 5 do
        inner_acc ++ [%{
          type: :learner_degradation,
          severity: :medium,
          hash: anomaly_hash(:learner_degradation, "arm_#{arm_name}"),
          details: %{arm: arm_name, mean: Float.round(mean, 3), alpha: alpha, beta: beta},
          topic: "How can #{arm_name} topic source quality be improved in multi-armed bandit research systems? The '#{arm_name}' arm has degraded to mean=#{Float.round(mean, 3)}.",
          steering: "Focus on topic quality from #{arm_name} source. The daemon uses Thompson Sampling across multiple topic sources (emergent questions, policy suggestions, synthesis gaps, code introspection). Look for papers about source quality improvement, bandit arm rehabilitation, and adaptive topic generation."
        }]
      else
        inner_acc
      end
    end)

    acc ++ anomalies
  end

  # ── Architectural Anomaly Detection ─────────────────────────────────
  # These detect structural violations (Shannon, Ashby, Wiener) that don't
  # need paper research — they go directly to InsightActuator via fast path.

  defp detect_architectural_anomalies(signals) do
    []
    |> detect_shannon_violations(signals)
    |> detect_ashby_violations(signals)
    |> detect_wiener_violations(signals)
  end

  # Shannon: channel saturation — mailbox depth exceeds processing capacity
  defp detect_shannon_violations(acc, signals) do
    overloaded =
      signals.mailbox_depths
      |> Enum.filter(fn {_name, len} -> len > @mailbox_threshold end)
      |> Enum.sort_by(fn {_name, len} -> -len end)

    if overloaded == [] do
      acc
    else
      {name, len} = hd(overloaded)
      severity = if len > @mailbox_threshold * 3, do: :high, else: :medium

      anomaly = %{
        diagnostic_type: :shannon_violation,
        severity: severity,
        hash: anomaly_hash(:shannon_violation, inspect(name)),
        topic: "Shannon violation: GenServer #{inspect(name)} mailbox depth #{len} exceeds capacity",
        evidence_summary: "Process #{inspect(name)} has #{len} pending messages " <>
          "(threshold: #{@mailbox_threshold}). " <>
          "#{length(overloaded)} total overloaded processes: " <>
          Enum.map_join(overloaded, ", ", fn {n, l} -> "#{inspect(n)}=#{l}" end),
        suggested_fix: "Investigate why #{inspect(name)} is processing slower than message arrival rate. " <>
          "Consider: adding backpressure, increasing processing throughput, or shedding low-priority work.",
        target_files: [],
        overloaded_processes: overloaded
      }
      acc ++ [anomaly]
    end
  end

  # Ashby: requisite variety — recurring crash patterns without specific handlers
  defp detect_ashby_violations(acc, signals) do
    pitfalls = case signals.crashes do
      {:ok, list} when is_list(list) -> list
      list when is_list(list) -> list
      _ -> []
    end

    # Only count patterns in the Ashby range: recurring enough to signal a variety
    # deficit, but below the metric detector's threshold (count >= 5) to avoid
    # overlapping with detect_crash_pattern which spawns full investigations.
    recurring = Enum.filter(pitfalls, fn p ->
      count = Map.get(p, :count, 0)
      count >= @ashby_min_occurrences and count < 5
    end)

    if recurring == [] do
      acc
    else
      total = length(recurring)
      worst = Enum.max_by(recurring, fn p -> Map.get(p, :count, 0) end)
      severity = if total >= 5, do: :high, else: :medium

      anomaly = %{
        diagnostic_type: :ashby_violation,
        severity: severity,
        hash: anomaly_hash(:ashby_violation, "pitfalls_#{total}"),
        topic: "Ashby violation: #{total} recurring crash patterns without specific handlers",
        evidence_summary: "CrashLearner shows #{total} distinct failure patterns recurring #{@ashby_min_occurrences}+ times. " <>
          "Worst: \"#{String.slice(Map.get(worst, :summary, ""), 0, 100)}\" (#{Map.get(worst, :count, 0)}x). " <>
          "Each pattern represents a failure mode the system handles generically rather than specifically.",
        suggested_fix: "Add targeted rescue/catch clauses or error handlers for each recurring crash pattern. " <>
          "Patterns: " <> Enum.map_join(Enum.take(recurring, 5), "; ", fn p ->
            "\"#{String.slice(Map.get(p, :pattern, ""), 0, 80)}\" (#{Map.get(p, :count, 0)}x)"
          end),
        target_files: [],
        unhandled_patterns: Enum.map(recurring, fn p -> Map.get(p, :pattern, "") end)
      }
      acc ++ [anomaly]
    end
  end

  # Wiener: open feedback loops — event types with zero subscribers
  defp detect_wiener_violations(acc, signals) do
    event_types = signals.bus_event_types
    handler_map = signals.bus_handlers

    unsubscribed = Enum.filter(event_types, fn type ->
      Map.get(handler_map, type, 0) <= @wiener_min_subscribers
    end)

    # Exclude event types that are inherently fire-and-forget
    expected_no_handler = [:channel_connected, :channel_disconnected, :channel_error]
    true_violations = unsubscribed -- expected_no_handler

    if true_violations == [] do
      acc
    else
      severity = if length(true_violations) >= 3, do: :high, else: :medium

      anomaly = %{
        diagnostic_type: :wiener_violation,
        severity: severity,
        hash: anomaly_hash(:wiener_violation, "open_loops_#{length(true_violations)}"),
        topic: "Wiener violation: #{length(true_violations)} event types with no subscribers (open feedback loops)",
        evidence_summary: "Event types emitted on the bus with zero handlers: #{inspect(true_violations)}. " <>
          "These signals are produced but never consumed — information flows into the void " <>
          "with no feedback path. Total event types: #{length(event_types)}, " <>
          "subscribed: #{length(event_types) - length(unsubscribed)}.",
        suggested_fix: "For each unsubscribed event type, either: (1) add a handler that tracks outcomes, " <>
          "or (2) remove the event emission if the signal serves no purpose. " <>
          "Unsubscribed: #{inspect(true_violations)}",
        target_files: ["lib/daemon/events/bus.ex"],
        open_loops: true_violations
      }
      acc ++ [anomaly]
    end
  end

  # ── Baseline & Z-Score ──────────────────────────────────────────────

  defp update_baselines(baselines, signals) do
    health = Map.get(signals, :health, [])
    dlq_depth = Map.get(signals, :dlq_depth, 0)
    cost = Map.get(signals, :cost, %{})
    daily_cost = Map.get(cost, :daily_spent_cents, 0)

    # Per-agent baselines for error rates and latencies
    per_agent_errors = Map.get(baselines, "error_rates", %{})
    per_agent_latencies = Map.get(baselines, "avg_latencies", %{})

    {per_agent_errors, per_agent_latencies} = Enum.reduce(health, {per_agent_errors, per_agent_latencies}, fn agent, {err_acc, lat_acc} ->
      name = Map.get(agent, :agent, "unknown")
      rate = Map.get(agent, :error_rate, 0.0)
      latency = Map.get(agent, :avg_latency_ms, 0.0) || 0.0

      err_acc = Map.update(err_acc, name, [rate], fn window -> append_window(window, rate) end)
      lat_acc = Map.update(lat_acc, name, [latency], fn window -> append_window(window, latency) end)
      {err_acc, lat_acc}
    end)

    %{
      "error_rates" => per_agent_errors,
      "avg_latencies" => per_agent_latencies,
      "dlq_depths" => append_window(Map.get(baselines, "dlq_depths", []), dlq_depth * 1.0),
      "cost_daily" => append_window(Map.get(baselines, "cost_daily", []), daily_cost * 1.0)
    }
  end

  defp append_window(window, value) do
    (window ++ [value]) |> Enum.take(-@baseline_window)
  end

  # Cold-start suppression: don't flag as anomalous until we have enough data
  defp z_anomalous?(_value, window) when length(window) < @cold_start_min_samples, do: false

  defp z_anomalous?(value, window) do
    n = length(window)
    mean = Enum.sum(window) / n
    variance = Enum.sum(Enum.map(window, fn v -> (v - mean) * (v - mean) end)) / n
    std_dev = :math.sqrt(max(variance, 0.0001))
    z = (value - mean) / std_dev
    z > @anomaly_z_threshold
  end

  # ── Resolution Tracking ─────────────────────────────────────────────
  # After investigation completes, track whether the triggering anomaly resolves.
  # If it doesn't fire for @resolution_window_polls consecutive polls → resolved.
  # If it fires again → enrich next investigation's steering with previous findings.

  defp update_resolution_tracking(state, current_anomaly_types) do
    resolution_map = state.resolution_map
    resolutions_total = state.resolutions_total

    {updated_map, new_resolutions} = Enum.reduce(resolution_map, {%{}, 0}, fn {atype, entry}, {map_acc, res_acc} ->
      if MapSet.member?(current_anomaly_types, atype) do
        # Anomaly still firing — reset absence counter
        {Map.put(map_acc, atype, %{entry | polls_absent: 0}), res_acc}
      else
        new_absent = entry.polls_absent + 1
        if new_absent >= @resolution_window_polls do
          # Resolved! Super-reward the :introspection arm
          Logger.info("[CodeIntrospector] Resolution: #{atype} resolved after investigation (absent #{new_absent} polls)")
          super_reward_introspection_arm()
          {map_acc, res_acc + 1}
        else
          {Map.put(map_acc, atype, %{entry | polls_absent: new_absent}), res_acc}
        end
      end
    end)

    %{state | resolution_map: updated_map, resolutions_total: resolutions_total + new_resolutions}
  end

  defp super_reward_introspection_arm do
    try do
      # Read current introspection arm and apply bonus alpha
      case :ets.lookup(@outcomes_table, "__introspection_super_reward__") do
        _ ->
          # Write a synthetic high-quality outcome to boost the arm
          :ets.insert(@outcomes_table, {"__introspection_resolution_#{System.system_time(:second)}__", %{
            predicted_ig: 0.9,
            actual_quality: 0.95,
            quality_components: %{verification_rate: 1.0, grounded_ratio: 1.0, fraud_penalty: 0.0, certainty: 0.9, papers_found: 1, total_evidence: 1, total_sourced: 1, count_verified: 1},
            source_topic: "CodeIntrospector resolution reward",
            source: :introspection,
            depth: 0,
            steering_bottleneck: nil,
            measurement_version: 2,
            added_at: System.system_time(:second)
          }})
          Logger.info("[CodeIntrospector] Super-reward: boosted :introspection arm for anomaly resolution")
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp build_resolution_steering(state, anomaly_type) do
    case Map.get(state.resolution_map, anomaly_type) do
      %{findings_summary: summary} when is_binary(summary) and summary != "" ->
        """
        PRIOR INVESTIGATION CONTEXT: A previous investigation into this same anomaly type found: #{String.slice(summary, 0, 300)}. \
        The anomaly persists despite this research. Focus on DEEPER root causes or alternative solutions that the previous investigation may have missed. \
        Do NOT repeat surface-level analysis.
        """
      _ -> ""
    end
  end

  # ── Investigation Result Handling ───────────────────────────────────

  defp handle_investigation_result(state, hash, anomaly_type, result) do
    state = record_finding(state, hash, result, anomaly_type)

    case result do
      {:error, _} ->
        %{state | consecutive_failures: state.consecutive_failures + 1}

      _ ->
        # Success — reset failure counter, update resolution map
        summary = extract_finding_summary(result)

        resolution_map = if anomaly_type do
          Map.put(state.resolution_map, anomaly_type, %{
            findings_summary: summary,
            investigated_at: DateTime.utc_now(),
            polls_absent: 0,
            anomaly_hash: hash
          })
        else
          state.resolution_map
        end

        %{state | consecutive_failures: 0, resolution_map: resolution_map}
    end
  end

  defp extract_finding_summary(result) when is_map(result) do
    summary = Map.get(result, :summary) || Map.get(result, "summary") || ""
    direction = Map.get(result, :direction) || Map.get(result, "direction") || ""
    topic = Map.get(result, :topic) || Map.get(result, "topic") || ""

    cond do
      summary != "" -> "#{direction}: #{String.slice(summary, 0, 200)}"
      topic != "" -> "Investigated: #{String.slice(topic, 0, 200)}"
      true -> "Investigation completed"
    end
  end

  defp extract_finding_summary({:ok, result}) when is_map(result), do: extract_finding_summary(result)
  defp extract_finding_summary(_), do: "Investigation completed"

  # ── Topic Generation & Investigation Spawning ───────────────────────

  defp spawn_if_capacity(state, anomaly) do
    if length(state.active_tasks) >= @max_concurrent do
      Logger.debug("[CodeIntrospector] At capacity (#{@max_concurrent}), deferring anomaly #{anomaly.type}")
      state
    else
      spawn_investigation(state, anomaly)
    end
  end

  defp spawn_investigation(state, anomaly) do
    hash = anomaly.hash
    topic = anomaly.topic
    ig = severity_to_ig(anomaly.severity)

    # Enrich steering with previous findings if this anomaly type was investigated before
    resolution_steering = build_resolution_steering(state, anomaly.type)
    steering = if resolution_steering != "" do
      anomaly.steering <> "\n\n" <> resolution_steering <> code_action_suffix()
    else
      anomaly.steering <> code_action_suffix()
    end

    # Record prediction in ActiveLearner's outcomes ETS
    record_introspection_prediction(topic, ig)

    # Mark investigated
    now = DateTime.utc_now()
    mark_seen(hash)

    parent = self()
    atype = anomaly.type

    metadata = %{
      "source_module" => "code_introspector",
      "anomaly_type" => to_string(anomaly.type),
      "anomaly_hash" => hash,
      "severity" => to_string(anomaly.severity)
    }

    {_pid, ref} = spawn_monitor(fn ->
      result = try do
        Daemon.Tools.Builtins.Investigate.execute(%{"topic" => topic, "steering" => steering, "metadata" => metadata})
      rescue
        e ->
          Logger.warning("[CodeIntrospector] Investigation failed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          Logger.warning("[CodeIntrospector] Investigation exited: #{inspect(reason)}")
          {:error, inspect(reason)}
      end

      send(parent, {:introspection_complete, hash, atype, result})
    end)

    Logger.info("[CodeIntrospector] Spawned investigation: #{anomaly.type} — #{String.slice(topic, 0, 80)}...")

    investigated = Map.put(state.investigated_anomalies, hash, now)

    %{state |
      active_tasks: [{ref, hash, now, atype} | state.active_tasks],
      investigated_anomalies: investigated,
      topics_today: state.topics_today + 1,
      total_topics: state.total_topics + 1
    }
  end

  defp code_action_suffix do
    "\n\nACTION REQUIRED: After reviewing the research, provide SPECIFIC code changes " <>
    "for the vaos-daemon Elixir/OTP codebase. Reference actual module paths (lib/daemon/...), " <>
    "function names, and config values. The goal is a concrete, implementable code improvement — " <>
    "not a literature review."
  end

  defp record_introspection_prediction(topic, ig) do
    key = topic
      |> then(fn t -> "investigate " <> t end)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    try do
      :ets.insert(@outcomes_table, {key, %{
        predicted_ig: ig,
        actual_quality: nil,
        quality_components: nil,
        source_topic: "CodeIntrospector anomaly analysis",
        source: :introspection,
        depth: 0,
        steering_bottleneck: nil,
        measurement_version: 2,
        added_at: System.system_time(:second)
      }})
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp severity_to_ig(:high), do: 0.95
  defp severity_to_ig(:medium), do: 0.75
  defp severity_to_ig(_), do: 0.60

  # ── Finding Storage ─────────────────────────────────────────────────

  defp record_finding(state, hash, result, anomaly_type) do
    finding = %{
      hash: hash,
      anomaly_type: anomaly_type,
      result: result,
      timestamp: DateTime.utc_now()
    }

    findings = Enum.take([finding | state.findings], @max_findings)
    %{state | findings: findings}
  end

  # ── Dedup & Cooldown ────────────────────────────────────────────────

  defp recently_investigated?(state, hash, now) do
    case Map.get(state.investigated_anomalies, hash) do
      nil -> false
      last_at ->
        DateTime.diff(now, last_at, :second) < @cooldown_seconds
    end
  end

  defp prune_investigated(state, now) do
    # Use max cooldown to avoid pruning architectural entries (24hr) at metric cadence (4hr)
    max_cooldown = max(@cooldown_seconds, @arch_cooldown_seconds)
    pruned = state.investigated_anomalies
      |> Enum.filter(fn {_hash, last_at} ->
        DateTime.diff(now, last_at, :second) < max_cooldown * 2
      end)
      |> Map.new()

    %{state | investigated_anomalies: pruned}
  end

  defp seen_fresh?(hash) do
    key = to_string(hash)
    case :ets.lookup(@seen_table, key) do
      [{^key, seen_at}] ->
        age = System.system_time(:second) - seen_at
        if age > @seen_ttl_seconds do
          :ets.delete(@seen_table, key)
          false
        else
          true
        end
      _ -> false
    end
  rescue
    _ -> false
  end

  defp mark_seen(hash) do
    key = to_string(hash)
    :ets.insert(@seen_table, {key, System.system_time(:second)})
  rescue
    _ -> :ok
  end

  # ── Architectural Self-Protection ────────────────────────────────────

  defp arch_recently_emitted?(hash, state) do
    case Map.get(state.investigated_anomalies, hash) do
      nil -> false
      dt -> DateTime.diff(DateTime.utc_now(), dt) < @arch_cooldown_seconds
    end
  end

  defp self_modification_target?(anomaly) do
    targets = Map.get(anomaly, :target_files, [])
    Enum.any?(targets, fn path ->
      Enum.any?(@self_modification_blocked, fn blocked ->
        String.contains?(path, blocked)
      end)
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp anomaly_hash(type, identifier) do
    :erlang.phash2({type, identifier})
  end

  defp severity_rank(:high), do: 3
  defp severity_rank(:medium), do: 2
  defp severity_rank(_), do: 1

  defp summarize_baselines(baselines) do
    error_counts = baselines |> Map.get("error_rates", %{}) |> Map.values() |> Enum.map(&length/1)
    latency_counts = baselines |> Map.get("avg_latencies", %{}) |> Map.values() |> Enum.map(&length/1)

    %{
      agents_tracked: length(error_counts),
      error_rates_min_samples: if(error_counts == [], do: 0, else: Enum.min(error_counts)),
      latencies_min_samples: if(latency_counts == [], do: 0, else: Enum.min(latency_counts)),
      dlq_depths_count: length(Map.get(baselines, "dlq_depths", [])),
      cost_daily_count: length(Map.get(baselines, "cost_daily", []))
    }
  end

  defp ensure_ets_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
      _ ->
        table
    end
  rescue
    _ -> table
  end

  # ── Persistence ─────────────────────────────────────────────────────

  defp persistence_path do
    config_dir = Application.get_env(:daemon, :config_dir, "~/.daemon") |> Path.expand()
    Path.join(config_dir, @persistence_file)
  end

  defp persist_state(state) do
    investigated = state.investigated_anomalies
      |> Enum.map(fn {hash, dt} -> %{"hash" => hash, "at" => DateTime.to_iso8601(dt)} end)

    resolution = state.resolution_map
      |> Enum.map(fn {type, entry} ->
        %{
          "type" => to_string(type),
          "findings_summary" => Map.get(entry, :findings_summary, ""),
          "investigated_at" => DateTime.to_iso8601(entry.investigated_at),
          "polls_absent" => entry.polls_absent,
          "anomaly_hash" => entry.anomaly_hash
        }
      end)

    data = %{
      "version" => 2,
      "total_topics" => state.total_topics,
      "baselines" => state.baselines,
      "investigated_anomalies" => investigated,
      "resolution_map" => resolution,
      "resolutions_total" => state.resolutions_total
    }

    path = persistence_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    e -> Logger.warning("[CodeIntrospector] Failed to persist state: #{Exception.message(e)}")
  end

  defp load_persisted_state do
    case File.read(persistence_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"version" => _} = data} -> data
          _ -> %{}
        end
      {:error, _} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp restore_investigated(persisted) do
    persisted
    |> Map.get("investigated_anomalies", [])
    |> Enum.reduce(%{}, fn entry, acc ->
      hash = Map.get(entry, "hash")
      case DateTime.from_iso8601(Map.get(entry, "at", "")) do
        {:ok, dt, _} -> Map.put(acc, hash, dt)
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  end

  defp restore_resolution_map(persisted) do
    persisted
    |> Map.get("resolution_map", [])
    |> Enum.reduce(%{}, fn entry, acc ->
      type = case Map.get(entry, "type", "") do
        "high_error_rate" -> :high_error_rate
        "latency_spike" -> :latency_spike
        "dlq_growth" -> :dlq_growth
        "circuit_tripped" -> :circuit_tripped
        "cost_spike" -> :cost_spike
        "crash_pattern" -> :crash_pattern
        "learner_degradation" -> :learner_degradation
        "correlated_incident" -> :correlated_incident
        "shannon_violation" -> :shannon_violation
        "ashby_violation" -> :ashby_violation
        "wiener_violation" -> :wiener_violation
        _ -> nil
      end

      if type do
        case DateTime.from_iso8601(Map.get(entry, "investigated_at", "")) do
          {:ok, dt, _} ->
            Map.put(acc, type, %{
              findings_summary: Map.get(entry, "findings_summary", ""),
              investigated_at: dt,
              polls_absent: Map.get(entry, "polls_absent", 0),
              anomaly_hash: Map.get(entry, "anomaly_hash")
            })
          _ -> acc
        end
      else
        acc
      end
    end)
  rescue
    _ -> %{}
  end
end
