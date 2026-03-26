defmodule OptimalSystemAgent.Investigation.StrategyStoreTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Investigation.{Strategy, StrategyStore}

  @test_topic "test_strategy_store_#{:rand.uniform(100_000)}"

  setup do
    # Clean up any existing test strategy file
    on_exit(fn ->
      hash =
        :crypto.hash(:sha256, @test_topic)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      path = Path.join(StrategyStore.store_dir(), "#{hash}.json")
      File.rm(path)
    end)

    :ok
  end

  describe "save/1 and load_best/1" do
    test "round-trip save and load preserves all parameters" do
      strategy = %{
        Strategy.default()
        | topic: @test_topic,
          grounded_threshold: 0.55,
          review_weight: 4.0,
          direction_ratio: 1.5,
          generation: 3,
          created_at: "2024-01-15T10:30:00Z"
      }

      assert :ok = StrategyStore.save(strategy)
      assert {:ok, loaded} = StrategyStore.load_best(@test_topic)

      assert loaded.grounded_threshold == 0.55
      assert loaded.review_weight == 4.0
      assert loaded.direction_ratio == 1.5
      assert loaded.generation == 3
      assert loaded.topic == @test_topic
      assert loaded.created_at == "2024-01-15T10:30:00Z"
    end

    test "load_best returns :error for missing topic" do
      assert :error = StrategyStore.load_best("nonexistent_topic_#{:rand.uniform(100_000)}")
    end
  end

  describe "load_all/0" do
    test "returns a list (possibly empty)" do
      result = StrategyStore.load_all()
      assert is_list(result)
    end

    test "includes saved strategies" do
      strategy = %{Strategy.default() | topic: @test_topic, grounded_threshold: 0.33}
      StrategyStore.save(strategy)

      all = StrategyStore.load_all()
      assert Enum.any?(all, fn s -> s.grounded_threshold == 0.33 end)
    end
  end
end
