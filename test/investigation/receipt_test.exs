defmodule OptimalSystemAgent.Investigation.ReceiptTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Investigation.{Receipt, Strategy}

  describe "build/1" do
    test "computes improvement percentage" do
      receipt =
        Receipt.build(
          baseline_strategy: Strategy.default(),
          winning_strategy: %{Strategy.default() | grounded_threshold: 0.5},
          baseline_eig: 0.4,
          winning_eig: 0.6,
          iterations_run: 200,
          elapsed_ms: 1500,
          tree_size: 1600,
          best_path: [:tighten_grounding, :shift_hierarchy]
        )

      assert receipt.improvement_pct == 50.0
      assert receipt.baseline_eig == 0.4
      assert receipt.winning_eig == 0.6
      assert receipt.iterations_run == 200
      assert receipt.elapsed_ms == 1500
      assert receipt.tree_size == 1600
      assert receipt.best_path == [:tighten_grounding, :shift_hierarchy]
    end

    test "handles zero baseline EIG" do
      receipt =
        Receipt.build(
          baseline_eig: 0.0,
          winning_eig: 0.5
        )

      assert receipt.improvement_pct == 0.0
    end

    test "sets timestamp" do
      receipt = Receipt.build([])
      assert is_binary(receipt.timestamp)
      assert String.contains?(receipt.timestamp, "T")
    end

    test "computes parent and winning hashes" do
      baseline = Strategy.default()
      winning = %{Strategy.default() | grounded_threshold: 0.5}

      receipt =
        Receipt.build(
          baseline_strategy: baseline,
          winning_strategy: winning
        )

      assert receipt.parent_hash == Strategy.param_hash(baseline)
      assert receipt.winning_hash == Strategy.param_hash(winning)
      refute receipt.parent_hash == receipt.winning_hash
    end
  end

  describe "strategy_diff/2" do
    test "returns empty list for identical strategies" do
      s = Strategy.default()
      assert Receipt.strategy_diff(s, s) == []
    end

    test "returns changed parameters only" do
      baseline = Strategy.default()
      winning = %{baseline | grounded_threshold: 0.6, review_weight: 4.5}

      diff = Receipt.strategy_diff(baseline, winning)
      assert length(diff) == 2

      gt_diff = Enum.find(diff, fn d -> d.param == :grounded_threshold end)
      assert gt_diff.old == 0.4
      assert gt_diff.new == 0.6
      assert_in_delta gt_diff.delta, 0.2, 0.0001

      rw_diff = Enum.find(diff, fn d -> d.param == :review_weight end)
      assert rw_diff.old == 3.0
      assert rw_diff.new == 4.5
      assert_in_delta rw_diff.delta, 1.5, 0.0001
    end

    test "ignores metadata changes" do
      baseline = Strategy.default()
      winning = %{baseline | topic: "changed", generation: 5}

      diff = Receipt.strategy_diff(baseline, winning)
      # topic and generation are metadata, not in param_keys
      assert diff == []
    end
  end

  describe "to_map/1" do
    test "returns JSON-serializable map" do
      receipt =
        Receipt.build(
          baseline_strategy: Strategy.default(),
          winning_strategy: %{Strategy.default() | grounded_threshold: 0.5},
          baseline_eig: 0.3,
          winning_eig: 0.5,
          iterations_run: 150,
          elapsed_ms: 1200,
          tree_size: 800,
          best_path: [:tighten_grounding]
        )

      map = Receipt.to_map(receipt)

      assert is_map(map)
      assert map.baseline_eig == 0.3
      assert map.winning_eig == 0.5
      assert map.iterations_run == 150
      assert is_list(map.strategy_diff)
      assert is_list(map.best_path)
      assert Enum.all?(map.best_path, &is_binary/1)
      assert Enum.all?(map.strategy_diff, fn d -> is_binary(d.param) end)

      # Should be JSON-encodable
      assert {:ok, _json} = Jason.encode(map)
    end
  end
end
