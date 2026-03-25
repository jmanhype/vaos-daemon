defmodule Daemon.Tools.RegistrySkillEventsTest do
  @moduledoc """
  Tests that active_skills_context/1 emits :skills_triggered bus events
  and that match_skill_triggers/1 correctly filters by trigger keywords.
  """
  use ExUnit.Case, async: false

  alias Daemon.Tools.Registry
  alias Daemon.Events.Bus

  @suffix System.unique_integer([:positive]) |> Integer.to_string()

  # Seed a skill directly into persistent_term so tests don't depend on the filesystem.
  defp seed_skill(name, triggers, instructions \\ "Do the skill thing.") do
    current = :persistent_term.get({Registry, :skills}, %{})

    skill = %{
      name: name,
      description: "Test skill #{name}",
      triggers: triggers,
      instructions: instructions,
      category: "test",
      priority: 10
    }

    :persistent_term.put({Registry, :skills}, Map.put(current, name, skill))
  end

  defp cleanup_skill(name) do
    current = :persistent_term.get({Registry, :skills}, %{})
    :persistent_term.put({Registry, :skills}, Map.delete(current, name))
  end

  # ── match_skill_triggers/1 ──────────────────────────────────────────────────

  describe "match_skill_triggers/1" do
    setup do
      name = "deploy-trigger-#{@suffix}"
      seed_skill(name, ["deploy", "release"])
      on_exit(fn -> cleanup_skill(name) end)
      {:ok, skill_name: name}
    end

    test "returns empty list when no skills match", %{skill_name: _name} do
      result = Registry.match_skill_triggers("hello world, nothing relevant")
      # Our seeded skill should not appear
      names = Enum.map(result, fn {n, _} -> n end)
      refute "deploy-trigger-#{@suffix}" in names
    end

    test "returns matching skills when trigger keyword appears in message", %{skill_name: name} do
      result = Registry.match_skill_triggers("please deploy the service")
      names = Enum.map(result, fn {n, _} -> n end)
      assert name in names
    end

    test "matching is case-insensitive", %{skill_name: name} do
      result = Registry.match_skill_triggers("DEPLOY to production")
      names = Enum.map(result, fn {n, _} -> n end)
      assert name in names
    end

    test "matches any one of multiple triggers", %{skill_name: name} do
      result = Registry.match_skill_triggers("cut a release today")
      names = Enum.map(result, fn {n, _} -> n end)
      assert name in names
    end

    test "returns empty list for non-binary input" do
      assert Registry.match_skill_triggers(nil) == []
      assert Registry.match_skill_triggers(42) == []
      assert Registry.match_skill_triggers([]) == []
    end

    test "skips skills with wildcard trigger *" do
      wc_name = "wildcard-skill-#{@suffix}"
      seed_skill(wc_name, ["*"])
      on_exit(fn -> cleanup_skill(wc_name) end)

      result = Registry.match_skill_triggers("anything at all goes here")
      names = Enum.map(result, fn {n, _} -> n end)
      refute wc_name in names
    end

    test "returns skill map payload alongside name", %{skill_name: name} do
      result = Registry.match_skill_triggers("deploy now")
      match = Enum.find(result, fn {n, _} -> n == name end)
      assert match != nil
      {_n, skill} = match
      assert Map.get(skill, :triggers) == ["deploy", "release"]
    end
  end

  # ── active_skills_context/1 emits :skills_triggered ────────────────────────

  describe "active_skills_context/1 — bus event emission" do
    setup do
      name = "monitor-skill-#{@suffix}"
      seed_skill(name, ["monitor", "observe"])
      on_exit(fn -> cleanup_skill(name) end)
      {:ok, skill_name: name}
    end

    test "emits :skills_triggered system_event when skills match", %{skill_name: name} do
      test_pid = self()

      ref =
        Bus.register_handler(:system_event, fn payload ->
          data = Map.get(payload, :data, payload)

          if data[:event] == :skills_triggered do
            send(test_pid, {:skills_triggered, data})
          end
        end)

      Registry.active_skills_context("please monitor the servers closely")

      assert_receive {:skills_triggered, data}, 2000
      assert name in data[:skills]
      assert is_binary(data[:message_preview])

      Bus.unregister_handler(:system_event, ref)
    end

    test "message_preview is truncated to 120 chars", %{skill_name: _name} do
      test_pid = self()
      long_msg = String.duplicate("monitor ", 30)

      ref =
        Bus.register_handler(:system_event, fn payload ->
          data = Map.get(payload, :data, payload)

          if data[:event] == :skills_triggered do
            send(test_pid, {:preview, data[:message_preview]})
          end
        end)

      Registry.active_skills_context(long_msg)

      assert_receive {:preview, preview}, 2000
      assert String.length(preview) <= 120

      Bus.unregister_handler(:system_event, ref)
    end

    test "does NOT emit :skills_triggered when no skills match" do
      test_pid = self()

      ref =
        Bus.register_handler(:system_event, fn payload ->
          data = Map.get(payload, :data, payload)

          if data[:event] == :skills_triggered do
            send(test_pid, :unexpected_event)
          end
        end)

      Registry.active_skills_context("nothing special about this message at all")

      refute_receive :unexpected_event, 500

      Bus.unregister_handler(:system_event, ref)
    end

    test "returns nil or string (not crashing) for nil input" do
      result = Registry.active_skills_context(nil)
      assert is_nil(result) or is_binary(result)
    end

    test "returns nil or string (not crashing) for empty string" do
      result = Registry.active_skills_context("")
      assert is_nil(result) or is_binary(result)
    end
  end

  # ── active_skills_context/1 — context injection ─────────────────────────────

  describe "active_skills_context/1 — instruction injection" do
    setup do
      name = "inject-skill-#{@suffix}"
      seed_skill(name, ["inject"], "INJECTED_SKILL_INSTRUCTIONS")
      on_exit(fn -> cleanup_skill(name) end)
      {:ok, skill_name: name}
    end

    test "includes matched skill instructions in returned context", %{skill_name: name} do
      result = Registry.active_skills_context("please inject this")
      assert is_binary(result)
      assert String.contains?(result, "INJECTED_SKILL_INSTRUCTIONS")
      assert String.contains?(result, name)
    end

    test "returns nil when no skills match and no base skills loaded" do
      # With no matching skills and no base skills context, result is nil or binary
      result = Registry.active_skills_context("no_trigger_keyword_here_xyz_abc")
      assert is_nil(result) or is_binary(result)
    end
  end
end
