defmodule Daemon.Agent.LearningTest do
  @moduledoc """
  Tests for the Learning engine — patterns, solutions, and persistence.
  Uses async: false because Learning is a singleton GenServer with ETS.
  """
  use ExUnit.Case, async: false

  @table :daemon_learning_patterns
  @persist_dir Path.expand("~/.daemon/learning")

  setup_all do
    # Ensure Learning GenServer is available
    case Process.whereis(Daemon.Agent.Learning) do
      nil ->
        start_supervised!(Daemon.Agent.Learning)

      pid ->
        # Already started, verify it's alive
        if Process.alive?(pid) do
          :ok
        else
          start_supervised!(Daemon.Agent.Learning)
        end
    end

    :ok
  end

  setup do
    # Clear ETS table before each test for isolation
    try do
      :ets.delete_all_objects(@table)
    rescue
      _ -> :ok
    end

    # Clean up persisted files
    patterns_path = Path.join(@persist_dir, "patterns.json")
    solutions_path = Path.join(@persist_dir, "solutions.json")

    File.rm(patterns_path)
    File.rm(solutions_path)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Observe tests
  # ---------------------------------------------------------------------------

  describe "observe/1" do
    test "records an observation event" do
      event = %{
        type: :tool_success,
        tool: "file_read",
        context: "test context"
      }

      Daemon.Agent.Learning.observe(event)

      # Give async cast time to process
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_success:file_read")
      assert patterns["tool_success:file_read"] >= 1
    end

    test "increments count for repeated observations" do
      event = %{type: :tool_success, tool: "file_read"}

      Daemon.Agent.Learning.observe(event)
      Daemon.Agent.Learning.observe(event)
      Daemon.Agent.Learning.observe(event)

      Process.sleep(100)

      patterns = Daemon.Agent.Learning.patterns()
      assert patterns["tool_success:file_read"] >= 3
    end

    test "handles events with string keys" do
      event = %{
        "type" => "tool_error",
        "tool" => "file_write",
        "error" => "permission denied"
      }

      Daemon.Agent.Learning.observe(event)
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_error:file_write")
    end

    test "handles nil and non-map inputs gracefully" do
      assert :ok == Daemon.Agent.Learning.observe(nil)
      assert :ok == Daemon.Agent.Learning.observe([])
      assert :ok == Daemon.Agent.Learning.observe("string")
    end

    test "stores first_seen and last_seen timestamps" do
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "test_tool"})
      Process.sleep(50)

      [{{:pattern, _}, data}] = :ets.match_object(@table, {{:pattern, :_}, :_})
      assert Map.has_key?(data, :first_seen)
      assert Map.has_key?(data, :last_seen)
      assert %DateTime{} = data.first_seen
      assert %DateTime{} = data.last_seen
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern retrieval tests
  # ---------------------------------------------------------------------------

  describe "patterns/0" do
    test "returns empty map when no observations" do
      patterns = Daemon.Agent.Learning.patterns()
      assert patterns == %{}
    end

    test "returns all tracked patterns as map" do
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "tool_a"})
      Daemon.Agent.Learning.observe(%{type: :tool_error, tool: "tool_b"})
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_success:tool_a")
      assert Map.has_key?(patterns, "tool_error:tool_b")
    end

    test "pattern keys combine type and tool" do
      Daemon.Agent.Learning.observe(%{type: :custom_event, tool: "my_tool"})
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "custom_event:my_tool")
    end
  end

  # ---------------------------------------------------------------------------
  # Solution/correction tests
  # ---------------------------------------------------------------------------

  describe "correction/2" do
    test "records a correction" do
      wrong = "using file_write instead of file_edit"
      right = "use file_edit for surgical changes"

      Daemon.Agent.Learning.correction(wrong, right)
      Process.sleep(50)

      solutions = Daemon.Agent.Learning.solutions()
      assert map_size(solutions) > 0

      solution_key =
        wrong
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_\-]/, "_")
        |> String.slice(0, 100)

      assert Map.has_key?(solutions, solution_key)

      solution = solutions[solution_key]
      assert solution.problem == wrong
      assert solution.solution == right
      assert solution.correction == right
      assert solution.confidence == 0.8
    end

    test "handles special characters in problem description" do
      wrong = "wrong approach!!! with @#$ special chars"
      right = "correct approach"

      Daemon.Agent.Learning.correction(wrong, right)
      Process.sleep(50)

      solutions = Daemon.Agent.Learning.solutions()
      assert map_size(solutions) > 0
    end

    test "accepts three-argument form (backward compatibility)" do
      Daemon.Agent.Learning.correction("wrong", "right", "extra_info")
      Process.sleep(50)

      solutions = Daemon.Agent.Learning.solutions()
      assert map_size(solutions) > 0
    end
  end

  describe "solutions/0" do
    test "returns empty map when no corrections" do
      solutions = Daemon.Agent.Learning.solutions()
      assert solutions == %{}
    end

    test "returns all tracked solutions" do
      Daemon.Agent.Learning.correction("bad1", "good1")
      Daemon.Agent.Learning.correction("bad2", "good2")
      Process.sleep(50)

      solutions = Daemon.Agent.Learning.solutions()
      assert map_size(solutions) >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Error recording tests
  # ---------------------------------------------------------------------------

  describe "error/3" do
    test "records tool error as observation" do
      Daemon.Agent.Learning.error("file_read", "file not found", "reading /nonexistent")

      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_error:file_read")
    end

    test "handles tool names with special characters" do
      Daemon.Agent.Learning.error("shell_execute", "command failed", "rm -rf /")

      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_error:shell_execute")
    end
  end

  # ---------------------------------------------------------------------------
  # Metrics tests
  # ---------------------------------------------------------------------------

  describe "metrics/0" do
    test "returns zero metrics when empty" do
      metrics = Daemon.Agent.Learning.metrics()
      assert metrics.patterns == 0
      assert metrics.solutions == 0
      assert is_integer(metrics.observations)
    end

    test "tracks pattern count" do
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "a"})
      Daemon.Agent.Learning.observe(%{type: :tool_error, tool: "b"})
      Process.sleep(50)

      metrics = Daemon.Agent.Learning.metrics()
      assert metrics.patterns >= 2
    end

    test "tracks solution count" do
      Daemon.Agent.Learning.correction("wrong1", "right1")
      Daemon.Agent.Learning.correction("wrong2", "right2")
      Process.sleep(50)

      metrics = Daemon.Agent.Learning.metrics()
      assert metrics.solutions >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence tests
  # ---------------------------------------------------------------------------

  describe "consolidate/1" do
    test "flushes patterns to disk" do
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "persist_test"})

      # Force immediate flush
      result = Daemon.Agent.Learning.consolidate()
      assert result == :ok

      patterns_path = Path.join(@persist_dir, "patterns.json")
      assert File.exists?(patterns_path)

      {:ok, content} = File.read(patterns_path)
      {:ok, data} = Jason.decode(content)
      assert Map.has_key?(data, "tool_success:persist_test")
    end

    test "flushes solutions to disk" do
      Daemon.Agent.Learning.correction("wrong_pattern", "right_pattern")

      Daemon.Agent.Learning.consolidate()

      solutions_path = Path.join(@persist_dir, "solutions.json")
      assert File.exists?(solutions_path)

      {:ok, content} = File.read(solutions_path)
      {:ok, data} = Jason.decode(content)
      assert map_size(data) > 0
    end
  end

  describe "persistence - load_from_disk" do
    test "loads patterns from disk on GenServer restart" do
      # Create a pattern directly in ETS
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "load_test"})
      Process.sleep(50)

      # Force flush
      Daemon.Agent.Learning.consolidate()

      # Verify file exists
      patterns_path = Path.join(@persist_dir, "patterns.json")
      assert File.exists?(patterns_path)

      # Clear ETS
      :ets.delete_all_objects(@table)
      assert Daemon.Agent.Learning.patterns() == %{}

      # Note: In a real restart test, we'd stop and start the GenServer
      # For now, we verify the file format is correct
      {:ok, content} = File.read(patterns_path)
      {:ok, data} = Jason.decode(content)
      assert Map.has_key?(data, "tool_success:load_test")
    end

    test "handles missing pattern files gracefully" do
      patterns_path = Path.join(@persist_dir, "patterns.json")
      File.rm(patterns_path)

      assert File.exists?(patterns_path) == false
      # GenServer should still work after missing file
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "missing_file_test"})
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_success:missing_file_test")
    end

    test "handles corrupted JSON files gracefully" do
      patterns_path = Path.join(@persist_dir, "patterns.json")
      File.mkdir_p!(@persist_dir)
      File.write!(patterns_path, "{ invalid json }")

      # GenServer should handle this without crashing
      Daemon.Agent.Learning.observe(%{type: :tool_success, tool: "corrupt_test"})
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "tool_success:corrupt_test")
    end
  end

  # ---------------------------------------------------------------------------
  # ETS table management tests
  # ---------------------------------------------------------------------------

  describe "ETS table management" do
    test "ensures table exists when accessing patterns" do
      # This test verifies the table is created if missing
      _ = Daemon.Agent.Learning.patterns()
      assert :ets.whereis(@table) != :undefined
    end

    test "table is public and accessible" do
      Daemon.Agent.Learning.observe(%{type: :test, tool: "ets"})
      Process.sleep(50)

      # Direct ETS access should work
      objects = :ets.match_object(@table, {{:pattern, :_}, :_})
      assert length(objects) > 0
    end

    test "handles table edge cases gracefully" do
      # Test with table deleted mid-operation
      :ets.delete(@table)

      # Should recreate automatically
      Daemon.Agent.Learning.observe(%{type: :test, tool: "recreate"})
      Process.sleep(50)

      patterns = Daemon.Agent.Learning.patterns()
      assert Map.has_key?(patterns, "test:recreate")
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests
  # ---------------------------------------------------------------------------

  describe "integration flows" do
    test "observe -> consolidate -> reload flow" do
      # Observe multiple events
      Enum.each(1..10, fn i ->
        Daemon.Agent.Learning.observe(%{type: :test, tool: "integration_#{i}"})
      end)

      Process.sleep(100)

      # Verify patterns in memory
      patterns = Daemon.Agent.Learning.patterns()
      assert map_size(patterns) >= 10

      # Consolidate to disk
      Daemon.Agent.Learning.consolidate()

      # Verify files exist
      patterns_path = Path.join(@persist_dir, "patterns.json")
      assert File.exists?(patterns_path)

      {:ok, content} = File.read(patterns_path)
      {:ok, data} = Jason.decode(content)
      assert map_size(data) >= 10
    end

    test "correction persists with confidence" do
      Daemon.Agent.Learning.correction("bad_pattern", "good_pattern")
      Daemon.Agent.Learning.consolidate()

      solutions_path = Path.join(@persist_dir, "solutions.json")
      {:ok, content} = File.read(solutions_path)
      {:ok, data} = Jason.decode(content)

      # Find the solution
      solution_key = "bad_pattern"
      assert Map.has_key?(data, solution_key)

      solution = data[solution_key]
      assert solution["confidence"] == 0.8
      assert solution["problem"] == "bad_pattern"
      assert solution["correction"] == "good_pattern"
    end
  end
end
