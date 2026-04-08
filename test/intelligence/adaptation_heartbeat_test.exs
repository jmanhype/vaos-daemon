defmodule Daemon.Intelligence.AdaptationHeartbeatTest do
  use ExUnit.Case, async: false

  alias Daemon.Intelligence.AdaptationHeartbeat

  defmodule JournalStub do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            meta_state: %{},
            recent_events: [],
            stats: %{status: :running, adaptation_event_count: 0, in_flight_count: 0},
            recorded: []
          }
        end,
        name: __MODULE__
      )
    end

    def seed(meta_state, recent_events, stats \\ %{}) do
      Agent.update(__MODULE__, fn _state ->
        %{
          meta_state: meta_state,
          recent_events: recent_events,
          stats:
            Map.merge(%{status: :running, adaptation_event_count: length(recent_events), in_flight_count: 0}, stats),
          recorded: []
        }
      end)
    end

    def meta_state do
      Agent.get(__MODULE__, & &1.meta_state)
    end

    def adaptation_events(limit) do
      Agent.get(__MODULE__, fn state ->
        (state.recorded ++ state.recent_events)
        |> Enum.take(limit)
      end)
    end

    def stats do
      Agent.get(__MODULE__, fn state ->
        Map.put(state.stats, :adaptation_event_count, length(state.recorded) + length(state.recent_events))
      end)
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

    defp normalize(value) when is_atom(value), do: Atom.to_string(value)
    defp normalize(value), do: value

    defp normalize_context(context) when is_map(context) do
      Map.new(context, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)
    end
  end

  setup do
    case Process.whereis(JournalStub) do
      nil -> start_supervised!(JournalStub)
      _pid -> :ok
    end

    :ok
  end

  test "detect_intents requests reflect and pivot from clustered failures" do
    meta_state = %{
      authority_domain: "research",
      active_bottleneck: "low_verification",
      recent_failed_adaptations: [%{event_type: "strategy_experiment_revert"}, %{event_type: "quality_gate_skip"}],
      last_experiment: %{domain: "research", event_type: "strategy_experiment_inconclusive"}
    }

    recent_events = [
      event("research", "strategy_experiment_revert"),
      event("research", "quality_gate_skip")
    ]

    intents = AdaptationHeartbeat.detect_intents(meta_state, recent_events, %{status: :running, in_flight_count: 1})

    assert {:meta_reflect_requested, reflect_context} = Enum.at(intents, 0)
    assert reflect_context.trigger == "failed_adaptation_cluster"

    assert {:meta_pivot_requested, pivot_context} = Enum.at(intents, 1)
    assert pivot_context.trigger == "repeated_research_stagnation"
    assert pivot_context.research_failure_count == 2
  end

  test "detect_intents requests consolidation after enough research progress" do
    meta_state = %{
      authority_domain: "research",
      active_bottleneck: "low_verification",
      recent_failed_adaptations: [],
      last_experiment: nil
    }

    recent_events = [
      event("research", "topic_selected"),
      event("research", "steering_applied"),
      event("research", "prompt_evolution_triggered"),
      event("research", "prompt_variant_registered"),
      event("research", "strategy_experiment_keep"),
      event("research", "synthesis_completed")
    ]

    intents = AdaptationHeartbeat.detect_intents(meta_state, recent_events, %{status: :running})

    assert [{:meta_consolidate_requested, context}] = intents
    assert context.trigger == "accumulated_research_progress"
    assert context.progress_event_count == 6
  end

  test "detect_intents suppresses duplicate markers within cooldown window" do
    meta_state = %{
      authority_domain: "research",
      active_bottleneck: "low_verification",
      recent_failed_adaptations: [%{event_type: "strategy_experiment_revert"}, %{event_type: "quality_gate_skip"}],
      last_experiment: %{domain: "research", event_type: "strategy_experiment_inconclusive"}
    }

    recent_events = [
      event("coordination", "meta_reflect_requested"),
      event("coordination", "meta_pivot_requested"),
      event("research", "strategy_experiment_revert"),
      event("research", "quality_gate_skip")
    ]

    intents = AdaptationHeartbeat.detect_intents(meta_state, recent_events, %{status: :running})

    assert intents == []
  end

  test "detect_intents ignores stale research events outside the freshness window" do
    meta_state = %{
      authority_domain: "research",
      active_bottleneck: "low_verification",
      recent_failed_adaptations: [],
      last_experiment: nil
    }

    stale_time = DateTime.add(DateTime.utc_now(), -2, :hour)

    recent_events = [
      event("research", "topic_selected", %{}, stale_time),
      event("research", "steering_applied", %{}, stale_time),
      event("research", "prompt_evolution_triggered", %{}, stale_time),
      event("research", "prompt_variant_registered", %{}, stale_time),
      event("research", "strategy_experiment_keep", %{}, stale_time),
      event("research", "synthesis_completed", %{}, stale_time),
      event("research", "strategy_experiment_revert", %{}, stale_time),
      event("research", "quality_gate_skip", %{}, stale_time)
    ]

    intents = AdaptationHeartbeat.detect_intents(meta_state, recent_events, %{status: :running})

    assert intents == []
  end

  test "tick_now records coordination intents into the journal" do
    JournalStub.seed(
      %{
        authority_domain: "research",
        active_bottleneck: "low_verification",
        recent_failed_adaptations: [%{event_type: "strategy_experiment_revert"}, %{event_type: "quality_gate_skip"}],
        last_experiment: %{domain: "research", event_type: "strategy_experiment_inconclusive"}
      },
      [
        event("research", "topic_selected"),
        event("research", "steering_applied"),
        event("research", "prompt_evolution_triggered"),
        event("research", "prompt_variant_registered"),
        event("research", "strategy_experiment_keep"),
        event("research", "synthesis_completed"),
        event("research", "strategy_experiment_revert"),
        event("research", "quality_gate_skip")
      ],
      %{status: :running, in_flight_count: 2}
    )

    name = :"adaptation-heartbeat-test-#{System.unique_integer([:positive])}"

    start_supervised!(
      {AdaptationHeartbeat,
       name: name, journal: JournalStub, interval_ms: :timer.hours(1), recent_limit: 20}
    )

    AdaptationHeartbeat.tick_now(name)
    Process.sleep(25)

    recorded = JournalStub.recorded()
    types = Enum.map(recorded, & &1.event_type)

    assert "meta_reflect_requested" in types
    assert "meta_consolidate_requested" in types
    assert "meta_pivot_requested" in types

    stats = AdaptationHeartbeat.stats(name)
    assert stats.tick_count == 1
    assert stats.intents_emitted.reflect == 1
    assert stats.intents_emitted.consolidate == 1
    assert stats.intents_emitted.pivot == 1
  end

  defp event(domain, event_type, context \\ %{}, timestamp \\ DateTime.utc_now()) do
    %{
      domain: domain,
      event_type: event_type,
      timestamp: timestamp,
      context: context
    }
  end
end
