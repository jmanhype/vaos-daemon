defmodule Daemon.Investigation.EvidencePlanner do
  @moduledoc """
  Budgeted evidence-plan planner for investigate.

  Instead of routing directly from a topic box to one fixed retrieval shape,
  the planner proposes several competing evidence-operation plans, scores them
  cheaply, and selects one as the default retrieval path.

  This first slice keeps the scoring deterministic and local. It does not yet
  run a network probe for every candidate plan.
  """

  @type query :: {atom(), String.t(), keyword()}
  @type evidence_signatures :: %{
          measurement_signature: boolean(),
          physical_geometry_signature: boolean(),
          intervention_signature: boolean(),
          health_effect_signature: boolean(),
          review_signature: boolean(),
          consensus_signature: boolean()
        }
  @type plan :: %{
          mode: atom(),
          profile: atom(),
          heuristic_score: float(),
          probe_score: float() | nil,
          selection_score: float(),
          rationale: String.t(),
          semantic_seed: String.t(),
          ss_queries: [query()],
          oa_queries: [query()],
          evidence_profile: map() | nil,
          probe: map() | nil
        }

  @candidate_order %{
    measurement: 1,
    randomized_intervention: 2,
    observational: 3,
    systematic_review: 4,
    consensus: 5,
    general_empirical: 6
  }

  @review_opts [publication_types: "Review,MetaAnalysis", type: "review"]
  @guideline_terms ~w(guideline guidelines consensus recommendation recommendations position statement statements)
  @measurement_terms ~w(measurement measurements observe observed observation observations physical empirical curvature geodesy gravity orbit orbital satellite surveying)
  @shape_geometry_terms ~w(flat round spherical sphere spheroid oblate prolate curved curvature geometry geometric geodesy geodetic ellipsoid ellipsoidal globe globular)
  @physical_subject_terms ~w(earth planet planets moon moons mars venus mercury jupiter saturn uranus neptune world worlds globe globes body bodies surface surfaces)
  @intervention_terms ~w(intervention interventions treatment treatments therapy therapies supplement supplements supplementation placebo randomized randomised trial trials drug drugs dose dosing medication medications)
  @administration_terms ~w(intake ingestion ingest ingested consume consumes consumed consuming administration administered administering)
  @performance_context_terms ~w(endurance performance time-trial cycling cyclist cyclists triathlon triathlete triathletes sprint sprinting aerobic anaerobic race racing competition competitive athletic athletics sport sports exercise exercising pace pacing power output)
  @clinical_outcome_terms ~w(strength muscular endurance performance sleep insomnia recovery
    cognition cognitive memory pain fatigue mood anxiety depression function functional
    mobility balance symptoms symptom quality wellbeing well-being blood pressure glucose
    cholesterol weight bmi outcome outcomes result results race racing competition
    competitive athletic athletics sport sports exercise exercising time-trial pace pacing
    power output)
  @health_effect_terms ~w(cause causes caused causing risk risks associated association linked links smoking smoker smokers vaccine vaccines autism cancer disease diseases mortality incidence prevalence outcome outcomes)
  @causal_terms ~w(cause causes caused causing risk risks associated association linked links mortality incidence prevalence)

  @doc false
  def plan(topic, keywords, terms)
      when is_binary(topic) and is_list(keywords) and is_list(terms) do
    plan(topic, keywords, terms, nil)
  end

  @doc false
  def plan(topic, keywords, terms, evidence_profile)
      when is_binary(topic) and is_list(keywords) and is_list(terms) do
    keyword_topic = keyword_query_topic(topic, keywords)
    evidence_signatures = infer_evidence_signatures(topic, terms)

    candidates =
      candidate_modes()
      |> Enum.map(
        &build_candidate(&1, topic, keyword_topic, evidence_profile, evidence_signatures)
      )
      |> Enum.map(&score_candidate(&1, topic, terms, evidence_signatures))
      |> Enum.sort_by(fn candidate ->
        {-candidate.selection_score, Map.fetch!(@candidate_order, candidate.mode)}
      end)
      |> Enum.take(4)

    selected =
      candidates
      |> List.first()
      |> case do
        nil ->
          score_candidate(
            build_candidate(
              :general_empirical,
              topic,
              keyword_topic,
              evidence_profile,
              evidence_signatures
            ),
            topic,
            terms,
            evidence_signatures
          )

        candidate ->
          candidate
      end

    %{
      selected: selected,
      candidates: candidates,
      evidence_signatures: evidence_signatures
    }
  end

  def plan(topic, keywords, _terms, evidence_profile) do
    keyword_topic = keyword_query_topic(topic, keywords)
    evidence_signatures = infer_evidence_signatures(topic, [])

    selected =
      build_candidate(
        :general_empirical,
        topic,
        keyword_topic,
        evidence_profile,
        evidence_signatures
      )

    %{selected: selected, candidates: [selected], evidence_signatures: evidence_signatures}
  end

  @doc false
  def plan(topic, keywords, terms, _claim_family, evidence_profile)
      when is_binary(topic) and is_list(keywords) and is_list(terms) do
    plan(topic, keywords, terms, evidence_profile)
  end

  @doc false
  def summary(%{} = plan) do
    %{
      mode: plan.mode,
      profile: plan.profile,
      heuristic_score: round_score(plan.heuristic_score),
      probe_score: round_score(plan.probe_score),
      selection_score: round_score(plan.selection_score),
      rationale: plan.rationale,
      semantic_seed: plan.semantic_seed,
      probe: summarize_probe(plan.probe)
    }
  end

  @doc false
  def candidate_summaries(candidates) when is_list(candidates) do
    Enum.map(candidates, &summary/1)
  end

  @doc false
  def apply_probe_results(candidates, probe_results) when is_list(candidates) do
    results_by_mode =
      Map.new(probe_results, fn result ->
        {Map.fetch!(result, :mode), result}
      end)

    candidates =
      candidates
      |> Enum.map(fn candidate ->
        apply_probe_result(candidate, Map.get(results_by_mode, candidate.mode))
      end)
      |> Enum.sort_by(fn candidate ->
        {-candidate.selection_score, Map.fetch!(@candidate_order, candidate.mode)}
      end)

    %{
      selected: List.first(candidates),
      candidates: candidates
    }
  end

  defp candidate_modes do
    [
      :measurement,
      :randomized_intervention,
      :observational,
      :systematic_review,
      :consensus,
      :general_empirical
    ]
  end

  defp build_candidate(:measurement, topic, keyword_topic, evidence_profile, _evidence_signatures) do
    {ss_queries, oa_queries, semantic_seed} =
      case evidence_profile do
        %{direct_queries: direct_queries, semantic_seed: seed}
        when is_list(direct_queries) and direct_queries != [] and is_binary(seed) ->
          {
            Enum.take(direct_queries, 3),
            direct_queries ++
              [
                {:keywords, keyword_topic, []},
                {:evidence, "#{keyword_topic} empirical evidence", []}
              ],
            seed
          }

        _ ->
          {
            [
              {:topic, topic, []},
              {:measurement, "#{keyword_topic} measurement data", []},
              {:observation, "#{keyword_topic} direct observation", []}
            ],
            [
              {:topic, topic, []},
              {:measurement, "#{keyword_topic} measurement data", []},
              {:observation, "#{keyword_topic} direct observation", []},
              {:evaluation, "#{keyword_topic} physical evidence", []},
              {:analysis, "#{keyword_topic} empirical test", []}
            ],
            topic
          }
      end

    %{
      mode: :measurement,
      profile: :general,
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor measurement and observation evidence",
      semantic_seed: semantic_seed,
      ss_queries: ss_queries,
      oa_queries: oa_queries,
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp build_candidate(
         :randomized_intervention,
         topic,
         keyword_topic,
         evidence_profile,
         _evidence_signatures
       ) do
    performance_keyword_topic = performance_query_topic(topic, keyword_topic)

    performance_queries =
      case performance_keyword_topic do
        nil ->
          []

        expanded_topic ->
          [
            {:performance_placebo, "#{expanded_topic} placebo controlled trial", []},
            {:performance_rct, "randomized controlled trial #{expanded_topic}", []},
            {:performance_reviews, "systematic review #{expanded_topic}", @review_opts}
          ]
      end

    %{
      mode: :randomized_intervention,
      profile: :clinical_intervention,
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor trial and placebo evidence",
      semantic_seed: keyword_topic,
      ss_queries:
        [
          {:topic, topic, []}
        ] ++
          performance_queries ++
          [
            {:rct, "randomized controlled trial #{keyword_topic}", []},
            {:placebo, "#{keyword_topic} placebo controlled trial", []},
            {:reviews, "systematic review #{keyword_topic}", @review_opts}
          ],
      oa_queries:
        [
          {:topic, topic, []}
        ] ++
          performance_queries ++
          [
            {:placebo, "#{keyword_topic} placebo controlled trial", []},
            {:rct, "randomized controlled trial #{keyword_topic}", []},
            {:reviews, "systematic review #{keyword_topic}", @review_opts},
            {:meta_analysis, "meta-analysis #{keyword_topic}", @review_opts},
            {:guideline, "clinical guideline #{keyword_topic}", []}
          ],
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp build_candidate(
         :observational,
         topic,
         keyword_topic,
         evidence_profile,
         _evidence_signatures
       ) do
    %{
      mode: :observational,
      profile: :health_claim,
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor cohort and case-control evidence",
      semantic_seed: keyword_topic,
      ss_queries: [
        {:topic, topic, []},
        {:cohort, "cohort study #{keyword_topic}", []},
        {:observational, "observational study #{keyword_topic}", []}
      ],
      oa_queries: [
        {:topic, topic, []},
        {:cohort, "cohort study #{keyword_topic}", []},
        {:case_control, "case-control study #{keyword_topic}", []},
        {:observational, "observational study #{keyword_topic}", []},
        {:registry, "registry study #{keyword_topic}", []}
      ],
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp build_candidate(
         :systematic_review,
         topic,
         keyword_topic,
         evidence_profile,
         evidence_signatures
       ) do
    %{
      mode: :systematic_review,
      profile: review_profile(evidence_signatures),
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor synthesis and review evidence",
      semantic_seed: keyword_topic,
      ss_queries: [
        {:topic, topic, []},
        {:reviews, "systematic review #{keyword_topic}", @review_opts},
        {:meta_analysis, "meta-analysis #{keyword_topic}", @review_opts}
      ],
      oa_queries: [
        {:topic, topic, []},
        {:reviews, "systematic review #{keyword_topic}", @review_opts},
        {:meta_analysis, "meta-analysis #{keyword_topic}", @review_opts},
        {:umbrella, "umbrella review #{keyword_topic}", @review_opts},
        {:review, "review #{keyword_topic}", @review_opts}
      ],
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp build_candidate(:consensus, topic, keyword_topic, evidence_profile, _evidence_signatures) do
    %{
      mode: :consensus,
      profile: :general,
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor consensus, guidance, and authoritative summaries",
      semantic_seed: keyword_topic,
      ss_queries: [
        {:topic, topic, []},
        {:consensus, "scientific consensus #{keyword_topic}", []},
        {:reviews, "review #{keyword_topic}", @review_opts}
      ],
      oa_queries: [
        {:topic, topic, []},
        {:consensus, "scientific consensus #{keyword_topic}", []},
        {:guideline, "guideline #{keyword_topic}", []},
        {:position, "position statement #{keyword_topic}", []},
        {:review, "review #{keyword_topic}", @review_opts}
      ],
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp build_candidate(
         :general_empirical,
         topic,
         keyword_topic,
         evidence_profile,
         _evidence_signatures
       ) do
    %{
      mode: :general_empirical,
      profile: :general,
      heuristic_score: 0.0,
      probe_score: nil,
      selection_score: 0.0,
      rationale: "favor broad empirical search without committing to one evidence mode",
      semantic_seed: topic,
      ss_queries: [
        {:topic, topic, []},
        {:keywords, keyword_topic, []},
        {:evidence, "#{keyword_topic} empirical evidence", []}
      ],
      oa_queries: [
        {:topic, topic, []},
        {:keywords, keyword_topic, []},
        {:evidence, "#{keyword_topic} empirical evidence", []},
        {:observation, "#{keyword_topic} direct observation", []},
        {:analysis, "#{keyword_topic} empirical test", []}
      ],
      evidence_profile: evidence_profile,
      probe: nil
    }
  end

  defp review_profile(%{intervention_signature: true}), do: :clinical_intervention
  defp review_profile(%{health_effect_signature: true}), do: :health_claim

  defp review_profile(_evidence_signatures), do: :general

  defp score_candidate(candidate, topic, terms, evidence_signatures) do
    intervention_signature = Map.get(evidence_signatures, :intervention_signature, false)

    generic_bias =
      case candidate.mode do
        :measurement ->
          if(Map.get(evidence_signatures, :measurement_signature, false), do: 5.5, else: 0.5)

        :randomized_intervention ->
          if(intervention_signature, do: 5.0, else: 0.5)

        :observational ->
          if(Map.get(evidence_signatures, :health_effect_signature, false), do: 5.0, else: 0.5)

        :systematic_review ->
          cond do
            intervention_signature -> 4.0
            Map.get(evidence_signatures, :health_effect_signature, false) -> 3.5
            Map.get(evidence_signatures, :review_signature, false) -> 2.0
            true -> 0.5
          end

        :consensus ->
          cond do
            Map.get(evidence_signatures, :consensus_signature, false) -> 3.0
            Map.get(evidence_signatures, :health_effect_signature, false) -> 2.5
            true -> 0.5
          end

        :general_empirical ->
          2.0
      end

    lexical_bias =
      case candidate.mode do
        :measurement ->
          term_hits(terms, @measurement_terms) * 0.8

        :randomized_intervention ->
          term_hits(terms, @intervention_terms ++ @administration_terms) * 0.8 +
            term_hits(terms, @clinical_outcome_terms) * 0.35 +
            if(intervention_signature, do: 1.5, else: 0.0)

        :observational ->
          term_hits(terms, @health_effect_terms) * 0.6

        :systematic_review ->
          term_hits(terms, @guideline_terms ++ @health_effect_terms ++ @clinical_outcome_terms) *
            0.2 +
            if(intervention_signature, do: 0.4, else: 0.0)

        :consensus ->
          term_hits(terms, @guideline_terms) * 0.9

        :general_empirical ->
          max(length(terms) - 1, 0) * 0.2
      end

    score = Float.round(1.0 + generic_bias + lexical_bias, 2)

    rationale =
      candidate.mode
      |> rationale_parts(topic, terms, evidence_signatures)
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.join("; ")

    %{candidate | heuristic_score: score, selection_score: score, rationale: rationale}
  end

  defp apply_probe_result(candidate, nil), do: candidate

  defp apply_probe_result(candidate, probe_result) do
    raw_empirical_score =
      case Map.get(probe_result, :status) do
        :ok -> Map.get(probe_result, :score)
        _ -> nil
      end

    empirical_score =
      case raw_empirical_score do
        value when is_number(value) ->
          Float.round(value + selection_probe_bonus(candidate, probe_result), 2)

        _ ->
          raw_empirical_score
      end

    selection_score =
      case empirical_score do
        value when is_number(value) ->
          Float.round(candidate.heuristic_score * 0.35 + value * 0.65, 2)

        _ ->
          candidate.heuristic_score
      end

    %{
      candidate
      | probe: probe_result,
        probe_score: raw_empirical_score,
        selection_score: selection_score
    }
  end

  defp selection_probe_bonus(
         %{profile: :clinical_intervention, mode: :randomized_intervention},
         %{
           status: :ok,
           query_label: query_label,
           relevant_papers: relevant,
           groundable_papers: groundable
         }
       )
       when query_label in [:placebo, :rct] and relevant > 0 and groundable > 0,
       do: 1.0

  defp selection_probe_bonus(_candidate, _probe_result), do: 0.0

  defp rationale_parts(mode, topic, terms, evidence_signatures) do
    base =
      case mode do
        :measurement -> ["measurement/observation route"]
        :randomized_intervention -> ["trial/placebo route"]
        :observational -> ["cohort/case-control route"]
        :systematic_review -> ["review/meta-analysis route"]
        :consensus -> ["consensus/guideline route"]
        :general_empirical -> ["broad empirical route"]
      end

    signature_hint =
      cond do
        mode == :measurement and Map.get(evidence_signatures, :physical_geometry_signature, false) ->
          ["physical geometry signature present"]

        mode == :measurement and Map.get(evidence_signatures, :measurement_signature, false) ->
          ["physical measurement signature present"]

        mode == :randomized_intervention and
            Map.get(evidence_signatures, :intervention_signature, false) ->
          ["intervention + outcome signature present"]

        mode == :observational and Map.get(evidence_signatures, :health_effect_signature, false) ->
          ["exposure/outcome signature present"]

        mode == :consensus and Map.get(evidence_signatures, :consensus_signature, false) ->
          ["consensus/guideline signature present"]

        true ->
          []
      end

    lexical_hint =
      cond do
        mode == :measurement and term_hits(terms, @measurement_terms) > 0 ->
          ["measurement terms present"]

        mode == :randomized_intervention and term_hits(terms, @intervention_terms) > 0 ->
          ["intervention terms present"]

        mode == :randomized_intervention and intervention_signature?(topic, terms) ->
          ["intervention + outcome signature present"]

        mode == :observational and term_hits(terms, @health_effect_terms) > 0 ->
          ["causal/epidemiology terms present"]

        mode == :consensus and term_hits(terms, @guideline_terms) > 0 ->
          ["consensus/guideline terms present"]

        true ->
          []
      end

    base ++ signature_hint ++ lexical_hint
  end

  defp term_hits(terms, candidates) do
    Enum.count(terms, &(&1 in candidates))
  end

  defp infer_evidence_signatures(topic, terms) when is_binary(topic) and is_list(terms) do
    intervention_signature = intervention_signature?(topic, terms)
    health_effect_signature = health_effect_signature?(topic, terms, intervention_signature)
    physical_geometry_signature = physical_geometry_signature?(terms)

    %{
      measurement_signature:
        term_hits(terms, @measurement_terms) > 0 or physical_geometry_signature,
      physical_geometry_signature: physical_geometry_signature,
      intervention_signature: intervention_signature,
      health_effect_signature: health_effect_signature,
      review_signature: review_signature?(topic, terms),
      consensus_signature: consensus_signature?(topic, terms)
    }
  end

  defp infer_evidence_signatures(_topic, _terms) do
    %{
      measurement_signature: false,
      physical_geometry_signature: false,
      intervention_signature: false,
      health_effect_signature: false,
      review_signature: false,
      consensus_signature: false
    }
  end

  defp health_effect_signature?(topic, terms, intervention_signature)
       when is_binary(topic) and is_list(terms) do
    not intervention_signature and
      (term_hits(terms, @causal_terms) > 0 or
         term_hits(terms, @health_effect_terms) >= 2 or
         Regex.match?(
           ~r/\b(cause|causes|caused|causing|risk|risks|linked|association|associated|increase|increases|decrease|decreases)\b/i,
           topic
         ))
  end

  defp health_effect_signature?(_topic, _terms, _intervention_signature), do: false

  defp physical_geometry_signature?(terms) when is_list(terms) do
    term_hits(terms, @shape_geometry_terms) > 0 and
      term_hits(terms, @physical_subject_terms ++ @measurement_terms) > 0
  end

  defp physical_geometry_signature?(_terms), do: false

  defp review_signature?(topic, terms) when is_binary(topic) and is_list(terms) do
    term_hits(terms, @guideline_terms) > 0 or
      Regex.match?(
        ~r/\b(review|reviews|meta-analysis|meta analysis|umbrella review)\b/i,
        topic
      )
  end

  defp review_signature?(_topic, _terms), do: false

  defp consensus_signature?(topic, terms) when is_binary(topic) and is_list(terms) do
    term_hits(terms, @guideline_terms) > 0 or
      Regex.match?(~r/\b(consensus|guideline|position statement|recommendation)\b/i, topic)
  end

  defp consensus_signature?(_topic, _terms), do: false

  defp intervention_signature?(topic, terms) when is_binary(topic) and is_list(terms) do
    term_hits(terms, @intervention_terms ++ @administration_terms) > 0 and
      (term_hits(terms, @clinical_outcome_terms) > 0 or
         Regex.match?(
           ~r/\b(improve|improves|improved|improving|reduce|reduces|reduced|reducing|prevent|prevents|prevented|preventing|treat|treats|treated|treating|relieve|relieves|relieved|relieving|help|helps|helped|helping|benefit|benefits|benefited|benefiting|enhance|enhances|enhanced|enhancing|increase|increases|increased|increasing|decrease|decreases|decreased|decreasing|manage|manages|managed|managing)\b/i,
           topic
         ))
  end

  defp intervention_signature?(_topic, _terms), do: false

  defp keyword_query_topic(topic, keywords) do
    case keywords do
      [] -> topic
      _ -> Enum.join(keywords, " ")
    end
  end

  defp performance_query_topic(topic, keyword_topic)
       when is_binary(topic) and is_binary(keyword_topic) do
    cond do
      String.match?(keyword_topic, ~r/\bperformance\b/i) ->
        nil

      not performance_context_topic?(topic <> " " <> keyword_topic) ->
        nil

      not String.match?(keyword_topic, ~r/\b(outcome|outcomes|result|results)\b/i) ->
        nil

      true ->
        keyword_topic
        |> String.replace(~r/\b(outcome|outcomes|result|results)\b/i, "performance")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
    end
  end

  defp performance_query_topic(_topic, _keyword_topic), do: nil

  defp performance_context_topic?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> term_hits(@performance_context_terms)
    |> Kernel.>(0)
  end

  defp performance_context_topic?(_text), do: false

  defp summarize_probe(nil), do: nil

  defp summarize_probe(probe) when is_map(probe) do
    probe
    |> Map.take([
      :status,
      :reason,
      :source,
      :fallback_from,
      :fallback,
      :query_label,
      :query,
      :raw_papers,
      :relevant_papers,
      :groundable_papers,
      :carried_papers,
      :filtered_out,
      :avg_directness,
      :score
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {key, value} when is_float(value) -> {key, Float.round(value, 2)}
      pair -> pair
    end)
  end

  defp round_score(nil), do: nil
  defp round_score(value) when is_float(value), do: Float.round(value, 2)
  defp round_score(value), do: value
end
