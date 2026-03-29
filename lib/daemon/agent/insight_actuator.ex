defmodule Daemon.Agent.InsightActuator do
  @moduledoc """
  Closes the investigation → code change → PR loop.

  Subscribes to `:investigation_complete` events, classifies findings through
  a two-tier filter (rule-based pre-filter + LLM classifier), and dispatches
  code-actionable insights to `Daemon.Agent.Orchestrator.execute/3` with a
  PACT strategy prompt that creates draft PRs.

  **Two-tier classification**:
  - Tier 1: Rule-based pre-filter — matches topic against daemon subsystem
    keywords and checks evidence quality. Zero tokens. ~90% rejected here.
  - Tier 2: LLM classifier — structured JSON output determining actionability,
    change type, risk level, and target files. One call, ~500 tokens.

  **Thompson Sampling on actuation arms**:
  Arms = `{topic_cluster, change_type}` pairs. Two-phase reward:
  1. Immediate: `mix test` pass → 0.3 partial reward
  2. Delayed: PR merged=1.0, modified-then-merged=0.7, rejected=0.2, abandoned=0.0

  The bandit LEARNS which findings produce good PRs, replacing brittle keyword
  filtering with data-driven selection.

  **Code-level safety gate**: After orchestration completes, `verify_pr_safety/1`
  checks the diff against blocked path patterns. Violations cause branch deletion
  and zero reward to the arm.

  **Rate limiting**: 1 PR/hour, 5/day, max 3 concurrent orchestrations.

  **Persistence**: State (arms, PR history, rejections) persisted to
  `<config_dir>/insight_actuator_state.json` and survives restarts.
  """
  use GenServer
  require Logger

  alias Daemon.Investigation.Retrospector
  alias Daemon.Investigation.PromptSelector
  alias Daemon.Governance.Approvals
  alias Daemon.Intelligence.DecisionJournal
  alias MiosaProviders.Registry, as: Providers

  # ── Constants ────────────────────────────────────────────────────

  @quality_threshold 0.5
  @subscribe_delay_ms 10_000
  @rate_limit_ms 3_600_000       # 1 hour between PRs
  @daily_pr_cap 5
  @max_pending 3
  @persistence_file "insight_actuator_state.json"
  @daemon_repo "jmanhype/vaos-daemon"
  @max_completed 50
  @max_rejected 50

  # Thompson Sampling for PR actuation
  @actuation_threshold 0.3
  @pr_poll_interval_ms 3_600_000  # 1 hour
  @immediate_reward 0.3
  @starvation_limit 5            # Force-accept after N consecutive Thompson rejections

  # Code-level safety gate — blocked path patterns (as strings, compiled once in init)
  @blocked_path_strings [
    "application\\.ex$",
    "supervisors/",
    "security/",
    "agent/loop\\.ex$",
    "runtime\\.exs$",
    "mix\\.(exs|lock)$"
  ]

  # ETS dedup table
  @seen_topics_table :insight_actuator_seen_topics
  @seen_ttl_seconds 24 * 3600    # 24 hours — shorter than ActiveLearner since these are code changes

  # Daemon subsystem keywords for Tier 1 pre-filter (seed data for arm init)
  @daemon_subsystems %{
    "agent_loop" => ["react loop", "reasoning loop", "tool call", "doom loop"],
    "investigation" => ["citation verification", "evidence quality", "source scoring"],
    "thompson_sampling" => ["thompson sampling", "multi-armed bandit", "beta distribution"],
    "event_bus" => ["event bus", "goldrush", "pub sub", "event dispatch"],
    "circuit_breaker" => ["circuit breaker", "failure detection", "cascading failure"],
    "prompt_engineering" => ["prompt engineering", "system prompt", "chain of thought"],
    "rate_limiting" => ["rate limit", "backoff", "retry", "throttle"],
    "error_handling" => ["error recovery", "fault tolerance", "supervision tree"],
    "scheduling" => ["task scheduling", "heartbeat", "cron"],
    "orchestration" => ["multi-agent", "task decomposition", "swarm"]
  }

  @change_types ~w(config_change bug_fix optimization test new_feature refactor)a
  @risk_levels ~w(trivial low medium high critical)a

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats about InsightActuator activity."
  @spec stats() :: map()
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> empty_stats()
    catch
      :exit, _ -> empty_stats()
    end
  end

  @doc "Disable InsightActuator — stops processing new findings."
  @spec disable() :: :ok
  def disable, do: GenServer.cast(__MODULE__, :disable)

  @doc "Enable InsightActuator — resumes processing findings."
  @spec enable() :: :ok
  def enable, do: GenServer.cast(__MODULE__, :enable)

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    persisted = load_persisted_state()

    # Compile blocked path regexes once at init, store in state
    blocked_regexes = Enum.map(@blocked_path_strings, &Regex.compile!/1)

    # ETS dedup table (same pattern as ActiveLearner)
    ensure_ets_table(@seen_topics_table)

    Process.send_after(self(), :subscribe, @subscribe_delay_ms)
    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_interval_ms)

    state = %{
      event_ref: nil,
      arch_event_ref: nil,
      prs_created: Map.get(persisted, "prs_created", 0),
      prs_today: 0,
      last_pr_at: nil,
      last_day_reset: Date.utc_today(),
      pending_tasks: [],           # [{task_ref, topic, change_type, started_at, quality}]
      completed_prs: parse_pr_list(Map.get(persisted, "completed_prs", [])),
      rejected_findings: parse_rejection_list(Map.get(persisted, "rejected_findings", [])),
      arms: parse_arms(Map.get(persisted, "arms", %{})),
      blocked_regexes: blocked_regexes,
      consecutive_thompson_skips: 0,
      enabled: Map.get(persisted, "enabled", true)
    }

    Logger.info("[InsightActuator] Started (enabled=#{state.enabled}, prs_created=#{state.prs_created})")
    {:ok, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    ref = Daemon.Events.Bus.register_handler(:investigation_complete, &handle_event/1)
    arch_ref = Daemon.Events.Bus.register_handler(:architectural_finding, &handle_arch_event/1)
    Logger.info("[InsightActuator] Subscribed to :investigation_complete and :architectural_finding events")
    {:noreply, %{state | event_ref: ref, arch_event_ref: arch_ref}}
  end

  def handle_info({:insight_candidate, data}, state) do
    state = maybe_reset_daily_count(state)

    if state.enabled do
      state = process_finding(data, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:arch_candidate, data}, state) do
    state = maybe_reset_daily_count(state)

    if state.enabled do
      state = process_architectural_finding(data, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:orchestration_complete, task_ref, result}, state) do
    state = handle_orchestration_result(task_ref, result, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.pending_tasks, fn {task_ref, _, _, _, _} -> task_ref == ref end) do
      {^ref, topic, _, _, _} ->
        Logger.warning("[InsightActuator] Orchestration crashed for '#{topic}': #{inspect(reason)}")
        pending = Enum.reject(state.pending_tasks, fn {r, _, _, _, _} -> r == ref end)
        {:noreply, %{state | pending_tasks: pending}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:poll_pr_outcomes, state) do
    state = poll_pr_outcomes(state)
    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_interval_ms)
    {:noreply, state}
  end

  # Handle PR outcome from Decision Journal (unified polling)
  def handle_info({:journal_pr_outcome, branch, reward}, state) do
    matching_pr = Enum.find(state.completed_prs, fn p -> Map.get(p, :branch) == branch end)

    if matching_pr do
      arm_key = Map.get(matching_pr, :arm_key)
      if arm_key do
        Logger.info("[InsightActuator] Journal PR outcome for #{branch}: reward=#{reward}")
        state = record_delayed_reward(arm_key, reward, state)
        persist_state(state)
        {:noreply, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    reply = %{
      prs_created: state.prs_created,
      prs_today: state.prs_today,
      last_pr_at: state.last_pr_at,
      pending_count: length(state.pending_tasks),
      recent_prs: Enum.take(state.completed_prs, 10),
      recent_rejections: Enum.take(state.rejected_findings, 10),
      arms: summarize_arms(state.arms),
      consecutive_thompson_skips: state.consecutive_thompson_skips,
      enabled: state.enabled
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:disable, state) do
    Logger.info("[InsightActuator] Disabled")
    state = %{state | enabled: false}
    persist_state(state)
    {:noreply, state}
  end

  def handle_cast(:enable, state) do
    Logger.info("[InsightActuator] Enabled")
    state = %{state | enabled: true}
    persist_state(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{event_ref: ref} = state) when not is_nil(ref) do
    persist_state(state)
    Daemon.Events.Bus.unregister_handler(:investigation_complete, ref)
    arch_ref = Map.get(state, :arch_event_ref)
    if arch_ref, do: Daemon.Events.Bus.unregister_handler(:architectural_finding, arch_ref)
    :ok
  end

  def terminate(_reason, state) do
    persist_state(state)
    arch_ref = Map.get(state, :arch_event_ref)
    if arch_ref, do: Daemon.Events.Bus.unregister_handler(:architectural_finding, arch_ref)
    :ok
  end

  # ── Event Handler (runs in bus process — must be fast) ──────────

  defp handle_event(%{data: data}) when is_map(data) do
    send(__MODULE__, {:insight_candidate, data})
  end

  defp handle_event(meta) when is_map(meta) do
    send(__MODULE__, {:insight_candidate, meta})
  end

  defp handle_event(_), do: :ok

  defp handle_arch_event(%{data: data}) when is_map(data) do
    send(__MODULE__, {:arch_candidate, data})
  end

  defp handle_arch_event(meta) when is_map(meta) do
    send(__MODULE__, {:arch_candidate, meta})
  end

  defp handle_arch_event(_), do: :ok

  # ── Core Pipeline ──────────────────────────────────────────────

  defp process_finding(data, state) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || "unknown"

    # FIX #4: Dedup — reject if we've seen this topic recently
    if seen_fresh?(topic) do
      Logger.debug("[InsightActuator] Dedup: already seen '#{String.slice(topic, 0, 60)}'")
      return_state(state)
    else
      do_process_finding(data, topic, state)
    end
  end

  defp do_process_finding(data, topic, state) do
    source = Map.get(data, :source_module) || Map.get(data, "source_module") || "unknown"
    Logger.info("[InsightActuator] Processing finding: source=#{source}, topic='#{String.slice(topic, 0, 60)}'")

    # Compute quality once, pass through the pipeline
    quality = safe_compute_quality(data)

    with :ok <- quality_gate(quality),
         :ok <- rate_limit_check(state),
         {:ok, matched_subsystems} <- tier1_prefilter(data),
         {:ok, change_spec} <- tier2_classify(data, matched_subsystems),
         :ok <- risk_gate(change_spec, topic),
         {:ok, state} <- thompson_gate(topic, change_spec, state) do

      # Mark topic as seen AFTER all gates pass
      mark_seen(topic)

      Logger.info("[InsightActuator] Dispatching to Orchestrator: insight/#{slugify(topic)}")
      state = dispatch_to_orchestrator(data, change_spec, quality, state)
      state
    else
      {:skip, reason} ->
        Logger.debug("[InsightActuator] Skipped '#{String.slice(topic, 0, 60)}': #{reason}")
        record_rejection(topic, reason, quality, state)

      {:blocked, reason} ->
        Logger.info("[InsightActuator] Blocked '#{String.slice(topic, 0, 60)}': #{reason}")
        record_rejection(topic, reason, quality, state)

      _ ->
        state
    end
  end

  # ── Architectural Finding Fast Path ──────────────────────────────
  # Skips Tier 1 entirely — architectural findings are pre-classified as
  # daemon-relevant. Goes directly to Tier 2 for actionability, then dispatch.

  defp process_architectural_finding(data, state) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || "unknown"
    diagnostic_type = Map.get(data, :diagnostic_type) || Map.get(data, "diagnostic_type")

    if seen_fresh?(topic) do
      Logger.debug("[InsightActuator] Dedup: architectural finding already seen")
      state
    else
      Logger.info("[InsightActuator] Fast path: #{diagnostic_type} — skipping Tier 1, going to Tier 2")
      # Architectural findings are pre-qualified by runtime diagnostics — don't
      # run them through Retrospector's quality gate (designed for paper evidence).
      quality = 1.0

      with :ok <- rate_limit_check(state),
           {:ok, change_spec} <- tier2_classify(data, ["architectural_diagnostic"]),
           :ok <- risk_gate(change_spec, topic),
           {:ok, state} <- thompson_gate(topic, change_spec, state) do
        mark_seen(topic)
        dispatch_to_orchestrator(data, change_spec, quality, state)
      else
        {:skip, reason} ->
          Logger.info("[InsightActuator] Fast path rejected: #{reason}")
          record_rejection(topic, reason, quality, state)
        {:blocked, reason} ->
          Logger.info("[InsightActuator] Fast path blocked: #{reason}")
          record_rejection(topic, reason, quality, state)
        _ -> state
      end
    end
  end

  defp return_state(state), do: state

  # ── Quality Gate ───────────────────────────────────────────────

  defp safe_compute_quality(data) do
    Retrospector.compute_quality(data)
  rescue
    _ -> 0.0
  catch
    :exit, _ -> 0.0
  end

  defp quality_gate(quality) do
    if quality >= @quality_threshold do
      :ok
    else
      {:skip, "quality #{Float.round(quality, 3)} < #{@quality_threshold}"}
    end
  end

  # ── Rate Limiting ──────────────────────────────────────────────

  defp rate_limit_check(state) do
    cond do
      length(state.pending_tasks) >= @max_pending ->
        {:skip, "max concurrent orchestrations (#{@max_pending})"}

      state.prs_today >= @daily_pr_cap ->
        {:skip, "daily PR cap reached (#{@daily_pr_cap})"}

      state.last_pr_at != nil and
          (System.monotonic_time(:millisecond) - state.last_pr_at) < @rate_limit_ms ->
        remaining_ms = @rate_limit_ms - (System.monotonic_time(:millisecond) - state.last_pr_at)
        remaining_min = div(remaining_ms, 60_000)
        {:skip, "rate limited: cooldown #{remaining_min}m remaining"}

      true ->
        :ok
    end
  end

  # ── Tier 1: Rule-Based Pre-Filter ──────────────────────────────

  defp tier1_prefilter(data) do
    source = Map.get(data, :source_module) || Map.get(data, "source_module")
    topic = Map.get(data, :topic) || Map.get(data, "topic") || ""
    direction = Map.get(data, :direction) || Map.get(data, "direction") || ""
    topic_lower = String.downcase(topic <> " " <> direction)

    # CodeIntrospector findings are daemon-specific by definition — bypass keyword check
    matched = if source == "code_introspector" do
      Logger.info("[InsightActuator] Tier 1: source=code_introspector, bypassing keyword check")
      ["code_introspection"]
    else
      @daemon_subsystems
      |> Enum.filter(fn {_subsystem, keywords} ->
        Enum.any?(keywords, &String.contains?(topic_lower, &1))
      end)
      |> Enum.map(fn {subsystem, _} -> subsystem end)
    end

    cond do
      matched == [] ->
        {:skip, "Tier 1: no daemon subsystem match"}

      not evidence_quality_ok?(data) ->
        {:skip, "Tier 1: evidence quality insufficient"}

      contested_direction?(data) ->
        {:skip, "Tier 1: contested/opposing evidence direction"}

      true ->
        Logger.info("[InsightActuator] Tier 1 PASS: matched subsystems #{inspect(matched)}")
        {:ok, matched}
    end
  end

  defp evidence_quality_ok?(data) do
    grounded_for = Map.get(data, :grounded_for_count) || Map.get(data, "grounded_for_count") || 0
    verification_rate = compute_verification_rate(data)
    fraudulent = Map.get(data, :fraudulent_citations) || Map.get(data, "fraudulent_citations") || 0

    grounded_for >= 2 and verification_rate >= 0.5 and fraudulent == 0
  end

  defp compute_verification_rate(data) do
    supporting = Map.get(data, :supporting) || Map.get(data, "supporting") || []
    opposing = Map.get(data, :opposing) || Map.get(data, "opposing") || []
    all_evidence = supporting ++ opposing

    sourced = Enum.filter(all_evidence, fn ev ->
      is_map(ev) and (Map.get(ev, :source_type) == :sourced or Map.get(ev, "source_type") == "sourced")
    end)

    total_sourced = length(sourced)

    if total_sourced == 0 do
      0.0
    else
      verified = Enum.count(sourced, fn ev ->
        v = Map.get(ev, :verification) || Map.get(ev, "verification")
        v in ["verified", :verified]
      end)

      verified / total_sourced
    end
  end

  defp contested_direction?(data) do
    direction = Map.get(data, :direction) || Map.get(data, "direction") || ""
    String.downcase(direction) in ["against", "opposing", "refuted"]
  end

  # ── Tier 2: LLM Classifier ────────────────────────────────────

  defp tier2_classify(data, matched_subsystems) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || ""
    direction = Map.get(data, :direction) || Map.get(data, "direction") || ""
    source = Map.get(data, :source_module) || Map.get(data, "source_module")

    top_evidence = extract_top_evidence(data, 3)

    source_context = if source == "code_introspector" do
      anomaly_type = Map.get(data, :anomaly_type) || Map.get(data, "anomaly_type") || ""
      severity = Map.get(data, :severity) || Map.get(data, "severity") || ""
      "\n\nIMPORTANT: This finding originated from CodeIntrospector runtime anomaly detection " <>
      "(anomaly_type=#{anomaly_type}, severity=#{severity}). It was triggered by a REAL observed " <>
      "problem in the daemon. Bias toward actionable=true unless the evidence is genuinely weak."
    else
      ""
    end

    messages = [
      %{role: "user", content: """
      You are classifying whether an investigation finding is actionable as a code change
      for the vaos-daemon Elixir project.

      ## Investigation Finding
      Topic: #{topic}
      Direction: #{direction}
      Matched subsystems: #{Enum.join(matched_subsystems, ", ")}

      ## Top Evidence
      #{top_evidence}

      ## Daemon Codebase Context
      The daemon is an Elixir/OTP application with: agent loop (ReAct), investigation pipeline,
      Thompson Sampling, event bus (goldrush), circuit breakers, prompt engineering, rate limiting,
      error handling (supervision trees), scheduling (heartbeat/cron), orchestration (multi-agent).
      #{source_context}

      ## Task
      Classify this finding. Return ONLY a JSON object:
      {
        "actionable": true/false,
        "change_type": "config_change|bug_fix|optimization|test|new_feature|refactor",
        "risk_level": "trivial|low|medium|high|critical",
        "target_files": ["lib/daemon/..."],
        "description": "Brief description of what code change to make"
      }

      Default to NOT actionable unless there is clear, specific evidence suggesting
      a concrete code improvement. Generic research findings are NOT actionable.
      """}
    ]

    case Providers.chat(messages, temperature: 0.1, max_tokens: 500) do
      {:ok, %{content: response}} ->
        parse_classification(response)

      {:error, reason} ->
        Logger.warning("[InsightActuator] Tier 2 LLM failed: #{inspect(reason)}")
        {:skip, "Tier 2: LLM classifier unavailable"}
    end
  rescue
    e ->
      Logger.warning("[InsightActuator] Tier 2 error: #{Exception.message(e)}")
      {:skip, "Tier 2: classification error"}
  catch
    :exit, _ ->
      {:skip, "Tier 2: LLM provider unavailable"}
  end

  defp extract_top_evidence(data, n) do
    supporting = Map.get(data, :supporting) || Map.get(data, "supporting") || []

    supporting
    |> Enum.take(n)
    |> Enum.map(fn ev ->
      claim = Map.get(ev, :claim) || Map.get(ev, "claim") || ""
      source = Map.get(ev, :source_title) || Map.get(ev, "source_title") || ""
      verification = Map.get(ev, :verification) || Map.get(ev, "verification") || ""
      "- #{String.slice(claim, 0, 200)} [#{source}] (#{verification})"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "(no evidence available)"
      text -> text
    end
  end

  defp parse_classification(response) do
    cleaned =
      response
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"actionable" => true} = spec} ->
        change_type = parse_change_type(Map.get(spec, "change_type", ""))
        risk_level = parse_risk_level(Map.get(spec, "risk_level", ""))

        if change_type && risk_level do
          change_spec = %{
            change_type: change_type,
            risk_level: risk_level,
            target_files: Map.get(spec, "target_files", []),
            description: Map.get(spec, "description", "")
          }

          Logger.info("[InsightActuator] Tier 2: actionable=true, type=#{change_type}, risk=#{risk_level}")
          {:ok, change_spec}
        else
          {:skip, "Tier 2: invalid change_type or risk_level"}
        end

      {:ok, %{"actionable" => false}} ->
        {:skip, "Tier 2: classified as not actionable"}

      {:ok, _} ->
        {:skip, "Tier 2: unexpected classification format"}

      {:error, _} ->
        {:skip, "Tier 2: failed to parse JSON response"}
    end
  end

  defp parse_change_type(type) when is_binary(type) do
    atom = String.to_atom(type)
    if atom in @change_types, do: atom, else: nil
  rescue
    _ -> nil
  end

  defp parse_change_type(_), do: nil

  defp parse_risk_level(level) when is_binary(level) do
    atom = String.to_atom(level)
    if atom in @risk_levels, do: atom, else: nil
  rescue
    _ -> nil
  end

  defp parse_risk_level(_), do: nil

  # ── Risk Gate ──────────────────────────────────────────────────

  # FIX #3: Medium risk now blocks until governance approval exists
  defp risk_gate(%{risk_level: risk}, _topic) when risk in [:high, :critical] do
    {:blocked, "risk level #{risk} — logged only, not dispatched"}
  end

  defp risk_gate(%{risk_level: :medium, change_type: change_type}, topic) do
    case Approvals.create(%{
      type: "code_change",
      title: "InsightActuator: #{change_type} — #{String.slice(topic, 0, 50)}",
      description: "Medium-risk code change classified by InsightActuator. Requires approval before execution.",
      requested_by: "insight_actuator"
    }) do
      {:ok, _approval} ->
        Logger.info("[InsightActuator] Governance approval created for medium-risk change — BLOCKING")
        {:blocked, "medium risk — governance approval required (created, awaiting review)"}

      {:error, _} ->
        Logger.warning("[InsightActuator] Governance unavailable — blocking medium-risk change")
        {:blocked, "medium risk — governance system unavailable"}
    end
  rescue
    _ -> {:blocked, "medium risk — governance error"}
  catch
    :exit, _ -> {:blocked, "medium risk — governance unavailable"}
  end

  defp risk_gate(_, _topic), do: :ok

  # ── Thompson Sampling Gate ─────────────────────────────────────

  # FIX #5: Starvation recovery — force-accept after N consecutive Thompson rejections
  defp thompson_gate(topic, change_spec, state) do
    arm_key = actuation_arm_key(topic, change_spec.change_type)
    arm = Map.get(state.arms, arm_key, %{alpha: 1.0, beta: 1.0})
    sample = PromptSelector.sample_beta(arm.alpha, arm.beta)

    cond do
      sample > @actuation_threshold ->
        Logger.debug("[InsightActuator] Thompson gate PASS: arm=#{inspect(arm_key)}, sample=#{Float.round(sample, 3)} > #{@actuation_threshold}")
        {:ok, %{state | consecutive_thompson_skips: 0}}

      state.consecutive_thompson_skips + 1 >= @starvation_limit ->
        Logger.info("[InsightActuator] Thompson starvation recovery: #{state.consecutive_thompson_skips + 1} consecutive skips, forcing through")
        {:ok, %{state | consecutive_thompson_skips: 0}}

      true ->
        skips = state.consecutive_thompson_skips + 1
        {:skip, "Thompson gate: sample #{Float.round(sample, 3)} <= #{@actuation_threshold} for arm #{inspect(arm_key)} (skip #{skips}/#{@starvation_limit})"}
    end
  end

  defp actuation_arm_key(topic, change_type) do
    cluster = topic_to_cluster(topic)
    {cluster, change_type}
  end

  defp topic_to_cluster(topic) do
    topic_lower = String.downcase(topic)

    # Find the best-matching daemon subsystem
    {best_cluster, _score} =
      @daemon_subsystems
      |> Enum.map(fn {subsystem, keywords} ->
        score = Enum.count(keywords, &String.contains?(topic_lower, &1))
        {subsystem, score}
      end)
      |> Enum.max_by(fn {_s, score} -> score end, fn -> {"general", 0} end)

    best_cluster
  end

  # ── Orchestration Prompt & Dispatch ────────────────────────────

  # FIX #1 & #2: Pass change_type and quality through pending_tasks
  defp dispatch_to_orchestrator(data, change_spec, quality, state) do
    # Guard: skip if WorkDirector has an active dispatch on the repo
    if Daemon.Agent.WorkDirector.dispatching?() do
      topic = Map.get(data, :topic) || Map.get(data, "topic") || "unknown"
      Logger.info("[InsightActuator] Skipping dispatch for '#{topic}' — WorkDirector dispatch active")
      state
    else
      dispatch_to_orchestrator_impl(data, change_spec, quality, state)
    end
  end

  defp dispatch_to_orchestrator_impl(data, change_spec, quality, state) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || "unknown"
    top_evidence = extract_top_evidence(data, 3)
    branch_name = "insight/#{slugify(topic)}"

    # Check with Decision Journal for cross-module conflicts
    case DecisionJournal.propose(:insight_actuator, :create_pr, %{
      topic: topic,
      branch: branch_name,
      change_type: change_spec.change_type,
      quality: quality
    }) do
      {:conflict, reason} ->
        Logger.info("[InsightActuator] Journal conflict: #{reason}")
        record_rejection(topic, "journal_conflict: #{reason}", quality, state)

      :approved ->
        do_dispatch_to_orchestrator(data, change_spec, quality, state, topic, top_evidence, branch_name)
    end
  end

  defp do_dispatch_to_orchestrator(data, change_spec, quality, state, topic, top_evidence, branch_name) do
    session_id = "insight-#{System.unique_integer([:positive])}"
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    prompt = build_orchestration_prompt(topic, quality, top_evidence, change_spec, branch_name, data)

    parent = self()
    ref = make_ref()

    {_pid, _monitor_ref} = spawn_monitor(fn ->
      result =
        try do
          case Daemon.Agent.ExecutionAwaiter.execute_and_await(
            prompt, session_id, branch_name, repo_path,
            strategy: [strategy: "pact"]
          ) do
            {:ok, synthesis, branch} -> {:ok, synthesis, branch}
            {:partial, synthesis} -> {:error, {:no_branch, synthesis}}
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      send(parent, {:orchestration_complete, ref, result})
    end)

    # Store change_type and quality in pending_tasks for result handling
    pending = [{ref, topic, change_spec.change_type, System.monotonic_time(:millisecond), quality} | state.pending_tasks]
    %{state | pending_tasks: pending}
  end

  defp build_orchestration_prompt(topic, quality, evidence, change_spec, branch_name, data) do
    daemon_repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    source_info = case Map.get(data, :source_module) || Map.get(data, "source_module") do
      "code_introspector" ->
        anomaly_type = Map.get(data, :anomaly_type) || Map.get(data, "anomaly_type") || "unknown"
        "- Source: CodeIntrospector (anomaly: #{anomaly_type})\n"
      _ -> ""
    end

    """
    ## Task: Implement Code Change from Investigation Finding

    ### Investigation Context
    - Topic: #{topic}
    - Quality Score: #{Float.round(quality, 3)}
    - Change Type: #{change_spec.change_type}
    - Risk Level: #{change_spec.risk_level}
    #{source_info}- Target Files: #{Enum.join(change_spec.target_files, ", ")}

    ### Description
    #{change_spec.description}

    ### Supporting Evidence
    #{evidence}

    ### Implementation Instructions
    1. Working directory: #{daemon_repo_path}
    2. Create feature branch: `git checkout -b #{branch_name}`
    3. Implement the change described above
    4. Run `mix compile --warnings-as-errors` — if it fails, fix or revert
    5. Run `mix test` — if tests fail, fix or revert
    6. Stage ONLY the files you changed (NO `git add .` or `git add -A`)
    7. Commit with message: "feat(insight): #{change_spec.change_type} — #{String.slice(topic, 0, 50)}"
    8. Push the branch: `git push origin #{branch_name}`
    9. Create a **draft** PR on #{@daemon_repo} with:
       - Title: "[InsightActuator] #{String.slice(change_spec.description, 0, 60)}"
       - Body must include:
         ```
         ## Provenance
         - Investigation topic: #{topic}
         - Quality score: #{Float.round(quality, 3)}
         - Change type: #{change_spec.change_type}
         - Risk level: #{change_spec.risk_level}
         #{source_info}
         ## Evidence
         #{evidence}

         ---
         *Auto-generated by InsightActuator from investigation findings.*
         ```

    ### SAFETY CONSTRAINTS (CRITICAL — NEVER VIOLATE)
    - NEVER push to main
    - NEVER modify these paths:
      - lib/daemon/application.ex
      - lib/daemon/supervisors/*.ex
      - lib/daemon/security/*.ex
      - lib/daemon/agent/loop.ex
      - config/runtime.exs
      - mix.exs / mix.lock
    - If `mix test` fails after your changes, revert ALL changes and report failure
    - If you cannot implement the change safely, report why and stop
    """
  end

  # ── Orchestration Result Handling ──────────────────────────────

  # FIX #1: Use actual change_type from pending_tasks, not hardcoded :optimization
  # FIX #2: Use stored quality instead of computing from empty map
  defp handle_orchestration_result(task_ref, result, state) do
    case Enum.find(state.pending_tasks, fn {ref, _, _, _, _} -> ref == task_ref end) do
      {^task_ref, topic, change_type, started_at, quality} ->
        pending = Enum.reject(state.pending_tasks, fn {ref, _, _, _, _} -> ref == task_ref end)
        state = %{state | pending_tasks: pending}
        duration_ms = System.monotonic_time(:millisecond) - started_at

        case result do
          {:ok, _output, branch_name} ->
            # Code-level safety gate (FIX #6: uses pre-compiled regexes from state)
            case verify_pr_safety(branch_name, state.blocked_regexes) do
              :safe ->
                arm_key = actuation_arm_key(topic, change_type)
                state = record_immediate_reward(arm_key, @immediate_reward, state)
                DecisionJournal.record_outcome(branch_name, :success, %{topic: topic, change_type: change_type})

                pr_record = %{
                  topic: topic,
                  branch: branch_name,
                  quality: quality,
                  change_type: change_type,
                  timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                  duration_ms: duration_ms,
                  arm_key: arm_key
                }

                completed = [pr_record | state.completed_prs] |> Enum.take(@max_completed)
                state = %{state |
                  prs_created: state.prs_created + 1,
                  prs_today: state.prs_today + 1,
                  last_pr_at: System.monotonic_time(:millisecond),
                  completed_prs: completed
                }

                Logger.info("[InsightActuator] PR created: #{branch_name} (#{duration_ms}ms)")
                persist_state(state)
                state

              {:unsafe, violations} ->
                Logger.warning("[InsightActuator] SAFETY VIOLATION on #{branch_name}: #{inspect(violations)} — deleting branch")
                delete_branch(branch_name)
                DecisionJournal.record_outcome(branch_name, :failure, %{reason: :safety_violation})

                # Zero reward with ACTUAL change_type
                arm_key = actuation_arm_key(topic, change_type)
                state = record_immediate_reward(arm_key, 0.0, state)
                persist_state(state)
                state
            end

          {:error, reason} ->
            Logger.warning("[InsightActuator] Orchestration failed for '#{topic}': #{inspect(reason)} (#{duration_ms}ms)")
            state
        end

      nil ->
        # Unknown task ref — ignore
        state
    end
  rescue
    e ->
      Logger.warning("[InsightActuator] Error handling orchestration result: #{Exception.message(e)}")
      state
  end

  # ── Code-Level Safety Gate ─────────────────────────────────────

  # FIX #6: Accept pre-compiled regexes instead of compiling per call
  defp verify_pr_safety(branch, blocked_regexes) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    case System.cmd("git", ["diff", "--name-only", "main...#{branch}"], cd: repo_path, stderr_to_stdout: true) do
      {diff, 0} ->
        changed_files = String.split(diff, "\n", trim: true)

        violations =
          Enum.filter(changed_files, fn f ->
            Enum.any?(blocked_regexes, &Regex.match?(&1, f))
          end)

        if violations == [], do: :safe, else: {:unsafe, violations}

      {error, _code} ->
        Logger.warning("[InsightActuator] Safety check git diff failed: #{String.slice(error, 0, 200)}")
        # Conservative: treat as unsafe if we can't verify
        {:unsafe, ["(unable to verify — git diff failed)"]}
    end
  rescue
    _ -> {:unsafe, ["(unable to verify — exception)"]}
  end

  defp delete_branch(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  # ── Thompson Sampling Arms ─────────────────────────────────────

  defp record_immediate_reward(arm_key, reward, state) do
    arm = Map.get(state.arms, arm_key, %{alpha: 1.0, beta: 1.0})
    clamped = max(0.0, min(1.0, reward))
    updated = %{alpha: arm.alpha + clamped, beta: arm.beta + (1.0 - clamped)}
    arms = Map.put(state.arms, arm_key, updated)
    %{state | arms: arms}
  end

  defp record_delayed_reward(arm_key, reward, state) do
    record_immediate_reward(arm_key, reward, state)
  end

  defp poll_pr_outcomes(state) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    case System.cmd("gh", ["pr", "list", "--repo", @daemon_repo, "--json", "number,state,mergedAt,headRefName", "--limit", "20"],
                     cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} when is_list(prs) ->
            process_pr_outcomes(prs, state)

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp process_pr_outcomes(prs, state) do
    Enum.reduce(prs, state, fn pr, acc ->
      branch = Map.get(pr, "headRefName", "")

      if String.starts_with?(branch, "insight/") do
        matching_pr = Enum.find(acc.completed_prs, fn p -> Map.get(p, :branch) == branch end)

        if matching_pr do
          arm_key = Map.get(matching_pr, :arm_key)
          merged_at = Map.get(pr, "mergedAt")
          state_str = Map.get(pr, "state", "")

          cond do
            merged_at != nil and merged_at != "" ->
              Logger.info("[InsightActuator] PR outcome: #{branch} MERGED")
              record_delayed_reward(arm_key, 1.0, acc)

            state_str == "CLOSED" ->
              Logger.info("[InsightActuator] PR outcome: #{branch} REJECTED")
              record_delayed_reward(arm_key, 0.2, acc)

            true ->
              # Still open — no update
              acc
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  # ── Recording & Stats ──────────────────────────────────────────

  defp record_rejection(topic, reason, quality, state) do
    rejection = %{
      topic: topic,
      reason: reason,
      quality: Float.round(quality, 3),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    rejected = [rejection | state.rejected_findings] |> Enum.take(@max_rejected)
    # Increment thompson skip counter when rejection is from Thompson gate
    thompson_skips = if String.starts_with?(reason, "Thompson gate:") do
      state.consecutive_thompson_skips + 1
    else
      state.consecutive_thompson_skips
    end

    %{state | rejected_findings: rejected, consecutive_thompson_skips: thompson_skips}
  end

  defp maybe_reset_daily_count(state) do
    today = Date.utc_today()

    if state.last_day_reset != today do
      %{state | prs_today: 0, last_day_reset: today}
    else
      state
    end
  end

  defp empty_stats do
    %{prs_created: 0, prs_today: 0, last_pr_at: nil, pending_count: 0,
      recent_prs: [], recent_rejections: [], arms: %{}, consecutive_thompson_skips: 0, enabled: false}
  end

  defp summarize_arms(arms) do
    Map.new(arms, fn {key, arm} ->
      mean = Float.round(arm.alpha / (arm.alpha + arm.beta), 3)
      {key, %{alpha: Float.round(arm.alpha, 1), beta: Float.round(arm.beta, 1), mean: mean}}
    end)
  end

  # ── ETS Dedup ──────────────────────────────────────────────────

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

  defp seen_fresh?(topic) do
    key = normalize_topic(topic)

    case :ets.lookup(@seen_topics_table, key) do
      [{^key, seen_at}] ->
        age = System.system_time(:second) - seen_at
        if age > @seen_ttl_seconds do
          :ets.delete(@seen_topics_table, key)
          false
        else
          true
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp mark_seen(topic) do
    key = normalize_topic(topic)
    :ets.insert(@seen_topics_table, {key, System.system_time(:second)})
  rescue
    _ -> :ok
  end

  defp normalize_topic(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.slice(0, 50)
    |> String.trim("-")
  end

  # ── Persistence ────────────────────────────────────────────────

  defp persistence_path do
    config_dir = Application.get_env(:daemon, :config_dir, "~/.daemon") |> Path.expand()
    Path.join(config_dir, @persistence_file)
  end

  defp persist_state(state) do
    data = %{
      "version" => 1,
      "prs_created" => state.prs_created,
      "enabled" => state.enabled,
      "arms" => serialize_arms(state.arms),
      "completed_prs" => Enum.map(state.completed_prs, &serialize_pr_record/1),
      "rejected_findings" => Enum.map(state.rejected_findings, &serialize_rejection/1)
    }

    path = persistence_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    e ->
      Logger.warning("[InsightActuator] Failed to persist state: #{Exception.message(e)}")
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

  defp serialize_arms(arms) do
    Map.new(arms, fn {key, arm} ->
      key_str = case key do
        {cluster, change_type} -> "#{cluster}:#{change_type}"
        other -> to_string(other)
      end

      {key_str, %{"alpha" => arm.alpha, "beta" => arm.beta}}
    end)
  end

  defp parse_arms(raw) when is_map(raw) do
    Map.new(raw, fn {key_str, arm_data} ->
      key = case String.split(key_str, ":", parts: 2) do
        [cluster, change_type] -> {cluster, String.to_atom(change_type)}
        _ -> key_str
      end

      alpha = Map.get(arm_data, "alpha", 1.0)
      beta = Map.get(arm_data, "beta", 1.0)

      if is_number(alpha) and is_number(beta) and alpha > 0 and beta > 0 do
        {key, %{alpha: alpha / 1.0, beta: beta / 1.0}}
      else
        {key, %{alpha: 1.0, beta: 1.0}}
      end
    end)
  rescue
    _ -> %{}
  end

  defp parse_arms(_), do: %{}

  defp serialize_pr_record(pr) do
    arm_key = case Map.get(pr, :arm_key) do
      {cluster, change_type} -> "#{cluster}:#{change_type}"
      other -> to_string(other || "")
    end

    %{
      "topic" => Map.get(pr, :topic, ""),
      "branch" => Map.get(pr, :branch, ""),
      "quality" => Map.get(pr, :quality, 0.0),
      "change_type" => to_string(Map.get(pr, :change_type, "")),
      "timestamp" => Map.get(pr, :timestamp, ""),
      "duration_ms" => Map.get(pr, :duration_ms, 0),
      "arm_key" => arm_key
    }
  end

  defp parse_pr_list(list) when is_list(list) do
    Enum.map(list, fn pr ->
      arm_key = case String.split(Map.get(pr, "arm_key", ""), ":", parts: 2) do
        [cluster, change_type] -> {cluster, String.to_atom(change_type)}
        _ -> nil
      end

      change_type = case Map.get(pr, "change_type", "") do
        "" -> nil
        ct -> String.to_atom(ct)
      end

      %{
        topic: Map.get(pr, "topic", ""),
        branch: Map.get(pr, "branch", ""),
        quality: Map.get(pr, "quality", 0.0),
        change_type: change_type,
        timestamp: Map.get(pr, "timestamp", ""),
        duration_ms: Map.get(pr, "duration_ms", 0),
        arm_key: arm_key
      }
    end)
  rescue
    _ -> []
  end

  defp parse_pr_list(_), do: []

  defp serialize_rejection(rej) do
    %{
      "topic" => Map.get(rej, :topic, ""),
      "reason" => Map.get(rej, :reason, ""),
      "quality" => Map.get(rej, :quality, 0.0),
      "timestamp" => Map.get(rej, :timestamp, "")
    }
  end

  defp parse_rejection_list(list) when is_list(list) do
    Enum.map(list, fn rej ->
      %{
        topic: Map.get(rej, "topic", ""),
        reason: Map.get(rej, "reason", ""),
        quality: Map.get(rej, "quality", 0.0),
        timestamp: Map.get(rej, "timestamp", "")
      }
    end)
  rescue
    _ -> []
  end

  defp parse_rejection_list(_), do: []
end
