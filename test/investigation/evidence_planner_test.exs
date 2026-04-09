defmodule Daemon.Investigation.EvidencePlannerTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.{ClaimFamily, EvidencePlanner}

  test "selects measurement route for planetary-shape claims" do
    topic = "the earth is flat"
    keywords = ["earth", "flat"]
    terms = ["earth", "flat"]
    claim_family = ClaimFamily.match(topic, keywords, terms)
    evidence_profile = ClaimFamily.evidence_profile(topic, keywords, terms)

    planner = EvidencePlanner.plan(topic, keywords, terms, claim_family, evidence_profile)

    assert planner.selected.mode == :measurement
    assert planner.selected.profile == :general
    assert planner.selected.semantic_seed == "earth curvature measurement"
    assert Enum.any?(planner.candidates, &(&1.mode == :measurement))
  end

  test "selects observational route for exposure-outcome claims" do
    topic = "smoking causes lung cancer"
    keywords = ["smoking", "lung", "cancer"]
    terms = ["smoking", "lung", "cancer"]
    claim_family = ClaimFamily.match(topic, keywords, terms)

    planner = EvidencePlanner.plan(topic, keywords, terms, claim_family, nil)

    assert planner.selected.mode == :observational
    assert planner.selected.profile == :health_claim
  end

  test "selects randomized-intervention route for treatment claims" do
    topic = "creatine supplementation improves muscular strength in resistance training"
    keywords = ["creatine", "supplementation", "muscular", "strength"]
    terms = ["creatine", "supplementation", "muscular", "strength", "resistance", "training"]
    claim_family = ClaimFamily.match(topic, keywords, terms)

    planner = EvidencePlanner.plan(topic, keywords, terms, claim_family, nil)

    assert planner.selected.mode == :randomized_intervention
    assert planner.selected.profile == :clinical_intervention
  end
end
