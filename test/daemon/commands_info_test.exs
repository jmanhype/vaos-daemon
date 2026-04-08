defmodule Daemon.CommandsInfoTest do
  use ExUnit.Case, async: false

  alias Daemon.Commands
  alias Daemon.Commands.Info

  test "format_adaptation_status reports inactive journal cleanly" do
    output =
      Info.format_adaptation_status(
        %{
          authority_domain: nil,
          active_bottleneck: nil,
          pivot_reason: nil,
          active_steering_hypothesis: nil,
          last_experiment: nil,
          recent_failed_adaptations: [],
          last_updated_at: nil
        },
        [],
        %{}
      )

    assert output =~ "Adaptation Status:"
    assert output =~ "journal:             inactive"
    assert output =~ "authority:           -"
    assert output =~ "Recent signals:\n  - none"
  end

  test "format_adaptation_status includes meta-state and recent signals" do
    now = ~U[2026-04-08 07:12:45Z]

    output =
      Info.format_adaptation_status(
        %{
          authority_domain: "reliability",
          active_bottleneck: "low_verification",
          pivot_reason: "smoke",
          active_steering_hypothesis: "Prefer verified sources",
          last_updated_at: now,
          last_experiment: %{
            domain: "research",
            event_type: "strategy_experiment_started",
            timestamp: now
          },
          recent_failed_adaptations: [
            %{event_type: "self_diagnosis_error"},
            %{event_type: "strategy_experiment_revert"}
          ]
        },
        [
          %{
            timestamp: now,
            domain: "reliability",
            event_type: "tool_failure_escalated",
            context: %{
              "reason" => "nil",
              "authority_domain" => "reliability",
              "pattern_key" => "shell_execute:git",
              "session_rate" => 75.0
            }
          },
          %{
            timestamp: now,
            domain: "research",
            event_type: "quality_gate_skip",
            context: %{
              "bottleneck" => "low_verification",
              "reason" => "smoke"
            }
          }
        ],
        %{status: :running, adaptation_event_count: 12, in_flight_count: 1}
      )

    assert output =~ "journal:             running"
    assert output =~ "authority:           reliability"
    assert output =~ "bottleneck:          low_verification"
    assert output =~ "pivot reason:        smoke"
    assert output =~ "failed adaptations:  2"
    assert output =~ "signals stored:      12"
    assert output =~ "decisions in flight: 1"
    assert output =~ "strategy_experiment_started"
    assert output =~ "tool_failure_escalated"
    assert output =~ "pattern_key=shell_execute:git"
    refute output =~ "reason=nil"
  end

  test "format_adaptation_status includes active trial details when present" do
    now = ~U[2026-04-08 08:42:09Z]

    output =
      Info.format_adaptation_status(
        %{
          authority_domain: "research",
          active_bottleneck: "low_verification",
          pivot_reason: nil,
          active_steering_hypothesis: nil,
          last_updated_at: now,
          last_experiment: nil,
          recent_failed_adaptations: []
        },
        [],
        %{status: :running, adaptation_event_count: 1, in_flight_count: 0},
        %{
          trial_type: "steering",
          trigger_event: "meta_pivot_requested",
          status: :pending,
          remaining_uses: 1
        }
      )

    assert output =~
             "active trial:        steering via meta_pivot_requested (pending, 1 use left)"
  end

  test "format_adaptation_status includes promotion and suppression details when present" do
    now = ~U[2026-04-08 09:01:11Z]

    output =
      Info.format_adaptation_status(
        %{
          authority_domain: "research",
          active_bottleneck: "low_verification",
          pivot_reason: nil,
          active_steering_hypothesis: nil,
          last_updated_at: now,
          last_experiment: nil,
          recent_failed_adaptations: []
        },
        [],
        %{status: :running, adaptation_event_count: 3, in_flight_count: 0},
        nil,
        %{
          active_promotions: [
            %{
              trigger_event: "meta_pivot_requested",
              bottleneck: "low_verification",
              helpful_streak: 2,
              expires_at: now
            }
          ],
          active_suppressions: [
            %{
              trigger_event: "meta_reflect_requested",
              bottleneck: "low_verification",
              negative_streak: 2,
              expires_at: now
            }
          ]
        }
      )

    assert output =~ "promoted steering:   meta_pivot_requested / low_verification (2 helpful)"

    assert output =~
             "trial suppression:   meta_reflect_requested / low_verification (2 negatives)"
  end

  test "format_adaptation_review summarizes longitudinal trial quality" do
    now = ~U[2026-04-08 10:11:30Z]

    output =
      Info.format_adaptation_review(%{
        window_event_count: 12,
        window_started_at: DateTime.add(now, -10, :minute),
        window_ended_at: now,
        trials: %{
          started: 4,
          completed: 2,
          helpful: 1,
          inconclusive: 0,
          not_helpful: 1,
          blocked: 1,
          expired: 1,
          helpful_rate: 0.5,
          blocked_rate: 0.25,
          expiry_rate: 0.25
        },
        promotions: %{started: 1, cleared: 0, keep_rate: 1.0},
        suppressions: %{started: 1, hits: 1, hit_rate: 1.0},
        domain_skew: [
          %{domain: "coordination", count: 11, share: 0.9167},
          %{domain: "research", count: 1, share: 0.0833}
        ],
        positive_signatures: [
          %{
            signature: "meta_pivot_requested|low_verification",
            trigger_event: "meta_pivot_requested",
            bottleneck: "low_verification",
            helpful: 1,
            promotions: 1,
            net_score: 1
          }
        ],
        noisy_signatures: [
          %{
            signature: "meta_reflect_requested|source_exploration",
            trigger_event: "meta_reflect_requested",
            bottleneck: "source_exploration",
            not_helpful: 1,
            suppression_hits: 1,
            net_score: -1
          }
        ]
      })

    assert output =~ "Adaptation Review:"
    assert output =~ "window:              12 signals"
    assert output =~ "trial hit rate:      50.0% (1/2 helpful)"
    assert output =~ "blocked rate:        25.0% (1/4)"
    assert output =~ "expiry rate:         25.0% (1/4)"
    assert output =~ "promotion keep rate: 100.0% (1 started, 0 cleared)"
    assert output =~ "suppression hit rate: 100.0% (1/1)"
    assert output =~ "domain skew:         coordination 91.7%, research 8.3%"
    assert output =~ "Positive signatures:"
    assert output =~ "meta_pivot_requested / low_verification"
    assert output =~ "Noisy signatures:"
    assert output =~ "meta_reflect_requested / source_exploration"
  end

  test "/status adaptation review returns longitudinal summary" do
    assert {:command, output} = Commands.execute("status adaptation review", "test-session")
    assert output =~ "Adaptation Review:"
  end

  test "/status adaptation returns adaptation snapshot" do
    assert {:command, output} = Commands.execute("status adaptation", "test-session")
    assert output =~ "Adaptation Status:"
    assert output =~ "Recent signals:"
  end

  test "/status keeps default system output" do
    assert {:command, output} = Commands.execute("status", "test-session")
    assert output =~ "System Status:"
    refute output =~ "Adaptation Status:"
  end

  test "/help advertises status adaptation" do
    assert {:command, output} = Commands.execute("help", "test-session")
    assert output =~ "/status adaptation"
    assert output =~ "/status adaptation review"
  end
end
