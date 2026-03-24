defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — uses the real Vaos.Ledger.Epistemic.Ledger
  GenServer for claim/evidence tracking with Bayesian confidence.

  PAPER-FIRST DESIGN: Searches alphaXiv/arXiv for papers BEFORE asking the LLM.
  Papers are fed as context so evidence is generated FROM the literature, not
  stapled on after. Each evidence item must cite [Paper N] or be marked [REASONING].
  Unsourced evidence strength is halved. Temperature 0.1 for reproducibility.
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
    "Investigate a claim or topic: searches papers first, generates evidence from literature, " <>
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
          "description" => "standard = search papers + LLM analysis; deep = broader paper search + LLM analysis"
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

    # Start alphaXiv MCP client (best-effort, falls back to arXiv if unavailable)
    OptimalSystemAgent.Tools.Builtins.AlphaXivClient.start_link()

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

    # 4. PAPER-FIRST: Search for papers BEFORE generating evidence
    paper_query = case depth do
      "deep" -> "Research on #{topic}. Papers covering empirical evidence, methods, and analysis."
      _ -> topic
    end

    papers = case search_papers(paper_query) do
      {:ok, found} when found != [] -> found
      _ -> []
    end

    Logger.info("[investigate] Found #{length(papers)} papers for topic: #{topic}")

    papers_context = if papers != [] do
      papers_text = papers
        |> Enum.with_index(1)
        |> Enum.map(fn {p, i} ->
          "[Paper #{i}] #{p["title"]} (#{p["year"]})\nAbstract: #{p["abstract"]}"
        end)
        |> Enum.join("\n\n")

      "\n\nRELEVANT PAPERS FOUND:\n" <> papers_text <>
        "\n\nYou MUST cite specific papers by number [Paper N] when your evidence is based on them.\n"
    else
      "\n\nNo relevant papers found. Base your evidence on your training knowledge, but mark everything as [REASONING].\n"
    end

    # 5. LLM call -- structured evidence generation WITH paper context
    prior_text = if prior == [], do: "None found.", else: Enum.join(prior, "\n")

    prompt =
      "Given this topic: \"" <> topic <> "\"\n" <>
      "Prior knowledge from our database: " <> prior_text <> "\n" <>
      papers_context <> "\n" <>
      "Generate ALL evidence relevant to this claim. Do NOT force equal numbers.\n" <>
      "For each piece of evidence:\n" <>
      "- If based on a specific paper above, cite it as [Paper N] and tag as [VERIFIABLE]\n" <>
      "- If based on your own reasoning without a paper, tag as [REASONING]\n" <>
      "- Rate strength 1-10. Paper-backed evidence should be 7-10. Pure reasoning should be 3-7.\n" <>
      "- Be honest about which side the evidence favors.\n" <>
      "- Label it SUPPORTING or OPPOSING based on what it actually shows\n" <>
      "- If the evidence overwhelmingly supports one side, reflect that. Do NOT manufacture balance.\n\n" <>
      "Format:\nSUPPORTING:\n1. [VERIFIABLE/REASONING] [Paper N] (strength: N) <evidence>\n...\n\nOPPOSING:\n1. [VERIFIABLE/REASONING] [Paper N] (strength: N) <evidence>\n...\n\nASSUMPTIONS (2 hidden assumptions this rests on):\n1. <assumption> (risk: high/medium/low)\n2. <assumption> (risk: high/medium/low)\n"

    sys_msg = "You are a rigorous epistemic analyst. Produce exactly the requested format. " <>
      "Each evidence line must start with [VERIFIABLE] or [REASONING]. " <>
      "If citing a paper, include [Paper N] right after the tag. " <>
      "Follow with (strength: N) where N is 1-10. " <>
      "Paper-backed [VERIFIABLE] evidence should score 7-10. " <>
      "Pure [REASONING] without paper support should score 3-7. " <>
      "Be intellectually honest. Your strength ratings should vary."

    messages = [
      %{role: "system", content: sys_msg},
      %{role: "user", content: prompt}
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    llm_opts = [temperature: 0.1, max_tokens: 2_500]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    case Providers.chat(messages, llm_opts) do
      {:ok, %{content: response}} when is_binary(response) ->
        {supporting, opposing, assumptions} = parse_analysis(response)

        # 6. Create claim in the real ledger
        claim = EpistemicLedger.add_claim(
          [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto"]],
          @ledger_name
        )

        # 7. Add evidence through the real ledger
        #    Unsourced (reasoning-only) evidence gets strength halved
        supporting_records =
          supporting
          |> Enum.map(fn ev ->
            raw_strength = ev.llm_strength || evidence_strength(ev.source_type)
            strength = if ev.source_type == :sourced, do: raw_strength, else: raw_strength * 0.5
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
            raw_strength = ev.llm_strength || evidence_strength(ev.source_type)
            strength = if ev.source_type == :sourced, do: raw_strength, else: raw_strength * 0.5
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

        # 8. Add assumptions through the real ledger
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

        # 9. Literature note -- how many papers found and cited
        supporting_parsed = Enum.map(supporting, &Map.put(&1, :direction, :support))
        opposing_parsed = Enum.map(opposing, &Map.put(&1, :direction, :contradict))
        all_parsed = supporting_parsed ++ opposing_parsed

        cited_count = Enum.count(all_parsed, fn p -> p.source_type == :sourced end)
        literature_note = "#{length(papers)} papers found, #{cited_count} cited in evidence"

        # 10. Refresh claim -- let the ledger compute Bayesian confidence
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

        # 11. Persist ledger to disk
        EpistemicLedger.save(@ledger_name)

        # 12. Determine commitment level
        fresh_state = EpistemicLedger.state(@ledger_name)
        all_evidence = fresh_state.evidence
          |> Map.values()
          |> Enum.filter(fn ev -> ev.claim_id == claim.id end)
        has_sourced = Enum.any?(all_evidence, fn ev -> ev.source_type == "sourced" end)
        commitment = if has_sourced, do: "committed", else: "belief_only"

        # 13. Store in knowledge graph with keywords
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

        # 13b. Run OWL reasoner to infer new facts from combined old + new triples
        case MiosaKnowledge.Reasoner.materialize(store) do
          {:ok, count} when count > 0 ->
            Logger.info("[investigate] OWL reasoner inferred #{count} new triples")
          _ -> :ok
        end

        # 13c. Cross-investigation contradiction detection
        conflicts = detect_contradictions(store, topic_id, status, confidence, keywords)
        conflict_note = if conflicts == [] do
          ""
        else
          conflict_lines = Enum.map(conflicts, fn c ->
            "  - #{c.prior_topic} (#{c.prior_id}): #{c.prior_status} @ #{c.prior_confidence} vs current #{Atom.to_string(status)} @ #{Float.round(confidence, 3)}"
          end)
          "\n### Cross-Investigation Conflicts\n" <> Enum.join(conflict_lines, "\n") <> "\n"
        end

        # 14. Format result
        result =
          "## Investigation: " <> topic <> "\n\n" <>
          "**Commitment**: " <> commitment <> "\n" <>
          "**Confidence**: " <> Float.to_string(Float.round(confidence, 3)) <> "\n" <>
          "**Status**: " <> Atom.to_string(status) <> "\n" <>
          "**Literature**: " <> literature_note <> "\n\n" <>
          "### Supporting Evidence\n" <> format_evidence_records(supporting_records) <> "\n\n" <>
          "### Opposing Evidence\n" <> format_evidence_records(opposing_records) <> "\n\n" <>
          "### Assumptions\n" <> format_assumptions(assumptions) <> "\n" <>
          conflict_note <>
          "\n" <>
          "### Prior Knowledge\n" <>
          (if prior == [], do: "  None", else: Enum.join(prior, "\n")) <> "\n\n" <>
          "### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
          "*Claim ID: " <> claim.id <> " -- stored in knowledge graph as " <> topic_id <> "*"

        # FIX 2: Build JSON result and store in knowledge graph
        json_result = Jason.encode!(%{
          topic: topic,
          commitment: commitment,
          confidence: confidence,
          status: Atom.to_string(status),
          literature: literature_note,
          papers_found: length(papers),
          papers_cited: cited_count,
          supporting: Enum.map(supporting_records, fn ev -> %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type, direction: ev.direction} end),
          opposing: Enum.map(opposing_records, fn ev -> %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type, direction: ev.direction} end),
          assumptions: Enum.map(assumptions, fn a -> %{text: a.text, risk: a.risk} end),
          claim_id: claim.id,
          investigation_id: topic_id,
          keywords: keywords
        })
        MiosaKnowledge.assert(store, {topic_id, "vaos:json_result", json_result})

        result = result <> "\n\n<!-- VAOS_JSON:" <> json_result <> " -->"

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
    |> Enum.flat_map(fn word ->
      # Basic stemming: add both the word and its stem
      stem = word
        |> String.replace(~r/ing$/, "")
        |> String.replace(~r/tion$/, "t")
        |> String.replace(~r/ness$/, "")
        |> String.replace(~r/ment$/, "")
        |> String.replace(~r/able$/, "")
        |> String.replace(~r/ible$/, "")
        |> String.replace(~r/ly$/, "")
        |> String.replace(~r/ed$/, "")
        |> String.replace(~r/er$/, "")
        |> String.replace(~r/es$/, "")
        |> String.replace(~r/s$/, "")
      if stem != word and String.length(stem) >= 3, do: [word, stem], else: [word]
    end)
    |> Enum.uniq()
    |> Enum.take(20)
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
    kw_matched_ids =
      kw_results
      |> Enum.filter(fn bindings ->
        stored_kw = Map.get(bindings, "kw", "") |> to_string() |> String.downcase()
        exact_match = Enum.any?(keywords, fn kw -> kw == stored_kw end)
        topic_match = Enum.any?(keywords, fn kw -> String.contains?(stored_kw, kw) or String.contains?(kw, stored_kw) end)
        exact_match or topic_match
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)
      |> MapSet.new()

    Logger.debug("[investigate] Keyword-matched investigation IDs: #{inspect(MapSet.to_list(kw_matched_ids))}")

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

  # -- Literature search -- alphaXiv/arXiv ---------------------------

  # BUG 6: Removed :inets.start()/:ssl.start() -- moved to run_investigation init
  # BUG 7: Log non-200 HTTP status codes

  # Try alphaXiv MCP first (semantic embedding search), fall back to arXiv API
  defp search_papers(query) do
    alias OptimalSystemAgent.Tools.Builtins.AlphaXivClient

    case AlphaXivClient.embedding_search(query) do
      {:ok, papers} when papers != [] ->
        Logger.debug("[investigate] alphaXiv returned #{length(papers)} papers")
        {:ok, papers}

      _ ->
        Logger.debug("[investigate] alphaXiv unavailable, falling back to arXiv API")
        search_arxiv(query)
    end
  end

  defp search_arxiv(query) do
    # Use arXiv API (free, no auth, reliable)
    terms = query |> String.split(~r/\s+/) |> Enum.take(5) |> Enum.join("+")
    url = "https://export.arxiv.org/api/query?search_query=all:#{URI.encode(terms)}&max_results=5"
    headers = [{~c"User-Agent", ~c"VAOS/1.0 (https://vaos.sh; mailto:straughter@vaos.sh)"}]
    case :httpc.request(:get, {String.to_charlist(url), headers}, [{:timeout, 15_000}, {:autoredirect, true}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        xml = List.to_string(body)
        papers = Regex.scan(~r/<entry>[\s\S]*?<\/entry>/, xml)
        |> Enum.map(fn [entry] ->
          title = case Regex.run(~r/<title>([^<]+)<\/title>/, entry) do [_, t] -> String.trim(t); _ -> "Unknown" end
          abstract = case Regex.run(~r/<summary>([\s\S]*?)<\/summary>/, entry) do [_, a] -> String.trim(a) |> String.slice(0, 500); _ -> "" end
          year = case Regex.run(~r/<published>(\d{4})/, entry) do [_, y] -> y; _ -> "unknown" end
          %{"title" => title, "abstract" => abstract, "year" => year, "citationCount" => 0}
        end)
        {:ok, papers}
      {:ok, {{_, status_code, reason_phrase}, _, _body}} ->
        Logger.warning("[investigate] arXiv returned HTTP #{status_code}: #{reason_phrase}")
        {:error, :search_failed}
      {:error, reason} ->
        Logger.warning("[investigate] arXiv request failed: #{inspect(reason)}")
        {:error, :search_failed}
    end
  rescue
    e ->
      Logger.warning("[investigate] arXiv exception: #{Exception.message(e)}")
      {:error, :search_failed}
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

    # Deduplicate: if same evidence appears in both supporting and opposing, keep only in supporting
    sup_summaries = MapSet.new(Enum.map(supporting, & &1.summary))
    opposing = Enum.reject(opposing, fn ev -> MapSet.member?(sup_summaries, ev.summary) end)

    # If opposing is now empty (LLM duplicated everything), generate a warning
    if opposing == [] and supporting != [] do
      Logger.warning("[investigate] LLM returned identical evidence for both sides — opposing section was deduplicated to empty")
    end

    {supporting, opposing, assumptions}
  end

  defp parse_evidence_section(section) do
    # Match: N. [VERIFIABLE/REASONING] [Paper N] (strength: N) <evidence>
    # Paper citation is optional
    ~r/\d+\.\s*\[(VERIFIABLE|REASONING)\]\s*(?:\[Paper\s+(\d+)\]\s*)?(?:\(strength:\s*(\d+)\))?\s*(.+)/i
    |> Regex.scan(section)
    |> Enum.map(fn
      [_, type, paper_ref, strength_str, summary] ->
        has_paper = paper_ref != "" and paper_ref != nil
        source_type = if has_paper, do: :sourced, else: parse_source_type(type)
        llm_strength = parse_strength(strength_str)
        paper_num = if has_paper, do: String.to_integer(paper_ref), else: nil
        summary = if has_paper do
          summary <> " [Paper #{paper_ref}]"
        else
          summary
        end
        %{summary: String.trim(summary), source_type: source_type, llm_strength: llm_strength, paper_num: paper_num}
    end)
  end

  defp parse_source_type(type) do
    case String.upcase(type) do
      "VERIFIABLE" -> :verifiable
      "REASONING" -> :reasoning
      _ -> :reasoning
    end
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

  defp detect_contradictions(store, current_id, current_status, current_confidence, current_keywords) do
    # Find prior investigations with overlapping keywords
    case MiosaKnowledge.sparql(store, "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }") do
      {:ok, results} when is_list(results) ->
        results
        |> Enum.reject(fn r -> Map.get(r, "s") == current_id end)
        |> Enum.filter(fn r ->
          prior_topic = Map.get(r, "topic", "") |> String.downcase()
          Enum.any?(current_keywords, fn kw -> String.contains?(prior_topic, kw) end)
        end)
        |> Enum.flat_map(fn r ->
          prior_id = Map.get(r, "s", "")
          prior_topic = Map.get(r, "topic", "")

          # Get the prior investigation's status and confidence
          case MiosaKnowledge.sparql(store, "SELECT ?status ?conf WHERE { <" <> prior_id <> "> vaos:status ?status . <" <> prior_id <> "> vaos:confidence ?conf }") do
            {:ok, [prior | _]} ->
              prior_status = Map.get(prior, "status", "unknown")
              prior_conf = Map.get(prior, "conf", "0.5")

              current_s = Atom.to_string(current_status)
              is_conflict =
                (current_s == "supported" and prior_status in ["contested", "falsified", "uncertain"]) or
                (current_s in ["contested", "falsified"] and prior_status == "supported") or
                (current_s == "supported" and prior_status == "supported" and
                 abs(current_confidence - parse_float(prior_conf)) > 0.25)

              if is_conflict do
                MiosaKnowledge.assert(store, {current_id, "vaos:contradicts", prior_id})
                MiosaKnowledge.assert(store, {prior_id, "vaos:contradictedBy", current_id})
                Logger.warning("[investigate] Epistemic tension: #{current_id} contradicts #{prior_id}")

                [%{prior_id: prior_id, prior_topic: prior_topic, prior_status: prior_status, prior_confidence: prior_conf}]
              else
                []
              end
            _ -> []
          end
        end)
      _ -> []
    end
  end

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.5
    end
  end
  defp parse_float(_), do: 0.5

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
