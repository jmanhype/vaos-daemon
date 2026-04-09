defmodule Daemon.Investigation.ClaimFamilyTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.ClaimFamily

  test "normalize_topic strips manual-eval wrappers" do
    assert ClaimFamily.normalize_topic("cross-check whether the earth is flat") ==
             "the earth is flat"

    assert ClaimFamily.normalize_topic("map the evidence on whether the earth is flat") ==
             "the earth is flat"

    assert ClaimFamily.normalize_topic("Investigate whether creatine helps cognition") ==
             "creatine helps cognition"
  end

  test "evidence_profile returns declarative planetary-shape retrieval hints" do
    profile =
      ClaimFamily.evidence_profile(
        "the earth is flat",
        ["earth", "flat"],
        ["earth", "flat"]
      )

    assert profile.kind == :planetary_shape
    assert profile.semantic_seed == "earth curvature measurement"
    assert profile.subject_terms == ["earth"]

    queries = Enum.map(profile.direct_queries, fn {_label, query, _opts} -> query end)

    assert "earth curvature measurement" in queries
    assert "earth geodesy" in queries
    assert "earth satellite observation" in queries
  end

  test "match returns health-effect family for epidemiology-style claims" do
    family =
      ClaimFamily.match(
        "smoking causes lung cancer",
        ["smoking", "lung", "cancer"],
        ["smoking", "lung", "cancer"]
      )

    assert family.kind == :health_effect
    assert family.profile == :health_claim
    assert family.query_templates[:ss] != []
    assert family.query_templates[:oa] != []
  end

  test "match returns clinical-intervention family when treatment and health terms co-occur" do
    family =
      ClaimFamily.match(
        "creatine supplementation improves muscular strength in resistance training",
        ["creatine", "supplementation", "muscular", "strength"],
        ["creatine", "supplementation", "muscular", "strength", "resistance", "training"]
      )

    assert family.kind == :clinical_intervention
    assert family.profile == :clinical_intervention
    assert family.query_templates[:ss] != []
    assert family.query_templates[:oa] != []
  end

  test "evidence_profile stays nil for unrelated general claims" do
    assert ClaimFamily.evidence_profile(
             "creatine helps cognition",
             ["creatine", "cognition"],
             ["creatine", "helps", "cognition"]
           ) == nil
  end

  test "normalize_verification_claim applies planetary-shape-specific rewrite only inside the family" do
    summary =
      "The theoretical framework of gravitation, confirmed by centuries of observation, establishes that Earth's surface must be an oblate spheroid—not any flat geometry. [Paper 8] demonstrates this rigorously, showing that without assuming Earth's original fluidity but \"merely assuming the theory of universal gravitation,\" the surface must be \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\""

    assert ClaimFamily.normalize_verification_claim(summary) ==
             "\"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\""

    generic =
      "Paper 2 reports improved calibration under controlled conditions."

    assert ClaimFamily.normalize_verification_claim(generic) == generic
  end

  test "search_queries renders family-specific health-effect query templates" do
    {ss_queries, oa_queries} =
      ClaimFamily.search_queries(
        "vaccines cause autism",
        ["vaccines", "autism"],
        ["vaccines", "autism"],
        nil
      )

    queries = Enum.map(ss_queries ++ oa_queries, fn {_label, query, _opts} -> query end)

    assert "systematic review vaccines autism" in queries
    assert "cohort study vaccines autism" in queries
    assert "case-control study vaccines autism" in queries
    refute Enum.any?(queries, &String.contains?(&1, "randomized controlled trial"))
  end
end
