defmodule Daemon.Investigation.EvidencePlannerTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.EvidencePlanner

  test "selects measurement route for planetary-shape claims" do
    topic = "the earth is flat"
    keywords = ["earth", "flat"]
    terms = ["earth", "flat"]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :measurement
    assert planner.selected.profile == :general
    assert planner.selected.evidence_profile.kind == :physical_measurement
    assert planner.evidence_signatures.measurement_signature
    assert planner.evidence_signatures.physical_geometry_signature
    assert Enum.any?(planner.candidates, &(&1.mode == :measurement))
  end

  test "selects artifact-reference route for repository documentation claims" do
    topic =
      "the repository documentation says Documentation.md is the canonical Roberto status file"

    keywords = ["repository", "documentation", "Documentation.md", "status"]

    terms = [
      "repository",
      "documentation",
      "documentation",
      "md",
      "canonical",
      "roberto",
      "status",
      "file"
    ]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :artifact_reference
    assert planner.selected.profile == :artifact_reference
    assert planner.selected.evidence_profile.kind == :artifact_reference
    assert planner.evidence_signatures.artifact_reference_signature

    assert [
             %{
               kind: :artifact,
               operation: :local_artifact_search,
               source: :local_repo
             }
           ] = planner.selected.retrieval_ops
  end

  test "selects observational route for exposure-outcome claims" do
    topic = "smoking causes lung cancer"
    keywords = ["smoking", "lung", "cancer"]
    terms = ["smoking", "lung", "cancer"]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :observational
    assert planner.selected.profile == :health_claim
    assert planner.selected.evidence_profile.kind == :observational
    assert planner.evidence_signatures.health_effect_signature
  end

  test "selects randomized-intervention route for treatment claims" do
    topic = "creatine supplementation improves muscular strength in resistance training"
    keywords = ["creatine", "supplementation", "muscular", "strength"]
    terms = ["creatine", "supplementation", "muscular", "strength", "resistance", "training"]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :randomized_intervention
    assert planner.selected.profile == :clinical_intervention
    assert planner.selected.evidence_profile.kind == :randomized_intervention
    assert planner.evidence_signatures.intervention_signature
  end

  test "selects randomized-intervention route for supplementation claims without explicit training phrasing" do
    topic = "caffeine supplementation improves endurance performance"
    keywords = ["caffeine", "supplementation", "endurance", "performance"]
    terms = ["caffeine", "supplementation", "endurance", "performance"]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :randomized_intervention
    assert planner.selected.profile == :clinical_intervention
  end

  test "selects randomized-intervention route for administration-style performance claims" do
    topic =
      "acute caffeine intake enhances endurance time-trial performance in trained cyclists and triathletes"

    keywords = ["acute", "caffeine", "intake", "endurance", "time-trial", "performance"]

    terms = [
      "acute",
      "caffeine",
      "intake",
      "enhances",
      "endurance",
      "time-trial",
      "performance",
      "trained",
      "cyclists",
      "triathletes"
    ]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :randomized_intervention
    assert planner.selected.profile == :clinical_intervention

    query_labels = Enum.map(planner.selected.oa_queries, &elem(&1, 0))
    queries = Enum.map(planner.selected.oa_queries ++ planner.selected.ss_queries, &elem(&1, 1))

    assert :performance_crossover in query_labels
    assert Enum.any?(queries, &String.contains?(&1, "caffeine supplementation"))
    assert Enum.any?(queries, &String.contains?(&1, "trained cyclists"))
    assert Enum.any?(queries, &String.contains?(&1, "placebo crossover"))
  end

  test "selects randomized-intervention route for administration-style outcome claims" do
    topic =
      "acute caffeine ingestion enhances cycling time-trial outcomes in trained cyclists and triathletes"

    keywords = ["acute", "caffeine", "ingestion", "cycling", "time-trial", "outcomes"]

    terms = [
      "acute",
      "caffeine",
      "ingestion",
      "cycling",
      "time-trial",
      "outcomes",
      "trained",
      "cyclists",
      "triathletes"
    ]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :randomized_intervention
    assert planner.selected.profile == :clinical_intervention

    query_labels = Enum.map(planner.selected.oa_queries, &elem(&1, 0))
    queries = Enum.map(planner.selected.oa_queries ++ planner.selected.ss_queries, &elem(&1, 1))

    assert :performance_placebo in query_labels
    assert :performance_rct in query_labels
    assert Enum.any?(queries, &String.contains?(&1, "cycling time-trial performance"))
  end

  test "randomized-intervention candidates prioritize direct trial probes before reviews" do
    topic = "acute caffeine supplementation improves endurance performance in trained cyclists"
    keywords = ["acute", "caffeine", "supplementation", "endurance", "performance"]

    terms = [
      "acute",
      "caffeine",
      "supplementation",
      "endurance",
      "performance",
      "trained",
      "cyclists"
    ]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :randomized_intervention

    assert Enum.take(Enum.map(planner.selected.ss_queries, &elem(&1, 0)), 5) == [
             :topic,
             :performance_crossover,
             :rct,
             :placebo,
             :reviews
           ]

    assert Enum.take(Enum.map(planner.selected.oa_queries, &elem(&1, 0)), 5) == [
             :topic,
             :performance_crossover,
             :placebo,
             :rct,
             :reviews
           ]
  end

  test "apply_probe_results lets empirical probe signal overturn the heuristic prior" do
    topic = "smoking causes lung cancer"
    keywords = ["smoking", "lung", "cancer"]
    terms = ["smoking", "lung", "cancer"]

    planner = EvidencePlanner.plan(topic, keywords, terms)

    assert planner.selected.mode == :observational

    probed =
      EvidencePlanner.apply_probe_results(planner.candidates, [
        %{mode: :observational, status: :ok, score: 1.0, relevant_papers: 0},
        %{mode: :systematic_review, status: :ok, score: 10.0, relevant_papers: 3}
      ])

    assert probed.selected.mode == :systematic_review
    assert probed.selected.probe_score == 10.0
    assert probed.selected.selection_score > probed.selected.heuristic_score
  end
end
