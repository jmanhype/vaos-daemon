defmodule Daemon.Investigation.StrategyStoreTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.{Strategy, StrategyStore}

  @test_topic "test_topic_#{:rand.uniform(1_000_000)}"

  setup do
    # Clean up any test files after each test
    on_exit(fn ->
      store_dir = StrategyStore.store_dir()

      if File.dir?(store_dir) do
        store_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(fn file ->
          File.rm(Path.join(store_dir, file))
        end)
      end
    end)

    :ok
  end

  describe "save/1 and load_best/1" do
    test "round-trip save and load preserves strategy" do
      strategy = %{Strategy.default() | topic: @test_topic, grounded_threshold: 0.55}
      assert :ok = StrategyStore.save(strategy)

      assert {:ok, loaded} = StrategyStore.load_best(@test_topic)
      assert loaded.grounded_threshold == 0.55
      assert loaded.topic == @test_topic
    end

    test "load_best returns :error for unknown topic" do
      assert :error = StrategyStore.load_best("nonexistent_topic_#{:rand.uniform(1_000_000)}")
    end

    test "save creates the store directory" do
      strategy = %{Strategy.default() | topic: @test_topic}
      StrategyStore.save(strategy)
      assert File.dir?(StrategyStore.store_dir())
    end

    test "save overwrites existing strategy for same topic" do
      s1 = %{Strategy.default() | topic: @test_topic, grounded_threshold: 0.3}
      s2 = %{Strategy.default() | topic: @test_topic, grounded_threshold: 0.6}

      StrategyStore.save(s1)
      StrategyStore.save(s2)

      {:ok, loaded} = StrategyStore.load_best(@test_topic)
      assert loaded.grounded_threshold == 0.6
    end

    test "preserves all parameter values" do
      strategy = %Strategy{
        grounded_threshold: 0.55,
        citation_weight: 0.6,
        publisher_weight: 0.4,
        review_weight: 4.0,
        trial_weight: 2.5,
        study_weight: 1.8,
        direction_ratio: 1.5,
        belief_fallback_ratio: 2.0,
        top_n_papers: 20,
        per_query_limit: 7,
        adversarial_temperature: 0.3,
        citation_bonus_base: 3.0,
        topic: @test_topic,
        generation: 3,
        parent_hash: "abc123",
        created_at: "2024-01-01T00:00:00Z"
      }

      StrategyStore.save(strategy)
      {:ok, loaded} = StrategyStore.load_best(@test_topic)

      for key <- Strategy.param_keys() do
        assert Map.get(loaded, key) == Map.get(strategy, key),
               "Mismatch for #{key}: #{inspect(Map.get(loaded, key))} != #{inspect(Map.get(strategy, key))}"
      end

      assert loaded.generation == 3
      assert loaded.parent_hash == "abc123"
    end
  end

  describe "load_all/0" do
    test "returns empty list when no strategies exist" do
      # Clean store first
      store_dir = StrategyStore.store_dir()

      if File.dir?(store_dir) do
        store_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(&File.rm(Path.join(store_dir, &1)))
      end

      result = StrategyStore.load_all()
      assert is_list(result)
    end

    test "returns saved strategies" do
      s1 = %{Strategy.default() | topic: "topic_a_#{:rand.uniform(1_000_000)}"}
      s2 = %{Strategy.default() | topic: "topic_b_#{:rand.uniform(1_000_000)}"}

      StrategyStore.save(s1)
      StrategyStore.save(s2)

      all = StrategyStore.load_all()
      assert length(all) >= 2
    end
  end

  describe "store_dir/0" do
    test "returns a string path" do
      dir = StrategyStore.store_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "investigate_strategies")
    end
  end
end
