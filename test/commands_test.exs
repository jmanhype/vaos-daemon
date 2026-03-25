defmodule Daemon.CommandsTest do
  use ExUnit.Case, async: false

  alias Daemon.Commands

  # ---------------------------------------------------------------------------
  # Module smoke tests
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Commands module is defined and loaded" do
      assert Code.ensure_loaded?(Commands)
    end

    test "exports execute/2" do
      assert function_exported?(Commands, :execute, 2)
    end

    test "exports list_commands/0" do
      assert function_exported?(Commands, :list_commands, 0)
    end

    test "exports register/3" do
      assert function_exported?(Commands, :register, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # list_commands/0 smoke tests
  # ---------------------------------------------------------------------------

  describe "list_commands/0" do
    test "returns a list" do
      result = Commands.list_commands()
      assert is_list(result)
    end

    test "each entry is a three-element tuple of strings" do
      Commands.list_commands()
      |> Enum.each(fn {name, desc, category} ->
        assert is_binary(name), "expected name to be a string, got: #{inspect(name)}"
        assert is_binary(desc), "expected desc to be a string, got: #{inspect(desc)}"
        assert is_binary(category), "expected category to be a string, got: #{inspect(category)}"
      end)
    end

    test "built-in help command is present" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "help" in names
    end
  end

  # ---------------------------------------------------------------------------
  # execute/2 smoke tests
  # ---------------------------------------------------------------------------

  describe "execute/2" do
    test "unknown command returns :unknown" do
      assert :unknown == Commands.execute("zzz_no_such_command_xyz", "test-session")
    end

    test "help returns a command tuple with string output" do
      # The CLI strips the leading slash before calling execute/2.
      # Builtin keys are plain names: "help", "status", etc.
      result = Commands.execute("help", "test-session")
      assert {:command, output} = result
      assert is_binary(output)
    end

    # ── Previously-missing slash commands (Bug 18) ──────────────────────────

    test "/budget does not return :unknown" do
      result = Commands.execute("budget", "test-session")
      refute result == :unknown
      assert {:command, _output} = result
    end

    test "/budget returns string output" do
      {:command, output} = Commands.execute("budget", "test-session")
      assert is_binary(output)
    end

    test "/thinking with no arg does not return :unknown" do
      result = Commands.execute("thinking", "test-session")
      refute result == :unknown
      assert {:command, _output} = result
    end

    test "/thinking on enables extended thinking" do
      {:command, output} = Commands.execute("thinking on", "test-session")
      assert String.contains?(output, "enabled")
    end

    test "/thinking off disables extended thinking" do
      Commands.execute("thinking on", "test-session")
      {:command, output} = Commands.execute("thinking off", "test-session")
      assert String.contains?(output, "disabled")
    end

    test "/thinking budget N sets budget tokens" do
      {:command, output} = Commands.execute("thinking budget 8000", "test-session")
      assert String.contains?(output, "8,000")
    end

    test "/export does not return :unknown" do
      result = Commands.execute("export", "test-session")
      refute result == :unknown
      assert {:command, _output} = result
    end

    test "/export returns string output" do
      {:command, output} = Commands.execute("export", "test-session")
      assert is_binary(output)
    end

    test "/machines does not return :unknown" do
      result = Commands.execute("machines", "test-session")
      refute result == :unknown
      assert {:command, _output} = result
    end

    test "/machines returns string output" do
      {:command, output} = Commands.execute("machines", "test-session")
      assert is_binary(output)
    end

    test "/providers does not return :unknown" do
      result = Commands.execute("providers", "test-session")
      refute result == :unknown
      assert {:command, _output} = result
    end

    test "/providers returns string output" do
      {:command, output} = Commands.execute("providers", "test-session")
      assert is_binary(output)
    end
  end

  # ---------------------------------------------------------------------------
  # list_commands/0 registration check
  # ---------------------------------------------------------------------------

  describe "list_commands/0 - Bug 18 commands registered" do
    test "budget is listed" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "budget" in names
    end

    test "thinking is listed" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "thinking" in names
    end

    test "export is listed" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "export" in names
    end

    test "machines is listed" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "machines" in names
    end

    test "providers is listed" do
      names = Commands.list_commands() |> Enum.map(&elem(&1, 0))
      assert "providers" in names
    end
  end
end
