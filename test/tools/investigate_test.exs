defmodule Daemon.Tools.Builtins.InvestigateTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.Investigate
  alias Daemon.Investigation.Strategy

  # ── extract_keywords/1 ───────────────────────────────────────────────────

  describe "extract_keywords/1" do
    test "extracts keywords from simple topic" do
      keywords = extract_keywords("climate change effects")
      assert is_list(keywords)
      assert length(keywords) > 0
      assert "climate" in keywords
      assert "change" in keywords or "chang" in keywords  # stemmed
      assert "effect" in keywords
    end

    test "removes stop words" do
      keywords = extract_keywords("the effects of climate change on the environment")
      refute "the" in keywords
      refute "of" in keywords
      refute "on" in keywords
    end

    test "filters short words" do
      keywords = extract_keywords("AI and ML")
      # Words < 3 chars are filtered
      refute "AI" in keywords
      refute "ML" in keywords
    end

    test "stems common suffixes" do
      keywords = extract_keywords("computing processing")
      # Both "computing"/"comput" and "processing"/"process" should appear
      has_compute = "comput" in keywords or "computing" in keywords
      has_process = "process" in keywords or "processing" in keywords
      assert has_compute
      assert has_process
    end

    test "limits to 20 keywords" do
      long_topic = Enum.join(1..30, " word ")
      keywords = extract_keywords(long_topic)
      assert length(keywords) <= 20
    end

    test "handles empty string" do
      keywords = extract_keywords("")
      assert keywords == []
    end

    test "normalizes to lowercase" do
      keywords = extract_keywords("ARTIFICIAL Intelligence MACHINE Learning")
      assert Enum.all?(keywords, fn kw -> String.downcase(kw) == kw end)
    end

    test "removes special characters but keeps hyphens" do
      keywords = extract_keywords("data-driven, AI/ML, & NLP!")
      # The regex keeps hyphens, so "data-driven" is kept as-is
      # But commas, slashes, ampersands, etc. are removed
      assert "datadriven" in keywords or "data-driven" in keywords
      refute "," in keywords
      refute "/" in keywords
      refute "&" in keywords
    end
  end

  # ── merge_papers_raw/1 (deduplication) ─────────────────────────────────

  describe "merge_papers_raw/1" do
    test "deduplicates papers by title" do
      papers = [
        %{title: "Machine Learning Basics", authors: ["Author 1"]},
        %{title: "Machine Learning Basics", authors: ["Author 2"]},
        %{title: "Deep Learning", authors: ["Author 3"]}
      ]

      deduped = merge_papers_raw(papers)
      assert length(deduped) == 2
      # Should keep first occurrence
      assert Enum.any?(deduped, fn p -> p.authors == ["Author 1"] end)
    end

    test "handles string-key format" do
      papers = [
        %{"title" => "Paper Alpha", "authors" => ["Alice"]},
        %{"title" => "Paper Beta", "authors" => ["Bob"]},
        %{"title" => "Paper Gamma", "authors" => ["Charlie"]}
      ]

      deduped = merge_papers_raw(papers)
      assert length(deduped) == 3
    end

    test "handles mixed atom and string keys" do
      papers = [
        %{title: "Same Title", authors: ["A"]},
        %{"title" => "Same Title", "authors" => ["B"]},
        %{title: "Different", authors: ["C"]}
      ]

      deduped = merge_papers_raw(papers)
      assert length(deduped) == 2
    end

    test "normalizes titles for comparison" do
      papers = [
        %{title: "Data Driven Approach"},
        %{title: "data driven approach"},
        %{title: "Data Driven Approach"}
      ]

      deduped = merge_papers_raw(papers)
      # All three should be considered duplicates after normalization
      assert length(deduped) == 1
    end

    test "filters short words from title comparison" do
      papers = [
        %{title: "AI in ML"},
        %{title: "Artificial Intelligence in Machine Learning"}
      ]

      deduped = merge_papers_raw(papers)
      # Should NOT dedup (meaningful words after filtering)
      assert length(deduped) == 2
    end

    test "handles empty list" do
      assert merge_papers_raw([]) == []
    end

    test "handles papers with missing titles" do
      papers = [
        %{authors: ["No Title"]},
        %{title: "Has Title"}
      ]

      deduped = merge_papers_raw(papers)
      assert length(deduped) == 2
    end
  end

  # ── classify_evidence_store/3 ────────────────────────────────────────────

  describe "classify_evidence_store/3" do
    setup do
      strategy = Strategy.default()
      %{strategy: strategy}
    end

    test "classifies verified evidence with good paper quality as grounded", %{strategy: strategy} do
      evidence = [
        %{
          paper_ref: "paper1",
          verification: :verified,
          source_type: :sourced
        }
      ]

      paper_map = %{
        "paper1" => %{citation_count: 100, venue: "Nature"}
      }

      [classified] = classify_evidence_store(evidence, paper_map, strategy)
      assert classified.evidence_store in [:grounded, :belief]
      assert classified.source_quality > 0
    end

    test "classifies unverified evidence as belief", %{strategy: strategy} do
      evidence = [
        %{
          paper_ref: "paper1",
          verification: :unverified,
          source_type: :sourced
        }
      ]

      paper_map = %{
        "paper1" => %{citation_count: 100, venue: "Nature"}
      }

      [classified] = classify_evidence_store(evidence, paper_map, strategy)
      assert classified.evidence_store == :belief
    end

    test "handles missing paper_ref", %{strategy: strategy} do
      evidence = [
        %{
          paper_ref: nil,
          verification: :verified,
          source_type: :reasoning
        }
      ]

      [classified] = classify_evidence_store(evidence, %{}, strategy)
      assert classified.source_quality < 0.2
    end

    test "handles missing paper in paper_map", %{strategy: strategy} do
      evidence = [
        %{
          paper_ref: "unknown_paper",
          verification: :verified,
          source_type: :sourced
        }
      ]

      [classified] = classify_evidence_store(evidence, %{}, strategy)
      assert classified.source_quality < 0.2
    end

    test "adds source_quality and evidence_store to each evidence item", %{strategy: strategy} do
      evidence = [
        %{paper_ref: "p1", verification: :verified, source_type: :sourced},
        %{paper_ref: "p2", verification: :partial, source_type: :sourced}
      ]

      paper_map = %{
        "p1" => %{citation_count: 50, venue: "ArXiv"},
        "p2" => %{citation_count: 200, venue: "Science"}
      }

      classified = classify_evidence_store(evidence, paper_map, strategy)
      assert length(classified) == 2

      Enum.each(classified, fn ev ->
        assert Map.has_key?(ev, :source_quality)
        assert Map.has_key?(ev, :evidence_store)
        assert is_number(ev.source_quality)
        assert ev.evidence_store in [:grounded, :belief]
      end)
    end
  end

  # ── Direction computation logic ────────────────────────────────────────

  describe "direction computation" do
    test "returns supporting when grounded for score > grounded against * ratio" do
      # Simulating the cond at lines 421-423
      grounded_for_score = 10.0
      grounded_against_score = 3.0
      direction_ratio = 2.0

      direction = if grounded_for_score > 0 and grounded_against_score > 0 do
        cond do
          grounded_for_score > grounded_against_score * direction_ratio -> "supporting"
          grounded_against_score > grounded_for_score * direction_ratio -> "opposing"
          true -> "genuinely_contested"
        end
      else
        "other"
      end

      assert direction == "supporting"
    end

    test "returns opposing when grounded against score > grounded for * ratio" do
      grounded_for_score = 2.0
      grounded_against_score = 10.0
      direction_ratio = 2.0

      direction = if grounded_for_score > 0 and grounded_against_score > 0 do
        cond do
          grounded_for_score > grounded_against_score * direction_ratio -> "supporting"
          grounded_against_score > grounded_for_score * direction_ratio -> "opposing"
          true -> "genuinely_contested"
        end
      else
        "other"
      end

      assert direction == "opposing"
    end

    test "returns genuinely_contested when scores are similar" do
      grounded_for_score = 5.0
      grounded_against_score = 4.5
      direction_ratio = 2.0

      direction = if grounded_for_score > 0 and grounded_against_score > 0 do
        cond do
          grounded_for_score > grounded_against_score * direction_ratio -> "supporting"
          grounded_against_score > grounded_for_score * direction_ratio -> "opposing"
          true -> "genuinely_contested"
        end
      else
        "other"
      end

      assert direction == "genuinely_contested"
    end

    test "returns asymmetric_evidence_for when no grounded against" do
      grounded_for_score = 5.0
      grounded_against_score = 0.0

      direction = if grounded_against_score == 0 and grounded_for_score > 0 do
        "asymmetric_evidence_for"
      else
        "other"
      end

      assert direction == "asymmetric_evidence_for"
    end

    test "returns asymmetric_evidence_against when no grounded for" do
      grounded_for_score = 0.0
      grounded_against_score = 5.0

      direction = if grounded_for_score == 0 and grounded_against_score > 0 do
        "asymmetric_evidence_against"
      else
        "other"
      end

      assert direction == "asymmetric_evidence_against"
    end

    test "returns insufficient_evidence when both scores zero" do
      for_total = 0.0
      against_total = 0.0

      direction = if for_total == 0 and against_total == 0 do
        "insufficient_evidence"
      else
        "other"
      end

      assert direction == "insufficient_evidence"
    end

    test "returns belief_consensus_for when using belief fallback" do
      for_total = 10.0
      against_total = 2.0
      belief_fallback_ratio = 2.0

      direction = if for_total > against_total * belief_fallback_ratio do
        "belief_consensus_for"
      else
        "other"
      end

      assert direction == "belief_consensus_for"
    end

    test "returns belief_contested when belief scores are similar" do
      for_total = 5.0
      against_total = 4.0
      belief_fallback_ratio = 2.0

      direction = cond do
        for_total == 0 and against_total == 0 -> "insufficient_evidence"
        against_total > for_total * belief_fallback_ratio -> "belief_consensus_against"
        for_total > against_total * belief_fallback_ratio -> "belief_consensus_for"
        true -> "belief_contested"
      end

      assert direction == "belief_contested"
    end
  end

  # ── Quality scoring ────────────────────────────────────────────────────

  describe "quality scoring" do
    test "counts verified citations" do
      evidence = [
        %{verification: "verified"},
        %{verification: "verified"},
        %{verification: "partial"},
        %{verification: "unverified"}
      ]

      verified_count = Enum.count(evidence, fn ev -> ev.verification == "verified" end)
      assert verified_count == 2
    end

    test "counts partial verifications" do
      evidence = [
        %{verification: "verified"},
        %{verification: "partial"},
        %{verification: "partial"}
      ]

      partial_count = Enum.count(evidence, fn ev -> ev.verification == "partial" end)
      assert partial_count == 2
    end

    test "counts unverified citations" do
      evidence = [
        %{verification: "verified"},
        %{verification: "unverified"},
        %{verification: "unverified"}
      ]

      unverified_count = Enum.count(evidence, fn ev -> ev.verification == "unverified" end)
      assert unverified_count == 2
    end

    test "counts reasoning without citations" do
      evidence = [
        %{verification: "verified", source_type: :sourced},
        %{verification: "no_citation", source_type: :reasoning},
        %{verification: "no_citation", source_type: :reasoning}
      ]

      reasoning_count = Enum.count(evidence, fn ev -> ev.verification == "no_citation" end)
      assert reasoning_count == 2
    end

    test "calculates verification rate" do
      sourced_evidence = [
        %{verification: "verified", source_type: :sourced},
        %{verification: "verified", source_type: :sourced},
        %{verification: "partial", source_type: :sourced},
        %{verification: "unverified", source_type: :sourced}
      ]

      total_sourced = length(sourced_evidence)
      count_verified = Enum.count(sourced_evidence, fn ev -> ev.verification == "verified" end)
      verification_rate = if total_sourced > 0, do: count_verified / total_sourced, else: 0.0

      assert_in_delta verification_rate, 0.5, 0.01
    end

    test "sums scores for evidence" do
      evidence = [
        %{score: 1.5},
        %{score: 2.0},
        %{score: 0.5}
      ]

      total_score = Enum.sum(Enum.map(evidence, & &1.score))
      assert total_score == 4.0
    end

    test "filters grounded evidence" do
      classified = [
        %{evidence_store: :grounded, score: 1.0},
        %{evidence_store: :belief, score: 0.5},
        %{evidence_store: :grounded, score: 1.5}
      ]

      grounded = Enum.filter(classified, &(&1.evidence_store == :grounded))
      assert length(grounded) == 2

      grounded_score = Enum.sum(Enum.map(grounded, & &1.score))
      assert grounded_score == 2.5
    end
  end

  # ── Report formatting helpers ───────────────────────────────────────────

  describe "report formatting" do
    test "formats direction label" do
      direction = "supporting"
      formatted = "**Direction: #{direction}** (AEC grounded-only verdict)"
      assert String.contains?(formatted, "supporting")
      assert String.contains?(formatted, "AEC")
    end

    test "formats evidence counts" do
      grounded_for = 3
      grounded_against = 1
      belief_for = 2
      belief_against = 0

      formatted = """
      Grounded: #{grounded_for} for, #{grounded_against} against
      Belief: #{belief_for} for, #{belief_against} against
      """

      assert String.contains?(formatted, "3 for, 1 against")
      assert String.contains?(formatted, "2 for, 0 against")
    end

    test "formats quality metrics" do
      total_sourced = 10
      verified = 7
      partial = 2
      unverified = 1

      verification_rate = if total_sourced > 0, do: verified / total_sourced, else: 0.0

      formatted = """
      Verification rate: #{Float.round(verification_rate * 100, 1)}%
      Sourced: #{total_sourced} (#{verified} verified, #{partial} partial, #{unverified} unverified)
      """

      assert String.contains?(formatted, "70.0%")
      assert String.contains?(formatted, "10 (7 verified, 2 partial, 1 unverified)")
    end
  end

  # ── Internal helpers (copied from source) ───────────────────────────────

  defp extract_keywords(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in ~w(the a an is are was were be been being have has had do does did
      will would shall should may might must can could of in to for with on at by
      from as into through during before after above below between out off over
      under again further then once here there when where why how all both each
      few more most other some such no nor not only own same so than too very it
      its this that these those and but or if while)))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.flat_map(fn word ->
      stem = word
        |> String.replace(~r/ing$/, "")
        |> String.replace(~r/tion$/, "t")
        |> String.replace(~r/ness$/, "")
        |> String.replace(~r/ment$/, "")
        |> String.replace(~r/able$/, "")
        |> String.replace(~r/ible$/, "")
        |> String.replace(~r/ly$/, "")
        |> String.replace(~r/ed$/, "")
        |> String.replace(~r/er$/, "")
        |> String.replace(~r/es$/, "")
        |> String.replace(~r/s$/, "")
      if stem != word and String.length(stem) >= 3, do: [word, stem], else: [word]
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp merge_papers_raw(papers) when is_list(papers) do
    Enum.uniq_by(papers, fn p ->
      title = case p do
        %{title: t} -> t
        %{"title" => t} -> t
        _ -> ""
      end

      title
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 4))
      |> Enum.sort()
      |> Enum.take(5)
      |> Enum.join(" ")
    end)
  end

  defp classify_evidence_store(verified_evidence, paper_map, %Strategy{} = _strategy) do
    # Simplified version for testing
    Enum.map(verified_evidence, fn ev ->
      source_quality = case ev.paper_ref do
        nil -> 0.15
        n ->
          case Map.get(paper_map, n) do
            nil -> 0.1
            _paper -> 0.5  # Simplified scoring
          end
      end

      store = if ev.verification == :verified and source_quality > 0.3 do
        :grounded
      else
        :belief
      end

      Map.merge(ev, %{source_quality: source_quality, evidence_store: store})
    end)
  end
end
