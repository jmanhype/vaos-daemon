defmodule OptimalSystemAgent.Bridge.PubSubTuiEventsTest do
  @moduledoc """
  Tests that Bridge.PubSub correctly routes events to the osa:tui:output topic.

  The tui_event?/1 predicate is private, so we test it through observable
  behavior: subscribe to the osa:tui:output Phoenix.PubSub topic, emit events
  via Events.Bus, and assert which ones arrive (or don't).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Events.Event

  @pubsub OptimalSystemAgent.PubSub
  @tui_topic "osa:tui:output"

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp subscribe_tui do
    Phoenix.PubSub.subscribe(@pubsub, @tui_topic)
  end

  defp emit_event(type, payload \\ %{}) do
    Bus.emit(type, payload)
  end

  # Drain any queued messages for the TUI topic before assertions.
  defp drain_tui do
    receive do
      {:osa_event, _} -> drain_tui()
    after
      50 -> :ok
    end
  end

  setup do
    subscribe_tui()
    drain_tui()
    :ok
  end

  # ── Primary TUI event types ──────────────────────────────────────────────────

  describe "primary TUI event types reach osa:tui:output" do
    test "llm_chunk events are forwarded to TUI" do
      emit_event(:llm_response, %{content: "hello from llm", session_id: "tui-test-1"})
      assert_receive {:osa_event, event}, 2000
      data = Map.get(event, :data, event)
      assert Map.get(data, :type) == :llm_response or Map.get(event, :type) == :llm_response
    end

    test "tool_result events are forwarded to TUI" do
      emit_event(:tool_result, %{tool: "shell_execute", result: "ok", session_id: "tui-test-2"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "agent_response events are forwarded to TUI" do
      emit_event(:agent_response, %{content: "agent done", session_id: "tui-test-3"})
      assert_receive {:osa_event, _event}, 2000
    end
  end

  # ── system_event subtypes that must reach TUI ───────────────────────────────

  describe "system_event subtypes routed to TUI" do
    test "skills_triggered reaches TUI" do
      emit_event(:system_event, %{event: :skills_triggered, skills: ["deploy"], message_preview: "deploy"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "sub_agent_started reaches TUI" do
      emit_event(:system_event, %{event: :sub_agent_started, sub_task: "research", session_id: "tui-test-4"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "sub_agent_completed reaches TUI" do
      emit_event(:system_event, %{event: :sub_agent_completed, sub_task: "research", session_id: "tui-test-5"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "orchestrator_agent_started reaches TUI" do
      emit_event(:system_event, %{event: :orchestrator_agent_started, session_id: "tui-test-6"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "orchestrator_agent_completed reaches TUI" do
      emit_event(:system_event, %{event: :orchestrator_agent_completed, session_id: "tui-test-7"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "orchestrator_started reaches TUI" do
      emit_event(:system_event, %{event: :orchestrator_started, session_id: "tui-test-8"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "orchestrator_finished reaches TUI" do
      emit_event(:system_event, %{event: :orchestrator_finished, session_id: "tui-test-9"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "skill_evolved reaches TUI" do
      emit_event(:system_event, %{event: :skill_evolved, skill_name: "auto-retry"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "skill_bootstrap_created reaches TUI" do
      emit_event(:system_event, %{event: :skill_bootstrap_created, skill_name: "new-skill"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "doom_loop_detected reaches TUI" do
      emit_event(:system_event, %{event: :doom_loop_detected, session_id: "tui-test-10"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "agent_cancelled reaches TUI" do
      emit_event(:system_event, %{event: :agent_cancelled, session_id: "tui-test-11"})
      assert_receive {:osa_event, _event}, 2000
    end

    test "budget_alert reaches TUI" do
      emit_event(:system_event, %{event: :budget_alert, used: 1000, limit: 5000})
      assert_receive {:osa_event, _event}, 2000
    end
  end

  # ── system_event subtypes that must NOT reach TUI ───────────────────────────

  describe "non-TUI system_event subtypes are filtered out" do
    test "unrelated system_event subtype does not reach TUI" do
      drain_tui()
      emit_event(:system_event, %{event: :some_internal_housekeeping, detail: "nothing"})
      refute_receive {:osa_event, event} when is_map(event) and
                       (Map.get(event, :data, %{})[:event] == :some_internal_housekeeping or
                        Map.get(event, :event) == :some_internal_housekeeping),
                     500
    end
  end

  # ── Firehose topic still receives everything ─────────────────────────────────

  describe "firehose topic osa:events receives all events" do
    test "user_message events appear on firehose" do
      Phoenix.PubSub.subscribe(@pubsub, "osa:events")
      emit_event(:user_message, %{content: "hello", session_id: "firehose-test"})
      assert_receive {:osa_event, _event}, 2000
      Phoenix.PubSub.unsubscribe(@pubsub, "osa:events")
    end
  end

  # ── Session topic receives scoped events ────────────────────────────────────

  describe "session topic receives events with matching session_id" do
    test "event with session_id arrives on osa:session:<id>" do
      sid = "sess-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(@pubsub, "osa:session:#{sid}")
      emit_event(:agent_response, %{content: "done", session_id: sid})
      assert_receive {:osa_event, _event}, 2000
      Phoenix.PubSub.unsubscribe(@pubsub, "osa:session:#{sid}")
    end
  end

  # ── Type topic receives events filtered by type ─────────────────────────────

  describe "type topic receives events of matching type" do
    test "tool_result events arrive on osa:type:tool_result" do
      Phoenix.PubSub.subscribe(@pubsub, "osa:type:tool_result")
      emit_event(:tool_result, %{tool: "read", result: "content"})
      assert_receive {:osa_event, _event}, 2000
      Phoenix.PubSub.unsubscribe(@pubsub, "osa:type:tool_result")
    end
  end
end
