defmodule Daemon.Bridge.PubSubTest do
  use ExUnit.Case, async: false

  alias Daemon.Bridge.PubSub

  @pubsub Daemon.PubSub

  # Ensure PubSub is running — it may already be started by the application.
  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    # The application supervisor may have already started PubSub.
    # Only start it if it's not already running.
    unless Process.whereis(Daemon.PubSub) do
      start_supervised!({Phoenix.PubSub, name: @pubsub})
    end

    :ok
  end

  # Simulate the 4-tier fan-out that the private broadcast_event/1 performs.
  # This lets us exercise the subscription helpers end-to-end without calling
  # the private function directly.
  @tui_event_types ~w(llm_chunk llm_response agent_response tool_result tool_error
                      thinking_chunk agent_message signal_classified)a

  defp simulate_broadcast(event) do
    # Tier 1: Firehose
    Phoenix.PubSub.broadcast(@pubsub, "osa:events", {:daemon_event, event})

    # Tier 2: Session
    if session_id = Map.get(event, :session_id) do
      Phoenix.PubSub.broadcast(@pubsub, "osa:session:#{session_id}", {:daemon_event, event})
    end

    # Tier 3: Type
    if type = Map.get(event, :type) do
      Phoenix.PubSub.broadcast(@pubsub, "osa:type:#{type}", {:daemon_event, event})
    end

    # Tier 4: TUI output
    if Map.get(event, :type) in @tui_event_types do
      Phoenix.PubSub.broadcast(@pubsub, "osa:tui:output", {:daemon_event, event})
    end
  end

  # -----------------------------------------------------------------------
  # subscribe helpers
  # -----------------------------------------------------------------------

  describe "subscribe helpers" do
    test "subscribe_firehose/0 subscribes to osa:events" do
      assert :ok = PubSub.subscribe_firehose()
    end

    test "subscribe_session/1 subscribes to session-scoped topic" do
      assert :ok = PubSub.subscribe_session("sess-abc")
    end

    test "subscribe_type/1 subscribes to type-scoped topic" do
      assert :ok = PubSub.subscribe_type(:llm_response)
    end

    test "subscribe_tui_output/0 subscribes to osa:tui:output" do
      assert :ok = PubSub.subscribe_tui_output()
    end
  end

  # -----------------------------------------------------------------------
  # Tier 1: Firehose
  # -----------------------------------------------------------------------

  describe "tier 1 firehose" do
    test "any event is delivered to osa:events subscribers" do
      PubSub.subscribe_firehose()
      event = %{type: :some_event, payload: "hello"}
      simulate_broadcast(event)
      assert_receive {:daemon_event, ^event}, 500
    end
  end

  # -----------------------------------------------------------------------
  # Tier 2: Session fan-out
  # -----------------------------------------------------------------------

  describe "tier 2 session fan-out" do
    test "event with session_id is delivered to session subscribers" do
      PubSub.subscribe_session("sess-1")
      event = %{type: :agent_response, session_id: "sess-1"}
      simulate_broadcast(event)
      assert_receive {:daemon_event, ^event}, 500
    end

    test "event without session_id is NOT delivered to session subscribers" do
      PubSub.subscribe_session("sess-2")
      event = %{type: :agent_response}
      simulate_broadcast(event)
      refute_receive {:daemon_event, _}, 100
    end
  end

  # -----------------------------------------------------------------------
  # Tier 3: Type fan-out
  # -----------------------------------------------------------------------

  describe "tier 3 type fan-out" do
    test "event with type is delivered to type subscribers" do
      PubSub.subscribe_type(:llm_response)
      event = %{type: :llm_response, text: "hi"}
      simulate_broadcast(event)
      assert_receive {:daemon_event, ^event}, 500
    end

    test "event with different type is NOT delivered to type subscribers" do
      PubSub.subscribe_type(:tool_result)
      event = %{type: :agent_started}
      simulate_broadcast(event)
      refute_receive {:daemon_event, _}, 100
    end
  end

  # -----------------------------------------------------------------------
  # Tier 4: TUI output fan-out
  # -----------------------------------------------------------------------

  describe "tier 4 TUI fan-out" do
    test "TUI-visible event types are delivered to osa:tui:output subscribers" do
      PubSub.subscribe_tui_output()
      Enum.each(@tui_event_types, fn t ->
        event = %{type: t, text: "payload"}
        simulate_broadcast(event)
        assert_receive {:daemon_event, ^event}, 500,
          "Expected TUI event for type #{t}"
      end)
    end

    test "non-TUI event type is NOT delivered to osa:tui:output subscribers" do
      PubSub.subscribe_tui_output()
      event = %{type: :agent_started, session_id: "x"}
      simulate_broadcast(event)
      refute_receive {:daemon_event, _}, 100
    end
  end
end
