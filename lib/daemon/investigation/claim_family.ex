defmodule Daemon.Investigation.ClaimFamily do
  @moduledoc """
  Declarative claim-family registry for family-specific retrieval hints and
  verification-claim normalization.

  The investigate loop stays generic. Claim families only provide:
  - topic wrapper normalization
  - query-family selection
  - evidence-oriented query rewrites
  - rerank stability hints
  - narrowly scoped claim-normalization rewrites for recurring paper families
  """

  @search_relation_words ~w(cause causes caused causing improve improves improved improving
    prevent prevents prevented preventing effective effectiveness efficacy associated
    association linked links linking relation relationship claims claim whether if)
  @clinical_intervention_terms ~w(supplement supplements supplementation treatment treatments
    therapy therapies drug drugs medication medications placebo homeopathy dose dosing
    intervention interventions)
  @clinical_outcome_terms ~w(strength muscular endurance performance sleep insomnia recovery
    cognition cognitive memory pain fatigue mood anxiety depression function functional
    mobility balance symptoms symptom quality wellbeing well-being blood pressure glucose
    cholesterol weight bmi)
  @health_claim_terms ~w(health disease diseases disorder disorders symptom symptoms
    cancer autism vaccine vaccines smoking smoker smokers lung lungs muscular strength
    training resistance cognition mortality survival risk risks pain pains)
  @celestial_body_terms ~w(earth world globe planet planets planetary moon moons mars venus
    mercury jupiter saturn uranus neptune)
  @shape_property_terms ~w(flat round spherical sphere curved curvature globe globular oblate)
  @planetary_shape_required_terms ~w(curvature geodesy geodetic satellite orbital orbit gravity
    circumnavigation horizon navigation surveying ellipsoid spheroid spherical)
  @planetary_shape_stable_terms ~w(geodesy geodetic gravity geoid ellipsoid spheroid spherical
    curvature reference frame terrestrial gps gnss satellite orbital orbit
    vlbi slr doris gravimetry surveying navigation)
  @planetary_shape_query_templates [
    {:curvature, "{subject} curvature measurement", []},
    {:geodesy, "{subject} geodesy", []},
    {:satellite, "{subject} satellite observation", []},
    {:gravity, "{subject} gravity spheroid", []},
    {:navigation, "{subject} circumnavigation navigation", []},
    {:surveying, "{subject} geodetic surveying", []}
  ]
  @planetary_shape_verification_triggers @planetary_shape_stable_terms ++
                                           ~w(oblate spheroid ellipsoid gravitation)

  @family_specs [
    %{
      kind: :clinical_intervention,
      profile: :clinical_intervention,
      required_term_sets: [@clinical_intervention_terms],
      any_term_sets: [@health_claim_terms, @clinical_outcome_terms],
      query_templates: %{
        ss: [
          {:topic, "{topic}", []},
          {:reviews, "systematic review {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:rct, "randomized controlled trial {keyword_topic}", []}
        ],
        oa: [
          {:topic, "{topic}", []},
          {:reviews, "systematic review {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:meta_analysis, "meta-analysis {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:cochrane, "Cochrane review {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:placebo, "{keyword_topic} placebo controlled trial", []},
          {:guideline, "clinical guideline {keyword_topic}", []},
          {:rct, "randomized controlled trial {keyword_topic}", []}
        ]
      }
    },
    %{
      kind: :health_effect,
      profile: :health_claim,
      required_term_sets: [@health_claim_terms],
      query_templates: %{
        ss: [
          {:topic, "{topic}", []},
          {:reviews, "systematic review {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:cohort, "cohort study {keyword_topic}", []}
        ],
        oa: [
          {:topic, "{topic}", []},
          {:reviews, "systematic review {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:meta_analysis, "meta-analysis {keyword_topic}",
           [publication_types: "Review,MetaAnalysis", type: "review"]},
          {:cohort, "cohort study {keyword_topic}", []},
          {:case_control, "case-control study {keyword_topic}", []},
          {:observational, "observational study {keyword_topic}", []},
          {:consensus, "scientific consensus {keyword_topic}", []}
        ]
      }
    },
    %{
      kind: :planetary_shape,
      profile: :general,
      required_term_sets: [@celestial_body_terms, @shape_property_terms],
      subject_term_pool: @celestial_body_terms,
      subject_term_exclusions: @shape_property_terms ++ @search_relation_words,
      semantic_seed_template: "{subject} curvature measurement",
      required_terms: @planetary_shape_required_terms,
      stable_terms: @planetary_shape_stable_terms,
      direct_query_templates: @planetary_shape_query_templates,
      verification_normalizer: :planetary_shape,
      verification_trigger_terms: @planetary_shape_verification_triggers
    }
  ]

  @doc false
  def normalize_topic(topic) do
    original =
      topic
      |> to_string()
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.trim_trailing("?")
      |> String.trim_trailing("!")

    normalized =
      Enum.reduce(search_topic_wrappers(), original, fn pattern, acc ->
        String.replace(acc, pattern, "")
      end)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if normalized == "", do: original, else: normalized
  end

  @doc false
  def match(topic, keywords, terms)
      when is_binary(topic) and is_list(keywords) and is_list(terms) do
    fallback_query = keyword_query_topic(topic, keywords)
    keyword_topic = keyword_query_topic(topic, keywords)

    Enum.find_value(@family_specs, fn spec ->
      build_match(spec, topic, keyword_topic, terms, fallback_query)
    end)
  end

  def match(_topic, _keywords, _terms), do: nil

  @doc false
  def search_profile(topic, keywords, terms) do
    case match(topic, keywords, terms) do
      %{profile: profile} -> profile
      _ -> :general
    end
  end

  @doc false
  def evidence_profile(topic, keywords, terms) do
    case match(topic, keywords, terms) do
      %{evidence_profile: evidence_profile} -> evidence_profile
      _ -> nil
    end
  end

  @doc false
  def search_queries(topic, keywords, terms, evidence_profile) do
    keyword_topic = keyword_query_topic(topic, keywords)

    case match(topic, keywords, terms) do
      %{query_templates: query_templates} ->
        {
          render_query_templates(query_templates[:ss] || [], topic, keyword_topic),
          render_query_templates(query_templates[:oa] || [], topic, keyword_topic)
        }

      %{profile: :general} ->
        general_search_queries(topic, keyword_topic, evidence_profile)

      _ ->
        general_search_queries(topic, keyword_topic, evidence_profile)
    end
  end

  @doc false
  def normalize_verification_claim(summary) when is_binary(summary) do
    case family_for_verification(summary) do
      %{verification_normalizer: :planetary_shape} ->
        summary
        |> prefer_gravitation_shape_quote()
        |> prefer_ought_shape_quote()

      _ ->
        summary
    end
  end

  def normalize_verification_claim(summary), do: summary

  defp build_match(spec, topic, keyword_topic, terms, fallback_query) do
    if matches_spec?(spec, terms) do
      Map.merge(
        %{
          kind: spec.kind,
          profile: spec.profile
        },
        build_match_payload(spec, topic, keyword_topic, terms, fallback_query)
      )
    end
  end

  defp build_match_payload(
         %{profile: :general} = spec,
         _topic,
         _keyword_topic,
         terms,
         fallback_query
       ) do
    subject_terms =
      terms
      |> Enum.reject(&(&1 in spec.subject_term_exclusions))
      |> Enum.filter(&(&1 in spec.subject_term_pool))
      |> Enum.uniq()

    subject_query =
      case subject_terms do
        [] -> fallback_query
        _ -> Enum.join(subject_terms, " ")
      end

    evidence_profile = %{
      kind: spec.kind,
      subject_terms: subject_terms,
      semantic_seed: render_template(spec.semantic_seed_template, subject_query),
      required_terms: spec.required_terms,
      stable_terms: spec.stable_terms,
      direct_queries: render_direct_queries(spec.direct_query_templates, subject_query)
    }

    %{evidence_profile: evidence_profile}
  end

  defp build_match_payload(spec, _topic, _keyword_topic, _terms, _fallback_query) do
    %{
      query_templates: Map.get(spec, :query_templates)
    }
  end

  defp matches_spec?(spec, terms) do
    matches_term_sets?(terms, Map.get(spec, :required_term_sets, [])) and
      matches_any_term_sets?(terms, Map.get(spec, :any_term_sets))
  end

  defp matches_term_sets?(terms, required_term_sets) do
    Enum.all?(required_term_sets, fn term_set ->
      Enum.any?(terms, &(&1 in term_set))
    end)
  end

  defp matches_any_term_sets?(_terms, nil), do: true
  defp matches_any_term_sets?(_terms, []), do: true

  defp matches_any_term_sets?(terms, any_term_sets) do
    Enum.any?(any_term_sets, fn term_set ->
      Enum.any?(terms, &(&1 in term_set))
    end)
  end

  defp render_direct_queries(templates, subject_query) do
    Enum.map(templates, fn {label, query_template, opts} ->
      {label, render_template(query_template, subject_query), opts}
    end)
  end

  defp render_query_templates(templates, topic, keyword_topic) do
    Enum.map(templates, fn {label, query_template, opts} ->
      {label, render_query_template(query_template, topic, keyword_topic), opts}
    end)
  end

  defp render_template(template, subject_query) do
    String.replace(template, "{subject}", subject_query)
  end

  defp render_query_template(template, topic, keyword_topic) do
    template
    |> String.replace("{topic}", topic)
    |> String.replace("{keyword_topic}", keyword_topic)
  end

  defp keyword_query_topic(topic, keywords) do
    case keywords do
      [] -> topic
      _ -> Enum.join(keywords, " ")
    end
  end

  defp family_for_verification(summary) do
    search_text = normalize_search_text(summary)

    Enum.find(@family_specs, fn spec ->
      spec
      |> Map.get(:verification_trigger_terms, [])
      |> Enum.any?(fn trigger ->
        String.contains?(search_text, normalize_search_text(trigger))
      end)
    end)
  end

  defp prefer_ought_shape_quote(summary) when is_binary(summary) do
    case Regex.run(
           ~r/(?:^|["“])(?:the\s+[^"”]{0,80}?\s+)?ought\s+to\s+be\s+of\s+the\s+form\s+of\s+an?\s+([^"”]+)(?:["”]|$)/iu,
           summary,
           capture: :all_but_first
         ) do
      [core] ->
        ~s("#{String.trim(core)}")

      _ ->
        summary
    end
  end

  defp prefer_ought_shape_quote(summary), do: summary

  defp prefer_gravitation_shape_quote(summary) when is_binary(summary) do
    if Regex.match?(~r/\b(?:assuming|assume|without\s+making|merely\s+assuming)\b/iu, summary) do
      case Regex.scan(~r/["“]([^"”]*oblate spheroid[^"”]*)["”]/iu, summary,
             capture: :all_but_first
           ) do
        [[quoted] | _] ->
          ~s("#{String.trim(quoted)}")

        _ ->
          summary
      end
    else
      summary
    end
  end

  defp prefer_gravitation_shape_quote(summary), do: summary

  defp normalize_search_text(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp general_search_queries(_topic, keyword_topic, %{direct_queries: direct_queries})
       when is_list(direct_queries) and direct_queries != [] do
    ss_queries = Enum.take(direct_queries, 3)

    oa_queries =
      direct_queries ++
        [
          {:keywords, keyword_topic, []},
          {:evidence, "#{keyword_topic} empirical evidence", []}
        ]

    {ss_queries, oa_queries}
  end

  defp general_search_queries(topic, keyword_topic, _evidence_profile) do
    {
      [
        {:topic, topic, []},
        {:keywords, keyword_topic, []},
        {:evidence, "#{keyword_topic} empirical evidence", []}
      ],
      [
        {:topic, topic, []},
        {:keywords, keyword_topic, []},
        {:evidence, "#{keyword_topic} empirical evidence", []},
        {:observation, "#{keyword_topic} direct observation", []},
        {:measurement, "#{keyword_topic} measurement data", []},
        {:evaluation, "#{keyword_topic} physical evidence", []},
        {:analysis, "#{keyword_topic} empirical test", []}
      ]
    }
  end

  defp search_topic_wrappers do
    [
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+(?:whether|if)\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+(?:whether|if)\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+/i,
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check|probe|verify|determine|establish)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check|probe|verify|determine|establish)\s+(?:whether|if)\s+/i,
      ~r/^\s*(?:find\s+out|figure\s+out)\s+(?:whether|if)\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check|probe|verify|determine|establish)\s+/i
    ]
  end
end
