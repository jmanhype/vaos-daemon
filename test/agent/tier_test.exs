defmodule Daemon.Agent.TierTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Tier

  # ── max_agents/1 ──────────────────────────────────────────────────

  describe "max_agents/1" do
    test "elite allows 50 agents" do
      assert Tier.max_agents(:elite) == 50
    end

    test "specialist allows 30 agents" do
      assert Tier.max_agents(:specialist) == 30
    end

    test "utility allows 10 agents" do
      assert Tier.max_agents(:utility) == 10
    end
  end

  # ── tier_for_complexity/1 ─────────────────────────────────────────

  describe "tier_for_complexity/1" do
    test "low complexity maps to utility" do
      assert Tier.tier_for_complexity(1) == :utility
      assert Tier.tier_for_complexity(2) == :utility
      assert Tier.tier_for_complexity(3) == :utility
    end

    test "medium complexity maps to specialist" do
      assert Tier.tier_for_complexity(4) == :specialist
      assert Tier.tier_for_complexity(5) == :specialist
      assert Tier.tier_for_complexity(6) == :specialist
    end

    test "high complexity maps to elite" do
      assert Tier.tier_for_complexity(7) == :elite
      assert Tier.tier_for_complexity(8) == :elite
      assert Tier.tier_for_complexity(9) == :elite
      assert Tier.tier_for_complexity(10) == :elite
    end
  end

  # ── budget_for/1 ──────────────────────────────────────────────────

  describe "budget_for/1" do
    test "returns budget map for each tier" do
      for tier <- [:elite, :specialist, :utility] do
        budget = Tier.budget_for(tier)
        assert is_map(budget)
        assert Map.has_key?(budget, :total)
        assert budget.total > 0
      end
    end

    test "elite has highest total budget" do
      assert Tier.total_budget(:elite) > Tier.total_budget(:specialist)
      assert Tier.total_budget(:specialist) > Tier.total_budget(:utility)
    end
  end

  # ── max_response_tokens/1 ─────────────────────────────────────────

  describe "max_response_tokens/1" do
    test "elite gets most response tokens" do
      assert Tier.max_response_tokens(:elite) > Tier.max_response_tokens(:specialist)
      assert Tier.max_response_tokens(:specialist) > Tier.max_response_tokens(:utility)
    end
  end

  # ── tier_info/1 ───────────────────────────────────────────────────

  describe "tier_info/1" do
    test "returns complete tier info with max_agents reflecting new ceilings" do
      info = Tier.tier_info(:elite)
      assert info.max_agents == 50

      info = Tier.tier_info(:specialist)
      assert info.max_agents == 30

      info = Tier.tier_info(:utility)
      assert info.max_agents == 10
    end
  end

  describe "model_for/2" do
    test "uses a supported flash model for zhipu utility tier" do
      assert Tier.model_for(:utility, :zhipu) == "glm-4.5-flash"
    end
  end
end
