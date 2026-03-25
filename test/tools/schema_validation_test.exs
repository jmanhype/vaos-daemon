defmodule Daemon.Tools.SchemaValidationTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Registry

  # ---------------------------------------------------------------------------
  # Test tool module with a strict JSON Schema
  # ---------------------------------------------------------------------------

  defmodule FakeTool do
    @behaviour MiosaTools.Behaviour

    @impl true
    def name, do: "fake_tool"

    @impl true
    def description, do: "A fake tool for testing schema validation"

    @impl true
    def safety, do: :read_only

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query"},
          "limit" => %{"type" => "integer", "description" => "Max results"},
          "verbose" => %{"type" => "boolean", "description" => "Verbose output"}
        },
        "required" => ["query"]
      }
    end

    @impl true
    def execute(%{"query" => query}) do
      {:ok, "results for: #{query}"}
    end
  end

  # A tool with no required fields (should accept empty map)
  defmodule OptionalTool do
    @behaviour MiosaTools.Behaviour

    @impl true
    def name, do: "optional_tool"

    @impl true
    def description, do: "Tool with only optional params"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "tag" => %{"type" => "string"}
        }
      }
    end

    @impl true
    def execute(_args), do: {:ok, "ok"}
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — valid args
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with valid args" do
    test "should pass when all required args present with correct types" do
      args = %{"query" => "hello", "limit" => 10}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass when only required args present" do
      args = %{"query" => "hello"}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass when all args present with correct types" do
      args = %{"query" => "hello", "limit" => 5, "verbose" => true}
      assert :ok = Registry.validate_arguments(FakeTool, args)
    end

    test "should pass with empty map when no required fields" do
      assert :ok = Registry.validate_arguments(OptionalTool, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — missing required args
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with missing required args" do
    test "should return error when required arg is missing" do
      args = %{"limit" => 10}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error with empty map when required fields exist" do
      assert {:error, message} = Registry.validate_arguments(FakeTool, %{})
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — wrong types
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with wrong types" do
    test "should return error when string arg receives integer" do
      args = %{"query" => 12345}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error when integer arg receives string" do
      args = %{"query" => "hello", "limit" => "not_a_number"}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end

    test "should return error when boolean arg receives string" do
      args = %{"query" => "hello", "verbose" => "yes"}
      assert {:error, message} = Registry.validate_arguments(FakeTool, args)
      assert message =~ "fake_tool"
      assert message =~ "validation failed"
    end
  end

  # ---------------------------------------------------------------------------
  # safety/0 callback
  # ---------------------------------------------------------------------------

  describe "safety/0 callback" do
    test "should return :read_only for FileRead" do
      assert Daemon.Tools.Builtins.FileRead.safety() == :read_only
    end

    test "should return :write_safe for FileWrite" do
      assert Daemon.Tools.Builtins.FileWrite.safety() == :write_safe
    end

    test "should return :terminal for ShellExecute" do
      assert Daemon.Tools.Builtins.ShellExecute.safety() == :terminal
    end

    test "should return :write_destructive for Git" do
      assert Daemon.Tools.Builtins.Git.safety() == :write_destructive
    end

    test "should return :read_only for FakeTool" do
      assert FakeTool.safety() == :read_only
    end
  end

  # ---------------------------------------------------------------------------
  # validate_arguments/2 — real tool schemas
  # ---------------------------------------------------------------------------

  describe "validate_arguments/2 with real tool modules" do
    test "should validate file_read args correctly" do
      mod = Daemon.Tools.Builtins.FileRead
      assert :ok = Registry.validate_arguments(mod, %{"path" => "/tmp/test.txt"})
    end

    test "should reject file_read with missing path" do
      mod = Daemon.Tools.Builtins.FileRead
      assert {:error, msg} = Registry.validate_arguments(mod, %{})
      assert msg =~ "validation failed"
    end

    test "should reject shell_execute with wrong type for command" do
      mod = Daemon.Tools.Builtins.ShellExecute
      assert {:error, msg} = Registry.validate_arguments(mod, %{"command" => 42})
      assert msg =~ "validation failed"
    end
  end
end
