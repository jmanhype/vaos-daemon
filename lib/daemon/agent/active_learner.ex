defmodule Daemon.Agent.ActiveLearner do
  @moduledoc """
  Closes the investigation → topic selection loop.

  Subscribes to `:investigation_complete` events and extracts `suggested_next`
  topics (ranked by information gain via `Policy.rank_actions`). Uses ε-greedy
  selection to pick the best suggestion and appends it to HEARTBEAT.md as a new
  pending task.

  This creates an infinite self-directed research agenda: seed topics produce
  investigations, which produce suggested_next, which become new heartbeat tasks,
  which produce more investigations, ad infinitum.
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

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats: topics_added count and last_added_at datetime."
  @spec stats() :: %{topics_added: non_neg_integer(), last_added_at: DateTime.t() | nil}
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{topics_added: 0, last_added_at: nil}
    catch
      :exit, _ -> %{topics_added: 0, last_added_at: nil}
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_ets_table()
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
    state = maybe_add_topic(data, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{topics_added: state.topics_added, last_added_at: state.last_added_at}, state}
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

  defp maybe_add_topic(data, state) do
    quality = Retrospector.compute_quality(data)

    if quality < @quality_threshold do
      Logger.debug("[ActiveLearner] Skipping — quality #{Float.round(quality, 3)} below threshold #{@quality_threshold}")
      state
    else
      suggested = extract_suggested_next(data)

      if suggested == [] do
        Logger.debug("[ActiveLearner] No suggested_next in event data")
        state
      else
        case select_suggestion(suggested) do
          nil ->
            state

          suggestion ->
            task_text = build_task_text(suggestion)

            cond do
              seen?(task_text) ->
                Logger.debug("[ActiveLearner] Already seen: '#{task_text}'")
                state

              heartbeat_contains?(task_text) ->
                Logger.debug("[ActiveLearner] Already in HEARTBEAT.md: '#{task_text}'")
                mark_seen(task_text)
                state

              pending_count() >= @max_pending_tasks ->
                Logger.debug("[ActiveLearner] Pending task cap reached (#{@max_pending_tasks})")
                state

              true ->
                case safe_add_heartbeat_task(task_text) do
                  :ok ->
                    ig = Map.get(suggestion, :information_gain, Map.get(suggestion, "information_gain", 0.0))
                    Logger.info("[ActiveLearner] Added: '#{task_text}' (ig: #{Float.round(ig * 1.0, 3)}, quality: #{Float.round(quality, 3)})")
                    mark_seen(task_text)
                    %{state | topics_added: state.topics_added + 1, last_added_at: DateTime.utc_now()}

                  {:error, reason} ->
                    Logger.warning("[ActiveLearner] Failed to add task: #{inspect(reason)}")
                    state
                end
            end
        end
      end
    end
  end

  defp extract_suggested_next(data) do
    # Handle both :suggested_next and "suggested_next" keys
    suggested = Map.get(data, :suggested_next) || Map.get(data, "suggested_next") || []

    case suggested do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc false
  def select_suggestion([]), do: nil

  def select_suggestion(suggestions) do
    if :rand.uniform() < @epsilon do
      # Exploration: random pick
      Enum.random(suggestions)
    else
      # Exploitation: highest information_gain
      Enum.max_by(suggestions, fn s ->
        Map.get(s, :information_gain, Map.get(s, "information_gain", 0.0))
      end)
    end
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

  defp heartbeat_contains?(task_text) do
    normalized = normalize_topic(task_text)

    case File.read(Heartbeat.path()) do
      {:ok, content} ->
        pending = Heartbeat.parse_pending_tasks(content)
        completed = parse_completed_tasks(content)
        all_tasks = pending ++ completed

        Enum.any?(all_tasks, fn t ->
          normalize_topic(t) == normalized
        end)

      {:error, _} ->
        false
    end
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

  defp pending_count do
    case File.read(Heartbeat.path()) do
      {:ok, content} -> length(Heartbeat.parse_pending_tasks(content))
      {:error, _} -> 0
    end
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

  # ── ETS Dedup ───────────────────────────────────────────────────────

  defp ensure_ets_table do
    case :ets.whereis(@seen_topics_table) do
      :undefined ->
        :ets.new(@seen_topics_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @seen_topics_table
    end
  rescue
    _ -> @seen_topics_table
  end

  defp seen?(task_text) do
    key = normalize_topic(task_text)

    case :ets.lookup(@seen_topics_table, key) do
      [{^key, _}] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp mark_seen(task_text) do
    key = normalize_topic(task_text)
    :ets.insert(@seen_topics_table, {key, DateTime.utc_now()})
  rescue
    _ -> :ok
  end
end
