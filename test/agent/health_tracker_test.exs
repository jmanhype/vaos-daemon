defmodule OptimalSystemAgent.Agent.HealthTrackerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.HealthTracker

  @table :osa_agent_health

  setup do
    # Ensure a clean ETS table for each test.
    # If the GenServer is already running, stop it so we can start fresh.
    case GenServer.whereis(HealthTracker) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Clear the ETS table if it exists from a prior run
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    {:ok, pid} = HealthTracker.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid}
  end

  describe "record_call/2" do
    test "increments total_calls" do
      HealthTracker.record_call("test_agent", 100)
      # Cast is async, give GenServer time to process
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("test_agent")
      assert health.total_calls == 1

      HealthTracker.record_call("test_agent", 200)
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("test_agent")
      assert health.total_calls == 2
    end

    test "accumulates latency for average calculation" do
      HealthTracker.record_call("latency_agent", 100)
      HealthTracker.record_call("latency_agent", 300)
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("latency_agent")
      assert health.total_calls == 2
      assert health.avg_latency_ms == 200.0
    end
  end

  describe "record_error/1" do
    test "increments error_count" do
      HealthTracker.record_error("err_agent")
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("err_agent")
      assert health.error_count == 1

      HealthTracker.record_error("err_agent")
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("err_agent")
      assert health.error_count == 2
    end
  end

  describe "get/1" do
    test "returns {:error, :not_found} for unknown agents" do
      assert {:error, :not_found} = HealthTracker.get("nonexistent")
    end

    test "returns correct health shape" do
      HealthTracker.record_call("shape_agent", 150)
      :sys.get_state(HealthTracker)

      assert {:ok, health} = HealthTracker.get("shape_agent")
      assert is_binary(health.agent)
      assert is_integer(health.last_active)
      assert is_integer(health.total_calls)
      assert is_integer(health.error_count)
      assert is_number(health.avg_latency_ms) or is_nil(health.avg_latency_ms)
      assert is_float(health.error_rate)
    end
  end

  describe "all/0" do
    test "returns sorted list of all tracked agents" do
      HealthTracker.record_call("zeta", 10)
      HealthTracker.record_call("alpha", 20)
      HealthTracker.record_call("mid", 30)
      :sys.get_state(HealthTracker)

      results = HealthTracker.all()
      assert length(results) == 3
      agents = Enum.map(results, & &1.agent)
      assert agents == ["alpha", "mid", "zeta"]
    end
  end
end
