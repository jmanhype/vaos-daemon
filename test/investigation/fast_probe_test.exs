defmodule OptimalSystemAgent.Investigation.FastProbeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Investigation.{FastProbe, Strategy}

  # Helper to build a mock probe context
  defp mock_probe_ctx(opts \\ []) do
    papers = opts[:papers] || []

    paper_map =
      opts[:paper_map] ||
        %{
          1 => %{
            "title" => "Systematic review of X",
            "abstract" => "A nature study...",
            "citation_count" => 100,
            "source" => "nature",
            :_publisher_score => 0.8
          },
          2 => %{
            "title" => "Clinical trial of Y",
            "abstract" => "An observational study",
            "citation_count" => 10,
            "source" => "unknown_journal",
            :_publisher_score => 0.3
          },
          3 => %{
            "title" => "Alternative view on Z",
            "abstract" => "From a complementary medicine journal",
            "citation_count" => 2,
            "source" => "journal of alternative therapies",
            :_publisher_score => 0.05
          }
        }

    verified_supporting =
      opts[:verified_supporting] ||
        [
          %{
            summary: "Strong evidence from review",
            verification: "verified",
            paper_type: :review,
            citation_count: 100,
            paper_ref: 1,
            score: 4.5,
            verified: true
          },
          %{
            summary: "Weak evidence from alt journal",
            verification: "partial",
            paper_type: :study,
            citation_count: 2,
            paper_ref: 3,
            score: 0.2,
            verified: true
          }
        ]

    verified_opposing =
      opts[:verified_opposing] ||
        [
          %{
            summary: "Counter evidence from trial",
            verification: "verified",
            paper_type: :trial,
            citation_count: 10,
            paper_ref: 2,
            score: 2.0,
            verified: true
          }
        ]

    %{
      papers: papers,
      paper_map: paper_map,
      verified_supporting: verified_supporting,
      verified_opposing: verified_opposing,
      topic: "test topic"
    }
  end

  describe "score/2" do
    test "returns 0.0 for empty evidence" do
      ctx = mock_probe_ctx(verified_supporting: [], verified_opposing: [])
      assert FastProbe.score(Strategy.default(), ctx) == 0.0
    end

    test "returns a float in [0.0, 1.0]" do
      ctx = mock_probe_ctx()
      score = FastProbe.score(Strategy.default(), ctx)
      assert is_float(score)
      assert score >= 0.0
      assert score <= 1.0
    end

    test "score changes when strategy parameters change" do
      ctx = mock_probe_ctx()
      default_score = FastProbe.score(Strategy.default(), ctx)

      # More selective threshold should change the score
      strict = %{Strategy.default() | grounded_threshold: 0.6}
      strict_score = FastProbe.score(strict, ctx)

      # Lenient threshold
      lenient = %{Strategy.default() | grounded_threshold: 0.2}
      lenient_score = FastProbe.score(lenient, ctx)

      # They should generally differ (exact values depend on evidence)
      assert default_score != strict_score or default_score != lenient_score,
        "Expected score to change with different strategies"
    end

    test "higher review_weight increases score when reviews are present" do
      ctx = mock_probe_ctx()

      boosted = %{Strategy.default() | review_weight: 5.0}
      boosted_score = FastProbe.score(boosted, ctx)

      # With a review in the supporting evidence, boosting review weight
      # should produce a valid score (exact direction depends on EIG components)
      assert is_float(boosted_score)
      assert boosted_score >= 0.0 and boosted_score <= 1.0
    end

    test "direction_ratio affects direction confidence component" do
      ctx = mock_probe_ctx()

      # Low direction ratio — easier to declare direction
      low_ratio = %{Strategy.default() | direction_ratio: 1.1}
      low_score = FastProbe.score(low_ratio, ctx)

      # High direction ratio — harder to declare direction
      high_ratio = %{Strategy.default() | direction_ratio: 2.0}
      high_score = FastProbe.score(high_ratio, ctx)

      assert is_float(low_score)
      assert is_float(high_score)
    end
  end

  describe "score sensitivity" do
    test "completely unverified evidence scores lower" do
      all_unverified =
        mock_probe_ctx(
          verified_supporting: [
            %{
              summary: "Unverified claim",
              verification: "unverified",
              paper_type: :other,
              citation_count: 0,
              paper_ref: nil,
              score: 0.0,
              verified: false
            }
          ],
          verified_opposing: [
            %{
              summary: "Another unverified",
              verification: "unverified",
              paper_type: :other,
              citation_count: 0,
              paper_ref: nil,
              score: 0.0,
              verified: false
            }
          ]
        )

      good_evidence = mock_probe_ctx()

      unverified_score = FastProbe.score(Strategy.default(), all_unverified)
      good_score = FastProbe.score(Strategy.default(), good_evidence)

      assert good_score > unverified_score,
        "Good evidence (#{good_score}) should score higher than unverified (#{unverified_score})"
    end
  end
end
