defmodule Daemon.Intelligence.AdaptationHeartbeat do
  @moduledoc """
  Thin CORAL-style heartbeat for the adaptation control plane.

  Periodically inspects `DecisionJournal` meta-state and recent adaptation
  signals, then records lightweight coordination intents:

  - `meta_reflect_requested`
  - `meta_consolidate_requested`
  - `meta_pivot_requested`

  This module does not arbitrate between adaptive subsystems or rewrite policy.
  It only makes adaptation timing explicit and durable so VAOS can observe when
  it believed reflection, consolidation, or pivoting was warranted.
  """
  use GenServer
  require Logger

  alias Daemon.Intelligence.DecisionJournal

  @default_recent_limit 50
  @default_interval_ms :timer.minutes(5)
  @default_signal_freshness_ms :timer.minutes(30)
  @intent_cooldown_events 8
  @reflect_failure_threshold 2
  @pivot_failure_threshold 2
  @consolidate_progress_threshold 6

  @consolidation_event_types MapSet.new([
                             "topic_selected",
                             "steering_applied",
                             "prompt_evolution_triggered",
                             "prompt_variant_registered",
                             "strategy_experiment_keep",
                             "synthesis_completed"
                           ])

  defstruct journal: DecisionJournal,
            interval_ms: @default_interval_ms,
            recent_limit: @default_recent_limit,
            tick_count: 0,
            last_tick_at: nil,
            intents_emitted: %{
              reflect: 0,
              consolidate: 0,
              pivot: 0
            }

  @type state :: %__MODULE__{}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Force a heartbeat evaluation immediately."
  def tick_now(server \\ __MODULE__) do
    GenServer.cast(server, :tick_now)
  end

  @doc "Heartbeat runtime stats."
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc false
  def detect_intents(meta_state, recent_events, journal_stats) do
    journal_status = Map.get(journal_stats, :status, :running)
    fresh_events = fresh_recent_events(recent_events)

    if journal_status != :running do
      []
    else
      []
      |> maybe_add_reflect(meta_state, fresh_events, journal_stats)
      |> maybe_add_consolidate(meta_state, fresh_events, journal_stats)
      |> maybe_add_pivot(meta_state, fresh_events, journal_stats)
    end
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      journal: Keyword.get(opts, :journal, DecisionJournal),
      interval_ms: Keyword.get(opts, :interval_ms, Application.get_env(:daemon, :adaptation_heartbeat_interval_ms, @default_interval_ms)),
      recent_limit: Keyword.get(opts, :recent_limit, @default_recent_limit)
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state.interval_ms)
    {:noreply, run_tick(state)}
  end

  @impl true
  def handle_cast(:tick_now, state) do
    {:noreply, run_tick(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       status: :running,
       tick_count: state.tick_count,
       last_tick_at: state.last_tick_at,
       intents_emitted: state.intents_emitted,
       interval_ms: state.interval_ms,
       recent_limit: state.recent_limit
     }, state}
  end

  defp run_tick(state) do
    meta_state = safe_call(state.journal, :meta_state, [], %{})
    recent_events = safe_call(state.journal, :adaptation_events, [state.recent_limit], [])
    journal_stats = safe_call(state.journal, :stats, [], %{status: :not_running})
    intents = detect_intents(meta_state, recent_events, journal_stats)

    Enum.each(intents, fn {event_type, context} ->
      state.journal.record_adaptation(:coordination, event_type, context)
      Logger.info("[AdaptationHeartbeat] intent=#{event_type} trigger=#{Map.get(context, :trigger, "-")}")
    end)

    intents_emitted =
      Enum.reduce(intents, state.intents_emitted, fn {event_type, _context}, acc ->
        case event_type do
          :meta_reflect_requested -> Map.update!(acc, :reflect, &(&1 + 1))
          :meta_consolidate_requested -> Map.update!(acc, :consolidate, &(&1 + 1))
          :meta_pivot_requested -> Map.update!(acc, :pivot, &(&1 + 1))
        end
      end)

    %{state | tick_count: state.tick_count + 1, last_tick_at: DateTime.utc_now(), intents_emitted: intents_emitted}
  end

  defp maybe_add_reflect(intents, meta_state, recent_events, journal_stats) do
    failed_count = meta_state |> Map.get(:recent_failed_adaptations, []) |> length()

    if failed_count >= @reflect_failure_threshold and
         not recent_intent?(recent_events, "meta_reflect_requested") do
      intents ++
        [
          {:meta_reflect_requested,
           %{
             trigger: "failed_adaptation_cluster",
             authority_domain: Map.get(meta_state, :authority_domain),
             bottleneck: Map.get(meta_state, :active_bottleneck),
             failed_adaptation_count: failed_count,
             in_flight_count: Map.get(journal_stats, :in_flight_count, 0)
           }}
        ]
    else
      intents
    end
  end

  defp maybe_add_consolidate(intents, meta_state, recent_events, journal_stats) do
    progress_count = Enum.count(recent_events, &research_progress_event?/1)

    if progress_count >= @consolidate_progress_threshold and
         not recent_intent?(recent_events, "meta_consolidate_requested") do
      intents ++
        [
          {:meta_consolidate_requested,
           %{
             trigger: "accumulated_research_progress",
             authority_domain: Map.get(meta_state, :authority_domain),
             bottleneck: Map.get(meta_state, :active_bottleneck),
             progress_event_count: progress_count,
             signal_count: Map.get(journal_stats, :adaptation_event_count, length(recent_events))
           }}
        ]
    else
      intents
    end
  end

  defp maybe_add_pivot(intents, meta_state, recent_events, journal_stats) do
    research_failure_count = Enum.count(recent_events, &research_failure_event?/1)
    authority_domain = Map.get(meta_state, :authority_domain)

    if research_failure_count >= @pivot_failure_threshold and authority_domain in ["research", nil] and
         not recent_intent?(recent_events, "meta_pivot_requested") do
      intents ++
        [
          {:meta_pivot_requested,
           %{
             trigger: "repeated_research_stagnation",
             authority_domain: authority_domain,
             bottleneck: Map.get(meta_state, :active_bottleneck),
             research_failure_count: research_failure_count,
             last_experiment: format_last_experiment(Map.get(meta_state, :last_experiment)),
             in_flight_count: Map.get(journal_stats, :in_flight_count, 0)
           }}
        ]
    else
      intents
    end
  end

  defp recent_intent?(recent_events, event_type) do
    recent_events
    |> Enum.take(@intent_cooldown_events)
    |> Enum.any?(fn event -> event_value(event, :event_type) == event_type end)
  end

  defp fresh_recent_events(recent_events, now \\ DateTime.utc_now()) do
    freshness_ms = signal_freshness_ms()

    Enum.filter(recent_events, fn event ->
      case event_timestamp(event) do
        %DateTime{} = timestamp ->
          DateTime.diff(now, timestamp, :millisecond) <= freshness_ms

        _ ->
          false
      end
    end)
  end

  defp research_progress_event?(event) do
    event_value(event, :domain) == "research" and
      MapSet.member?(@consolidation_event_types, event_value(event, :event_type))
  end

  defp research_failure_event?(event) do
    domain = event_value(event, :domain)
    event_type = event_value(event, :event_type) || ""
    context = event_value(event, :context)

    domain == "research" and
      (String.contains?(event_type, "revert") or
         String.contains?(event_type, "inconclusive") or
         event_type == "quality_gate_skip" or
         context_value(context, "outcome") in ["failure", "failed", "reverted", "error"])
  end

  defp event_value(event, key) do
    Map.get(event, key) || Map.get(event, to_string(key), default_event_value(key))
  end

  defp event_timestamp(event) do
    Map.get(event, :timestamp) || Map.get(event, "timestamp")
  end

  defp default_event_value(:context), do: %{}
  defp default_event_value(_), do: nil

  defp context_value(context, key) when is_map(context) do
    atom_key =
      case key do
        "outcome" -> :outcome
        _ -> nil
      end

    Map.get(context, key) || (atom_key && Map.get(context, atom_key))
  end

  defp context_value(_, _), do: nil

  defp format_last_experiment(%{domain: domain, event_type: event_type}), do: "#{domain}/#{event_type}"
  defp format_last_experiment(_), do: nil

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp signal_freshness_ms do
    Application.get_env(:daemon, :adaptation_meta_freshness_ms, @default_signal_freshness_ms)
  end

  defp safe_call(module, function, args, fallback) do
    try do
      apply(module, function, args)
    rescue
      _ -> fallback
    catch
      :exit, _ -> fallback
    end
  end
end
