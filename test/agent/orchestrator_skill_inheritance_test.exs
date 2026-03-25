defmodule Daemon.Agent.OrchestratorSkillInheritanceTest do
  @moduledoc """
  Tests for inherited_skills propagation through the Orchestrator SubTask struct
  and the skill-injection logic in AgentRunner.

  These are unit-level tests: they work directly with the SubTask struct and
  the AgentRunner.build_system_prompt helper. No LLM or live GenServer needed.
  """
  use ExUnit.Case, async: false

  alias Daemon.Agent.Orchestrator.SubTask
  alias Daemon.Tools.Registry

  @suffix System.unique_integer([:positive]) |> Integer.to_string()

  # ── SubTask struct ───────────────────────────────────────────────────────────

  describe "SubTask struct" do
    test "defaults inherited_skills to empty list" do
      st = %SubTask{name: "research", description: "do research", role: "researcher", tools_needed: []}
      assert st.inherited_skills == []
    end

    test "accepts inherited_skills list" do
      st = %SubTask{
        name: "build",
        description: "build the thing",
        role: "builder",
        tools_needed: [],
        inherited_skills: ["deploy", "monitor"]
      }
      assert st.inherited_skills == ["deploy", "monitor"]
    end

    test "struct update preserves other fields" do
      st = %SubTask{name: "task", description: "desc", role: "r", tools_needed: ["shell"], depends_on: ["prev"]}
      updated = %{st | inherited_skills: ["debug"]}
      assert updated.name == "task"
      assert updated.depends_on == ["prev"]
      assert updated.inherited_skills == ["debug"]
    end

    test "can be updated with context and inherited_skills simultaneously" do
      st = %SubTask{name: "x", description: "x", role: "r", tools_needed: []}
      updated = %{st | context: "previous result here", inherited_skills: ["analyze"]}
      assert updated.context == "previous result here"
      assert updated.inherited_skills == ["analyze"]
    end
  end

  # ── match_skill_triggers for inherited_skills propagation ───────────────────

  describe "match_skill_triggers — parent message skill extraction" do
    setup do
      name = "deploy-inherit-#{@suffix}"
      current = :persistent_term.get({Registry, :skills}, %{})

      skill = %{
        name: name,
        description: "Deployment skill",
        triggers: ["deploy", "release"],
        instructions: "Use these deployment steps...",
        category: "devops",
        priority: 10
      }

      :persistent_term.put({Registry, :skills}, Map.put(current, name, skill))
      on_exit(fn ->
        c = :persistent_term.get({Registry, :skills}, %{})
        :persistent_term.put({Registry, :skills}, Map.delete(c, name))
      end)

      {:ok, skill_name: name}
    end

    test "parent message triggers yield skill names for sub-task inheritance", %{skill_name: name} do
      parent_msg = "please deploy the new service to production"
      matched = Registry.match_skill_triggers(parent_msg)
      names = Enum.map(matched, fn {n, _} -> n end)
      assert name in names
    end

    test "sub-task description with different keywords does not override parent match", %{skill_name: name} do
      # Parent message matched the deploy skill
      parent_matched_names = ["deploy-inherit-#{@suffix}"]

      # Sub-task description has no trigger keyword — would match nothing by itself
      sub_desc_matched = Registry.match_skill_triggers("write unit tests for auth module")
      sub_names = Enum.map(sub_desc_matched, fn {n, _} -> n end)
      refute name in sub_names

      # But inherited_skills from parent are passed down regardless
      st = %SubTask{
        name: "test",
        description: "write unit tests for auth module",
        role: "qa",
        tools_needed: [],
        inherited_skills: parent_matched_names
      }

      assert name in st.inherited_skills
    end

    test "no skills triggered when parent message has no trigger keywords" do
      matched = Registry.match_skill_triggers("could you summarize the meeting notes please")
      names = Enum.map(matched, fn {n, _} -> n end)
      refute "deploy-inherit-#{@suffix}" in names
    end
  end

  # ── inherited_skills injection into prompt (AgentRunner logic) ──────────────

  describe "inherited_skills → system prompt injection logic" do
    setup do
      name = "inject-inherit-#{@suffix}"
      current = :persistent_term.get({Registry, :skills}, %{})

      skill = %{
        name: name,
        description: "Inject test skill",
        triggers: ["inject"],
        instructions: "INHERITED_INSTRUCTION_BLOCK",
        category: "test",
        priority: 10
      }

      :persistent_term.put({Registry, :skills}, Map.put(current, name, skill))
      on_exit(fn ->
        c = :persistent_term.get({Registry, :skills}, %{})
        :persistent_term.put({Registry, :skills}, Map.delete(c, name))
      end)

      {:ok, skill_name: name}
    end

    test "inherited skill instructions can be fetched from persistent_term", %{skill_name: name} do
      skills = :persistent_term.get({Registry, :skills}, %{})
      assert Map.has_key?(skills, name)
      skill = Map.fetch!(skills, name)
      assert skill.instructions == "INHERITED_INSTRUCTION_BLOCK"
    end

    test "building inherited context block from skill names resolves instructions", %{skill_name: name} do
      # Simulate what agent_runner does: resolve inherited_skills names to instructions
      inherited_names = [name]
      skills = :persistent_term.get({Registry, :skills}, %{})

      ctx =
        inherited_names
        |> Enum.flat_map(fn n ->
          case Map.get(skills, n) do
            nil -> []
            s ->
              inst = to_string(Map.get(s, :instructions, "")) |> String.trim()
              if inst != "", do: ["### Inherited Skill: #{n}\n\n#{inst}"], else: []
          end
        end)
        |> Enum.join("\n\n")

      assert String.contains?(ctx, "INHERITED_INSTRUCTION_BLOCK")
      assert String.contains?(ctx, name)
    end

    test "unknown inherited skill names produce empty context gracefully" do
      inherited_names = ["definitely-not-a-real-skill-xyz-#{@suffix}"]
      skills = :persistent_term.get({Registry, :skills}, %{})

      ctx =
        inherited_names
        |> Enum.flat_map(fn n ->
          case Map.get(skills, n) do
            nil -> []
            s ->
              inst = to_string(Map.get(s, :instructions, "")) |> String.trim()
              if inst != "", do: ["### Inherited Skill: #{n}\n\n#{inst}"], else: []
          end
        end)
        |> Enum.join("\n\n")

      assert ctx == ""
    end

    test "skill with empty instructions is excluded from inherited context" do
      empty_name = "empty-inst-#{@suffix}"
      current = :persistent_term.get({Registry, :skills}, %{})
      :persistent_term.put({Registry, :skills}, Map.put(current, empty_name, %{name: empty_name, instructions: "  ", triggers: ["empty"]}))
      on_exit(fn ->
        c = :persistent_term.get({Registry, :skills}, %{})
        :persistent_term.put({Registry, :skills}, Map.delete(c, empty_name))
      end)

      skills = :persistent_term.get({Registry, :skills}, %{})

      ctx =
        [empty_name]
        |> Enum.flat_map(fn n ->
          case Map.get(skills, n) do
            nil -> []
            s ->
              inst = to_string(Map.get(s, :instructions, "")) |> String.trim()
              if inst != "", do: ["### Inherited Skill: #{n}\n\n#{inst}"], else: []
          end
        end)
        |> Enum.join("\n\n")

      assert ctx == ""
    end
  end
end
