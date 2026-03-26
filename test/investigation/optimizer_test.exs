defmodule OptimalSystemAgent.Investigation.OptimizerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Investigation.{Optimizer, Strategy, Receipt}

  # Build a probe context with known evidence that allows MCTS to find improvements
  defp mock_probe_ctx do
    paper_map = %{
      1 => %{
        "title" => "Systematic review of efficacy",
        "abstract" => "A comprehensive nature review...",
        "citation_count" => 500,
        "source" => "nature",
        :_publisher_score => 0.8
      },
      2 => %{
        "title" => "Randomized controlled trial results",
        "abstract" => "An RCT published in lancet...",
        "citation_count" => 200,
        "source" => "lancet",
        :_publisher_score => 0.8
      },
      3 => %{
        "title" => "Observational study findings",
        "abstract" => "Study in bmj...",
        "citation_count" => 50,
        "source" => "bmj",
        :_publisher_score => 0.8
      },
      4 => %{
        "title" => "Niche journal opinion",
        "abstract" => "From alternative medicine...",
        "citation_count" => 3,
        "source" => "journal of alternative therapies",
        :_publisher_score => 0.05
      }
    }

    %{
      papers: [],
      paper_map: paper_map,
      verified_supporting: [
        %{
          summary: "Strong review evidence",
          verification: "verified",
          paper_type: :review,
          citation_count: 500,
          paper_ref: 1,
          score: 8.1,
          verified: true
        },
        %{
          summary: "Trial supports claim",
          verification: "verified",
          paper_type: :trial,
          citation_count: 200,
          paper_ref: 2,
          score: 4.6,
          verified: true
        },
        %{
          summary: "Niche support",
          verification: "partial",
          paper_type: :other,
          citation_count: 3,
          paper_ref: 4,
          score: 0.24,
          verified: true
        }
      ],
      verified_opposing: [
        %{
          summary: "Observational counter-evidence",
          verification: "verified",
          paper_type: :study,
          citation_count: 50,
          paper_ref: 3,
          score: 2.5,
          verified: true
        }
      ],
      topic: "test_optimizer_topic_#{:rand.uniform(100_000)}"
    }
  end

  describe "optimize/1" do
    test "returns a {strategy, receipt} tuple" do
      ctx = mock_probe_ctx()
      {strategy, receipt} = Optimizer.optimize(ctx)

      assert %Strategy{} = strategy
      assert %Receipt{} = receipt
    end

    test "returned strategy has valid parameter values" do
      ctx = mock_probe_ctx()
      {strategy, _receipt} = Optimizer.optimize(ctx)

      bounds = Strategy.bounds()

      for key <- Strategy.param_keys() do
        {min, max} = bounds[key]
        val = Map.get(strategy, key)

        assert val >= min and val <= max,
          "#{key}=#{val} outside bounds [#{min}, #{max}]"
      end
    end

    test "receipt contains valid metadata" do
      ctx = mock_probe_ctx()
      {_strategy, receipt} = Optimizer.optimize(ctx)

      assert receipt.iterations_run > 0
      assert receipt.elapsed_ms >= 0
      assert receipt.tree_size > 0
      assert is_float(receipt.baseline_eig)
      assert is_float(receipt.winning_eig)
      assert receipt.winning_eig >= receipt.baseline_eig
      assert is_binary(receipt.parent_hash)
      assert is_binary(receipt.winning_hash)
    end

    test "winning EIG is at least baseline EIG" do
      ctx = mock_probe_ctx()
      {_strategy, receipt} = Optimizer.optimize(ctx)

      assert receipt.winning_eig >= receipt.baseline_eig,
        "Winning EIG (#{receipt.winning_eig}) should be >= baseline (#{receipt.baseline_eig})"
    end
  end

  describe "enrich_probe_ctx/1" do
    test "adds _publisher_score to papers missing it" do
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Test paper",
            "abstract" => "Abstract",
            "source" => "nature",
            "citation_count" => 100
          }
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
            "abstract" => "",
            "source" => "",
            "citation_count" => 0,
            :_publisher_score => 0.99
          }
        }
      }

      enriched = Optimizer.enrich_probe_ctx(ctx)
      assert enriched[:paper_map][1][:_publisher_score] == 0.99
    end
  end
end
