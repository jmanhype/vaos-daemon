defmodule Daemon.Agent.ActiveLearner do
  @moduledoc """
  Closes the investigation → topic selection loop with outcome-weighted learning.

  Subscribes to `:investigation_complete` events and extracts `suggested_next`
  topics (ranked by information gain via `Policy.rank_actions`). Uses ε-greedy
  selection to pick the best suggestion and appends it to HEARTBEAT.md as a new
  pending task.

  **Learning loop**: Tracks which auto-added topics produced high-quality
  investigations. Maintains a correction factor (predicted IG vs actual quality)
  that improves topic selection over time. Without this, we'd just be an infinite
  loop — with it, we're an infinite loop that gets better at picking topics.

  Seen topics expire after 7 days, allowing re-investigation when new evidence
  accumulates.
  """
  use GenServer
  require Logger

  alias Daemon.Investigation.Retrospector
  alias Daemon.Agent.Scheduler
  alias Daemon.Agent.Scheduler.Heartbeat

  @quality_threshold 0.25
  @epsilon 0.20
  @max_pending_tasks 20
  @subscribe_delay_ms 5_000
  @task_prefix "Investigate: "
  @seen_topics_table :active_learner_seen_topics
  @outcomes_table :active_learner_outcomes
  @seen_ttl_seconds 7 * 24 * 3600

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats: topics_added count, last_added_at, and learning correction factor."
  @spec stats() :: map()
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{topics_added: 0, last_added_at: nil, correction_factor: 1.0, outcomes_count: 0}
    catch
      :exit, _ -> %{topics_added: 0, last_added_at: nil, correction_factor: 1.0, outcomes_count: 0}
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_ets_table(@seen_topics_table)
    ensure_ets_table(@outcomes_table)
    Process.send_after(self(), :subscribe, @subscribe_delay_ms)
    Logger.info("[ActiveLearner] Started")
    {:ok, %{event_ref: nil, topics_added: 0, last_added_at: nil}}
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

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    reply = %{
      topics_added: state.topics_added,
      last_added_at: state.last_added_at,
      correction_factor: compute_correction_factor(),
      outcomes_count: count_outcomes()
    }

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{event_ref: ref}) when not is_nil(ref) do
    Daemon.Events.Bus.unregister_handler(:investigation_complete, ref)
    :ok
  end

  def terminate(_, _), do: :ok

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

    # Record outcome if this investigation was an ActiveLearner-originated topic
    record_outcome_if_ours(data, quality)

    if quality < @quality_threshold do
      Logger.debug("[ActiveLearner] Skipping — quality #{Float.round(quality, 3)} below threshold #{@quality_threshold}")
      state
    else
      maybe_add_topic(data, quality, state)
    end
  end

  defp maybe_add_topic(data, quality, state) do
    suggested = extract_suggested_next(data)

    if suggested == [] do
      Logger.debug("[ActiveLearner] No suggested_next in event data")
      state
    else
      # Read heartbeat file ONCE for both dedup and cap check
      {pending_tasks, completed_tasks} = read_heartbeat_tasks()
      pending_len = length(pending_tasks)

      # Try suggestions in order until one sticks (don't bail on first dupe)
      ranked = rank_suggestions(suggested)
      try_add_suggestion(ranked, quality, pending_tasks, completed_tasks, pending_len, state)
    end
  end

  defp try_add_suggestion([], _quality, _pending, _completed, _pending_len, state), do: state

  defp try_add_suggestion([suggestion | rest], quality, pending, completed, pending_len, state) do
    task_text = build_task_text(suggestion)

    cond do
      pending_len >= @max_pending_tasks ->
        Logger.debug("[ActiveLearner] Pending task cap reached (#{@max_pending_tasks})")
        state

      seen_fresh?(task_text) ->
        Logger.debug("[ActiveLearner] Already seen: '#{task_text}'")
        try_add_suggestion(rest, quality, pending, completed, pending_len, state)

      heartbeat_has_task?(task_text, pending, completed) ->
        Logger.debug("[ActiveLearner] Already in HEARTBEAT.md: '#{task_text}'")
        mark_seen(task_text)
        try_add_suggestion(rest, quality, pending, completed, pending_len, state)

      true ->
        case safe_add_heartbeat_task(task_text) do
          :ok ->
            ig = get_ig(suggestion)
            Logger.info("[ActiveLearner] Added: '#{task_text}' (ig: #{Float.round(ig * 1.0, 3)}, quality: #{Float.round(quality, 3)})")
            mark_seen(task_text)
            record_prediction(task_text, ig)
            %{state | topics_added: state.topics_added + 1, last_added_at: DateTime.utc_now()}

          {:error, reason} ->
            Logger.warning("[ActiveLearner] Failed to add task: #{inspect(reason)}")
            state
        end
    end
  end

  defp extract_suggested_next(data) do
    suggested = Map.get(data, :suggested_next) || Map.get(data, "suggested_next") || []

    case suggested do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp rank_suggestions(suggestions) do
    correction = compute_correction_factor()

    if :rand.uniform() < @epsilon do
      Enum.shuffle(suggestions)
    else
      Enum.sort_by(suggestions, fn s -> -(get_ig(s) * correction) end)
    end
  end

  defp get_ig(suggestion) do
    Map.get(suggestion, :information_gain, Map.get(suggestion, "information_gain", 0.0))
  end

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

  # ── Outcome Tracking (Learning Loop) ────────────────────────────────
  # Records predicted_ig when we add a topic, then actual_quality when
  # that topic's investigation completes. The ratio becomes a correction
  # factor that makes future IG predictions more accurate.

  defp record_prediction(task_text, predicted_ig) do
    key = normalize_topic(task_text)

    :ets.insert(@outcomes_table, {key, %{
      predicted_ig: predicted_ig,
      actual_quality: nil,
      added_at: System.system_time(:second)
    }})
  rescue
    _ -> :ok
  end

  defp record_outcome_if_ours(data, quality) do
    topic = Map.get(data, :topic) || Map.get(data, "topic") || ""
    key = normalize_topic(@task_prefix <> topic)

    case :ets.lookup(@outcomes_table, key) do
      [{^key, %{actual_quality: nil} = record}] ->
        :ets.insert(@outcomes_table, {key, %{record | actual_quality: quality}})
        Logger.debug("[ActiveLearner] Recorded outcome for '#{topic}': quality=#{Float.round(quality, 3)}")

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
          # Expired — delete and treat as unseen
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
