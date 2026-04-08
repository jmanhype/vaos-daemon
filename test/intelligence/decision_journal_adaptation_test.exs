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
    assert length(meta.recent_failed_adaptations) == 1
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
end
