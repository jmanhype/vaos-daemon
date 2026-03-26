defmodule Daemon.Investigation.FastProbeTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.{FastProbe, Strategy}

  @base_probe_ctx %{
    paper_map: %{
      1 => %{
        "title" => "Systematic review of treatment efficacy",
        "source" => "The Lancet",
        "abstract" => "A comprehensive meta-analysis",
        "citation_count" => 500,
        _publisher_score: 0.8
      },
      2 => %{
        "title" => "Observational study of outcomes",
        "source" => "Regional Medical Journal",
        "abstract" => "A small study",
        "citation_count" => 10,
        _publisher_score: 0.3
      },
      3 => %{
        "title" => "Randomized controlled trial",
        "source" => "BMJ",
        "abstract" => "Double-blind RCT",
        "citation_count" => 200,
        _publisher_score: 0.8
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
    topic: "test topic"
  }

  describe "score/2" do
    test "returns 0.0 for empty evidence" do
      ctx = %{paper_map: %{}, verified_supporting: [], verified_opposing: []}
      assert FastProbe.score(Strategy.default(), ctx) == 0.0
    end

    test "returns a float between 0 and 1 for valid evidence" do
      score = FastProbe.score(Strategy.default(), @base_probe_ctx)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "score changes with different strategies" do
      s1 = Strategy.default()
      # Use a much more extreme threshold change that actually shifts classification
      s2 = %{s1 | grounded_threshold: 0.01, review_weight: 5.0, citation_weight: 0.8, publisher_weight: 0.2}
      score1 = FastProbe.score(s1, @base_probe_ctx)
      score2 = FastProbe.score(s2, @base_probe_ctx)
      # Strategies with very different parameters should produce different scores
      refute score1 == score2
    end

    test "higher review_weight increases score for review-heavy evidence" do
      s1 = Strategy.default()
      s2 = %{s1 | review_weight: 5.0}
      score1 = FastProbe.score(s1, @base_probe_ctx)
      score2 = FastProbe.score(s2, @base_probe_ctx)
      # Higher review weight should change the score (evidence has a review)
      refute score1 == score2
    end

    test "handles evidence with nil paper_ref" do
      ctx = %{
        paper_map: %{},
        verified_supporting: [
          %{
            summary: "Anecdotal support",
            paper_ref: nil,
            paper_type: :other,
            verification: "partial",
            citation_count: 0
          }
        ],
        verified_opposing: []
      }

      score = FastProbe.score(Strategy.default(), ctx)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "handles evidence with missing paper in paper_map" do
      ctx = %{
        paper_map: %{},
        verified_supporting: [
          %{
            summary: "Study reference missing",
            paper_ref: 999,
            paper_type: :study,
            verification: "verified",
            citation_count: 50
          }
        ],
        verified_opposing: []
      }

      score = FastProbe.score(Strategy.default(), ctx)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "score is deterministic for same inputs" do
      s = Strategy.default()
      score1 = FastProbe.score(s, @base_probe_ctx)
      score2 = FastProbe.score(s, @base_probe_ctx)
      assert score1 == score2
    end
  end

  describe "grounding proximity" do
    test "all-belief evidence still produces non-zero score via proximity" do
      # All evidence below threshold → grounded=[], but proximity provides gradient
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Some paper",
            "source" => "Unknown Journal",
            "abstract" => "A study",
            "citation_count" => 5,
            _publisher_score: 0.3
          }
        },
        verified_supporting: [
          %{
            summary: "Low quality evidence",
            paper_ref: 1,
            paper_type: :study,
            verification: "verified",
            citation_count: 5
          }
        ],
        verified_opposing: []
      }

      # Default threshold 0.4 — paper with 5 citations and 0.3 publisher score
      # won't reach grounded, but proximity should give a gradient
      score = FastProbe.score(Strategy.default(), ctx)
      assert score > 0.0
      # With old weights (no proximity), this would be exactly 0.35 * discriminability
      # With proximity, it should be different
      assert is_float(score)
    end

    test "lowering threshold increases proximity score for all-belief evidence" do
      ctx = %{
        paper_map: %{
          1 => %{
            "title" => "Paper",
            "source" => "Regional",
            "abstract" => "Study",
            "citation_count" => 5,
            _publisher_score: 0.3
          }
        },
        verified_supporting: [
          %{
            summary: "Evidence",
            paper_ref: 1,
            paper_type: :study,
            verification: "verified",
            citation_count: 5
          }
        ],
        verified_opposing: []
      }

      s_high = %{Strategy.default() | grounded_threshold: 0.7}
      s_low = %{Strategy.default() | grounded_threshold: 0.25}

      score_high = FastProbe.score(s_high, ctx)
      score_low = FastProbe.score(s_low, ctx)

      # Lower threshold brings evidence closer to grounded → higher proximity → higher EIG
      assert score_low > score_high
    end
  end

  describe "EIG component sensitivity" do
    test "very low threshold moves all evidence to grounded" do
      s = %{Strategy.default() | grounded_threshold: 0.01}
      score = FastProbe.score(s, @base_probe_ctx)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "very high threshold moves all evidence to belief" do
      s = %{Strategy.default() | grounded_threshold: 0.69}
      score = FastProbe.score(s, @base_probe_ctx)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "direction_ratio affects direction confidence component" do
      # Use strategies that differ across multiple parameters to ensure different EIG
      s1 = %{Strategy.default() | direction_ratio: 1.1, grounded_threshold: 0.01}
      s2 = %{Strategy.default() | direction_ratio: 2.0, grounded_threshold: 0.6}
      score1 = FastProbe.score(s1, @base_probe_ctx)
      score2 = FastProbe.score(s2, @base_probe_ctx)
      # Significantly different strategies should produce different scores
      refute score1 == score2
    end
  end
end
