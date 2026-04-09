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
end
