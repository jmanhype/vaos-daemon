defmodule Daemon.Tools.Builtins.InvestigateTest do
  use ExUnit.Case, async: false

  alias Daemon.Investigation.Strategy
  alias Daemon.Tools.Builtins.Investigate

  defmodule TrialStub do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{responses: %{}, calls: []} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{responses: %{}, calls: []} end)
    end

    def expect(topic, response) do
      Agent.update(__MODULE__, fn state ->
        put_in(state, [:responses, topic], response)
      end)
    end

    def consume_trial(topic) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.responses, topic, :none)

        next_state = %{
          state
          | responses: Map.delete(state.responses, topic),
            calls: [topic | state.calls]
        }

        {response, next_state}
      end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end
  end

  setup do
    keys = [
      :default_provider,
      :default_model,
      :utility_model,
      :investigate_verification_model,
      :investigate_verify_max_tokens
    ]

    original =
      Enum.into(keys, %{}, fn key ->
        {key, Application.get_env(:daemon, key, :__missing__)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, :__missing__} -> Application.delete_env(:daemon, key)
        {key, value} -> Application.put_env(:daemon, key, value)
      end)
    end)

    case Process.whereis(TrialStub) do
      nil -> start_supervised!(TrialStub)
      _pid -> TrialStub.reset()
    end

    :ok
  end

  test "preferred_verification_model prefers utility-tier model over default reasoning model" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.delete_env(:daemon, :utility_model)
    Application.delete_env(:daemon, :investigate_verification_model)

    assert Investigate.preferred_verification_model() == "glm-4.5-flash"
  end

  test "preferred_verification_model honors explicit override" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.put_env(:daemon, :utility_model, "glm-4.5-flash")
    Application.put_env(:daemon, :investigate_verification_model, "glm-custom-verify")

    assert Investigate.preferred_verification_model() == "glm-custom-verify"
  end

  test "merge_verification_stats aggregates counts and averages" do
    merged =
      Investigate.merge_verification_stats([
        %{
          total_items: 3,
          llm_items: 2,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 0,
          cache_hits: 1,
          cache_misses: 1,
          cache_lookup_ms: 4,
          llm_ms_total: 80,
          average_llm_ms: 80,
          slowest_llm_ms: 80,
          model: "glm-4.5-flash"
        },
        %{
          total_items: 4,
          llm_items: 3,
          no_llm_items: 1,
          unique_llm_items: 2,
          deduped_llm_items: 1,
          cache_hits: 0,
          cache_misses: 2,
          cache_lookup_ms: 3,
          llm_ms_total: 100,
          average_llm_ms: 50,
          slowest_llm_ms: 60,
          model: "glm-4.5-flash"
        }
      ])

    assert merged.total_items == 7
    assert merged.llm_items == 5
    assert merged.no_llm_items == 2
    assert merged.unique_llm_items == 4
    assert merged.deduped_llm_items == 1
    assert merged.cache_hits == 1
    assert merged.cache_misses == 3
    assert merged.cache_lookup_ms == 7
    assert merged.llm_ms_total == 180
    assert merged.average_llm_ms == 60
    assert merged.slowest_llm_ms == 80
    assert merged.model == "glm-4.5-flash"
  end

  test "maybe_apply_pending_trial_steering consumes a pending trial when opted in" do
    TrialStub.expect(
      "manual pilot topic",
      {:ok, %{steering: "TRIAL STEERING: Treat this investigation as a pivot pass."}}
    )

    args =
      Investigate.maybe_apply_pending_trial_steering(
        %{
          "topic" => "manual pilot topic",
          "steering" => "BASE STEERING",
          "apply_pending_trial" => true
        },
        TrialStub
      )

    assert args["steering"] ==
             "BASE STEERING\n\nTRIAL STEERING: Treat this investigation as a pivot pass."

    assert TrialStub.calls() == ["manual pilot topic"]
  end

  test "maybe_apply_pending_trial_steering leaves args unchanged without opt-in" do
    TrialStub.expect(
      "manual pilot topic",
      {:ok, %{steering: "TRIAL STEERING: Treat this investigation as a pivot pass."}}
    )

    args =
      Investigate.maybe_apply_pending_trial_steering(
        %{
          "topic" => "manual pilot topic",
          "steering" => "BASE STEERING"
        },
        TrialStub
      )

    assert args["steering"] == "BASE STEERING"
    assert TrialStub.calls() == []
  end

  test "partial_completion_metadata preserves classified evidence for one-sided successes" do
    supporting = [
      %{
        summary: "Creatine improved task performance [Paper 1]",
        score: 2.4,
        verified: true,
        verification: "verified",
        paper_type: :review,
        citation_count: 24,
        strength: "strong",
        source_quality: 0.9,
        source_type: :sourced,
        evidence_store: :grounded
      },
      %{
        summary: "Mechanistic rationale without direct sourcing",
        score: 0.3,
        verified: false,
        verification: "no_citation",
        paper_type: :other,
        citation_count: 0,
        strength: "weak",
        source_quality: 0.1,
        source_type: :belief,
        evidence_store: :belief
      }
    ]

    timings = %{
      preflight_ms: 10,
      paper_search_ms: 20,
      citation_verification_ms: 30,
      post_processing_ms: 40,
      total_ms: 100
    }

    verification_stats = %{
      total_items: 2,
      llm_items: 1,
      no_llm_items: 1,
      unique_llm_items: 1,
      deduped_llm_items: 0,
      cache_hits: 0,
      cache_misses: 1,
      cache_lookup_ms: 2,
      llm_ms_total: 30,
      average_llm_ms: 30,
      slowest_llm_ms: 30,
      model: "glm-4.5-flash"
    }

    metadata =
      Investigate.partial_completion_metadata(
        "creatine helps cognition",
        supporting,
        [],
        [%{"title" => "Creatine Review", "year" => 2024, "citation_count" => 24}],
        %{semantic_scholar: 1},
        Strategy.default(),
        "variant-123",
        timings,
        verification_stats
      )

    assert metadata.partial == true
    assert metadata.direction == "partial_supporting_only"
    assert metadata.verified_for == 1
    assert metadata.reasoning_for == 1
    assert metadata.grounded_for_count == 1
    assert metadata.belief_for_count == 1
    assert metadata.investigation_id =~ "investigate:"
    assert metadata.phase_timings_ms == timings
    assert metadata.verification_stats == verification_stats
    assert metadata.evidence_quality.reviews == 1
    assert metadata.variant_id == "variant-123"

    assert [
             %{
               source_type: "sourced",
               evidence_store: "grounded",
               paper_type: "review"
             },
             %{
               source_type: "belief",
               evidence_store: "belief",
               paper_type: "other"
             }
           ] =
             Enum.map(
               metadata.supporting,
               &Map.take(&1, [:source_type, :evidence_store, :paper_type])
             )

    assert metadata.opposing == []
  end

  test "partial_completion_metadata does not treat unverified sourced evidence as grounded" do
    supporting = [
      %{
        summary: "Quoted abstract sentence [Paper 1]",
        score: 0.2,
        verified: false,
        verification: "unverified",
        paper_type: :study,
        citation_count: 12,
        strength: "moderate",
        source_quality: 0.7,
        source_type: :sourced,
        evidence_store: :belief
      }
    ]

    metadata =
      Investigate.partial_completion_metadata(
        "test topic",
        supporting,
        [],
        [%{"title" => "Paper", "year" => 2024, "citation_count" => 12}],
        %{openalex: 1},
        Strategy.default(),
        "variant-456",
        %{total_ms: 50},
        %{total_items: 1, llm_items: 1}
      )

    assert metadata.verified_for == 0
    assert metadata.grounded_for_count == 0
    assert metadata.belief_for_count == 1
    assert metadata.fraudulent_citations == 1

    assert [
             %{
               source_type: "sourced",
               evidence_store: "belief",
               verification: "unverified"
             }
           ] =
             Enum.map(
               metadata.supporting,
               &Map.take(&1, [:source_type, :evidence_store, :verification])
             )
  end

  test "build_boundary_trace captures prompts, raw outputs, and evidence boundaries" do
    trace =
      Investigate.build_boundary_trace(
        %{
          steering:
            "CORRECTIVE FOCUS: Quote exact abstract sentences and demote unsupported claims.",
          for_messages: [
            %{content: "FOR SYSTEM PROMPT"},
            %{content: "FOR USER PROMPT"}
          ],
          against_messages: [
            %{content: "AGAINST SYSTEM PROMPT"},
            %{content: "AGAINST USER PROMPT"}
          ],
          for_result: {:ok, %{content: "FOR RAW OUTPUT [Paper 1]"}},
          against_result: {:error, :rate_limited}
        },
        %{
          parsed_supporting: [
            %{summary: "Quoted result [Paper 1]"}
          ],
          parsed_opposing: [],
          verified_supporting: [
            %{
              summary: "Quoted result [Paper 1]",
              score: 1.6,
              verified: true,
              verification: "verified",
              paper_type: :review,
              citation_count: 12,
              source_type: :sourced,
              evidence_store: :grounded
            }
          ],
          verified_opposing: [],
          timings: %{total_ms: 42},
          verification_stats: %{total_items: 1, llm_items: 1},
          final_metadata: %{
            direction: "supporting",
            grounded_for_count: 1,
            grounded_against_count: 0,
            belief_for_count: 0,
            belief_against_count: 0,
            verified_for: 1,
            verified_against: 0,
            fraudulent_citations: 0
          }
        }
      )

    assert trace.steering.preview =~ "CORRECTIVE FOCUS"
    assert trace.prompts.for_system.preview == "FOR SYSTEM PROMPT"
    assert trace.prompts.against_user.preview == "AGAINST USER PROMPT"
    assert trace.llm.for.status == "ok"
    assert trace.llm.for.content.preview =~ "FOR RAW OUTPUT"
    assert trace.llm.against.status == "error"
    assert trace.parsed.supporting_count == 1
    assert trace.verified.supporting_count == 1
    assert hd(trace.verified.supporting).paper_ref == 1
    assert hd(trace.verified.supporting).verification == "verified"
    assert trace.classification.grounded_for_count == 1
    assert trace.outcome.direction == "supporting"
    assert hd(trace.verified.supporting).verification_claim == "Quoted result"
  end

  test "maybe_capture_trace writes a trace artifact and annotates metadata" do
    json_metadata = %{
      topic: "the earth is flat",
      investigation_id: "investigate:test",
      direction: "opposing"
    }

    traced =
      Investigate.maybe_capture_trace(
        json_metadata,
        %{trace_capture: true, trace_label: "steered eval"},
        %{parsed: %{supporting_count: 0, opposing_count: 1}}
      )

    trace_path = traced.trace_path
    on_exit(fn -> File.rm(trace_path) end)

    assert traced.trace_label == "steered eval"
    assert is_binary(trace_path)
    assert File.exists?(trace_path)

    assert {:ok, payload} = File.read(trace_path)
    assert payload =~ "\"trace_label\": \"steered eval\""
    assert payload =~ "\"topic\": \"the earth is flat\""
    assert payload =~ "\"direction\": \"opposing\""
  end

  test "verification_claim_text trims traced sourced paragraphs down to the cited claim" do
    google_earth_engine_summary =
      "## 1. [SOURCED] (strength: 9) The entire enterprise of satellite remote sensing—which processes massive volumes of Earth observation data—fundamentally depends on and confirms a spheroidal Earth model. According to [Paper 2], Google Earth Engine facilitates \"processing big geo data over large areas and monitoring the environment for long periods of time,\" utilizing satellite datasets like Landsat and Sentinel that image the complete globe through orbital mechanics only possible around a spherical body. The platform's demonstrated success across \"Land Cover/land Use classification, hydrology, urban planning, natural disaster, climate analyses\" across \"large areas\" requires seamless stitching of imagery captured from orbit—imagery that consistently shows Earth's curvature and enables global coverage that would be geometrically impossible on a flat plane."

    normalized = Investigate.verification_claim_text(google_earth_engine_summary)

    assert normalized =~
             "According to Google Earth Engine facilitates \"processing big geo data over large areas and monitoring the environment for long periods of time,\""

    refute normalized =~ "only possible around a spherical body"
    refute normalized =~ "requires seamless stitching"
    refute normalized =~ "## 1."
    refute normalized =~ "[SOURCED]"
    refute normalized =~ "[Paper 2]"
  end

  test "verification_claim_text drops trailing inference after the cited sentence" do
    flat_earth_summary =
      "The academic literature explicitly classifies Flat Earth ideology as \"arguably the paragon of science denial\" and frames it as diametrically opposed to \"scientific consensus on the shape of the Earth\" [Paper 3]. The study empirically demonstrates that Flat Earth belief is predicted not by evidence evaluation but by \"conspiracy mentality,\" with participants recruited from the Flat Earth International Conference scoring \"significantly higher in conspiracy mentality\" than a national sample, while showing \"no significant difference in religiosity and belief in evolution\" [Paper 3]. This establishes that flat Earth adherence is a function of conspiratorial thinking patterns rather than rational assessment of physical evidence."

    normalized = Investigate.verification_claim_text(flat_earth_summary)

    assert normalized =~ "arguably the paragon of science denial"
    refute normalized =~ "This establishes"
    refute normalized =~ "[Paper 3]"
  end

  test "verification_claim_text recognizes bare Paper N references" do
    summary =
      "Paper 2 reports improved calibration under controlled conditions. This broader explanation goes beyond the paper and should be dropped."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized == "Paper 2 reports improved calibration under controlled conditions."
  end
end
