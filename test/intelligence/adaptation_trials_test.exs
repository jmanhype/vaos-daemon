defmodule Daemon.Intelligence.AdaptationTrialsTest do
  use ExUnit.Case, async: false

  alias Daemon.Intelligence.AdaptationTrials

  defmodule JournalStub do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{recorded: []} end, name: __MODULE__)
    end

    def record_adaptation(domain, event_type, context) do
      Agent.update(__MODULE__, fn state ->
        event = %{
          domain: normalize(domain),
          event_type: normalize(event_type),
          timestamp: DateTime.utc_now(),
          context: normalize_context(context)
        }

        %{state | recorded: [event | state.recorded]}
      end)
    end

    def recorded do
      Agent.get(__MODULE__, & &1.recorded)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{recorded: []} end)
    end

    defp normalize(value) when is_atom(value), do: Atom.to_string(value)
    defp normalize(value), do: value

    defp normalize_context(context) when is_map(context) do
      Map.new(context, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)
    end
  end

  defmodule BusStub do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{handlers: %{}} end, name: __MODULE__)
    end

    def register_handler(event_type, handler_fn) do
      ref = make_ref()

      Agent.update(__MODULE__, fn state ->
        put_in(state, [:handlers, ref], {event_type, handler_fn})
      end)

      ref
    end

    def unregister_handler(_event_type, ref) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [:handlers], &Map.delete(&1, ref))
      end)
    end

    def emit_system_event(payload) do
      handlers =
        Agent.get(__MODULE__, fn state ->
          state.handlers
          |> Map.values()
          |> Enum.filter(fn {event_type, _handler_fn} -> event_type == :system_event end)
        end)

      Enum.each(handlers, fn {_event_type, handler_fn} -> handler_fn.(payload) end)
    end
  end

  setup do
    case Process.whereis(JournalStub) do
      nil -> start_supervised!(JournalStub)
      _pid -> JournalStub.reset()
    end

    :ok
  end

  test "starts a bounded steering trial from trusted research meta intent" do
    name = :"adaptation-trials-test-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       scorer: fn _ -> 0.0 end,
       subscribe?: false,
       trial_ttl_ms: :timer.minutes(10)}
    )

    assert {:started, trial} =
             AdaptationTrials.consider_intent(
               :meta_reflect_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    assert trial.domain == "research"
    assert trial.trial_type == "steering"
    assert trial.status == :pending
    assert trial.remaining_uses == 1
    assert trial.trigger_event == "meta_reflect_requested"
    assert trial.steering =~ "TRIAL STEERING"

    recorded_types = Enum.map(JournalStub.recorded(), & &1.event_type)
    assert "trial_started" in recorded_types
  end

  test "consume plus observe completes a one-shot trial and clears it" do
    name = :"adaptation-trials-complete-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       scorer: fn _ -> 0.72 end,
       subscribe?: false,
       trial_ttl_ms: :timer.minutes(10)}
    )

    assert {:started, _trial} =
             AdaptationTrials.consider_intent(
               :meta_pivot_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    assert {:ok, consumed} = AdaptationTrials.consume_trial("sleep latency topic", name)
    assert consumed.status == :awaiting_outcome
    assert consumed.remaining_uses == 0

    :ok =
      AdaptationTrials.observe_investigation(
        %{"topic" => "sleep latency topic", "strategy_hash" => "abc123"},
        name
      )

    assert AdaptationTrials.current_trial(name) == nil

    recorded_types = Enum.map(JournalStub.recorded(), & &1.event_type)
    assert "trial_applied" in recorded_types
    assert "trial_completed" in recorded_types

    completed =
      JournalStub.recorded()
      |> Enum.find(&(&1.event_type == "trial_completed"))

    assert completed.context["outcome"] == "helpful"
    assert completed.context["quality"] == 0.72
  end

  test "ignores non-research authority intents for steering trials" do
    name = :"adaptation-trials-ignore-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name, journal: JournalStub, scorer: fn _ -> 0.0 end, subscribe?: false}
    )

    assert :ignored =
             AdaptationTrials.consider_intent(
               :meta_reflect_requested,
               %{authority_domain: "reliability", bottleneck: "low_verification"},
               name
             )

    assert AdaptationTrials.current_trial(name) == nil
    assert JournalStub.recorded() == []
  end

  test "blocked investigation closes the active trial explicitly" do
    name = :"adaptation-trials-blocked-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       scorer: fn _ -> 0.0 end,
       subscribe?: false,
       trial_ttl_ms: :timer.minutes(10)}
    )

    assert {:started, _trial} =
             AdaptationTrials.consider_intent(
               :meta_pivot_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    assert {:ok, _consumed} = AdaptationTrials.consume_trial("sleep latency topic", name)

    :ok =
      AdaptationTrials.observe_failure(
        "sleep latency topic",
        "HTTP 429 from provider",
        name
      )

    assert AdaptationTrials.current_trial(name) == nil

    blocked =
      JournalStub.recorded()
      |> Enum.find(&(&1.event_type == "trial_blocked"))

    assert blocked.context["outcome"] == "blocked"
    assert blocked.context["reason"] == "HTTP 429 from provider"
  end

  test "retries bus subscription until heartbeat intents can be observed" do
    name = :"adaptation-trials-retry-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       bus: BusStub,
       scorer: fn _ -> 0.0 end,
       subscribe?: true,
       subscribe_retry_ms: 10,
       trial_ttl_ms: :timer.minutes(10)}
    )

    assert AdaptationTrials.current_trial(name) == nil

    start_supervised!(BusStub)
    Process.sleep(30)

    BusStub.emit_system_event(%{
      event: :adaptation_signal,
      domain: :coordination,
      event_type: :meta_pivot_requested,
      context: %{authority_domain: "research", bottleneck: "low_verification"}
    })

    Process.sleep(30)

    assert %{trigger_event: "meta_pivot_requested", status: :pending} =
             AdaptationTrials.current_trial(name)
  end
end
