defmodule OptimalSystemAgent.Investigation.OperationsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Investigation.{Operations, Strategy}

  describe "operations/0" do
    test "returns 8 operations" do
      ops = Operations.operations()
      assert length(ops) == 8
      assert :tighten_grounding in ops
      assert :loosen_grounding in ops
      assert :shift_hierarchy in ops
      assert :widen_search in ops
      assert :narrow_search in ops
      assert :adjust_direction_sensitivity in ops
      assert :rebalance_source_quality in ops
      assert :perturb_temperature in ops
    end
  end

  describe "bounds enforcement" do
    test "tighten_grounding increases threshold within bounds" do
      s = Strategy.default()
      result = Operations.apply_op(s, :tighten_grounding)
      assert result.grounded_threshold == 0.45
      assert result.grounded_threshold >= 0.2
      assert result.grounded_threshold <= 0.7
    end

    test "loosen_grounding decreases threshold within bounds" do
      s = Strategy.default()
      result = Operations.apply_op(s, :loosen_grounding)
      assert_in_delta result.grounded_threshold, 0.35, 0.001
      assert result.grounded_threshold >= 0.2
      assert result.grounded_threshold <= 0.7
    end

    test "tighten_grounding cannot exceed upper bound" do
      s = %{Strategy.default() | grounded_threshold: 0.7}
      result = Operations.apply_op(s, :tighten_grounding)
      assert result.grounded_threshold == 0.7
    end

    test "loosen_grounding cannot go below lower bound" do
      s = %{Strategy.default() | grounded_threshold: 0.2}
      result = Operations.apply_op(s, :loosen_grounding)
      assert result.grounded_threshold == 0.2
    end

    test "widen_search increases papers and per_query within bounds" do
      s = Strategy.default()
      result = Operations.apply_op(s, :widen_search)
      assert result.top_n_papers == 17
      assert result.per_query_limit == 6
    end

    test "narrow_search decreases papers and per_query within bounds" do
      s = Strategy.default()
      result = Operations.apply_op(s, :narrow_search)
      assert result.top_n_papers == 13
      assert result.per_query_limit == 4
    end

    test "widen_search respects upper bounds" do
      s = %{Strategy.default() | top_n_papers: 25, per_query_limit: 10}
      result = Operations.apply_op(s, :widen_search)
      assert result.top_n_papers == 25
      assert result.per_query_limit == 10
    end

    test "narrow_search respects lower bounds" do
      s = %{Strategy.default() | top_n_papers: 8, per_query_limit: 3}
      result = Operations.apply_op(s, :narrow_search)
      assert result.top_n_papers == 8
      assert result.per_query_limit == 3
    end
  end

  describe "constraint preservation" do
    test "rebalance_source_quality maintains sum close to 1.0" do
      s = Strategy.default()
      # Run multiple times to test stochastic behavior
      for _ <- 1..20 do
        result = Operations.apply_op(s, :rebalance_source_quality)
        sum = result.citation_weight + result.publisher_weight
        assert_in_delta sum, 1.0, 0.01,
          "citation_weight + publisher_weight = #{sum}, expected ~1.0"
        assert result.citation_weight >= 0.2
        assert result.citation_weight <= 0.8
        assert result.publisher_weight >= 0.2
        assert result.publisher_weight <= 0.8
      end
    end
  end

  describe "shift_hierarchy" do
    test "all hierarchy weights stay within bounds" do
      s = Strategy.default()
      for _ <- 1..20 do
        result = Operations.apply_op(s, :shift_hierarchy)
        assert result.review_weight >= 1.5 and result.review_weight <= 5.0
        assert result.trial_weight >= 1.0 and result.trial_weight <= 3.5
        assert result.study_weight >= 1.0 and result.study_weight <= 2.5
      end
    end
  end

  describe "perturb_temperature" do
    test "temperature stays within bounds" do
      s = Strategy.default()
      for _ <- 1..20 do
        result = Operations.apply_op(s, :perturb_temperature)
        assert result.adversarial_temperature >= 0.0
        assert result.adversarial_temperature <= 0.5
      end
    end

    test "temperature at lower bound cannot decrease" do
      s = %{Strategy.default() | adversarial_temperature: 0.0}
      results = for _ <- 1..20, do: Operations.apply_op(s, :perturb_temperature)
      # About half should stay at 0.0, half should go to 0.05
      assert Enum.all?(results, fn r -> r.adversarial_temperature >= 0.0 end)
    end
  end

  describe "adjust_direction_sensitivity" do
    test "direction_ratio stays within bounds" do
      s = Strategy.default()
      for _ <- 1..20 do
        result = Operations.apply_op(s, :adjust_direction_sensitivity)
        assert result.direction_ratio >= 1.1 and result.direction_ratio <= 2.0
        assert result.belief_fallback_ratio >= 1.2 and result.belief_fallback_ratio <= 2.5
      end
    end
  end

  describe "clamp/3" do
    test "clamps below minimum" do
      assert Operations.clamp(-1.0, 0.0, 1.0) == 0.0
    end

    test "clamps above maximum" do
      assert Operations.clamp(2.0, 0.0, 1.0) == 1.0
    end

    test "passes through values within bounds" do
      assert Operations.clamp(0.5, 0.0, 1.0) == 0.5
    end

    test "works with integers" do
      assert Operations.clamp(3, 5, 10) == 5
      assert Operations.clamp(15, 5, 10) == 10
      assert Operations.clamp(7, 5, 10) == 7
    end
  end
end
