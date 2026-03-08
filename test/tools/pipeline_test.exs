defmodule MiosaTools.PipelineTest do
  use ExUnit.Case, async: true

  alias MiosaTools.Pipeline

  # A mock executor that echoes tool name and params back as the result
  defp echo_executor(tool_name, params) do
    {:ok, Map.put(params, :__tool, tool_name)}
  end

  # An executor that fails for a specific tool
  defp failing_executor(fail_tool) do
    fn tool_name, params ->
      if tool_name == fail_tool do
        {:error, "#{fail_tool} failed"}
      else
        {:ok, Map.put(params, :__tool, tool_name)}
      end
    end
  end

  # A stateful executor that tracks call count via the process dictionary
  defp counting_executor(tool_name, params) do
    count = Process.get(:call_count, 0)
    Process.put(:call_count, count + 1)

    if count < 2 do
      {:error, "attempt #{count + 1} failed"}
    else
      {:ok, Map.put(params, :__tool, tool_name)}
    end
  end

  # ---------------------------------------------------------------------------
  # pipe/2
  # ---------------------------------------------------------------------------

  describe "pipe/2" do
    test "executes instructions sequentially, threading results" do
      instructions = [
        {"step_a", %{"x" => 1}},
        {"step_b", %{"y" => 2}}
      ]

      assert {:ok, result} = Pipeline.pipe(instructions, executor: &echo_executor/2)
      # step_a produces %{"x" => 1, __tool: "step_a"}
      # step_b merges that with %{"y" => 2}, producing all keys
      assert result[:__tool] == "step_b"
      assert result["x"] == 1
      assert result["y"] == 2
    end

    test "halts on first failure" do
      instructions = [
        {"good_tool", %{}},
        {"bad_tool", %{}},
        {"never_reached", %{}}
      ]

      executor = failing_executor("bad_tool")
      assert {:error, "bad_tool failed"} = Pipeline.pipe(instructions, executor: executor)
    end

    test "returns ok with empty accumulated params for empty list" do
      assert {:ok, %{}} = Pipeline.pipe([], executor: &echo_executor/2)
    end

    test "supports custom transform function" do
      instructions = [
        {"step_a", %{"x" => 1}},
        {"step_b", %{}}
      ]

      # Custom transform that only keeps the result, not merged params
      transform = fn result, _params -> result end

      assert {:ok, result} =
               Pipeline.pipe(instructions, executor: &echo_executor/2, transform: transform)

      # step_b only gets step_a's result (no original step_b params merged)
      assert result[:__tool] == "step_b"
    end

    test "rejects invalid instruction input" do
      assert {:error, _} = Pipeline.pipe([42], executor: &echo_executor/2)
    end
  end

  # ---------------------------------------------------------------------------
  # parallel/2
  # ---------------------------------------------------------------------------

  describe "parallel/2" do
    test "runs all instructions and collects successes" do
      instructions = [
        {"tool_a", %{"a" => 1}},
        {"tool_b", %{"b" => 2}}
      ]

      assert {:ok, results} = Pipeline.parallel(instructions, executor: &echo_executor/2)
      assert Map.has_key?(results, "tool_a")
      assert Map.has_key?(results, "tool_b")
      assert results["tool_a"]["a"] == 1
      assert results["tool_b"]["b"] == 2
    end

    test "returns errors when any instruction fails" do
      instructions = [
        {"good_tool", %{}},
        {"bad_tool", %{}}
      ]

      executor = failing_executor("bad_tool")
      assert {:error, errors} = Pipeline.parallel(instructions, executor: executor)
      assert Map.has_key?(errors, "bad_tool")
    end

    test "handles empty list" do
      assert {:ok, %{}} = Pipeline.parallel([], executor: &echo_executor/2)
    end
  end

  # ---------------------------------------------------------------------------
  # fallback/2
  # ---------------------------------------------------------------------------

  describe "fallback/2" do
    test "returns first successful result" do
      instructions = [
        {"primary", %{}},
        {"backup", %{}}
      ]

      assert {:ok, result} = Pipeline.fallback(instructions, executor: &echo_executor/2)
      assert result[:__tool] == "primary"
    end

    test "falls through to next on failure" do
      instructions = [
        {"bad_tool", %{}},
        {"good_tool", %{"result" => true}}
      ]

      executor = failing_executor("bad_tool")
      assert {:ok, result} = Pipeline.fallback(instructions, executor: executor)
      assert result[:__tool] == "good_tool"
    end

    test "returns last error when all fail" do
      executor = fn _tool, _params -> {:error, "nope"} end

      instructions = [
        {"fail_a", %{}},
        {"fail_b", %{}}
      ]

      assert {:error, "nope"} = Pipeline.fallback(instructions, executor: executor)
    end

    test "errors on empty list" do
      assert {:error, _} = Pipeline.fallback([], executor: &echo_executor/2)
    end
  end

  # ---------------------------------------------------------------------------
  # retry/2
  # ---------------------------------------------------------------------------

  describe "retry/2" do
    test "retries until success" do
      Process.put(:call_count, 0)

      assert {:ok, result} =
               Pipeline.retry(
                 {"flaky_tool", %{}},
                 executor: &counting_executor/2,
                 max_attempts: 5,
                 base_backoff: 1,
                 max_backoff: 10
               )

      assert result[:__tool] == "flaky_tool"
      assert Process.get(:call_count) == 3
    end

    test "gives up after max_attempts" do
      executor = fn _tool, _params -> {:error, "always fails"} end

      assert {:error, "always fails"} =
               Pipeline.retry(
                 {"doomed", %{}},
                 executor: executor,
                 max_attempts: 2,
                 base_backoff: 1
               )
    end

    test "respects should_retry predicate" do
      call_count = :counters.new(1, [:atomics])

      executor = fn _tool, _params ->
        :counters.add(call_count, 1, 1)
        {:error, :permanent}
      end

      assert {:error, :permanent} =
               Pipeline.retry(
                 {"tool", %{}},
                 executor: executor,
                 max_attempts: 5,
                 base_backoff: 1,
                 should_retry: fn _error -> false end
               )

      # Should have only tried once since should_retry returns false
      assert :counters.get(call_count, 1) == 1
    end

    test "succeeds on first attempt without retrying" do
      assert {:ok, _} =
               Pipeline.retry(
                 {"good_tool", %{}},
                 executor: &echo_executor/2
               )
    end
  end
end
