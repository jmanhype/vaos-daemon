defmodule OptimalSystemAgent.Investigation.StrategyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Investigation.Strategy

  describe "default/0" do
    test "returns a strategy with expected default values" do
      s = Strategy.default()
      assert s.grounded_threshold == 0.4
      assert s.citation_weight == 0.5
      assert s.publisher_weight == 0.5
      assert s.review_weight == 3.0
      assert s.trial_weight == 2.0
      assert s.study_weight == 1.5
      assert s.direction_ratio == 1.3
      assert s.belief_fallback_ratio == 1.5
      assert s.top_n_papers == 15
      assert s.per_query_limit == 5
      assert s.adversarial_temperature == 0.1
      assert s.citation_bonus_base == 2.0
    end

    test "metadata fields have empty defaults" do
      s = Strategy.default()
      assert s.topic == ""
      assert s.generation == 0
      assert is_nil(s.parent_hash)
      assert s.created_at == ""
    end
  end

  describe "param_keys/0" do
    test "returns 12 optimizable parameter keys" do
      keys = Strategy.param_keys()
      assert length(keys) == 12
      assert :grounded_threshold in keys
      assert :citation_weight in keys
      assert :review_weight in keys
      assert :direction_ratio in keys
      # Metadata keys should NOT be in param_keys
      refute :topic in keys
      refute :generation in keys
      refute :parent_hash in keys
      refute :created_at in keys
    end
  end

  describe "param_hash/1" do
    test "returns a hex string" do
      hash = Strategy.param_hash(Strategy.default())
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, hash)
    end

    test "same params produce same hash" do
      s1 = Strategy.default()
      s2 = Strategy.default()
      assert Strategy.param_hash(s1) == Strategy.param_hash(s2)
    end

    test "different params produce different hash" do
      s1 = Strategy.default()
      s2 = %{s1 | grounded_threshold: 0.6}
      refute Strategy.param_hash(s1) == Strategy.param_hash(s2)
    end

    test "metadata changes do not affect hash" do
      s1 = Strategy.default()
      s2 = %{s1 | topic: "test topic", generation: 5, created_at: "2024-01-01"}
      assert Strategy.param_hash(s1) == Strategy.param_hash(s2)
    end
  end

  describe "bounds/0" do
    test "returns bounds for all param_keys" do
      bounds = Strategy.bounds()

      for key <- Strategy.param_keys() do
        assert Map.has_key?(bounds, key), "Missing bounds for #{key}"
        {min, max} = bounds[key]
        assert min < max, "Invalid bounds for #{key}: #{min} >= #{max}"
      end
    end

    test "default values are within bounds" do
      s = Strategy.default()
      bounds = Strategy.bounds()

      for key <- Strategy.param_keys() do
        {min, max} = bounds[key]
        val = Map.get(s, key)
        assert val >= min and val <= max,
          "Default #{key}=#{val} outside bounds [#{min}, #{max}]"
      end
    end
  end
end
