defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — uses the real Vaos.Ledger.Epistemic.Ledger
  GenServer for claim/evidence tracking with Bayesian confidence.

  Creates claims and evidence through the ledger API, letting IT compute
  confidence via refresh_claim. Prior knowledge search is keyword-based.
  At standard depth, still attempts ONE literature search for the strongest
  verifiable claim.
  """

  require Logger

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger
  alias Vaos.Ledger.Epistemic.Models

  # BUG 11: Use System.user_home!() instead of hardcoded path
  @ledger_path Path.join(System.user_home!(), ".openclaw/investigate_ledger.json")
  @ledger_name :investigate_ledger

  @stop_words ~w(the a an is are was were be been being have has had do does did
    will would shall should may might must can could of in to for with on at by
    from as into through during before after above below between out off over
    under again further then once here there when where why how all both each
    few more most other some such no nor not only own same so than too very it
    its this that these those and but or if while)

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "investigate"

  @impl true
  def description do
    "Investigate a claim or topic: generates structured supporting/opposing evidence, " <>
      "tracks epistemic confidence via Bayesian ledger, and stores results in the knowledge graph."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "description" => "The claim or topic to investigate"
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["standard", "deep"],
          "description" => "standard = LLM analysis + one literature search for best verifiable claim; deep = full literature enrichment"
        }
      },
      "required" => ["topic"]
    }
  end

  @impl true
  def execute(args) do
    topic = Map.get(args, "topic", "")
    depth = Map.get(args, "depth", "standard")

    if topic == "" do
      {:error, "Missing topic"}
    else
      run_investigation(topic, depth)
    end
  end

  # -- Main pipeline ---------------------------------------------------

  defp run_investigation(topic, depth) do
    # BUG 6: Start :inets/:ssl once at investigation start, not per-request in search_semantic_scholar
    :inets.start()
    :ssl.start()

    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 2. Extract keywords for prior knowledge search
    keywords = extract_keywords(topic)

    # 3. Prior knowledge search -- keyword-based, not hash-based
    # BUG 18: Check ensure_store_started return value
    case ensure_store_started() do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[investigate] Knowledge store unavailable: #{inspect(reason)}")
    end
    store = store_ref()
    prior = fetch_prior_by_keywords(store, keywords)

    # 4. LLM call -- structured evidence generation
    prior_text = if prior == [], do: "None found.", else: Enum.join(prior, "\n")

    prompt =
      "Given this topic: \"" <> topic <> "\"\n" <>
      "Prior knowledge from our database: " <> prior_text <> "\n\n" <>
      "Generate a structured analysis:\n\n" <>
      "SUPPORTING (3 arguments for this claim):\n" <>
      "1. [VERIFIABLE/REASONING] <argument>\n" <>
      "2. [VERIFIABLE/REASONING] <argument>\n" <>
      "3. [VERIFIABLE/REASONING] <argument>\n\n" <>
      "OPPOSING (3 arguments against):\n" <>
      "1. [VERIFIABLE/REASONING] <argument>\n" <>
      "2. [VERIFIABLE/REASONING] <argument>\n" <>
      "3. [VERIFIABLE/REASONING] <argument>\n\n" <>
      "ASSUMPTIONS (2 hidden assumptions this rests on):\n" <>
      "1. <assumption> (risk: high/medium/low)\n" <>
      "2. <assumption> (risk: high/medium/low)\n"

    sys_msg = "You are a rigorous epistemic analyst. Produce exactly the requested format. Each evidence line must start with [VERIFIABLE] or [REASONING] followed by (strength: N) where N is 1-10 rating of how strong/compelling the argument is. 10 = irrefutable empirical evidence, 1 = weak speculation. Be honest and differentiated — do NOT give all arguments the same strength."

    messages = [
      %{role: "system", content: sys_msg},
      %{role: "user", content: prompt}
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    llm_opts = [temperature: 0.3, max_tokens: 2_000]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    case Providers.chat(messages, llm_opts) do
      {:ok, %{content: response}} when is_binary(response) ->
        {supporting, opposing, assumptions} = parse_analysis(response)

        # 5. Create claim in the real ledger
        claim = EpistemicLedger.add_claim(
          [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto"]],
          @ledger_name
        )

        # 6. Add evidence through the real ledger -- with varying strengths
        # BUG 2: Wrap add_evidence calls to handle {:error, _} and filter nils
        supporting_records =
          supporting
          |> Enum.map(fn ev ->
            strength = ev.llm_strength || evidence_strength(ev.source_type)
            case EpistemicLedger.add_evidence(
              [
                claim_id: claim.id,
                summary: ev.summary,
                direction: :support,
                strength: strength,
                confidence: strength,
                source_type: Atom.to_string(ev.source_type)
              ],
              @ledger_name
            ) do
              %Models.Evidence{} = record -> record
              {:error, reason} ->
                Logger.warning("[investigate] Failed to add supporting evidence: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        opposing_records =
          opposing
          |> Enum.map(fn ev ->
            strength = ev.llm_strength || evidence_strength(ev.source_type)
            case EpistemicLedger.add_evidence(
              [
                claim_id: claim.id,
                summary: ev.summary,
                direction: :contradict,
                strength: strength,
                confidence: strength,
                source_type: Atom.to_string(ev.source_type)
              ],
              @ledger_name
            ) do
              %Models.Evidence{} = record -> record
              {:error, reason} ->
                Logger.warning("[investigate] Failed to add opposing evidence: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # 7. Add assumptions through the real ledger
        # BUG 4: Check add_assumption return value
        Enum.each(assumptions, fn a ->
          risk_val = case a.risk do
            "high" -> 0.9
            "medium" -> 0.5
            "low" -> 0.2
            _ -> 0.5
          end
          case EpistemicLedger.add_assumption(
            [claim_id: claim.id, text: a.text, risk: risk_val],
            @ledger_name
          ) do
            {:error, reason} ->
              Logger.warning("[investigate] Failed to add assumption: #{inspect(reason)}")
            _ -> :ok
          end
        end)

        # 8. Literature search
        #    - deep: enrich ALL verifiable evidence
        #    - standard: try ONE search for the strongest verifiable claim
        # BUG 20: Tag parsed evidence with direction so we don't use idx < 3 heuristic
        supporting_parsed = Enum.map(supporting, &Map.put(&1, :direction, :support))
        opposing_parsed = Enum.map(opposing, &Map.put(&1, :direction, :contradict))
        all_parsed = supporting_parsed ++ opposing_parsed

        literature_note =
          case depth do
            "deep" ->
              enriched = enrich_all_with_literature(all_parsed, claim.id)
              if enriched > 0, do: "#{enriched} evidence items grounded with literature", else: "No literature found"

            _ ->
              # Standard: try ONE literature search for best verifiable
              enrich_best_verifiable(all_parsed, claim.id)
          end

        # 9. Refresh claim -- let the ledger compute Bayesian confidence
        EpistemicLedger.refresh_claim(claim.id, @ledger_name)
        state = EpistemicLedger.state(@ledger_name)

        # BUG 9: state.claims[claim.id] can be nil -- add nil check
        updated_claim = state.claims[claim.id]
        {confidence, status} = if updated_claim do
          {updated_claim.confidence, updated_claim.status}
        else
          Logger.warning("[investigate] Claim #{claim.id} not found in ledger state after refresh")
          {0.5, :uncertain}
        end

        # 10. Persist ledger to disk
        EpistemicLedger.save(@ledger_name)

        # 11. Determine commitment level
        # BUG 1: Re-query ledger for ALL evidence after enrichment
        # (supporting_records ++ opposing_records only has originals, not literature-enriched ones)
        fresh_state = EpistemicLedger.state(@ledger_name)
        all_evidence = fresh_state.evidence
          |> Map.values()
          |> Enum.filter(fn ev -> ev.claim_id == claim.id end)
        has_sourced = Enum.any?(all_evidence, fn ev -> ev.source_type == "sourced" end)
        commitment = if has_sourced, do: "committed", else: "belief_only"

        # 12. Store in knowledge graph with keywords
        topic_id = "investigate:" <> short_hash(topic)

        triples = [
          {topic_id, "rdf:type", "vaos:Investigation"},
          {topic_id, "vaos:topic", topic},
          {topic_id, "vaos:confidence", Float.to_string(confidence)},
          {topic_id, "vaos:status", Atom.to_string(status)},
          {topic_id, "vaos:commitment", commitment},
          {topic_id, "vaos:claim_id", claim.id},
          {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
        ]

        keyword_triples = Enum.map(keywords, fn kw ->
          {topic_id, "vaos:keyword", kw}
        end)

        for triple <- triples ++ keyword_triples do
          MiosaKnowledge.assert(store, triple)
        end

        # 13. Format result
        result =
          "## Investigation: " <> topic <> "\n\n" <>
          "**Commitment**: " <> commitment <> "\n" <>
          "**Confidence**: " <> Float.to_string(Float.round(confidence, 3)) <> "\n" <>
          "**Status**: " <> Atom.to_string(status) <> "\n" <>
          "**Literature**: " <> literature_note <> "\n\n" <>
          "### Supporting Evidence\n" <> format_evidence_records(supporting_records) <> "\n\n" <>
          "### Opposing Evidence\n" <> format_evidence_records(opposing_records) <> "\n\n" <>
          "### Assumptions\n" <> format_assumptions(assumptions) <> "\n\n" <>
          "### Prior Knowledge\n" <>
          (if prior == [], do: "  None", else: Enum.join(prior, "\n")) <> "\n\n" <>
          "### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
          "*Claim ID: " <> claim.id <> " -- stored in knowledge graph as " <> topic_id <> "*"

        {:ok, result}

      {:ok, _} ->
        {:error, "LLM returned empty or unexpected response"}

      {:error, reason} ->
        {:error, "LLM call failed: " <> inspect(reason)}
    end
  rescue
    e -> {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- Evidence strength mapping ---------------------------------------

  defp evidence_strength(:sourced), do: 0.8
  defp evidence_strength(:verifiable), do: 0.6
  defp evidence_strength(:reasoning), do: 0.4
  defp evidence_strength(_), do: 0.4

  # -- Keyword extraction ----------------------------------------------

  defp extract_keywords(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  # -- Prior knowledge search -- keyword-based -------------------------

  defp fetch_prior_by_keywords(store, keywords) do
    # Two-phase search: match by topic text OR by stored keyword overlap
    topic_query = "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"
    kw_query = "SELECT ?s ?kw WHERE { ?s vaos:keyword ?kw . ?s rdf:type vaos:Investigation }"

    Logger.debug("[investigate] SPARQL prior search: #{length(keywords)} keywords = #{inspect(keywords)}")

    # Phase 1: Get all investigations with their topics
    topic_results = case MiosaKnowledge.sparql(store, topic_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    # Phase 2: Get all investigations with their stored keywords
    kw_results = case MiosaKnowledge.sparql(store, kw_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    Logger.debug("[investigate] Found #{length(topic_results)} investigation(s), #{length(kw_results)} keyword triple(s)")

    # Build a set of investigation IDs that match by stored keyword overlap
    # Check both directions: new keywords match stored keywords, AND stored keywords appear in new topic
    kw_matched_ids =
      kw_results
      |> Enum.filter(fn bindings ->
        stored_kw = Map.get(bindings, "kw", "") |> to_string() |> String.downcase()
        # Direction 1: new keyword exactly matches stored keyword
        exact_match = Enum.any?(keywords, fn kw -> kw == stored_kw end)
        # Direction 2: stored keyword appears in the new investigation topic (bidirectional)
        topic_match = Enum.any?(keywords, fn kw -> String.contains?(stored_kw, kw) or String.contains?(kw, stored_kw) end)
        exact_match or topic_match
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)
      |> MapSet.new()

    Logger.debug("[investigate] Keyword-matched investigation IDs: #{inspect(MapSet.to_list(kw_matched_ids))}")

    # Filter topic_results: match if keyword in topic text OR investigation ID matched by stored keywords
    topic_results
    |> Enum.filter(fn bindings ->
      s = Map.get(bindings, "s", "") |> to_string()
      topic_val = Map.get(bindings, "topic", Map.get(bindings, :topic, ""))
      topic_lower = String.downcase(to_string(topic_val))

      topic_match = Enum.any?(keywords, fn kw -> String.contains?(topic_lower, kw) end)
      kw_match = MapSet.member?(kw_matched_ids, s)

      topic_match or kw_match
    end)
    |> Enum.map(fn bindings ->
      s = Map.get(bindings, "s", Map.get(bindings, :s, "?"))
      t = Map.get(bindings, "topic", Map.get(bindings, :topic, "?"))
      "  Prior: " <> to_string(t) <> " (id: " <> to_string(s) <> ")"
    end)
  rescue
    e ->
      Logger.warning("[investigate] fetch_prior_by_keywords failed: #{Exception.message(e)}")
      []
  end

  # -- Literature search -- Semantic Scholar ---------------------------

  # BUG 6: Removed :inets.start()/:ssl.start() -- moved to run_investigation init
  # BUG 7: Log non-200 HTTP status codes
  defp search_semantic_scholar(query) do
    url = "https://api.semanticscholar.org/graph/v1/paper/search?query=#{URI.encode(query)}&limit=3&fields=title,abstract,citationCount,year"
    headers = [{~c"User-Agent", ~c"VAOS/1.0 (https://vaos.sh; mailto:straughter@vaos.sh)"}]
    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, Jason.decode!(List.to_string(body))["data"] || []}
      {:ok, {{_, status_code, reason_phrase}, _, _body}} ->
        Logger.warning("[investigate] Semantic Scholar returned HTTP #{status_code}: #{reason_phrase}")
        {:error, :search_failed}
      {:error, reason} ->
        Logger.warning("[investigate] Semantic Scholar request failed: #{inspect(reason)}")
        {:error, :search_failed}
    end
  rescue
    e ->
      Logger.warning("[investigate] Semantic Scholar exception: #{Exception.message(e)}")
      {:error, :search_failed}
  end

  # Deep: enrich ALL verifiable evidence with literature
  # BUG 20: Use direction from parsed data instead of idx < 3 heuristic
  defp enrich_all_with_literature(parsed_list, claim_id) do
    parsed_list
    |> Enum.reduce(0, fn parsed, count ->
      if parsed.source_type == :verifiable do
        case search_semantic_scholar(parsed.summary) do
          {:ok, papers} when papers != [] ->
            paper = List.first(papers)
            # BUG 8: Handle nil year/citationCount from API
            year = paper["year"] || "unknown"
            citations = paper["citationCount"] || 0
            source_ref = "#{paper["title"]} (#{year}, citations: #{citations})"
            direction = Map.get(parsed, :direction, :support)
            case EpistemicLedger.add_evidence(
              [
                claim_id: claim_id,
                summary: parsed.summary <> " [grounded: " <> source_ref <> "]",
                direction: direction,
                strength: 0.8,
                confidence: 0.8,
                source_type: "sourced",
                source_ref: source_ref
              ],
              @ledger_name
            ) do
              %Models.Evidence{} -> count + 1
              {:error, reason} ->
                Logger.warning("[investigate] Failed to add enriched evidence: #{inspect(reason)}")
                count
            end
          _ -> count
        end
      else
        count
      end
    end)
  end

  # Standard: try ONE literature search for the strongest verifiable claim
  defp enrich_best_verifiable(parsed_list, claim_id) do
    verifiable =
      parsed_list
      |> Enum.filter(fn parsed -> parsed.source_type == :verifiable end)

    case verifiable do
      [best_parsed | _] ->
        case search_semantic_scholar(best_parsed.summary) do
          {:ok, papers} when papers != [] ->
            paper = List.first(papers)
            # BUG 8: Handle nil year/citationCount from API
            year = paper["year"] || "unknown"
            citations = paper["citationCount"] || 0
            source_ref = "#{paper["title"]} (#{year}, citations: #{citations})"
            direction = Map.get(best_parsed, :direction, :support)
            # Add sourced evidence to the ledger
            case EpistemicLedger.add_evidence(
              [
                claim_id: claim_id,
                summary: best_parsed.summary <> " [grounded: " <> source_ref <> "]",
                direction: direction,
                strength: 0.8,
                confidence: 0.8,
                source_type: "sourced",
                source_ref: source_ref
              ],
              @ledger_name
            ) do
              %Models.Evidence{} ->
                "1 evidence item grounded: " <> source_ref
              {:error, reason} ->
                Logger.warning("[investigate] Failed to add sourced evidence: #{inspect(reason)}")
                "Literature found but failed to store: " <> source_ref
            end
          _ -> "Literature search returned no results"
        end
      [] -> "No verifiable claims to search"
    end
  end

  # -- Parsing ---------------------------------------------------------

  defp parse_analysis(text) do
    sections = String.split(text, ~r/\n(?=SUPPORTING|OPPOSING|ASSUMPTIONS)/i)

    sup_section = Enum.find(sections, "", &String.contains?(&1, "SUPPORTING"))
    opp_section = Enum.find(sections, "", &String.contains?(&1, "OPPOSING"))
    asm_section = Enum.find(sections, "", &String.contains?(&1, "ASSUMPTIONS"))

    supporting = parse_evidence_section(sup_section)
    opposing = parse_evidence_section(opp_section)
    assumptions = parse_assumptions_section(asm_section)

    {supporting, opposing, assumptions}
  end

  defp parse_evidence_section(section) do
    ~r/\d+\.\s*\[(VERIFIABLE|REASONING)\]\s*(?:\(strength:\s*(\d+)\))?\s*(.+)/i
    |> Regex.scan(section)
    |> Enum.map(fn
      [_, type, strength_str, summary] ->
        source_type = if String.upcase(type) == "VERIFIABLE", do: :verifiable, else: :reasoning
        llm_strength = parse_strength(strength_str)
        %{summary: String.trim(summary), source_type: source_type, llm_strength: llm_strength}
      [_, type, "", summary] ->
        source_type = if String.upcase(type) == "VERIFIABLE", do: :verifiable, else: :reasoning
        %{summary: String.trim(summary), source_type: source_type, llm_strength: nil}
    end)
  end

  defp parse_strength(str) when is_binary(str) and str != "" do
    case Integer.parse(str) do
      {n, _} when n >= 1 and n <= 10 -> n / 10.0
      {n, _} when n > 10 -> 1.0
      {n, _} when n < 1 -> 0.1
      _ -> nil
    end
  end
  defp parse_strength(_), do: nil

  defp parse_assumptions_section(section) do
    ~r/\d+\.\s*(.+?)\s*\(risk:\s*(high|medium|low)\)/i
    |> Regex.scan(section)
    |> Enum.map(fn [_, text, risk] ->
      %{text: String.trim(text), risk: String.downcase(risk)}
    end)
  end

  # -- Formatting ------------------------------------------------------

  defp format_evidence_records(records) do
    if records == [] do
      "  (none)"
    else
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        dir = Atom.to_string(ev.direction)
        "  #{i}. [#{ev.source_type}] #{ev.summary} (strength: #{ev.strength}, direction: #{dir})"
      end)
      |> Enum.join("\n")
    end
  end

  defp format_assumptions(items) do
    if items == [] do
      "  (none)"
    else
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {a, i} ->
        "  #{i}. #{a.text} (risk: #{a.risk})"
      end)
      |> Enum.join("\n")
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp short_hash(topic) do
    Base.encode16(:crypto.hash(:sha256, topic), case: :lower) |> String.slice(0, 16)
  end

  defp ensure_ledger_started do
    case Process.whereis(@ledger_name) do
      nil ->
        {:ok, _pid} = EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name)
        :ok
      _pid ->
        :ok
    end
  end

  defp store_ref, do: "osa_default"

  # BUG 18: Return errors instead of swallowing them
  defp ensure_store_started do
    case Vaos.Knowledge.open("osa_default") do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        Logger.error("[investigate] Failed to start knowledge store: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
