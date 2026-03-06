defmodule OptimalSystemAgent.Agent.Orchestrator.ComplexityScalerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Orchestrator.ComplexityScaler

  # ── optimal_agent_count/3 ─────────────────────────────────────────

  describe "optimal_agent_count/3" do
    test "maps each complexity score to expected count (no tier cap, elite)" do
      expected = %{1 => 1, 2 => 2, 3 => 3, 4 => 5, 5 => 8, 6 => 12, 7 => 18, 8 => 25, 9 => 35, 10 => 50}

      for {score, count} <- expected do
        assert ComplexityScaler.optimal_agent_count(score, :elite, nil) == count,
               "score #{score} should map to #{count} agents for elite"
      end
    end

    test "specialist tier caps at 30" do
      assert ComplexityScaler.optimal_agent_count(10, :specialist, nil) == 30
      assert ComplexityScaler.optimal_agent_count(9, :specialist, nil) == 30
      assert ComplexityScaler.optimal_agent_count(8, :specialist, nil) == 25
      assert ComplexityScaler.optimal_agent_count(7, :specialist, nil) == 18
    end

    test "utility tier caps at 10" do
      assert ComplexityScaler.optimal_agent_count(10, :utility, nil) == 10
      assert ComplexityScaler.optimal_agent_count(7, :utility, nil) == 10
      assert ComplexityScaler.optimal_agent_count(5, :utility, nil) == 8
      assert ComplexityScaler.optimal_agent_count(4, :utility, nil) == 5
      assert ComplexityScaler.optimal_agent_count(3, :utility, nil) == 3
    end

    test "user override takes priority over score and tier" do
      assert ComplexityScaler.optimal_agent_count(1, :utility, 25) == 25
      assert ComplexityScaler.optimal_agent_count(10, :elite, 5) == 5
      assert ComplexityScaler.optimal_agent_count(3, :specialist, 40) == 40
    end

    test "user override capped at 50" do
      assert ComplexityScaler.optimal_agent_count(10, :elite, 100) == 50
      assert ComplexityScaler.optimal_agent_count(1, :utility, 999) == 50
    end

    test "unknown tier defaults to ceiling of 10" do
      assert ComplexityScaler.optimal_agent_count(10, :unknown_tier, nil) == 10
      assert ComplexityScaler.optimal_agent_count(5, :whatever, nil) == 8
    end

    test "clamps score below 1 to 1" do
      assert ComplexityScaler.optimal_agent_count(0, :elite, nil) == 1
      assert ComplexityScaler.optimal_agent_count(-5, :elite, nil) == 1
    end

    test "clamps score above 10 to 10" do
      assert ComplexityScaler.optimal_agent_count(15, :elite, nil) == 50
      assert ComplexityScaler.optimal_agent_count(100, :specialist, nil) == 30
    end
  end

  # ── detect_agent_count_intent/1 ───────────────────────────────────

  describe "detect_agent_count_intent/1" do
    test "detects 'use N agents' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("use 25 agents to refactor auth") == 25
      assert ComplexityScaler.detect_agent_count_intent("Use 10 agents for this task") == 10
      assert ComplexityScaler.detect_agent_count_intent("use 1 agent on this") == 1
    end

    test "detects 'N agents to/for/on' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("deploy 8 agents to fix the bug") == 8
      assert ComplexityScaler.detect_agent_count_intent("send 12 agents for the refactor") == 12
    end

    test "detects 'swarm of N' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("swarm of 15") == 15
      assert ComplexityScaler.detect_agent_count_intent("launch a swarm of 30 on the codebase") == 30
    end

    test "detects 'dispatch N' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("dispatch 5") == 5
    end

    test "detects 'launch N agents' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("launch 20 agents") == 20
    end

    test "detects 'spawn N agents' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("spawn 7 agents for testing") == 7
    end

    test "detects 'deploy N agents' pattern" do
      assert ComplexityScaler.detect_agent_count_intent("deploy 3 agents") == 3
    end

    test "returns nil for no agent count intent" do
      assert ComplexityScaler.detect_agent_count_intent("fix the auth bug") == nil
      assert ComplexityScaler.detect_agent_count_intent("refactor the database") == nil
      assert ComplexityScaler.detect_agent_count_intent("hello world") == nil
      assert ComplexityScaler.detect_agent_count_intent("") == nil
    end

    test "returns nil for count > 50" do
      assert ComplexityScaler.detect_agent_count_intent("use 100 agents") == nil
      assert ComplexityScaler.detect_agent_count_intent("swarm of 51") == nil
    end

    test "returns nil for count = 0" do
      assert ComplexityScaler.detect_agent_count_intent("use 0 agents") == nil
    end

    test "is case-insensitive" do
      assert ComplexityScaler.detect_agent_count_intent("USE 15 AGENTS") == 15
      assert ComplexityScaler.detect_agent_count_intent("Spawn 8 Agents") == 8
      assert ComplexityScaler.detect_agent_count_intent("SWARM OF 20") == 20
    end
  end
end
