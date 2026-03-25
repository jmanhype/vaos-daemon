defmodule Daemon.PromptLoaderTest do
  use ExUnit.Case, async: false

  alias Daemon.PromptLoader

  # ---------------------------------------------------------------------------
  # get/1 — reading cached prompts
  # ---------------------------------------------------------------------------

  describe "get/1" do
    test "returns SYSTEM prompt (always present)" do
      # PromptLoader.load() is called at app boot
      result = PromptLoader.get(:SYSTEM)
      assert is_binary(result)
      assert String.length(result) > 100
    end

    test "returns IDENTITY prompt" do
      result = PromptLoader.get(:IDENTITY)
      assert is_binary(result)
    end

    test "returns SOUL prompt" do
      result = PromptLoader.get(:SOUL)
      assert is_binary(result)
    end

    test "returns compactor_summary prompt" do
      result = PromptLoader.get(:compactor_summary)
      assert is_binary(result)
    end

    test "returns compactor_key_facts prompt" do
      result = PromptLoader.get(:compactor_key_facts)
      assert is_binary(result)
    end

    test "returns cortex_synthesis prompt" do
      result = PromptLoader.get(:cortex_synthesis)
      assert is_binary(result)
    end

    test "returns nil for unknown keys" do
      assert is_nil(PromptLoader.get(:nonexistent_key))
    end

    test "dead keys are no longer loaded" do
      assert is_nil(PromptLoader.get(:classifier))
      assert is_nil(PromptLoader.get(:mode_behaviors))
      assert is_nil(PromptLoader.get(:genre_behaviors))
      assert is_nil(PromptLoader.get(:noise_filter))
    end
  end

  # ---------------------------------------------------------------------------
  # get/2 — with default fallback
  # ---------------------------------------------------------------------------

  describe "get/2" do
    test "returns prompt when key exists" do
      result = PromptLoader.get(:SYSTEM, "fallback")
      assert result != "fallback"
      assert is_binary(result)
    end

    test "returns default when key missing" do
      result = PromptLoader.get(:nonexistent_key, "my_default")
      assert result == "my_default"
    end
  end

  # ---------------------------------------------------------------------------
  # load/0 — full reload
  # ---------------------------------------------------------------------------

  describe "load/0" do
    test "loads all 6 known prompts without error" do
      assert :ok = PromptLoader.load()
    end

    test "all 6 known keys are populated after load" do
      PromptLoader.load()

      known = [:SYSTEM, :IDENTITY, :SOUL, :compactor_summary, :compactor_key_facts, :cortex_synthesis]

      for key <- known do
        value = PromptLoader.get(key)
        assert is_binary(value), "Expected #{key} to be loaded, got nil"
        assert String.length(value) > 0, "Expected #{key} to be non-empty"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Command prompt loading
  # ---------------------------------------------------------------------------

  describe "command prompts" do
    test "list_command_prompts/0 returns a list" do
      commands = PromptLoader.list_command_prompts()
      assert is_list(commands)
    end

    test "list_command_prompts/0 entries are {category, name} tuples" do
      commands = PromptLoader.list_command_prompts()

      if length(commands) > 0 do
        {cat, name} = hd(commands)
        assert is_binary(cat)
        assert is_binary(name)
      end
    end

    test "get_command/2 returns nil for nonexistent command" do
      assert is_nil(PromptLoader.get_command("fake_category", "fake_name"))
    end

    test "get_command/2 returns content for existing command" do
      commands = PromptLoader.list_command_prompts()

      if length(commands) > 0 do
        {cat, name} = hd(commands)
        result = PromptLoader.get_command(cat, name)
        assert is_binary(result)
        assert String.length(result) > 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SYSTEM.md content validation
  # ---------------------------------------------------------------------------

  describe "SYSTEM.md content" do
    test "contains Signal Theory instructions" do
      system = PromptLoader.get(:SYSTEM)
      assert String.contains?(system, "Signal Theory")
    end

    test "contains tool routing rules" do
      system = PromptLoader.get(:SYSTEM)
      assert String.contains?(system, "Tool Routing Rules")
    end

    test "contains mcts_index routing" do
      system = PromptLoader.get(:SYSTEM)
      assert String.contains?(system, "mcts_index")
    end

    test "does NOT contain references to deleted hooks" do
      system = PromptLoader.get(:SYSTEM)
      refute String.contains?(system, "learning_capture")
      refute String.contains?(system, "error_recovery")
      refute String.contains?(system, "context_optimizer")
      refute String.contains?(system, "episodic_memory")
    end

    test "hooks table references only surviving events" do
      system = PromptLoader.get(:SYSTEM)
      assert String.contains?(system, "pre_tool_use")
      assert String.contains?(system, "post_tool_use")
      # Deleted events should NOT appear in hooks table
      refute String.contains?(system, "pre_response")
      refute String.contains?(system, "session_start")
    end
  end
end
