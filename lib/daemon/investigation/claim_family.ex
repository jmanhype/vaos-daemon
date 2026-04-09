defmodule Daemon.Investigation.ClaimFamily do
  @moduledoc """
  Declarative claim-family registry for family-specific retrieval hints and
  verification-claim normalization.

  The investigate loop stays generic. Claim families only provide:
  - topic wrapper normalization
  - evidence-oriented query rewrites
  - rerank stability hints
  - narrowly scoped claim-normalization rewrites for recurring paper families
  """

  @search_relation_words ~w(cause causes caused causing improve improves improved improving
    prevent prevents prevented preventing effective effectiveness efficacy associated
    association linked links linking relation relationship claims claim whether if)
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
      kind: :planetary_shape,
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
  def evidence_profile(topic, keywords, terms)
      when is_binary(topic) and is_list(keywords) and is_list(terms) do
    fallback_query = keyword_query_topic(topic, keywords)

    Enum.find_value(@family_specs, fn spec ->
      build_profile(spec, terms, fallback_query)
    end)
  end

  def evidence_profile(_topic, _keywords, _terms), do: nil

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

  defp build_profile(spec, terms, fallback_query) do
    if matches_term_sets?(terms, spec.required_term_sets) do
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

      %{
        kind: spec.kind,
        subject_terms: subject_terms,
        semantic_seed: render_template(spec.semantic_seed_template, subject_query),
        required_terms: spec.required_terms,
        stable_terms: spec.stable_terms,
        direct_queries: render_direct_queries(spec.direct_query_templates, subject_query)
      }
    end
  end

  defp matches_term_sets?(terms, required_term_sets) do
    Enum.all?(required_term_sets, fn term_set ->
      Enum.any?(terms, &(&1 in term_set))
    end)
  end

  defp render_direct_queries(templates, subject_query) do
    Enum.map(templates, fn {label, query_template, opts} ->
      {label, render_template(query_template, subject_query), opts}
    end)
  end

  defp render_template(template, subject_query) do
    String.replace(template, "{subject}", subject_query)
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
      Enum.any?(spec.verification_trigger_terms, fn trigger ->
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

  defp search_topic_wrappers do
    [
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+(?:whether|if)\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+(?:whether|if)\s+/i,
      ~r/^\s*map\s+the\s+evidence\s+(?:on|for)\s+/i,
      ~r/^\s*(?:cross[\s-]*check|re[\s-]*evaluate|triage)\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check)\s+(?:the\s+)?claims?\s+that\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check)\s+(?:whether|if)\s+/i,
      ~r/^\s*(?:investigate|review|examine|assess|evaluate|analy[sz]e|test|check)\s+/i
    ]
  end
end
