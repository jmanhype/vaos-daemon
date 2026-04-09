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
      :zhipu_model,
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

  test "verification_request_opts defaults to a larger token budget for zhipu glm verifier models" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.delete_env(:daemon, :investigate_verify_max_tokens)

    opts = Investigate.verification_request_opts("glm-4.5-flash")

    assert opts[:temperature] == 0.0
    assert opts[:model] == "glm-4.5-flash"
    assert opts[:max_tokens] == 256
  end

  test "verification_request_opts keeps the compact default for non-zhipu verifier models" do
    Application.put_env(:daemon, :default_provider, :ollama)
    Application.delete_env(:daemon, :investigate_verify_max_tokens)

    assert Investigate.verification_request_opts("qwen2.5:7b")[:max_tokens] == 64
  end

  test "verification_request_opts honors explicit token override" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :investigate_verify_max_tokens, 96)

    assert Investigate.verification_request_opts("glm-4.5-flash")[:max_tokens] == 96
  end

  test "parse_verification_response extracts verdict tokens from reasoning-heavy verifier output" do
    response = """
    Okay, the abstract directly supports the claim, so the answer should be \"VERIFIED.\"
    That falls under \"OTHER\" because the example is not a review, trial, or study.
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "parse_verification_response infers verdict from reasoning-heavy zhipu output without final label" do
    response = """
    This is a strict classification task. I need to classify the paper based on the provided title, abstract, and claim.

    Looking at the abstract, this claim appears to be directly stated: "it has been shewn that the surface ought to be of the form of an oblate spheroid..."
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "parse_verification_response treats word-for-word match language as verified" do
    response = """
    3. Evaluate the claim against the abstract:
    * The claim matches almost word-for-word with the abstract language.
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "parse_verification_response salvages clearly-identifies reasoning without final label" do
    response = """
    I need to classify the claim about whether the paper "Spherical-Earth-Based Measurement Modeling for Practical OTHR Target Tracking" explicitly identifies that flat-Earth assumptions in over-the-horizon radar tracking produce two "obvious drawbacks".

    The abstract clearly identifies two "obvious drawbacks" of using a flat Earth OTHR measurement model.
    These are exactly the two "obvious drawbacks" mentioned in the claim.
    The paper is described as an article, which suggests it's a REVIEW of existing literature with a proposed solution.

    Classification:
    """

    assert Investigate.parse_verification_response(response) == {:verified, :review}
  end

  test "parse_verification_response overrides unverified when abstract directly states claim but model hedges on full-paper access" do
    response = """
    The claim is: "the error that must be taken into account when compiling and reading maps does not exceed 3%"

    In the abstract, the final sentence says exactly that the error that must be taken into account when compiling and reading maps does not exceed 3%.
    So the paper directly states this claim in its abstract.

    However, since I only have access to the abstract, I cannot verify if the methods and calculations in the full paper rigorously justify the exact 3% figure beyond the abstract's statement.

    UNVERIFIED OTHER
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "parse_verification_response treats fully-supported reasoning as verified without final label" do
    response = """
    The abstract clearly states that the flat-Earth assumptions have two obvious drawbacks.
    The paper explicitly identifies those drawbacks, which exactly matches the claim.
    Therefore, the claim is fully supported by the paper.
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "parse_verification_response treats explicitly-identify reasoning as verified without final label" do
    response = """
    Looking at the abstract, I can see that the paper does indeed explicitly identify two drawbacks of the flat-Earth model.
    That reasoning is enough to support the claim.
    """

    assert Investigate.parse_verification_response(response) == {:verified, :other}
  end

  test "preferred_utility_model prefers provider-specific active model over stale default_model" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-4.7")
    Application.put_env(:daemon, :zhipu_model, "glm-5.1")
    Application.delete_env(:daemon, :utility_model)

    assert Investigate.preferred_utility_model() == "glm-5.1"
  end

  test "emergent_question_generation_enabled?/4 requires real evidence tension" do
    supporting = [%{summary: "Supporting evidence"}]
    opposing = [%{summary: "Opposing evidence"}]

    assert Investigate.emergent_question_generation_enabled?(
             "genuinely_contested",
             supporting,
             opposing,
             0.2
           )

    assert Investigate.emergent_question_generation_enabled?(
             "supporting",
             supporting,
             opposing,
             0.8
           )

    refute Investigate.emergent_question_generation_enabled?(
             "supporting",
             supporting,
             opposing,
             0.5
           )

    refute Investigate.emergent_question_generation_enabled?(
             "supporting",
             supporting,
             [],
             0.8
           )

    refute Investigate.emergent_question_generation_enabled?(
             "supporting",
             supporting,
             opposing,
             nil
           )
  end

  test "verify_citation_pairs/5 runs both sides concurrently and preserves tuple order" do
    parent = self()

    verify_fun = fn evidence, _paper_map, _prompts ->
      tag = hd(evidence)
      send(parent, {:started, tag, self()})

      receive do
        {:release, ^tag} -> {[tag], %{tag: tag}}
      after
        1_000 -> flunk("timed out waiting to release #{inspect(tag)}")
      end
    end

    pair_task =
      Task.async(fn ->
        Investigate.verify_citation_pairs([:supporting], [:opposing], %{}, %{}, verify_fun)
      end)

    assert_receive {:started, :supporting, supporting_pid}
    assert_receive {:started, :opposing, opposing_pid}

    send(opposing_pid, {:release, :opposing})
    send(supporting_pid, {:release, :supporting})

    assert {
             {[:supporting], %{tag: :supporting}},
             {[:opposing], %{tag: :opposing}}
           } = Task.await(pair_task)
  end

  test "run_semantic_scholar_queries stops after terminal 429 failure" do
    counter = :counters.new(1, [])

    http_fn = fn _url, _opts ->
      :counters.add(counter, 1, 1)
      {:error, "HTTP 429"}
    end

    queries = [
      {:broad, "first query", []},
      {:mechanism, "second query", []},
      {:review, "third query", []}
    ]

    {results, terminal_failure?} =
      Investigate.run_semantic_scholar_queries(queries, http_fn, 5, nil)

    assert terminal_failure? == true
    assert :counters.get(counter, 1) == 1
    assert results == [ss_broad: []]
  end

  test "semantic_scholar_terminal_error? recognizes nested terminal failures" do
    assert Investigate.semantic_scholar_terminal_error?({:semantic_scholar_failed, "HTTP 429"})

    assert Investigate.semantic_scholar_terminal_error?(
             {:wrapped, {:semantic_scholar_failed, "HTTP 403"}}
           )

    refute Investigate.semantic_scholar_terminal_error?({:semantic_scholar_failed, "HTTP 500"})
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

  test "cross_side_overlap_stats reports shared normalized claim and paper pairs" do
    paper_map = %{
      1 => %{"title" => "Creatine Review"},
      2 => %{"title" => "Sleep Trial"}
    }

    supporting = [
      %{
        summary:
          "[SOURCED] (strength: 8) Creatine improved working memory in healthy adults [Paper 1]"
      },
      %{
        summary:
          "[SOURCED] (strength: 6) Better sleep consolidation followed supplementation [Paper 2]"
      }
    ]

    opposing = [
      %{
        summary:
          "[REASONING] (strength: 5) Creatine improved working memory in healthy adults [Paper 1]"
      },
      %{
        summary:
          "[SOURCED] (strength: 4) No meaningful benefit was observed for sleep onset latency [Paper 2]"
      }
    ]

    overlap =
      Investigate.cross_side_overlap_stats(
        supporting,
        opposing,
        paper_map
      )

    assert overlap.supporting_unique_llm_items == 2
    assert overlap.opposing_unique_llm_items == 2
    assert overlap.cross_side_overlap_items == 1
    assert overlap.cross_side_unique_llm_items == 3
    assert overlap.cross_side_overlap_rate == 0.333
    assert overlap.supporting_overlap_rate == 0.5
    assert overlap.opposing_overlap_rate == 0.5

    assert overlap.cross_side_overlap_examples == [
             %{
               paper_ref: 1,
               paper_title: "Creatine Review",
               claim: "Creatine improved working memory in healthy adults"
             }
           ]
  end

  test "rerank_retrieval_candidates tolerates nil evidence_profile for general plans" do
    papers = [
      %{
        "title" => "Adult cognition after creatine supplementation",
        "abstract" => "Creatine supplementation improved memory outcomes in adults."
      },
      %{
        "title" => "Unrelated social discourse review",
        "abstract" => "A review of discourse around nutrition claims."
      }
    ]

    reranked =
      Investigate.rerank_retrieval_candidates(papers, %{
        profile: :general,
        normalized_topic:
          "does creatine supplementation improve cognitive performance in healthy adults",
        evidence_profile: nil
      })

    assert hd(reranked)["title"] == "Adult cognition after creatine supplementation"
    assert length(reranked) == 2
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
      prompt_feedback_ms: 4,
      ledger_persistence_ms: 8,
      emergent_questions_ms: 3,
      knowledge_graph_ms: 11,
      deep_research_ms: 0,
      policy_ranking_ms: 5,
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
    assert metadata.phase_timings_ms.ledger_persistence_ms == 8
    assert metadata.phase_timings_ms.knowledge_graph_ms == 11

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
             "Google Earth Engine facilitates \"processing big geo data over large areas and monitoring the environment for long periods of time,\""

    refute normalized =~ "only possible around a spherical body"
    refute normalized =~ "requires seamless stitching"
    refute String.starts_with?(normalized, "According to")
    refute normalized =~ "## 1."
    refute normalized =~ "[SOURCED]"
    refute normalized =~ "[Paper 2]"
  end

  test "verification_claim_text strips /10 strength prefixes before normalizing sourced claims" do
    summary =
      "1. [SOURCED] (strength: 7/10) [Paper 4] reports that under the theory of universal gravitation, the Earth's surface \"ought to be of the form of an oblate spheroid of small ellipticity.\""

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"oblate spheroid of small ellipticity.\""

    refute normalized =~ "(strength: 7/10)"
    refute String.starts_with?(normalized, "1.")
  end

  test "verification_claim_text drops trailing inference after the cited sentence" do
    flat_earth_summary =
      "The academic literature explicitly classifies Flat Earth ideology as \"arguably the paragon of science denial\" and frames it as diametrically opposed to \"scientific consensus on the shape of the Earth\" [Paper 3]. The study empirically demonstrates that Flat Earth belief is predicted not by evidence evaluation but by \"conspiracy mentality,\" with participants recruited from the Flat Earth International Conference scoring \"significantly higher in conspiracy mentality\" than a national sample, while showing \"no significant difference in religiosity and belief in evolution\" [Paper 3]. This establishes that flat Earth adherence is a function of conspiratorial thinking patterns rather than rational assessment of physical evidence."

    normalized = Investigate.verification_claim_text(flat_earth_summary)

    assert normalized =~ "arguably the paragon of science denial"
    refute normalized =~ "This establishes"
    refute normalized =~ "[Paper 3]"
  end

  test "verification_claim_text prefers followup abstract quote after synthetic cited sentence" do
    summary =
      "The GRACE and GRACE Follow-On satellite gravity missions have operated continuously since 2002, successfully mapping mass transport across Earth by tracking orbital perturbations of twin satellites in three-dimensional orbits around a massive body [Paper 7]. The abstract describes how \"time-resolved satellite gravimetry has revolutionized understanding of mass transport in the Earth system,\" enabling monitoring of \"terrestrial water cycle, ice sheet and glacier mass balance, sea level change and ocean bottom pressure variations.\" These satellites orbit at approximately 400-500 km altitude, completing circuits around the entire planet."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"time-resolved satellite gravimetry has revolutionized understanding of mass transport in the Earth system,\" enabling monitoring of \"terrestrial water cycle, ice sheet and glacier mass balance, sea level change and ocean bottom pressure variations.\""

    refute normalized =~ "GRACE and GRACE Follow-On"
    refute normalized =~ "three-dimensional orbits around a massive body"
  end

  test "verification_claim_text strips abstract-document lead and trailing inference" do
    summary =
      "The International Terrestrial Reference Frame ITRF2008, constructed from 29 years of VLBI observations, 26 years of SLR data, 12.5 years of GPS measurements, and 16 years of DORIS data, defines Earth's center of mass as an origin point with three-dimensional X, Y, and Z coordinates—explicitly encoding a spheroidal body in 3D space [Paper 2]. The abstract documents origin agreement between ITRF2008 and ITRF2005 at the millimeter level (differences of −0.5, −0.9, and −4.7 mm along the three axes), demonstrating that thousands of observing stations distributed across the globe consistently triangulate positions on a roughly spherical surface."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "origin agreement between ITRF2008 and ITRF2005 at the millimeter level (differences of −0.5, −0.9, and −4.7 mm along the three axes)"

    refute normalized =~ "The abstract documents"
    refute normalized =~ "triangulate positions"
  end

  test "verification_claim_text prefers evidence-rich quote over mixed gravitation setup" do
    summary =
      "The theoretical framework of gravitation, confirmed by centuries of observation, establishes that Earth's surface must be an oblate spheroid—not any flat geometry. [Paper 8] demonstrates this rigorously, showing that without assuming Earth's original fluidity but \"merely assuming the theory of universal gravitation,\" the surface must be \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\" The paper further establishes Clairaut's Theorem connecting this spheroidal form to the observed variation of gravity across the surface."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\""

    refute normalized =~ "merely assuming the theory of universal gravitation"
  end

  test "verification_claim_text recognizes bare Paper N references" do
    summary =
      "Paper 2 reports improved calibration under controlled conditions. This broader explanation goes beyond the paper and should be dropped."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized == "Paper 2 reports improved calibration under controlled conditions."
  end

  test "verification_claim_text strips leading reporting verbs from sourced claims" do
    summary =
      "Multiple independent space geodetic techniques converge on a single three-dimensional reference frame that only makes sense for a spheroidal Earth. [Paper 10] describes ITRF2008, built from 29 years of VLBI observations, 26 years of Satellite Laser Ranging, 12.5 years of GPS, and 16 years of DORIS data, all combined into a frame whose \"origin is defined in such a way that it has zero translations and translation rates with respect to the mean Earth center of mass.\" The scale agreement between VLBI and SLR solutions is estimated at 1.05 ± 0.13 ppb, with origin accuracy at the 1 cm level."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized =~ "ITRF2008, built from 29 years of VLBI observations"
    assert normalized =~ "\"origin is defined in such a way that it has zero translations"
    refute String.starts_with?(normalized, "describes ")
  end

  test "verification_claim_text strips verb-that wrappers from quoted abstract claims" do
    summary =
      "The Earth's oblate spheroid shape is confirmed by gravitational theory and empirical measurement. [Paper 4] establishes that under the theory of universal gravitation, the Earth's surface \"ought to be of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\" and that \"gravity ought to vary along the surface according to a simple law\" captured by Clairaut's Theorem."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\""

    refute normalized =~ "under the theory of universal gravitation"
    refute normalized =~ "gravity ought to vary along the surface according to a simple law"
    refute String.starts_with?(normalized, "establishes that ")
  end

  test "verification_claim_text strips adverbial reporting wrappers before quotes" do
    summary =
      "The Earth's figure has been theoretically and observationally established as an oblate spheroid. [Paper 4] explicitly states that, under gravitational theory, the Earth's surface \"ought to be of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\" and that \"gravity ought to vary along the surface according to a simple law\" captured by Clairaut's Theorem."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\""

    refute normalized =~ "under gravitational theory"
    refute String.starts_with?(normalized, "explicitly states that")
  end

  test "verification_claim_text drops leading how wrapper after citation verbs" do
    summary =
      "The precise operation of Global Navigation Satellite Systems depends fundamentally on satellites orbiting a spheroidal Earth. [Paper 3] describes how modern geodesy uses GNSS, Satellite Laser Ranging, and Very Long Baseline Interferometry to measure \"the geometry, orientation and gravity field of the Earth,\" with the Global Geodetic Observing System integrating all observations to produce \"geodetic parameters for monitoring the phenomena and processes within the 'System Earth'.\""

    normalized = Investigate.verification_claim_text(summary)

    assert normalized =~ "modern geodesy uses GNSS"
    assert normalized =~ "\"the geometry, orientation and gravity field of the Earth,\""
    refute String.starts_with?(normalized, "how modern geodesy")
  end

  test "verification_claim_text rewrites traced as-involving fragments into direct claims" do
    summary =
      "Modern geodesy relies on complex mathematical models and interpretive frameworks rather than direct sensory observation of Earth's shape. [Paper 12] describes geodesy as involving theoretical background, measurement principles, and evaluation methods that must be \"integrated\" to produce \"geodetic parameters\"—meaning our understanding of Earth's geometry is mediated through layered mathematical constructions that could, in principle, embed assumptions about the final shape they purport to discover."

    normalized = Investigate.verification_claim_text(summary)

    assert String.starts_with?(normalized, "geodesy involves theoretical background")
    assert normalized =~ "\"integrated\" to produce \"geodetic parameters\""
    refute normalized =~ "as involving"
  end

  test "verification_claim_text prefers traced noted subclauses over measurement preambles" do
    summary =
      "Earth's spacetime curvature has been measured and matches the Schwarzschild metric of a spherical mass. [Paper 8] describes experiments measuring \"the Schwarzschild spacetime parameters of the Earth,\" noting that light sent from Earth to a satellite is \"redshifted and deformed due to the curvature of spacetime.\" The Schwarzschild solution specifically describes the gravitational field outside a spherically symmetric mass distribution; its successful application to Earth confirms both the planet's spheroidal geometry and its substantial mass (~5.97 × 10²⁴ kg), which produces gravitational forces that drive any sufficiently large body into hydrostatic equilibrium—a spheroidal shape."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "light sent from Earth to a satellite is \"redshifted and deformed due to the curvature of spacetime.\""

    refute String.starts_with?(normalized, "experiments measuring")
    refute normalized =~ "noting that"
  end

  test "verification_claim_text strips derives-that wrappers from sourced claims" do
    summary =
      "Classical geodetic theory, confirmed by centuries of observation, establishes that the Earth is an oblate spheroid. [Paper 4] explicitly derives that under gravitational theory, the Earth's surface \"ought to be of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\" and that gravity varies along the surface according to Clairaut's Theorem."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\""

    refute normalized =~ "under gravitational theory"
    refute String.starts_with?(normalized, "explicitly derives that")
  end

  test "verification_claim_text strips identifies-that wrappers from sourced claims" do
    summary =
      "Multiple independent engineering domains require spherical Earth models to achieve functional accuracy. [Paper 1] explicitly identifies that flat-Earth assumptions in over-the-horizon radar tracking produce two \"obvious drawbacks\": inability to use standard kinematic models and degraded measurement accuracy from ignoring Earth's curvature."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "flat-Earth assumptions in over-the-horizon radar tracking produce two \"obvious drawbacks\""

    refute String.starts_with?(normalized, "explicitly identifies that")
  end

  test "verification_claim_text strips subject-plus-reporting wrappers before quoted claim" do
    summary =
      "Classical geodesy established through gravitational theory that the Earth's surface forms an oblate spheroid consistent with rotation, not a plane. Research on gravity variation demonstrates that the surface must be \"perpendicular to the direction of gravity\" and \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation\" [Paper 3]. This shape is mathematically entailed by gravitational physics."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "the surface must be \"perpendicular to the direction of gravity\" and \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation\""

    refute String.starts_with?(normalized, "Research on gravity variation demonstrates that")
  end

  test "verification_claim_text prefers complete later quote when first quoted fragment is ellipsized" do
    summary =
      "Earth's curvature is routinely ignored in practical mapping applications with acceptable results. [Paper 3] states that \"curvature of the Earth's surface... is often ignored when making topographic maps\" and that for the Krasnodar Territory region studied, \"the error that must be taken into account when compiling and reading maps does not exceed 3%.\""

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"the error that must be taken into account when compiling and reading maps does not exceed 3%.\""
  end

  test "verification_claim_text strips drawback wrappers before quoted clause" do
    summary =
      "Multiple independent engineering systems must account for Earth's curvature to function accurately. [Paper 1] explicitly develops a spherical-earth-based measurement model for over-the-horizon radar tracking, noting that flat-Earth models suffer from the drawback that \"the curvature of earth is ignored, which affects the measurement accuracy of the OTHR.\""

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"the curvature of earth is ignored, which affects the measurement accuracy of the OTHR.\""
  end

  test "verification_claim_text prefers quoted context sentence before reporting-only citation sentence" do
    summary =
      "Deformation models used to interpret GPS and InSAR observations of earthquake and volcanic processes explicitly account for \"effects of irregular surface topography and earth curvature\" as necessary corrections for accurate geophysical analysis. [Paper 1] presents mathematical frameworks including \"elastic dislocation theory in homogeneous and layered half-spaces\" that model how the Earth's surface deforms in response to faulting and magmatic activity, with predictions \"compared against field data from seismic and volcanic settings from around the world.\" The need for curvature corrections—and the success of models incorporating them—constitutes direct operational evidence that the Earth is not flat."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized == "\"effects of irregular surface topography and earth curvature\""
  end

  test "verification_claim_text drops leading context clauses before quoted oblate-spheroid claims" do
    summary =
      "Gravitational measurements confirm Earth is an oblate spheroid, not a flat plane. [Paper 4] establishes that, under the theory of universal gravitation, Earth's surface should be \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,\" with gravity varying along the surface according to Clairaut's Theorem. This relationship between surface geometry and gravity variation has been empirically verified without requiring assumptions about Earth's interior—flat geometries produce fundamentally different gravitational signatures that contradict centuries of gravimetric observations."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "Earth's surface should be of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation,"

    refute normalized =~ "under the theory of universal gravitation"
  end

  test "verification_claim_text prefers quoted definition bodies after define verbs" do
    summary =
      "The entire discipline of geodesy operates on verified measurements of Earth's three-dimensional geometry. [Paper 12] defines geodesy as the science determining \"the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field\" using space techniques including GPS/GNSS, Satellite Laser Ranging, VLBI, and gravity mapping missions. [Paper 3] further notes that modern geodesy provides \"the foundation for high accuracy surveying and mapping\" with reference frames that serve as \"the basis for most national and regional datums\"—a globally consistent coordinate system that only works because Earth's shape is a closed spheroid."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field"

    refute String.starts_with?(normalized, "defines geodesy")
  end

  test "verification_claim_text strips adverbial reporting wrappers from oblate-spheroid claims" do
    summary =
      "Classical geodetic theory, established without any assumption about Earth's interior composition, mathematically demonstrates that the Earth's surface must be \"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\" [Paper 4] establishes this through Clairaut's Theorem, showing that gravity variation across the surface follows a precise mathematical law that only holds for a spheroidal body."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"of the form of an oblate spheroid of small ellipticity, having its axis of figure coincident with the axis of rotation.\""

    refute String.starts_with?(normalized, "mathematically demonstrates")
  end

  test "verification_claim_text prefers inline quoted claims before follow-up paper reporting" do
    summary =
      "Modern geodesy integrates multiple independent space technologies—including satellite laser ranging, very long baseline interferometry, and gravity mapping missions like GRACE—that collectively measure \"the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field.\" [Paper 12] describes how these diverse techniques converge on a consistent three-dimensional model of Earth as a dynamic spheroidal body."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field.\""

    refute normalized =~ "Modern geodesy integrates"
    refute normalized =~ "describes how"
  end

  test "verification_claim_text prefers later quoted definition bodies after inline paper-ref clauses" do
    summary =
      "Modern geodesy defines Earth's shape as a three-dimensional figure requiring multiple independent space techniques to characterize, with the Global Geodetic Observing System integrating \"all geodetic observations\" to produce consistent parameters for the \"System Earth.\" [Paper 12] states that geodesy determines \"the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field\" using space techniques, terrestrial methods, and global reference systems."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "\"the geometric shape of the earth and its kinematics, the variations of earth rotation, and the earth's gravity field\""

    refute normalized =~ "all geodetic observations"
    refute normalized =~ "System Earth"
  end

  test "verification_claim_text falls back to the substantive sentence when citation marker is isolated" do
    summary =
      "The International Terrestrial Reference Frame (ITRF2008) is constructed from four independent space geodetic techniques—VLBI, SLR, GPS, and DORIS—spanning 12.5 to 29 years of observations, with its origin defined as Earth's center of mass and positions defined in three-dimensional X, Y, Z coordinates. The scale agreement between VLBI and SLR solutions is 1.05 ± 0.13 ppb (approximately 6.6 mm at the equator), with origin stability at the 1 cm level over decades. This millimeter-precision three-dimensional reference frame, validated by multiple independent measurement systems, is only mathematically coherent for a roughly spherical body—such precision would be impossible on a flat plane, which lacks a center of mass toward which satellites could orbit. [Paper 10]"

    normalized = Investigate.verification_claim_text(summary)

    assert normalized ==
             "This millimeter-precision three-dimensional reference frame, validated by multiple independent measurement systems, is only mathematically coherent for a roughly spherical body—such precision would be impossible on a flat plane, which lacks a center of mass toward which satellites could orbit."
  end

  test "verification_claim_text drops later paper clauses from the selected citation sentence" do
    summary =
      "Local flatness approximations are routinely employed in geodetic and engineering calculations, demonstrating practical utility of flat-Earth models at certain scales. [Paper 1] describes elastic dislocation models using \"homogeneous and layered half-spaces\"—flat-plane approximations—for calculating earthquake deformations, while [Paper 12] notes that terrestrial geodetic techniques serve \"regional and local applications.\" These flat-plane mathematical frameworks produce accurate results at local scales, which is consistent with a surface that appears flat to human-scale observation."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized =~ "elastic dislocation models using"
    assert normalized =~ "\"homogeneous and layered half-spaces\""
    refute normalized =~ "regional and local applications"
    refute normalized =~ "while"
  end

  test "verification_claim_text keeps vs abbreviations inside the cited sentence" do
    summary =
      "The extreme precision required in modern geodetic measurements reveals that Earth's shape is a model-dependent construct rather than a directly observed fact. [Paper 10] reports that the International Terrestrial Reference Frame achieves only centimeter-level accuracy and undergoes continual refinement, with millimeter-scale discrepancies between successive reference frames (ITRF2005 vs. ITRF2008 showing translation differences of −0.5, −0.9, and −4.7 mm). [Paper 3] confirms that geodesy is \"striving to increase the level of accuracy by a factor of ten,\" indicating the Earth's precise shape remains an actively refined estimate rather than a directly verifiable observation."

    normalized = Investigate.verification_claim_text(summary)

    assert normalized =~ "ITRF2005 vs. ITRF2008"
    assert normalized =~ "−4.7 mm)."
    refute normalized =~ "striving to increase the level of accuracy"
  end

  test "normalized_search_topic strips wrapper phrasing from manual eval prompts" do
    assert Investigate.normalized_search_topic("examine claims that the earth is flat") ==
             "the earth is flat"

    assert Investigate.normalized_search_topic("Investigate whether creatine helps cognition") ==
             "creatine helps cognition"

    assert Investigate.normalized_search_topic("cross-check whether the earth is flat") ==
             "the earth is flat"

    assert Investigate.normalized_search_topic("re-evaluate the claim that the earth is flat") ==
             "the earth is flat"

    assert Investigate.normalized_search_topic("map the evidence on whether the earth is flat") ==
             "the earth is flat"

    assert Investigate.normalized_search_topic("triage whether the earth is flat") ==
             "the earth is flat"
  end

  test "search_query_plan uses general evidence queries for non-clinical claims" do
    plan =
      Investigate.search_query_plan("examine claims that the earth is flat", ["earth", "flat"])

    assert plan.normalized_topic == "the earth is flat"
    assert plan.profile == :general
    assert plan.claim_family == :planetary_shape
    assert plan.evidence_profile.kind == :planetary_shape

    ss_queries = Enum.map(plan.ss_queries, fn {_label, query, _opts} -> query end)
    oa_queries = Enum.map(plan.oa_queries, fn {_label, query, _opts} -> query end)

    assert "earth curvature measurement" in ss_queries
    assert "earth geodesy" in ss_queries
    assert "earth satellite observation" in oa_queries
    assert plan.evidence_profile.semantic_seed == "earth curvature measurement"
    refute "the earth is flat" in ss_queries

    refute Enum.any?(
             ss_queries ++ oa_queries,
             &String.contains?(&1, "randomized controlled trial")
           )

    refute Enum.any?(ss_queries ++ oa_queries, &String.contains?(&1, "placebo controlled trial"))
    refute Enum.any?(ss_queries ++ oa_queries, &String.contains?(&1, "Cochrane review"))
  end

  test "search_query_plan keeps clinical intervention queries for treatment claims" do
    plan =
      Investigate.search_query_plan(
        "creatine supplementation improves muscular strength in resistance training",
        ["creatine", "supplementation", "muscular", "strength"]
      )

    assert plan.profile == :clinical_intervention
    assert plan.claim_family == :clinical_intervention

    queries =
      Enum.map(plan.ss_queries ++ plan.oa_queries, fn {_label, query, _opts} -> query end)

    assert Enum.any?(queries, &String.contains?(&1, "systematic review"))
    assert Enum.any?(queries, &String.contains?(&1, "randomized controlled trial"))
    assert Enum.any?(queries, &String.contains?(&1, "placebo controlled trial"))
  end

  test "search_query_plan uses observational queries for health-effect claims without trials" do
    plan =
      Investigate.search_query_plan(
        "vaccines cause autism",
        ["vaccines", "autism"]
      )

    assert plan.profile == :health_claim
    assert plan.claim_family == :health_effect

    queries =
      Enum.map(plan.ss_queries ++ plan.oa_queries, fn {_label, query, _opts} -> query end)

    assert Enum.any?(queries, &String.contains?(&1, "cohort study"))
    assert Enum.any?(queries, &String.contains?(&1, "case-control study"))
    refute Enum.any?(queries, &String.contains?(&1, "placebo controlled trial"))
    refute Enum.any?(queries, &String.contains?(&1, "randomized controlled trial"))
  end

  test "rerank_retrieval_candidates demotes discourse-heavy papers for general claims" do
    plan =
      Investigate.search_query_plan("examine claims that the earth is flat", ["earth", "flat"])

    reranked =
      Investigate.rerank_retrieval_candidates(
        [
          %{
            title: "The Flat Transmission Spectrum of a Super-Earth Exoplanet",
            abstract:
              "Atmospheric spectroscopy of an exoplanet with a flat transmission spectrum."
          },
          %{
            title: "Flat Earth belief and misinformation on social media",
            abstract: "A discourse analysis of ideology and public attitudes."
          },
          %{
            title: "Satellite measurement of Earth curvature from geodetic orbit data",
            abstract: "Orbital observation and geodetic measurements constrain Earth curvature."
          }
        ],
        plan
      )

    assert hd(reranked).title ==
             "Satellite measurement of Earth curvature from geodetic orbit data"

    assert Enum.at(reranked, 2).title == "Flat Earth belief and misinformation on social media"
  end

  test "rerank_retrieval_candidates favors stable direct-evidence core over niche direct matches" do
    plan =
      Investigate.search_query_plan("cross-check whether the earth is flat", ["earth", "flat"])

    reranked =
      Investigate.rerank_retrieval_candidates(
        [
          %{
            title: "Spheroidal modes excited during the 1991 Pinatubo eruption",
            abstract:
              "Seismic observations identified spheroidal modes in a volcanic eruption context.",
            citation_count: 85
          },
          %{
            title: "International Terrestrial Reference Frame from VLBI, SLR, GPS, and DORIS",
            abstract:
              "A geodetic terrestrial reference frame combines VLBI, SLR, GPS, and DORIS into a stable three-dimensional Earth reference frame.",
            citation_count: 1165
          },
          %{
            title: "Flat Earth belief and misinformation on social media",
            abstract: "A discourse analysis of ideology and public attitudes.",
            citation_count: 24
          }
        ],
        plan
      )

    assert hd(reranked).title ==
             "International Terrestrial Reference Frame from VLBI, SLR, GPS, and DORIS"

    assert Enum.at(reranked, 1).title ==
             "Spheroidal modes excited during the 1991 Pinatubo eruption"

    assert Enum.at(reranked, 2).title == "Flat Earth belief and misinformation on social media"
  end
end
