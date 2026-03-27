defmodule Daemon.Agent.ActiveLearner do
  @moduledoc """
  Closes the investigation → topic selection loop with outcome-weighted learning.

  Subscribes to `:investigation_complete` events and extracts `suggested_next`
  topics (ranked by information gain via `Policy.rank_actions`) plus emergent
  questions synthesized from evidence tension. Uses **Thompson Sampling** with
  per-source Beta distributions to learn which source (emergent vs policy)
  produces better investigations.

  **Learning loop**: Two arms — `:emergent` and `:policy` — each with a Beta(α, β)
  posterior. When a topic we added completes an investigation, we update the arm
  with continuous quality signal: α += quality, β += (1 - quality). This makes
  learning ~5-10x more data-efficient than binary success/failure — a quality-0.95
  investigation contributes 19x more to α than a quality-0.05 one. Thompson
  Sampling naturally explores uncertain sources and exploits proven ones.

  **Direct chaining**: When a topic is selected, ActiveLearner directly calls
  `Investigate.execute/1` — bypassing the 5-min heartbeat polling delay and
  the agent loop LLM overhead (~15s). Investigations chain in ~60s intervals,
  creating a self-sustaining research pipeline.

  **Persistence**: Arms, outcomes, and seen topics are persisted to
  `<config_dir>/active_learner_state.json` and survive daemon restarts.

  Seen topics expire after 7 days, allowing re-investigation when new evidence
  accumulates.
  """
  use GenServer
  require Logger

  alias Daemon.Investigation.Retrospector
  alias Daemon.Investigation.PromptSelector
  alias Daemon.Agent.Scheduler
  alias Daemon.Agent.Scheduler.Heartbeat

  @quality_threshold 0.20  # Lowered from 0.25 — Z.AI proxy verification rates are lower
  @max_pending_tasks 20
  @max_research_depth 3    # Suppress emergent questions beyond depth 3 to prevent narrowing spiral
  @subscribe_delay_ms 5_000
  @task_prefix "Investigate: "
  @seen_topics_table :active_learner_seen_topics
  @outcomes_table :active_learner_outcomes
  @seen_ttl_seconds 7 * 24 * 3600
  @persistence_file "active_learner_state.json"

  # Direct investigation chaining — bypasses heartbeat polling + agent loop overhead
  @chain_enabled true
  @chain_cooldown_ms 60_000      # 60s between chained investigations (respects API rate limits)
  @chain_max_per_session 100     # Hard cap per daemon lifetime

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats: topics_added, arms, correction factor, lineage."
  @spec stats() :: map()
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{topics_added: 0, last_added_at: nil, arms: default_arms(), outcomes_count: 0}
    catch
      :exit, _ -> %{topics_added: 0, last_added_at: nil, arms: default_arms(), outcomes_count: 0}
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_ets_table(@seen_topics_table)
    ensure_ets_table(@outcomes_table)

    # Load persisted state (arms, outcomes, seen topics)
    persisted = load_persisted_state()
    hydrate_ets(persisted)

    arms = Map.get(persisted, "arms", %{}) |> parse_arms()

    Process.send_after(self(), :subscribe, @subscribe_delay_ms)
    Logger.info("[ActiveLearner] Started (arms: emergent=#{format_arm(arms.emergent)}, policy=#{format_arm(arms.policy)})")

    {:ok, %{
      event_ref: nil,
      topics_added: Map.get(persisted, "topics_added", 0),
      last_added_at: parse_datetime(Map.get(persisted, "last_added_at")),
      arms: arms,
      chain_in_flight: false,
      chain_count: 0,
      last_chain_at: nil
    }}
  end

  @impl true
  def handle_info(:subscribe, state) do
    ref = Daemon.Events.Bus.register_handler(:investigation_complete, &handle_event/1)
    Logger.info("[ActiveLearner] Subscribed to :investigation_complete events")
    {:noreply, %{state | event_ref: ref}}
  end

  def handle_info({:active_learning_suggestion, data}, state) do
    state = process_event(data, state)
    {:noreply, state}
  end

  def handle_info({:chain_investigation, topic}, state) do
    state = maybe_chain_investigation(topic, state)
    {:noreply, state}
  end

  def handle_info({:chain_complete, _ref}, state) do
    {:noreply, %{state | chain_in_flight: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Chained investigation task crashed — mark not in flight so next one can start
    {:noreply, %{state | chain_in_flight: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    reply = %{
      topics_added: state.topics_added,
      last_added_at: state.last_added_at,
      arms: %{
        emergent: state.arms.emergent,
        policy: state.arms.policy
      },
      correction_factor: compute_correction_factor(),
      outcomes_count: count_outcomes(),
      chain_count: state.chain_count,
      chain_in_flight: state.chain_in_flight,
      lineage: build_lineage()
    }

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{event_ref: ref} = state) when not is_nil(ref) do
    persist_state(state)
    Daemon.Events.Bus.unregister_handler(:investigation_complete, ref)
    :ok
  end

  def terminate(_reason, state) do
    persist_state(state)
    :ok
  end

  # ── Event Handler (runs in bus process — must be fast) ──────────────

  defp handle_event(%{data: data}) when is_map(data) do
    send(__MODULE__, {:active_learning_suggestion, data})
  end

  defp handle_event(meta) when is_map(meta) do
    send(__MODULE__, {:active_learning_suggestion, meta})
  end

  defp handle_event(_), do: :ok

  # ── Core Logic ──────────────────────────────────────────────────────

  defp process_event(data, state) do
    quality = Retrospector.compute_quality(data)

    # Mark that an investigation just completed — enforces cooldown before chaining
    state = %{state | last_chain_at: System.monotonic_time(:millisecond)}

    # Record outcome and update Thompson arm if this was our topic
    state = record_outcome_if_ours(data, quality, state)

    if quality < @quality_threshold do
      Logger.debug("[ActiveLearner] Skipping — quality #{Float.round(quality, 3)} below threshold #{@quality_threshold}")
      state
    else
      maybe_add_topic(data, quality, state)
    end
  end

  defp maybe_add_topic(data, quality, state) do
    source_topic = Map.get(data, :topic) || Map.get(data, "topic") || "unknown"
    depth = lookup_depth(source_topic)
    raw_emergent = extract_emergent_questions(data)
    suggested = extract_suggested_next(data)

    emergent = if depth < @max_research_depth do
      raw_emergent
    else
      if raw_emergent != [] do
        Logger.debug("[ActiveLearner] Depth #{depth} >= #{@max_research_depth} — suppressing #{length(raw_emergent)} emergent question(s), policy only")
      end
      []
    end

    all_suggestions = emergent ++ suggested

    if all_suggestions == [] do
      Logger.debug("[ActiveLearner] No suggestions in event data")
      state
    else
      {pending_tasks, completed_tasks} = read_heartbeat_tasks()
      pending_len = length(pending_tasks)

      if emergent != [] do
        Logger.info("[ActiveLearner] #{length(emergent)} emergent question(s) + #{length(suggested)} policy suggestion(s)")
      end

      ranked = rank_suggestions(all_suggestions, state.arms)
      try_add_suggestion(ranked, quality, source_topic, depth, pending_tasks, completed_tasks, pending_len, state)
    end
  end

  defp try_add_suggestion([], _quality, _source, _depth, _pending, _completed, _pending_len, state), do: state

  defp try_add_suggestion([suggestion | rest], quality, source_topic, depth, pending, completed, pending_len, state) do
    task_text = build_task_text(suggestion)

    cond do
      pending_len >= @max_pending_tasks ->
        Logger.debug("[ActiveLearner] Pending task cap reached (#{@max_pending_tasks})")
        state

      seen_fresh?(task_text) ->
        Logger.debug("[ActiveLearner] Already seen: '#{task_text}'")
        try_add_suggestion(rest, quality, source_topic, depth, pending, completed, pending_len, state)

      heartbeat_has_task?(task_text, pending, completed) ->
        Logger.debug("[ActiveLearner] Already in HEARTBEAT.md: '#{task_text}'")
        mark_seen(task_text)
        try_add_suggestion(rest, quality, source_topic, depth, pending, completed, pending_len, state)

      true ->
        case safe_add_heartbeat_task(task_text) do
          :ok ->
            ig = get_ig(suggestion)
            source = get_source(suggestion)
            child_depth = depth + 1
            arm = Map.get(state.arms, source, %{alpha: 1.0, beta: 1.0})
            Logger.info("[ActiveLearner] Added: '#{task_text}' (ig: #{Float.round(ig * 1.0, 3)}, source: #{source}, depth: #{child_depth}, arm: #{format_arm(arm)}, from: '#{source_topic}')")
            mark_seen(task_text)
            record_prediction(task_text, ig, source_topic, source, child_depth)
            state = %{state | topics_added: state.topics_added + 1, last_added_at: DateTime.utc_now()}
            persist_state(state)
            # Trigger direct investigation — bypasses heartbeat polling + agent loop
            topic_for_investigate = String.replace(task_text, ~r/^Investigate:\s*/i, "")
            send(self(), {:chain_investigation, topic_for_investigate})
            state

          {:error, reason} ->
            Logger.warning("[ActiveLearner] Failed to add task: #{inspect(reason)}")
            state
        end
    end
  end

  defp extract_emergent_questions(data) do
    emergent = Map.get(data, :emergent_questions) || Map.get(data, "emergent_questions") || []

    case emergent do
      list when is_list(list) ->
        Enum.map(list, fn q ->
          title = Map.get(q, :title) || Map.get(q, "title") || ""
          ig = Map.get(q, :information_gain) || Map.get(q, "information_gain") || 0.90
          %{claim_title: title, information_gain: ig, source: :emergent}
        end)
        |> Enum.reject(fn q -> q.claim_title == "" end)

      _ -> []
    end
  end

  defp extract_suggested_next(data) do
    suggested = Map.get(data, :suggested_next) || Map.get(data, "suggested_next") || []

    case suggested do
      list when is_list(list) ->
        Enum.map(list, fn s ->
          if is_map(s), do: Map.put_new(s, :source, :policy), else: s
        end)

      _ -> []
    end
  end

  # ── Thompson Sampling ─────────────────────────────────────────────

  defp rank_suggestions(suggestions, arms) do
    Enum.sort_by(suggestions, fn s ->
      source = get_source(s)
      arm = Map.get(arms, source, %{alpha: 1.0, beta: 1.0})
      theta = PromptSelector.sample_beta(arm.alpha, arm.beta)
      -(get_ig(s) * theta)
    end)
  end

  defp get_ig(suggestion) do
    Map.get(suggestion, :information_gain, Map.get(suggestion, "information_gain", 0.0))
  end

  defp get_source(suggestion) do
    case Map.get(suggestion, :source, Map.get(suggestion, "source", :policy)) do
      s when s in [:emergent, :policy] -> s
      "emergent" -> :emergent
      _ -> :policy
    end
  end

  defp update_arm(arms, source, quality) do
    arm = Map.get(arms, source, %{alpha: 1.0, beta: 1.0})
    # Continuous update: proportional to quality rather than binary threshold.
    # A quality-0.95 investigation contributes 19x more to alpha than quality-0.05.
    # Beta distribution posterior remains valid with non-integer parameters.
    clamped = max(0.0, min(1.0, quality))
    updated = %{alpha: arm.alpha + clamped, beta: arm.beta + (1.0 - clamped)}
    Map.put(arms, source, updated)
  end

  defp default_arms do
    %{emergent: %{alpha: 1.0, beta: 1.0}, policy: %{alpha: 1.0, beta: 1.0}}
  end

  defp format_arm(%{alpha: a, beta: b}) do
    mean = Float.round(a / (a + b), 3)
    "Beta(#{Float.round(a, 1)}, #{Float.round(b, 1)}) μ=#{mean}"
  end

  # ── Direct Investigation Chaining ─────────────────────────────────
  # Bypasses heartbeat polling (5 min) and agent loop overhead (~15s).
  # Calls Investigate.execute/1 directly, which emits :investigation_complete
  # that we're already subscribed to — creating a self-sustaining pipeline.

  defp maybe_chain_investigation(topic, state) do
    cond do
      not @chain_enabled ->
        state

      state.chain_in_flight ->
        Logger.debug("[ActiveLearner] Chain: already in flight, skipping '#{String.slice(topic, 0, 60)}...'")
        state

      state.chain_count >= @chain_max_per_session ->
        Logger.info("[ActiveLearner] Chain: session cap reached (#{@chain_max_per_session})")
        state

      not chain_cooldown_elapsed?(state) ->
        # Schedule retry after cooldown
        remaining = chain_cooldown_remaining(state)
        Logger.debug("[ActiveLearner] Chain: cooling down, retrying in #{remaining}ms")
        Process.send_after(self(), {:chain_investigation, topic}, remaining)
        state

      true ->
        Logger.info("[ActiveLearner] Chain: directly investigating '#{String.slice(topic, 0, 80)}...'")
        ref = spawn_investigation(topic)
        %{state | chain_in_flight: true, chain_count: state.chain_count + 1, last_chain_at: System.monotonic_time(:millisecond)}
    end
  end

  defp spawn_investigation(topic) do
    parent = self()
    ref = make_ref()

    {_pid, monitor_ref} = spawn_monitor(fn ->
      try do
        Daemon.Tools.Builtins.Investigate.execute(%{"topic" => topic})
      rescue
        e -> Logger.warning("[ActiveLearner] Chain investigation failed: #{Exception.message(e)}")
      catch
        :exit, reason -> Logger.warning("[ActiveLearner] Chain investigation exited: #{inspect(reason)}")
      after
        send(parent, {:chain_complete, ref})
      end
    end)

    monitor_ref
  end

  defp chain_cooldown_elapsed?(state) do
    case state.last_chain_at do
      nil -> true
      last -> (System.monotonic_time(:millisecond) - last) >= @chain_cooldown_ms
    end
  end

  defp chain_cooldown_remaining(state) do
    case state.last_chain_at do
      nil -> 0
      last -> max(0, @chain_cooldown_ms - (System.monotonic_time(:millisecond) - last))
    end
  end

  # ── Suggestion Building ────────────────────────────────────────────

  defp build_task_text(suggestion) do
    title =
      Map.get(suggestion, :claim_title) ||
        Map.get(suggestion, "claim_title") ||
        Map.get(suggestion, :title) ||
        Map.get(suggestion, "title") ||
        "unknown topic"

    @task_prefix <> title
  end

  defp read_heartbeat_tasks do
    case File.read(Heartbeat.path()) do
      {:ok, content} ->
        {Heartbeat.parse_pending_tasks(content), parse_completed_tasks(content)}

      {:error, _} ->
        {[], []}
    end
  end

  defp heartbeat_has_task?(task_text, pending, completed) do
    normalized = normalize_topic(task_text)

    Enum.any?(pending ++ completed, fn t ->
      normalize_topic(t) == normalized
    end)
  end

  @doc false
  def parse_completed_tasks(content) do
    content
    |> String.replace(~r/<!--[\s\S]*?-->/, "")
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\s*-\s*\[x\]\s*.+/i))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*-\s*\[x\]\s*/i, "")
      |> String.replace(~r/\s*\(completed\s+.*\)\s*$/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_topic(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp safe_add_heartbeat_task(text) do
    try do
      Scheduler.add_heartbeat_task(text)
    rescue
      e ->
        Logger.warning("[ActiveLearner] Scheduler error: #{Exception.message(e)}")
        {:error, :scheduler_not_running}
    catch
      :exit, _ ->
        Logger.warning("[ActiveLearner] Scheduler not running")
        {:error, :scheduler_not_running}
    end
  end

  # ── Outcome Tracking ───────────────────────────────────────────────
  # Records predicted_ig + source when we add a topic, then actual_quality
  # when that topic's investigation completes. Updates the Thompson arm
  # for the source that originated the suggestion.

  defp record_prediction(task_text, predicted_ig, source_topic, source, depth \\ 0) do
    key = normalize_topic(task_text)

    :ets.insert(@outcomes_table, {key, %{
      predicted_ig: predicted_ig,
      actual_quality: nil,
      source_topic: source_topic,
      source: source,
      depth: depth,
      added_at: System.system_time(:second)
    }})
  rescue
    _ -> :ok
  end

  defp record_outcome_if_ours(data, quality, state) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || ""
    stripped = String.replace(topic, ~r/^Investigate:\s*/i, "")

    candidates = [
      normalize_topic(@task_prefix <> stripped),
      normalize_topic(stripped)
    ] |> Enum.uniq()

    matched =
      Enum.find_value(candidates, fn key ->
        case :ets.lookup(@outcomes_table, key) do
          [{^key, %{actual_quality: nil} = record}] -> {key, record}
          _ -> nil
        end
      end)

    case matched do
      {key, record} ->
        :ets.insert(@outcomes_table, {key, %{record | actual_quality: quality}})
        source = Map.get(record, :source, :policy)
        arms = update_arm(state.arms, source, quality)
        Logger.info("[ActiveLearner] Outcome for '#{stripped}': quality=#{Float.round(quality, 3)}, source=#{source}, arm→#{format_arm(arms[source])}")
        state = %{state | arms: arms}
        persist_state(state)
        state

      nil ->
        state
    end
  rescue
    _ -> state
  end

  defp lookup_depth(source_topic) do
    # Find depth of the source investigation in our outcomes table.
    # Seed topics (not in our table) have depth 0.
    stripped = String.replace(source_topic, ~r/^Investigate:\s*/i, "")
    candidates = [
      normalize_topic(@task_prefix <> stripped),
      normalize_topic(stripped)
    ] |> Enum.uniq()

    Enum.find_value(candidates, 0, fn key ->
      case :ets.lookup(@outcomes_table, key) do
        [{^key, record}] -> Map.get(record, :depth, 0)
        _ -> nil
      end
    end)
  rescue
    _ -> 0
  end

  defp compute_correction_factor do
    pairs =
      @outcomes_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_k, v} -> v.actual_quality != nil and v.predicted_ig > 0 end)
      |> Enum.map(fn {_k, v} -> v.actual_quality / v.predicted_ig end)

    if pairs == [] do
      1.0
    else
      Enum.sum(pairs) / length(pairs)
    end
  rescue
    _ -> 1.0
  end

  defp count_outcomes do
    @outcomes_table
    |> :ets.tab2list()
    |> Enum.count(fn {_k, v} -> v.actual_quality != nil end)
  rescue
    _ -> 0
  end

  defp build_lineage do
    @outcomes_table
    |> :ets.tab2list()
    |> Enum.map(fn {topic_key, record} ->
      %{
        topic: topic_key,
        source: Map.get(record, :source_topic, "seed"),
        selection_source: Map.get(record, :source, :unknown),
        depth: Map.get(record, :depth, 0),
        predicted_ig: record.predicted_ig,
        actual_quality: record.actual_quality,
        added_at: record.added_at
      }
    end)
    |> Enum.sort_by(& &1.added_at)
  rescue
    _ -> []
  end

  # ── File-Backed Persistence ────────────────────────────────────────

  defp persistence_path do
    config_dir = Application.get_env(:daemon, :config_dir, "~/.daemon") |> Path.expand()
    Path.join(config_dir, @persistence_file)
  end

  defp persist_state(state) do
    data = %{
      "version" => 2,
      "arms" => %{
        "emergent" => %{"alpha" => state.arms.emergent.alpha, "beta" => state.arms.emergent.beta},
        "policy" => %{"alpha" => state.arms.policy.alpha, "beta" => state.arms.policy.beta}
      },
      "topics_added" => state.topics_added,
      "last_added_at" => if(state.last_added_at, do: DateTime.to_iso8601(state.last_added_at)),
      "outcomes" => serialize_outcomes(),
      "seen_topics" => serialize_seen_topics()
    }

    path = persistence_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  rescue
    e ->
      Logger.warning("[ActiveLearner] Failed to persist state: #{Exception.message(e)}")
  end

  defp load_persisted_state do
    case File.read(persistence_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"version" => _} = data} -> data
          _ ->
            Logger.warning("[ActiveLearner] Corrupted state file, starting fresh")
            %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp hydrate_ets(persisted) do
    # Restore outcomes
    outcomes = Map.get(persisted, "outcomes", [])
    Enum.each(outcomes, fn entry ->
      key = Map.get(entry, "key", "")
      record = %{
        predicted_ig: Map.get(entry, "predicted_ig", 0.0),
        actual_quality: Map.get(entry, "actual_quality"),
        source_topic: Map.get(entry, "source_topic", "unknown"),
        source: parse_source(Map.get(entry, "source", "policy")),
        depth: Map.get(entry, "depth", 0),
        added_at: Map.get(entry, "added_at", 0)
      }
      if key != "", do: :ets.insert(@outcomes_table, {key, record})
    end)

    # Restore seen topics
    seen = Map.get(persisted, "seen_topics", [])
    now = System.system_time(:second)
    Enum.each(seen, fn entry ->
      key = Map.get(entry, "key", "")
      seen_at = Map.get(entry, "seen_at", 0)
      # Only restore if not expired
      if key != "" and (now - seen_at) < @seen_ttl_seconds do
        :ets.insert(@seen_topics_table, {key, seen_at})
      end
    end)

    restored_outcomes = length(outcomes)
    restored_seen = length(seen)
    if restored_outcomes > 0 or restored_seen > 0 do
      Logger.info("[ActiveLearner] Restored #{restored_outcomes} outcomes, #{restored_seen} seen topics from disk")
    end
  rescue
    e ->
      Logger.warning("[ActiveLearner] Failed to hydrate ETS: #{Exception.message(e)}")
  end

  defp serialize_outcomes do
    @outcomes_table
    |> :ets.tab2list()
    |> Enum.map(fn {key, record} ->
      %{
        "key" => key,
        "predicted_ig" => record.predicted_ig,
        "actual_quality" => record.actual_quality,
        "source_topic" => Map.get(record, :source_topic, "unknown"),
        "source" => Atom.to_string(Map.get(record, :source, :policy)),
        "depth" => Map.get(record, :depth, 0),
        "added_at" => record.added_at
      }
    end)
  rescue
    _ -> []
  end

  defp serialize_seen_topics do
    @seen_topics_table
    |> :ets.tab2list()
    |> Enum.map(fn {key, seen_at} ->
      %{"key" => key, "seen_at" => seen_at}
    end)
  rescue
    _ -> []
  end

  defp parse_arms(raw) when is_map(raw) do
    %{
      emergent: parse_single_arm(Map.get(raw, "emergent", %{})),
      policy: parse_single_arm(Map.get(raw, "policy", %{}))
    }
  end

  defp parse_arms(_), do: default_arms()

  defp parse_single_arm(%{"alpha" => a, "beta" => b})
    when is_number(a) and is_number(b) and a > 0 and b > 0 do
    %{alpha: a / 1.0, beta: b / 1.0}
  end

  defp parse_single_arm(_), do: %{alpha: 1.0, beta: 1.0}

  defp parse_source("emergent"), do: :emergent
  defp parse_source("policy"), do: :policy
  defp parse_source(_), do: :policy

  defp parse_datetime(nil), do: nil
  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil

  # ── ETS Dedup with TTL ──────────────────────────────────────────────

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

  defp seen_fresh?(task_text) do
    key = normalize_topic(task_text)

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

  defp mark_seen(task_text) do
    key = normalize_topic(task_text)
    :ets.insert(@seen_topics_table, {key, System.system_time(:second)})
  rescue
    _ -> :ok
  end
end
