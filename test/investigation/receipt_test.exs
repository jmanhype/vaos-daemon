defmodule Daemon.Investigation.ReceiptTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.{Receipt, Strategy}

  describe "build/1" do
    test "builds receipt with correct EIG values" do
      receipt =
        Receipt.build(
          baseline_eig: 0.4,
          winning_eig: 0.6,
          iterations_run: 100,
          elapsed_ms: 1500,
          tree_size: 50,
          best_path: [:tighten_grounding, :widen_search]
        )

      assert receipt.baseline_eig == 0.4
      assert receipt.winning_eig == 0.6
      assert receipt.iterations_run == 100
      assert receipt.elapsed_ms == 1500
      assert receipt.tree_size == 50
      assert receipt.best_path == [:tighten_grounding, :widen_search]
    end

    test "computes improvement percentage" do
      receipt = Receipt.build(baseline_eig: 0.4, winning_eig: 0.6)
      assert receipt.improvement_pct == 50.0
    end

    test "handles zero baseline EIG" do
      receipt = Receipt.build(baseline_eig: 0.0, winning_eig: 0.5)
      assert receipt.improvement_pct == 0.0
    end

    test "computes strategy diff" do
      baseline = Strategy.default()
      winning = %{baseline | grounded_threshold: 0.55, review_weight: 4.0}

      receipt =
        Receipt.build(
          baseline_strategy: baseline,
          winning_strategy: winning,
          baseline_eig: 0.4,
          winning_eig: 0.5
        )

      assert length(receipt.strategy_diff) == 2

      gt_diff = Enum.find(receipt.strategy_diff, &(&1.param == :grounded_threshold))
      assert gt_diff.old == 0.4
      assert gt_diff.new == 0.55
      assert_in_delta gt_diff.delta, 0.15, 0.001

      rw_diff = Enum.find(receipt.strategy_diff, &(&1.param == :review_weight))
      assert rw_diff.old == 3.0
      assert rw_diff.new == 4.0
      assert_in_delta rw_diff.delta, 1.0, 0.001
    end

    test "empty diff when strategies are identical" do
      s = Strategy.default()

      receipt =
        Receipt.build(
          baseline_strategy: s,
          winning_strategy: s,
          baseline_eig: 0.5,
          winning_eig: 0.5
        )

      assert receipt.strategy_diff == []
    end

    test "includes strategy hashes" do
      baseline = Strategy.default()
      winning = %{baseline | grounded_threshold: 0.55}

      receipt =
        Receipt.build(
          baseline_strategy: baseline,
          winning_strategy: winning
        )

      assert is_binary(receipt.parent_hash)
      assert is_binary(receipt.winning_hash)
      assert String.length(receipt.parent_hash) == 64
      assert String.length(receipt.winning_hash) == 64
      refute receipt.parent_hash == receipt.winning_hash
    end

    test "includes timestamp" do
      receipt = Receipt.build([])
      assert is_binary(receipt.timestamp)
      assert String.length(receipt.timestamp) > 0
    end
  end

  describe "strategy_diff/2" do
    test "returns list of changed params with deltas" do
      s1 = Strategy.default()
      s2 = %{s1 | grounded_threshold: 0.6, top_n_papers: 20}
      diff = Receipt.strategy_diff(s1, s2)

      assert length(diff) == 2
      params = Enum.map(diff, & &1.param)
      assert :grounded_threshold in params
      assert :top_n_papers in params
    end

    test "delta is computed for numeric changes" do
      s1 = Strategy.default()
      s2 = %{s1 | citation_weight: 0.7}
      [entry] = Receipt.strategy_diff(s1, s2)

      assert entry.param == :citation_weight
      assert entry.old == 0.5
      assert entry.new == 0.7
      assert_in_delta entry.delta, 0.2, 0.001
    end

    test "returns empty list for identical strategies" do
      s = Strategy.default()
      assert Receipt.strategy_diff(s, s) == []
    end
  end

  describe "to_map/1" do
    test "converts receipt to JSON-serializable map" do
      receipt =
        Receipt.build(
          baseline_eig: 0.4,
          winning_eig: 0.6,
          iterations_run: 100,
          elapsed_ms: 1500,
          tree_size: 50,
          best_path: [:tighten_grounding]
        )

      map = Receipt.to_map(receipt)

      assert is_map(map)
      assert map.baseline_eig == 0.4
      assert map.winning_eig == 0.6
      assert map.iterations_run == 100
      assert map.elapsed_ms == 1500
      assert map.tree_size == 50
      assert map.best_path == ["tighten_grounding"]
      assert is_binary(map.parent_hash)
      assert is_binary(map.winning_hash)
      assert is_binary(map.timestamp)
    end

    test "strategy_diff params are stringified" do
      baseline = Strategy.default()
      winning = %{baseline | grounded_threshold: 0.55}

      receipt =
        Receipt.build(
          baseline_strategy: baseline,
          winning_strategy: winning
        )

      map = Receipt.to_map(receipt)
      [diff_entry] = map.strategy_diff
      assert diff_entry.param == "grounded_threshold"
    end
  end
end
