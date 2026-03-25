defmodule Daemon.Agent.ProactiveModeTest do
  use ExUnit.Case, async: false

  alias Daemon.Agent.ProactiveMode
  alias Daemon.Events.Bus

  setup do
    ProactiveMode.disable()
    ProactiveMode.clear_activity_log()
    ProactiveMode.clear_active_session()
    # Reset internal state to clear any pending notifications from prior tests
    :sys.replace_state(ProactiveMode, fn state ->
      %{state | pending_notifications: [], message_count_this_hour: 0, last_message_at: nil}
    end)
    :ok
  end

  describe "enable/disable" do
    test "starts disabled by default" do
      assert ProactiveMode.enabled?() == false
    end

    test "enable/disable toggles state" do
      ProactiveMode.enable()
      assert ProactiveMode.enabled?() == true

      ProactiveMode.disable()
      assert ProactiveMode.enabled?() == false
    end

    test "toggle flips the state" do
      ProactiveMode.enable()
      ProactiveMode.toggle()
      assert ProactiveMode.enabled?() == false

      ProactiveMode.toggle()
      assert ProactiveMode.enabled?() == true
    end

    test "emits proactive_mode_changed event on enable" do
      test_pid = self()

      ref =
        Bus.register_handler(:system_event, fn payload ->
          # Bus wraps in CloudEvent envelope
          data = Map.get(payload, :data, payload)

          if data[:event] == :proactive_mode_changed do
            send(test_pid, {:mode_changed, data[:enabled]})
          end
        end)

      ProactiveMode.enable()
      assert_receive {:mode_changed, true}, 2000

      ProactiveMode.disable()
      assert_receive {:mode_changed, false}, 2000

      Bus.unregister_handler(:system_event, ref)
    end
  end

  describe "status/0" do
    test "returns status map" do
      status = ProactiveMode.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :greeting_enabled)
      assert Map.has_key?(status, :autonomous_work)
      assert Map.has_key?(status, :messages_this_hour)
      assert Map.has_key?(status, :activity_log_count)
      assert Map.has_key?(status, :permission_tier)
    end
  end

  describe "notify/2" do
    test "logs activity when enabled" do
      ProactiveMode.enable()
      ProactiveMode.notify("test notification", :info)
      Process.sleep(50)

      log = ProactiveMode.activity_log()
      assert length(log) >= 1

      entry = hd(log)
      assert entry["message"] == "test notification"
      assert entry["type"] == "info"
    end

    test "does nothing when disabled" do
      ProactiveMode.disable()
      ProactiveMode.notify("should be dropped", :info)
      Process.sleep(50)

      log = ProactiveMode.activity_log()
      assert log == []
    end
  end

  describe "activity_log/0 and clear_activity_log/0" do
    test "starts empty after clear" do
      assert ProactiveMode.activity_log() == []
    end

    test "accumulates entries" do
      ProactiveMode.enable()
      ProactiveMode.notify("one", :info)
      ProactiveMode.notify("two", :info)
      Process.sleep(50)

      log = ProactiveMode.activity_log()
      assert length(log) >= 2
    end

    test "clear empties the log" do
      ProactiveMode.enable()
      ProactiveMode.notify("entry", :info)
      Process.sleep(50)

      ProactiveMode.clear_activity_log()
      assert ProactiveMode.activity_log() == []
    end
  end

  describe "activity_since/1" do
    test "filters by timestamp" do
      ProactiveMode.enable()
      ProactiveMode.notify("old entry", :info)
      Process.sleep(50)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert ProactiveMode.activity_since(future) == []

      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      entries = ProactiveMode.activity_since(past)
      assert length(entries) >= 1
    end
  end

  describe "handle_alert/1" do
    test "logs alert when enabled" do
      ProactiveMode.enable()

      alert = %{
        severity: :warning,
        message: "Test alert message",
        type: :system_health
      }

      ProactiveMode.handle_alert(alert)
      Process.sleep(50)

      log = ProactiveMode.activity_log()
      assert length(log) >= 1
      entry = hd(log)
      assert String.contains?(entry["type"], "alert")
    end

    test "drops alert when disabled" do
      ProactiveMode.disable()

      alert = %{severity: :info, message: "dropped", type: :test}
      ProactiveMode.handle_alert(alert)
      Process.sleep(50)

      assert ProactiveMode.activity_log() == []
    end
  end

  describe "greeting/1" do
    test "returns :skip when disabled" do
      ProactiveMode.disable()
      assert ProactiveMode.greeting("test_session") == :skip
    end

    test "returns greeting text when enabled" do
      ProactiveMode.enable()

      case ProactiveMode.greeting("test_session") do
        {:ok, text} ->
          assert is_binary(text)
          assert String.contains?(text, "Good")

        :skip ->
          # May skip if Onboarding.first_run?() is true
          :ok
      end
    end
  end

  describe "active session" do
    test "set and clear active session" do
      ProactiveMode.set_active_session("test_123")
      Process.sleep(20)
      status = ProactiveMode.status()
      assert status.active_session == "test_123"

      ProactiveMode.clear_active_session()
      Process.sleep(20)
      status = ProactiveMode.status()
      assert status.active_session == nil
    end
  end

  describe "message delivery" do
    test "delivers pending messages when session is active" do
      test_pid = self()

      ref =
        Bus.register_handler(:system_event, fn payload ->
          data = Map.get(payload, :data, payload)

          if data[:event] == :proactive_message do
            send(test_pid, {:proactive_msg, data})
          end
        end)

      ProactiveMode.enable()
      ProactiveMode.set_active_session("delivery_test")
      ProactiveMode.notify("hello user", :info)
      Process.sleep(50)

      # Trigger immediate delivery check instead of waiting for 5s timer
      send(Process.whereis(ProactiveMode), :delivery_check)

      assert_receive {:proactive_msg, payload}, 2_000
      assert payload.message == "hello user"
      assert payload.session_id == "delivery_test"

      Bus.unregister_handler(:system_event, ref)
    end
  end
end
