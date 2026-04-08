defmodule Daemon.Intelligence.DecisionJournalAdaptationTest do
  use ExUnit.Case, async: false

  alias Daemon.Intelligence.DecisionJournal

  @journal_path Path.expand("~/.daemon/intelligence/decision_journal.json")

  setup do
    original =
      case File.read(@journal_path) do
        {:ok, content} -> {:present, content}
        {:error, _} -> :missing
      end

    on_exit(fn ->
      case original do
        {:present, content} ->
          File.mkdir_p!(Path.dirname(@journal_path))
          File.write!(@journal_path, content)

        :missing ->
          File.rm(@journal_path)
      end
    end)

    :ok
  end

  test "records adaptation entries and derives meta state" do
    File.rm(@journal_path)

    assert {:ok, state} = DecisionJournal.init([])

    {:noreply, state} =
      DecisionJournal.handle_cast(
        {:record_adaptation, :research, :quality_gate_skip,
         %{
           bottleneck: :low_verification,
           reason: "quality below threshold",
           quality: 0.12,
           threshold: 0.18
         }},
        state
      )

    {:noreply, state} =
      DecisionJournal.handle_cast(
        {:record_adaptation, :research, :steering_applied,
         %{
           bottleneck: :low_verification,
           steering_hypothesis: "Prefer abstract-verified evidence"
         }},
        state
      )

    {:noreply, state} =
      DecisionJournal.handle_cast(
        {:record_adaptation, :reliability, :strategy_experiment_revert,
         %{
           outcome: :reverted,
           reason: "rate limit regression"
         }},
        state
      )

    {:reply, entries, _state} =
      DecisionJournal.handle_call({:adaptation_events, 10}, self(), state)

    assert length(entries) == 3
    assert hd(entries).domain == "reliability"
    assert hd(entries).event_type == "strategy_experiment_revert"

    {:reply, meta, _state} = DecisionJournal.handle_call(:meta_state, self(), state)
    assert meta.authority_domain == "reliability"
    assert meta.active_bottleneck == "low_verification"
    assert meta.pivot_reason == "rate limit regression"
    assert meta.active_steering_hypothesis == "Prefer abstract-verified evidence"

    assert Enum.map(meta.recent_failed_adaptations, & &1.event_type) == [
             "strategy_experiment_revert",
             "quality_gate_skip"
           ]
  end

  test "loads persisted adaptation entries from disk" do
    File.mkdir_p!(Path.dirname(@journal_path))

    File.write!(
      @journal_path,
      Jason.encode!(%{
        "version" => 2,
        "decisions" => [],
        "adaptation_entries" => [
          %{
            "domain" => "research",
            "event_type" => "topic_selected",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "context" => %{
              "bottleneck" => "low_verification",
              "steering_hypothesis" => "Prefer verified sources"
            }
          }
        ],
        "stats" => %{}
      })
    )

    assert {:ok, state} = DecisionJournal.init([])
    assert length(state.adaptation_entries) == 1

    {:reply, meta, _state} = DecisionJournal.handle_call(:meta_state, self(), state)
    assert meta.authority_domain == "research"
    assert meta.active_bottleneck == "low_verification"
    assert meta.active_steering_hypothesis == "Prefer verified sources"
  end

  test "meta state ignores stale adaptation history for current fields" do
    File.rm(@journal_path)

    assert {:ok, state} = DecisionJournal.init([])

    now = DateTime.utc_now()

    stale_entry = %{
      domain: "reliability",
      event_type: "strategy_experiment_revert",
      timestamp: DateTime.add(now, -2, :hour),
      context: %{
        "authority_domain" => "reliability",
        "bottleneck" => "low_verification",
        "reason" => "stale failure",
        "outcome" => "reverted"
      }
    }

    fresh_entry = %{
      domain: "research",
      event_type: "topic_selected",
      timestamp: now,
      context: %{
        "authority_domain" => "research",
        "bottleneck" => "source_exploration"
      }
    }

    state = %{state | adaptation_entries: [fresh_entry, stale_entry]}

    {:reply, meta, _state} = DecisionJournal.handle_call(:meta_state, self(), state)

    assert meta.authority_domain == "research"
    assert meta.active_bottleneck == "source_exploration"
    assert meta.pivot_reason == nil
    assert meta.last_experiment == nil
    assert meta.recent_failed_adaptations == []
    assert meta.last_updated_at == now
  end

  test "adaptation review summarizes trial outcomes, domain skew, and signature quality" do
    File.rm(@journal_path)

    assert {:ok, state} = DecisionJournal.init([])

    now = DateTime.utc_now()

    entries = [
      %{
        domain: "coordination",
        event_type: "trial_suppressed",
        timestamp: DateTime.add(now, -10, :second),
        context: %{
          "trigger_event" => "meta_reflect_requested",
          "bottleneck" => "source_exploration"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_suppression_started",
        timestamp: DateTime.add(now, -20, :second),
        context: %{
          "trigger_event" => "meta_reflect_requested",
          "bottleneck" => "source_exploration"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_completed",
        timestamp: DateTime.add(now, -30, :second),
        context: %{
          "trigger_event" => "meta_reflect_requested",
          "bottleneck" => "source_exploration",
          "outcome" => "not_helpful"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_started",
        timestamp: DateTime.add(now, -40, :second),
        context: %{
          "trigger_event" => "meta_reflect_requested",
          "bottleneck" => "source_exploration"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_expired",
        timestamp: DateTime.add(now, -50, :second),
        context: %{
          "trigger_event" => "meta_consolidate_requested",
          "bottleneck" => "synthesis_drift"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_started",
        timestamp: DateTime.add(now, -60, :second),
        context: %{
          "trigger_event" => "meta_consolidate_requested",
          "bottleneck" => "synthesis_drift"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_blocked",
        timestamp: DateTime.add(now, -70, :second),
        context: %{
          "trigger_event" => "meta_pivot_requested",
          "bottleneck" => "low_verification"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_started",
        timestamp: DateTime.add(now, -80, :second),
        context: %{
          "trigger_event" => "meta_pivot_requested",
          "bottleneck" => "low_verification"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_promoted",
        timestamp: DateTime.add(now, -90, :second),
        context: %{
          "trigger_event" => "meta_pivot_requested",
          "bottleneck" => "low_verification"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_completed",
        timestamp: DateTime.add(now, -100, :second),
        context: %{
          "trigger_event" => "meta_pivot_requested",
          "bottleneck" => "low_verification",
          "outcome" => "helpful"
        }
      },
      %{
        domain: "coordination",
        event_type: "trial_started",
        timestamp: DateTime.add(now, -110, :second),
        context: %{
          "trigger_event" => "meta_pivot_requested",
          "bottleneck" => "low_verification"
        }
      },
      %{
        domain: "research",
        event_type: "steering_applied",
        timestamp: DateTime.add(now, -120, :second),
        context: %{
          "bottleneck" => "low_verification",
          "steering_hypothesis" => "Prefer verified sources"
        }
      }
    ]

    state = %{state | adaptation_entries: entries}

    {:reply, review, _state} =
      DecisionJournal.handle_call({:adaptation_review, 50}, self(), state)

    assert review.window_event_count == 12
    assert review.trials.started == 4
    assert review.trials.completed == 2
    assert review.trials.helpful == 1
    assert review.trials.not_helpful == 1
    assert review.trials.blocked == 1
    assert review.trials.expired == 1
    assert review.trials.helpful_rate == 0.5
    assert review.trials.blocked_rate == 0.25
    assert review.trials.expiry_rate == 0.25

    assert review.promotions.started == 1
    assert review.promotions.cleared == 0
    assert review.promotions.keep_rate == 1.0

    assert review.suppressions.started == 1
    assert review.suppressions.hits == 1
    assert review.suppressions.hit_rate == 1.0

    assert [%{domain: "coordination", count: 11}, %{domain: "research", count: 1}] =
             review.domain_skew

    assert [
             %{
               signature: "meta_pivot_requested|low_verification",
               net_score: 1,
               helpful: 1,
               promotions: 1
             }
             | _
           ] = review.positive_signatures

    assert [
             %{
               signature: "meta_reflect_requested|source_exploration",
               net_score: -1,
               not_helpful: 1,
               suppression_hits: 1
             }
             | _
           ] = review.noisy_signatures
  end

  test "recording adaptation entries sanitizes datetime fields in context" do
    File.rm(@journal_path)

    assert {:ok, state} = DecisionJournal.init([])
    expires_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:noreply, state} =
      DecisionJournal.handle_cast(
        {:record_adaptation, :coordination, :trial_suppression_started,
         %{
           trigger_event: :meta_reflect_requested,
           bottleneck: :low_verification,
           negative_streak: 2,
           reason: "repeated_not_helpful",
           expires_at: expires_at
         }},
        state
      )

    {:reply, [entry], _state} =
      DecisionJournal.handle_call({:adaptation_events, 5}, self(), state)

    assert entry.event_type == "trial_suppression_started"
    assert entry.context["expires_at"] == DateTime.to_iso8601(expires_at)
    assert entry.context["trigger_event"] == "meta_reflect_requested"
  end
end
