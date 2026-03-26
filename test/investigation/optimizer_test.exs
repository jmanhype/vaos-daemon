defmodule Daemon.Investigation.OptimizerTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.{Optimizer, Strategy, Receipt, StrategyStore}

  @probe_ctx %{
    paper_map: %{
      1 => %{
        "title" => "Systematic review of treatment efficacy",
        "source" => "The Lancet",
        "abstract" => "A comprehensive meta-analysis",
        "citation_count" => 500
      },
      2 => %{
        "title" => "Observational study of outcomes",
        "source" => "Regional Medical Journal",
        "abstract" => "A small study",
        "citation_count" => 10
      },
      3 => %{
        "title" => "Randomized controlled trial",
        "source" => "BMJ",
        "abstract" => "Double-blind RCT",
        "citation_count" => 200
      }
    },
    verified_supporting: [
      %{
        summary: "Treatment shows efficacy",
        paper_ref: 1,
        paper_type: :review,
        verification: "verified",
        citation_count: 500
      },
      %{
        summary: "Trial confirms benefit",
        paper_ref: 3,
        paper_type: :trial,
        verification: "verified",
        citation_count: 200
      }
    ],
    verified_opposing: [
      %{
        summary: "Study shows no effect",
        paper_ref: 2,
        paper_type: :study,
        verification: "partial",
        citation_count: 10
      }
    ],
    topic: "optimizer_test_#{:rand.uniform(1_000_000)}"
  }

  setup do
    # Clean up strategy store after tests
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

  describe "optimize/1" do
    test "returns a {strategy, receipt} tuple" do
      {strategy, receipt} = Optimizer.optimize(@probe_ctx)
      assert %Strategy{} = strategy
      assert %Receipt{} = receipt
    end

    test "receipt has valid metadata" do
      {_strategy, receipt} = Optimizer.optimize(@probe_ctx)
      assert receipt.iterations_run > 0
      assert receipt.elapsed_ms > 0
      assert receipt.tree_size > 0
      assert is_binary(receipt.parent_hash)
      assert is_binary(receipt.winning_hash)
    end

    test "winning EIG is >= baseline EIG" do
      {_strategy, receipt} = Optimizer.optimize(@probe_ctx)
      assert receipt.winning_eig >= receipt.baseline_eig
    end

    test "returned strategy has valid parameter values within bounds" do
      {strategy, _receipt} = Optimizer.optimize(@probe_ctx)
      bounds = Strategy.bounds()

      for key <- Strategy.param_keys() do
        {min, max} = bounds[key]
        val = Map.get(strategy, key)

        assert val >= min and val <= max,
               "#{key}=#{val} outside bounds [#{min}, #{max}]"
      end
    end

    test "handles empty evidence gracefully" do
      empty_ctx = %{
        paper_map: %{},
        verified_supporting: [],
        verified_opposing: [],
        topic: "empty_test_#{:rand.uniform(1_000_000)}"
      }

      {strategy, receipt} = Optimizer.optimize(empty_ctx)
      assert %Strategy{} = strategy
      assert %Receipt{} = receipt
    end

    test "completes within timeout" do
      start = System.monotonic_time(:millisecond)
      {_strategy, _receipt} = Optimizer.optimize(@probe_ctx)
      elapsed = System.monotonic_time(:millisecond) - start
      # Should complete within 10s (timeout is 5s + overhead)
      assert elapsed < 10_000
    end
  end

  describe "threshold_presweep/2" do
    test "returns a strategy with optimal threshold" do
      enriched = Optimizer.enrich_probe_ctx(@probe_ctx)
      {strategy, eig} = Optimizer.threshold_presweep(Strategy.default(), enriched)
      assert %Strategy{} = strategy
      assert is_float(eig)
      assert eig >= 0.0
    end

    test "swept EIG >= default EIG" do
      enriched = Optimizer.enrich_probe_ctx(@probe_ctx)
      default_eig = Daemon.Investigation.FastProbe.score(Strategy.default(), enriched)
      {_strategy, swept_eig} = Optimizer.threshold_presweep(Strategy.default(), enriched)
      assert swept_eig >= default_eig
    end

    test "threshold stays within bounds" do
      enriched = Optimizer.enrich_probe_ctx(@probe_ctx)
      {strategy, _eig} = Optimizer.threshold_presweep(Strategy.default(), enriched)
      {min_t, max_t} = Strategy.bounds().grounded_threshold
      assert strategy.grounded_threshold >= min_t
      assert strategy.grounded_threshold <= max_t
    end

    test "preserves non-threshold parameters" do
      enriched = Optimizer.enrich_probe_ctx(@probe_ctx)
      base = Strategy.default()
      {strategy, _eig} = Optimizer.threshold_presweep(base, enriched)
      # All params except grounded_threshold should be unchanged
      assert strategy.citation_weight == base.citation_weight
      assert strategy.publisher_weight == base.publisher_weight
      assert strategy.review_weight == base.review_weight
      assert strategy.adversarial_temperature == base.adversarial_temperature
    end
  end

  describe "enrich_probe_ctx/1" do
    test "adds _publisher_score to papers without one" do
      ctx = %{
        paper_map: %{
          1 => %{"title" => "Nature study", "source" => "Nature", "abstract" => "Important"}
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      paper = enriched[:paper_map][1]
      assert Map.has_key?(paper, :_publisher_score)
      assert is_float(paper[:_publisher_score]) or is_integer(paper[:_publisher_score])
    end

    test "preserves existing _publisher_score" do
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Test",
            "source" => "Test",
            "abstract" => "Test",
            _publisher_score: 0.99
          }
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map][1][:_publisher_score] == 0.99
    end

    test "handles empty paper_map" do
      ctx = %{paper_map: %{}}
      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map] == %{}
    end

    test "handles missing paper_map" do
      ctx = %{}
      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map] == %{}
    end

    test "assigns high score to prestigious publishers" do
      ctx = %{
        paper_map: %{
          1 => %{"title" => "Study", "source" => "The Lancet", "abstract" => "Important study"}
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map][1][:_publisher_score] == 0.8
    end

    test "assigns low score to alternative medicine journals" do
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Study",
            "source" => "Journal of Alternative Medicine",
            "abstract" => "Study"
          }
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map][1][:_publisher_score] == 0.05
    end

    test "assigns default score to unknown publishers" do
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Some paper",
            "source" => "Unknown Regional Gazette",
            "abstract" => "A paper"
          }
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map][1][:_publisher_score] == 0.3
    end
  end
end
