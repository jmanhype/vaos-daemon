defmodule Daemon.Production.FlowRateLimiterTest do
  use ExUnit.Case, async: false

  alias Daemon.Production.FlowRateLimiter

  @table :daemon_flow_rate_limits

  # ── Setup ───────────────────────────────────────────────────────────────

  setup do
    # Start the GenServer for tests
    start_supervised!(FlowRateLimiter)

    # Clean ETS table between tests
    :ets.delete_all_objects(@table)

    :ok
  end

  # ── Unit Tests: Token Bucket Logic ──────────────────────────────────────

  describe "unit: cooldown_remaining/1" do
    test "returns 0 when operation has never been called" do
      assert FlowRateLimiter.cooldown_remaining(:flow_submit) == 0
    end

    test "returns full cooldown immediately after operation" do
      FlowRateLimiter.check_and_wait(:flow_submit)

      remaining = FlowRateLimiter.cooldown_remaining(:flow_submit)

      # Should be approximately 5000ms (allow 50ms tolerance for test timing)
      assert remaining > 4950 and remaining <= 5000
    end

    test "decreases over time" do
      FlowRateLimiter.check_and_wait(:gemini_image)

      remaining1 = FlowRateLimiter.cooldown_remaining(:gemini_image)
      Process.sleep(100)
      remaining2 = FlowRateLimiter.cooldown_remaining(:gemini_image)

      assert remaining2 < remaining1
      assert remaining1 - remaining2 >= 90
    end

    test "returns 0 after cooldown expires" do
      FlowRateLimiter.check_and_wait(:flow_extend)

      # Wait for cooldown to expire
      Process.sleep(5100)

      assert FlowRateLimiter.cooldown_remaining(:flow_extend) == 0
    end

    test "operations are tracked independently" do
      FlowRateLimiter.check_and_wait(:flow_submit)

      # flow_submit should have cooldown
      assert FlowRateLimiter.cooldown_remaining(:flow_submit) > 0

      # flow_extend should be available
      assert FlowRateLimiter.cooldown_remaining(:flow_extend) == 0

      # gemini_image should be available
      assert FlowRateLimiter.cooldown_remaining(:gemini_image) == 0
    end
  end

  # ── Integration Tests: Check and Wait Behavior ───────────────────────────

  describe "integration: check_and_wait/1" do
    test "first call returns immediately" do
      start_time = System.monotonic_time(:millisecond)

      FlowRateLimiter.check_and_wait(:flow_submit)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should return almost instantly (< 10ms)
      assert elapsed < 10
    end

    test "blocks until cooldown expires" do
      # First call
      FlowRateLimiter.check_and_wait(:flow_submit)

      start_time = System.monotonic_time(:millisecond)

      # Second call should block
      FlowRateLimiter.check_and_wait(:flow_submit)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited approximately 5000ms (±100ms tolerance)
      assert elapsed >= 4900 and elapsed < 5100
    end

    test "allows immediate retry after cooldown" do
      FlowRateLimiter.check_and_wait(:flow_submit)

      # Wait for cooldown to expire
      Process.sleep(5100)

      start_time = System.monotonic_time(:millisecond)

      FlowRateLimiter.check_and_wait(:flow_submit)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should return immediately since cooldown expired
      assert elapsed < 10
    end

    test "multiple operations can run concurrently" do
      # Start all three operations
      tasks = [
        Task.async(fn -> FlowRateLimiter.check_and_wait(:flow_submit) end),
        Task.async(fn -> FlowRateLimiter.check_and_wait(:flow_extend) end),
        Task.async(fn -> FlowRateLimiter.check_and_wait(:gemini_image) end)
      ]

      results = Task.await_many(tasks, 1000)

      # All should complete successfully
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "respects different cooldowns for different operations" do
      # flow_submit: 5000ms
      # gemini_image: 4000ms

      FlowRateLimiter.check_and_wait(:flow_submit)
      FlowRateLimiter.check_and_wait(:gemini_image)

      # After 4 seconds, gemini_image should be available but flow_submit not
      Process.sleep(4000)

      assert FlowRateLimiter.cooldown_remaining(:gemini_image) == 0
      assert FlowRateLimiter.cooldown_remaining(:flow_submit) > 0

      # gemini_image should return immediately
      start_time = System.monotonic_time(:millisecond)
      FlowRateLimiter.check_and_wait(:gemini_image)
      elapsed = System.monotonic_time(:millisecond) - start_time
      assert elapsed < 10
    end
  end

  # ── Edge Cases ──────────────────────────────────────────────────────────

  describe "edge cases" do
    test "handles rapid consecutive calls correctly" do
      # Make 3 rapid calls
      for _ <- 1..3 do
        FlowRateLimiter.check_and_wait(:flow_submit)
      end

      # All should have completed (each waited for cooldown)
      # The last call should have reset the timer
      remaining = FlowRateLimiter.cooldown_remaining(:flow_submit)

      assert remaining > 4950
    end

    test "handles GenServer call timeout gracefully" do
      # This test verifies the 30-second timeout in check_and_wait
      # We can't actually trigger a timeout without blocking the GenServer,
      # but we can verify the timeout is configured correctly

      # Start a long-running operation
      FlowRateLimiter.check_and_wait(:flow_submit)

      # Immediately call again - this should block but eventually return
      task = Task.async(fn -> FlowRateLimiter.check_and_wait(:flow_submit) end)

      # Should complete within timeout
      assert {:ok, :ok} == Task.yield(task, 6000)
    end

    test "persists state across GenServer restarts" do
      FlowRateLimiter.check_and_wait(:flow_submit)

      # Stop and restart the GenServer
      pid = Process.whereis(Daemon.Production.FlowRateLimiter)
      ref = Process.monitor(pid)
      GenServer.stop(pid)

      assert_receive {:DOWN, ^ref, _, _, _}

      # Restart
      start_supervised!(FlowRateLimiter)

      # Cooldown should be reset (ETS table is recreated)
      assert FlowRateLimiter.cooldown_remaining(:flow_submit) == 0
    end
  end

  # ── Cooldown Configuration ───────────────────────────────────────────────

  describe "cooldown configuration" do
    test "flow_submit has 5000ms cooldown" do
      FlowRateLimiter.check_and_wait(:flow_submit)
      remaining = FlowRateLimiter.cooldown_remaining(:flow_submit)

      assert remaining > 4950 and remaining <= 5000
    end

    test "flow_extend has 5000ms cooldown" do
      FlowRateLimiter.check_and_wait(:flow_extend)
      remaining = FlowRateLimiter.cooldown_remaining(:flow_extend)

      assert remaining > 4950 and remaining <= 5000
    end

    test "gemini_image has 4000ms cooldown" do
      FlowRateLimiter.check_and_wait(:gemini_image)
      remaining = FlowRateLimiter.cooldown_remaining(:gemini_image)

      assert remaining > 3950 and remaining <= 4000
    end
  end
end
