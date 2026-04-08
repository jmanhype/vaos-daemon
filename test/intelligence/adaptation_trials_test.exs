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

  defp complete_trial(server, topic, strategy_hash) do
    assert {:started, _trial} =
             AdaptationTrials.consider_intent(
               :meta_pivot_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               server
             )

    assert {:ok, _consumed} = AdaptationTrials.consume_trial(topic, server)

    :ok =
      AdaptationTrials.observe_investigation(
        %{"topic" => topic, "strategy_hash" => strategy_hash},
        server
      )
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
    assert trial.steering =~ "quote the EXACT sentence from the abstract"

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

  test "normalized investigation payload still scores helpful when evidence is present" do
    name = :"adaptation-trials-normalized-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       subscribe?: false,
       trial_ttl_ms: :timer.minutes(10)}
    )

    assert {:started, _trial} =
             AdaptationTrials.consider_intent(
               :meta_reflect_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    assert {:ok, _consumed} = AdaptationTrials.consume_trial("normalized payload topic", name)

    :ok =
      AdaptationTrials.observe_investigation(
        %{
          "topic" => "normalized payload topic",
          "strategy_hash" => "normalized-hash",
          "supporting" => [
            %{"source_type" => :sourced, "verification" => "verified"}
          ],
          "opposing" => [],
          "grounded_for_count" => 1,
          "grounded_against_count" => 0,
          "fraudulent_citations" => 0,
          "uncertainty" => 0.0
        },
        name
      )

    completed =
      JournalStub.recorded()
      |> Enum.find(&(&1.event_type == "trial_completed"))

    assert completed.context["outcome"] == "helpful"
    assert completed.context["quality"] >= 0.75
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

  test "accepts live event-bus envelopes with adaptation payload under data" do
    name = :"adaptation-trials-envelope-#{System.unique_integer([:positive])}"

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

    start_supervised!(BusStub)
    Process.sleep(30)

    BusStub.emit_system_event(%{
      type: :system_event,
      data: %{
        event: :adaptation_signal,
        domain: :coordination,
        event_type: :meta_pivot_requested,
        context: %{authority_domain: "research", bottleneck: "low_verification"}
      }
    })

    Process.sleep(30)

    assert %{trigger_event: "meta_pivot_requested", status: :pending} =
             AdaptationTrials.current_trial(name)
  end

  test "promotes repeated helpful trials into a temporary default" do
    name = :"adaptation-trials-promotion-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       scorer: fn _ -> 0.82 end,
       subscribe?: false,
       promotion_threshold: 2,
       promotion_ttl_ms: :timer.minutes(20)}
    )

    complete_trial(name, "topic one", "keep-1")
    complete_trial(name, "topic two", "keep-2")

    snapshot = AdaptationTrials.snapshot(name)
    assert snapshot.current_trial == nil

    assert [
             %{
               trigger_event: "meta_pivot_requested",
               bottleneck: "low_verification",
               helpful_streak: 2
             }
           ] = snapshot.active_promotions

    assert AdaptationTrials.promoted_steering("low_verification", name) =~ "TRIAL STEERING"

    recorded_types = Enum.map(JournalStub.recorded(), & &1.event_type)
    assert "trial_promoted" in recorded_types
  end

  test "suppresses repeated negative trials and ignores blocked trials as evidence" do
    name = :"adaptation-trials-suppression-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationTrials,
       name: name,
       journal: JournalStub,
       scorer: fn _ -> 0.12 end,
       subscribe?: false,
       suppression_threshold: 2,
       suppression_ttl_ms: :timer.minutes(20)}
    )

    assert {:started, _trial} =
             AdaptationTrials.consider_intent(
               :meta_pivot_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    assert {:ok, _consumed} = AdaptationTrials.consume_trial("blocked topic", name)
    :ok = AdaptationTrials.observe_failure("blocked topic", "HTTP 429", name)

    complete_trial(name, "negative one", "drop-1")
    complete_trial(name, "negative two", "drop-2")

    snapshot = AdaptationTrials.snapshot(name)
    assert snapshot.current_trial == nil
    assert length(snapshot.active_suppressions) == 1

    assert :suppressed =
             AdaptationTrials.consider_intent(
               :meta_pivot_requested,
               %{authority_domain: "research", bottleneck: "low_verification"},
               name
             )

    recorded_types = Enum.map(JournalStub.recorded(), & &1.event_type)
    assert "trial_suppression_started" in recorded_types
    assert "trial_suppressed" in recorded_types
    refute "trial_promoted" in recorded_types
  end
end
