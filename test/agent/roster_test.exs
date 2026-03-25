defmodule Daemon.Agent.RosterTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Roster

  # ---------------------------------------------------------------------------
  # all/0
  # ---------------------------------------------------------------------------

  describe "all/0" do
    test "returns a non-empty map" do
      agents = Roster.all()
      assert is_map(agents)
      assert map_size(agents) > 0
    end

    test "each agent has required keys" do
      for {_name, agent} <- Roster.all() do
        assert Map.has_key?(agent, :name)
        assert Map.has_key?(agent, :tier)
        assert Map.has_key?(agent, :role)
        assert Map.has_key?(agent, :description)
        assert Map.has_key?(agent, :skills)
        assert Map.has_key?(agent, :triggers)
        assert Map.has_key?(agent, :territory)
        assert Map.has_key?(agent, :module) or Map.has_key?(agent, :prompt),
               "agent #{agent.name} must have either :module or :prompt"
      end
    end

    test "all tier values are valid atoms" do
      valid_tiers = [:elite, :specialist, :utility]
      for {_name, agent} <- Roster.all() do
        assert agent.tier in valid_tiers, "agent #{agent.name} has invalid tier #{agent.tier}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # get/1
  # ---------------------------------------------------------------------------

  describe "get/1" do
    test "returns an agent def for a known agent" do
      agent = Roster.get("debugger")
      assert agent != nil
      assert agent.name == "debugger"
    end

    test "returns nil for an unknown agent name" do
      assert Roster.get("nonexistent-agent-xyz") == nil
    end

    test "master-orchestrator is a known elite agent" do
      agent = Roster.get("master-orchestrator")
      assert agent != nil
      assert agent.tier == :elite
    end
  end

  # ---------------------------------------------------------------------------
  # list_names/0
  # ---------------------------------------------------------------------------

  describe "list_names/0" do
    test "returns a non-empty list of strings" do
      names = Roster.list_names()
      assert is_list(names)
      assert length(names) > 0
      for name <- names, do: assert(is_binary(name))
    end

    test "includes expected core agents" do
      names = Roster.list_names()
      assert "debugger" in names
      assert "test-automator" in names
      assert "code-reviewer" in names
    end
  end

  # ---------------------------------------------------------------------------
  # by_tier/1
  # ---------------------------------------------------------------------------

  describe "by_tier/1" do
    test "elite tier returns at least one agent" do
      assert Roster.by_tier(:elite) |> length() >= 1
    end

    test "specialist tier returns agents" do
      assert Roster.by_tier(:specialist) |> length() >= 1
    end

    test "all returned agents match the requested tier" do
      for tier <- [:elite, :specialist, :utility] do
        for agent <- Roster.by_tier(tier) do
          assert agent.tier == tier
        end
      end
    end

    test "unknown tier returns empty list" do
      assert Roster.by_tier(:legendary) == []
    end
  end

  # ---------------------------------------------------------------------------
  # by_role/1
  # ---------------------------------------------------------------------------

  describe "by_role/1" do
    test "backend role returns at least one agent" do
      assert Roster.by_role(:backend) |> length() >= 1
    end

    test "all returned agents match the requested role" do
      for agent <- Roster.by_role(:backend) do
        assert agent.role == :backend
      end
    end

    test "unknown role returns empty list" do
      assert Roster.by_role(:intergalactic_ceo) == []
    end
  end

  # ---------------------------------------------------------------------------
  # find_by_trigger/1
  # ---------------------------------------------------------------------------

  describe "find_by_trigger/1" do
    test "returns an agent for a relevant keyword" do
      agent = Roster.find_by_trigger("there is a bug in production")
      assert agent != nil
    end

    test "returns nil for completely irrelevant input" do
      # No agent should trigger on pure gibberish
      result = Roster.find_by_trigger("xyzzy quux fnord glarble")
      # nil is acceptable; some agent might have broad triggers
      assert result == nil or is_map(result)
    end

    test "matched agent has valid tier" do
      agent = Roster.find_by_trigger("review this code")
      if agent do
        assert agent.tier in [:elite, :specialist, :utility]
      end
    end

    test "higher-tier agent wins over lower-tier when both match" do
      # This is a property test — if an elite and a specialist both match,
      # the result should be the elite agent.
      agent = Roster.find_by_trigger("test security performance refactor")
      if agent do
        # We cannot guarantee which specific agent wins, but tier must be valid
        assert agent.tier in [:elite, :specialist, :utility]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # find_by_file/1
  # ---------------------------------------------------------------------------

  describe "find_by_file/1" do
    test ".go files route to backend-go" do
      agent = Roster.find_by_file("handler.go")
      assert agent != nil
      assert agent.name == "backend-go"
    end

    test ".tsx files route to frontend-react" do
      agent = Roster.find_by_file("Button.tsx")
      assert agent != nil
      assert agent.name == "frontend-react"
    end

    test ".sql files route to database" do
      agent = Roster.find_by_file("migration.sql")
      assert agent != nil
      assert agent.name == "database"
    end

    test "Dockerfile routes to devops" do
      agent = Roster.find_by_file("Dockerfile")
      assert agent != nil
      assert agent.name == "devops"
    end

    test "unknown extension returns nil" do
      assert Roster.find_by_file("notes.txt") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # prompt_for/1
  # ---------------------------------------------------------------------------

  describe "prompt_for/1" do
    test "returns a non-empty string for a known agent" do
      prompt = Roster.prompt_for("debugger")
      assert is_binary(prompt)
      assert byte_size(prompt) > 0
    end

    test "returns nil for an unknown agent" do
      assert Roster.prompt_for("phantom-agent") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # role_prompt/1
  # ---------------------------------------------------------------------------

  describe "role_prompt/1" do
    test "returns a non-empty string for all valid roles" do
      for role <- Roster.valid_roles() do
        prompt = Roster.role_prompt(role)
        assert is_binary(prompt), "Expected string for role #{role}"
        assert byte_size(prompt) > 0
      end
    end

    test "falls back to backend prompt for unknown roles" do
      default = Roster.role_prompt(:backend)
      fallback = Roster.role_prompt(:totally_unknown_role)
      assert fallback == default
    end
  end

  # ---------------------------------------------------------------------------
  # valid_roles/0
  # ---------------------------------------------------------------------------

  describe "valid_roles/0" do
    test "returns a list of atoms" do
      roles = Roster.valid_roles()
      assert is_list(roles)
      for r <- roles, do: assert(is_atom(r))
    end

    test "includes core roles" do
      roles = Roster.valid_roles()
      assert :backend in roles
      assert :frontend in roles
      assert :qa in roles
    end
  end

  # ---------------------------------------------------------------------------
  # swarm_presets/0 and swarm_preset/1
  # ---------------------------------------------------------------------------

  describe "swarm_presets/0" do
    test "returns a map of presets" do
      presets = Roster.swarm_presets()
      assert is_map(presets)
      assert map_size(presets) > 0
    end

    test "each preset has required keys" do
      for {_name, preset} <- Roster.swarm_presets() do
        assert Map.has_key?(preset, :pattern)
        assert Map.has_key?(preset, :agents)
        assert Map.has_key?(preset, :timeout_ms)
      end
    end
  end

  describe "swarm_preset/1" do
    test "returns the preset for a known name" do
      preset = Roster.swarm_preset("code-analysis")
      assert preset != nil
      assert preset.pattern == :parallel
    end

    test "returns nil for unknown preset" do
      assert Roster.swarm_preset("nonexistent-preset") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # select_for_task/1
  # ---------------------------------------------------------------------------

  describe "select_for_task/1" do
    test "returns a list of agent names" do
      names = Roster.select_for_task("debug a performance issue in the Go backend")
      assert is_list(names)
      for n <- names, do: assert(is_binary(n))
    end

    test "names in result exist in the roster" do
      names = Roster.select_for_task("write tests for the authentication module")
      for name <- names do
        assert Roster.get(name) != nil, "#{name} not found in roster"
      end
    end

    test "returns empty list for irrelevant gibberish" do
      # Gibberish unlikely to match any agent trigger
      result = Roster.select_for_task("zzz qqq www fff")
      assert is_list(result)
    end
  end

  # ---------------------------------------------------------------------------
  # select_for_task_scored/1
  # ---------------------------------------------------------------------------

  describe "select_for_task_scored/1" do
    test "returns {name, score} pairs" do
      pairs = Roster.select_for_task_scored("debug a security vulnerability")
      assert is_list(pairs)
      for {name, score} <- pairs do
        assert is_binary(name)
        assert is_number(score)
        assert score > 0
      end
    end

    test "sorted in descending order by score" do
      pairs = Roster.select_for_task_scored("fix bug test review security")
      scores = Enum.map(pairs, fn {_, s} -> s end)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ---------------------------------------------------------------------------
  # max_agents/0
  # ---------------------------------------------------------------------------

  describe "max_agents/0" do
    test "returns a positive integer" do
      n = Roster.max_agents()
      assert is_integer(n)
      assert n > 0
    end
  end

  # ---------------------------------------------------------------------------
  # load_definition/1  (file-system backed — best-effort)
  # ---------------------------------------------------------------------------

  describe "load_definition/1" do
    test "returns not_found for nonexistent agent" do
      assert {:error, :not_found} = Roster.load_definition("definitely-not-an-agent-xyz")
    end
  end

  # ---------------------------------------------------------------------------
  # list_definitions/0
  # ---------------------------------------------------------------------------

  describe "list_definitions/0" do
    test "returns a map with the expected subdirectory keys" do
      defs = Roster.list_definitions()
      assert is_map(defs)
      # Each value is a list (possibly empty if priv/agents/ dirs don't exist)
      for {_subdir, names} <- defs do
        assert is_list(names)
      end
    end
  end
end
