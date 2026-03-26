defmodule Daemon.Investigation.SourceScoringTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.{SourceScoring, Strategy}

  describe "score/2" do
    test "high-quality publisher with citations scores above threshold" do
      paper = %{
        "title" => "Systematic review of treatment efficacy",
        "source" => "The Lancet",
        "abstract" => "A comprehensive meta-analysis",
        "citation_count" => 500,
        "publicationTypes" => []
      }

      score = SourceScoring.score(paper, Strategy.default())
      assert score >= 0.4
    end

    test "low-quality journal scores below threshold" do
      paper = %{
        "title" => "Alternative treatment study",
        "source" => "Journal of Alternative Medicine",
        "abstract" => "A study on healing",
        "citation_count" => 5,
        "publicationTypes" => []
      }

      score = SourceScoring.score(paper, Strategy.default())
      assert score < 0.4
    end

    test "low-quality journal blocks review-type boost" do
      paper = %{
        "title" => "Systematic review of homeopathic treatments",
        "source" => "Journal of Homeopathy Research",
        "abstract" => "A comprehensive meta-analysis",
        "citation_count" => 20,
        "publicationTypes" => ["Review"]
      }

      score = SourceScoring.score(paper, Strategy.default())
      # Should NOT get the 0.8 review boost because source is low-quality
      assert score < 0.2
    end

    test "unknown publisher with zero citations gets default score" do
      paper = %{
        "title" => "Some paper",
        "source" => "Unknown Regional Gazette",
        "abstract" => "A paper",
        "citation_count" => 0,
        "publicationTypes" => []
      }

      score = SourceScoring.score(paper, Strategy.default())
      # 0.0 * citation_weight + 0.3 * publisher_weight = 0.15
      assert_in_delta score, 0.15, 0.01
    end

    test "handles nil fields gracefully" do
      paper = %{}
      score = SourceScoring.score(paper, Strategy.default())
      assert is_float(score)
    end
  end

  describe "publisher_score/1" do
    test "prestigious publisher returns 0.8" do
      paper = %{"title" => "Study", "source" => "Nature", "abstract" => "Important"}
      assert SourceScoring.publisher_score(paper) == 0.8
    end

    test "alternative medicine journal returns 0.05" do
      paper = %{"title" => "Study", "source" => "Journal of Alternative Medicine", "abstract" => ""}
      assert SourceScoring.publisher_score(paper) == 0.05
    end

    test "unknown publisher returns 0.3" do
      paper = %{"title" => "Study", "source" => "Unknown Press", "abstract" => ""}
      assert SourceScoring.publisher_score(paper) == 0.3
    end

    test "systematic review in non-low-quality source returns 0.8" do
      paper = %{
        "title" => "Systematic review of outcomes",
        "source" => "Medical Publishing Co",
        "abstract" => "",
        "publicationTypes" => ["Review"]
      }

      assert SourceScoring.publisher_score(paper) == 0.8
    end

    test "nature negative lookahead: 'nature of' does not match" do
      paper = %{
        "title" => "The nature of consciousness",
        "source" => "Philosophy Press",
        "abstract" => ""
      }

      # "nature of" should NOT trigger the Nature journal pattern
      assert SourceScoring.publisher_score(paper) == 0.3
    end
  end

  describe "is_review_or_meta_analysis?/2" do
    test "detects systematic review in title" do
      assert SourceScoring.is_review_or_meta_analysis?("a systematic review of treatments", [])
    end

    test "detects meta-analysis in title" do
      assert SourceScoring.is_review_or_meta_analysis?("meta-analysis of drug efficacy", [])
    end

    test "detects review in publicationTypes" do
      assert SourceScoring.is_review_or_meta_analysis?("some title", ["Review"])
    end

    test "returns false for regular paper" do
      refute SourceScoring.is_review_or_meta_analysis?("a regular study", ["JournalArticle"])
    end
  end
end
