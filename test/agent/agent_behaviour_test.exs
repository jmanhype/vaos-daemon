defmodule Daemon.Agent.AgentBehaviourTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Roster

  @all_agent_modules [
    Daemon.Agents.MasterOrchestrator,
    Daemon.Agents.Architect,
    Daemon.Agents.Dragon,
    Daemon.Agents.Nova,
    Daemon.Agents.BackendGo,
    Daemon.Agents.FrontendReact,
    Daemon.Agents.FrontendSvelte,
    Daemon.Agents.Database,
    Daemon.Agents.SecurityAuditor,
    Daemon.Agents.RedTeam,
    Daemon.Agents.Debugger,
    Daemon.Agents.TestAutomator,
    Daemon.Agents.CodeReviewer,
    Daemon.Agents.PerformanceOptimizer,
    Daemon.Agents.Devops,
    Daemon.Agents.ApiDesigner,
    Daemon.Agents.Refactorer,
    Daemon.Agents.Explorer,
    Daemon.Agents.Formatter,
    Daemon.Agents.DocWriter,
    Daemon.Agents.DependencyAnalyzer,
    Daemon.Agents.TypescriptExpert,
    Daemon.Agents.TailwindExpert,
    Daemon.Agents.GoConcurrency,
    Daemon.Agents.OrmExpert
  ]

  describe "all agent modules implement AgentBehaviour" do
    for mod <- @all_agent_modules do
      @mod mod
      test "#{inspect(mod)} implements all callbacks" do
        # name/0
        name = @mod.name()
        assert is_binary(name)
        assert String.length(name) > 0

        # description/0
        desc = @mod.description()
        assert is_binary(desc)
        assert String.length(desc) > 0

        # tier/0
        tier = @mod.tier()
        assert tier in [:elite, :specialist, :utility]

        # role/0
        role = @mod.role()
        assert is_atom(role)

        # system_prompt/0
        prompt = @mod.system_prompt()
        assert is_binary(prompt)
        assert String.length(prompt) > 10

        # skills/0
        skills = @mod.skills()
        assert is_list(skills)
        assert Enum.all?(skills, &is_binary/1)

        # triggers/0
        triggers = @mod.triggers()
        assert is_list(triggers)
        assert Enum.all?(triggers, &is_binary/1)

        # territory/0
        territory = @mod.territory()
        assert is_list(territory)
        assert Enum.all?(territory, &is_binary/1)

        # escalate_to/0
        esc = @mod.escalate_to()
        assert is_nil(esc) or is_binary(esc)
      end
    end
  end

  describe "Roster backward compatibility" do
    test "all/0 returns 25+ agents as maps" do
      agents = Roster.all()
      assert map_size(agents) >= 25

      Enum.each(agents, fn {name, agent} ->
        assert is_binary(name)
        assert agent.name == name
        assert agent.tier in [:elite, :specialist, :utility]
        assert is_atom(agent.role)
        assert is_binary(agent.description)
        assert is_list(agent.skills)
        assert is_list(agent.triggers)
        assert is_list(agent.territory)
        assert is_binary(agent.prompt)
      end)
    end

    test "get/1 returns agent map or nil" do
      agent = Roster.get("dragon")
      assert agent.name == "dragon"
      assert agent.tier == :elite

      assert Roster.get("nonexistent-agent-xyz") == nil
    end

    test "list_names/0 includes all known agents" do
      names = Roster.list_names()
      assert "master-orchestrator" in names
      assert "dragon" in names
      assert "backend-go" in names
      assert "debugger" in names
      assert length(names) >= 25
    end

    test "by_tier/1 filters correctly" do
      elite = Roster.by_tier(:elite)
      assert length(elite) >= 3
      assert Enum.all?(elite, &(&1.tier == :elite))

      specialist = Roster.by_tier(:specialist)
      assert length(specialist) >= 10
      assert Enum.all?(specialist, &(&1.tier == :specialist))
    end

    test "by_role/1 filters correctly" do
      leads = Roster.by_role(:lead)
      assert length(leads) >= 1
      assert Enum.all?(leads, &(&1.role == :lead))
    end

    test "find_by_trigger/1 returns highest-tier match" do
      agent = Roster.find_by_trigger("debug this bug")
      assert agent != nil
      assert "debug" in agent.triggers or "bug" in agent.triggers
    end

    test "find_by_file/1 dispatches by extension" do
      go_agent = Roster.find_by_file("main.go")
      assert go_agent != nil
      assert go_agent.name == "backend-go"

      svelte_agent = Roster.find_by_file("App.svelte")
      assert svelte_agent != nil
      assert svelte_agent.name == "frontend-svelte"
    end

    test "select_for_task/1 returns ranked list" do
      results = Roster.select_for_task("fix the Go backend API")
      assert is_list(results)
      assert length(results) > 0
      assert Enum.all?(results, &is_binary/1)
    end

    test "select_for_task_scored/1 returns name-score pairs" do
      results = Roster.select_for_task_scored("security vulnerability scan")
      assert is_list(results)
      assert length(results) > 0

      Enum.each(results, fn {name, score} ->
        assert is_binary(name)
        assert is_number(score)
      end)
    end

    test "swarm_presets/0 returns 10 presets" do
      presets = Roster.swarm_presets()
      assert map_size(presets) == 10
      assert Map.has_key?(presets, "code-analysis")
      assert Map.has_key?(presets, "full-stack")
    end

    test "role_prompt/1 returns string for valid roles" do
      prompt = Roster.role_prompt(:backend)
      assert is_binary(prompt)
      assert String.length(prompt) > 10

      prompt = Roster.role_prompt(:red_team)
      assert is_binary(prompt)
    end

    test "valid_roles/0 returns list of atoms" do
      roles = Roster.valid_roles()
      assert is_list(roles)
      assert :backend in roles
      assert :frontend in roles
      assert :lead in roles
      assert :red_team in roles
    end

    test "max_agents/0 returns positive integer" do
      max = Roster.max_agents()
      assert is_integer(max)
      assert max > 0
    end
  end
end
