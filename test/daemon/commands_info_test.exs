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
  end
end
