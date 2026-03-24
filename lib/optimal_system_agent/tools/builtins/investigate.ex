defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — uses the real Vaos.Ledger.Epistemic.Ledger
  GenServer for claim/evidence tracking with Bayesian confidence.

  PAPER-FIRST DESIGN: Searches alphaXiv/arXiv for papers BEFORE asking the LLM.
  Papers are fed as context so evidence is generated FROM the literature, not
  stapled on after. Each evidence item must cite [Paper N] or be marked [REASONING].
  Unsourced evidence strength is halved.

  ACE PATTERN (Agentic Context Engineering, Stanford 2510.04618):
  - Helpful/Harmful counters on evidence triples in the knowledge graph
  - Semantic dedup of evidence across compound investigation loops
  - Parallel multi-run ensemble (3 LLM calls, consensus weighting)
  """

  require Logger

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger
  alias Vaos.Ledger.Epistemic.Models

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
      "tracks epistemic confidence via Bayesian ledger, and stores results in the knowledge graph. " <>
      "Uses ACE pattern: 3-run ensemble with consensus weighting, semantic dedup, helpful/harmful counters."
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
    :inets.start()
    :ssl.start()

    OptimalSystemAgent.Tools.Builtins.AlphaXivClient.start_link()

    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 2. Extract keywords for prior knowledge search
    keywords = extract_keywords(topic)

    # 3. Prior knowledge search
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

    # 5. ACE: Parallel multi-run ensemble (3 temperatures)
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

    messages_with_papers = [
      %{role: "system", content: sys_msg},
      %{role: "user", content: prompt}
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    llm_opts = [max_tokens: 2_500]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    # ACE: Run 3 parallel LLM calls with different temperatures
    temperatures = [0.0, 0.15, 0.3]
    tasks = Enum.map(temperatures, fn temp ->
      Task.async(fn ->
        opts = Keyword.put(llm_opts, :temperature, temp)
        Providers.chat(messages_with_papers, opts)
      end)
    end)

    # 180s timeout to handle Anthropic rate limiting (60s retry + LLM generation time)
    results = Task.await_many(tasks, 180_000)

    # Parse evidence from all 3 runs
    all_parsed = results
      |> Enum.with_index()
      |> Enum.flat_map(fn {result, idx} ->
        case result do
          {:ok, %{content: response}} when is_binary(response) ->
            {sup, opp, _asm} = parse_analysis(response)
            sup_tagged = Enum.map(sup, &Map.put(&1, :direction, :support))
            opp_tagged = Enum.map(opp, &Map.put(&1, :direction, :contradict))
            all = sup_tagged ++ opp_tagged
            Enum.map(all, &Map.put(&1, :run_index, idx))
          _ ->
            Logger.warning("[investigate] ACE ensemble run #{idx} failed")
            []
        end
      end)

    # Collect assumptions from all successful runs
    all_assumptions = results
      |> Enum.flat_map(fn
        {:ok, %{content: response}} when is_binary(response) ->
          {_sup, _opp, asm} = parse_analysis(response)
          asm
        _ -> []
      end)

    # Dedup assumptions by text similarity
    assumptions = dedup_assumptions(all_assumptions)

    successful_runs = Enum.count(results, fn
      {:ok, %{content: r}} when is_binary(r) -> true
      _ -> false
    end)

    if successful_runs == 0 do
      {:error, "All 3 LLM ensemble runs failed"}
    else
      # ACE: Dedup with consensus counting
      {deduped, consensus_counts} = dedup_with_consensus(all_parsed)

      # Log consensus stats
      by_consensus = Enum.group_by(deduped, fn ev ->
        Map.get(consensus_counts, ev.summary, 1)
      end)
      consensus_log = Enum.map(by_consensus, fn {count, items} ->
        "#{count}/#{successful_runs} for #{length(items)} items"
      end) |> Enum.join(", ")
      Logger.info("[investigate] Evidence consensus: #{consensus_log}")

      # Weight by consensus: evidence in N/N runs gets full strength, 1/N gets 1/N
      final_evidence = Enum.map(deduped, fn ev ->
        consensus = Map.get(consensus_counts, ev.summary, 1)
        consensus_weight = consensus / successful_runs
        raw_strength = ev.llm_strength || evidence_strength(ev.source_type)
        %{ev | llm_strength: raw_strength * consensus_weight}
        |> Map.put(:consensus, consensus)
      end)

      supporting = Enum.filter(final_evidence, &(&1.direction == :support))
      opposing = Enum.filter(final_evidence, &(&1.direction == :contradict))

      # 6. Create claim in the real ledger
      claim = EpistemicLedger.add_claim(
        [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto", "ace"]],
        @ledger_name
      )

      # ACE: Semantic dedup against prior evidence in the ledger
      existing_state = EpistemicLedger.state(@ledger_name)
      existing_evidence = Map.values(existing_state.evidence)

      # 7. Add evidence with ACE dedup
      {supporting_records, sup_dupes} = add_evidence_with_dedup(
        supporting, claim, :support, existing_evidence
      )

      {opposing_records, opp_dupes} = add_evidence_with_dedup(
        opposing, claim, :contradict, existing_evidence
      )

      total_dupes = sup_dupes + opp_dupes
      if total_dupes > 0 do
        Logger.info("[investigate] ACE semantic dedup: skipped #{total_dupes} duplicate evidence items")
      end

      # 8. Add assumptions
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

      # 9. Literature note
      all_final = supporting ++ opposing
      cited_count = Enum.count(all_final, fn p -> p.source_type == :sourced end)
      literature_note = "#{length(papers)} papers found, #{cited_count} cited in evidence"

      # 10. Refresh claim -- let the ledger compute Bayesian confidence
      EpistemicLedger.refresh_claim(claim.id, @ledger_name)
      state = EpistemicLedger.state(@ledger_name)

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
      all_evidence_records = fresh_state.evidence
        |> Map.values()
        |> Enum.filter(fn ev -> ev.claim_id == claim.id end)
      has_sourced = Enum.any?(all_evidence_records, fn ev -> ev.source_type == "sourced" end)
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
        {topic_id, "vaos:ensemble_runs", Integer.to_string(successful_runs)},
        {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
      ]

      keyword_triples = Enum.map(keywords, fn kw ->
        {topic_id, "vaos:keyword", kw}
      end)

      for triple <- triples ++ keyword_triples do
        MiosaKnowledge.assert(store, triple)
      end

      # ACE: Store helpful/harmful counters for each evidence item in the KG
      Enum.each(supporting_records ++ opposing_records, fn ev ->
        ev_id = "evidence:" <> ev.id
        MiosaKnowledge.assert(store, {topic_id, "vaos:has_evidence", ev_id})
        MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", "0"})
        MiosaKnowledge.assert(store, {ev_id, "vaos:harmful_count", "0"})
        MiosaKnowledge.assert(store, {ev_id, "vaos:summary", ev.summary})
      end)

      # ACE: Increment helpful counters for prior evidence that was reused
      increment_helpful_counters(store, prior)

      # 13b. Run OWL reasoner
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

      # 14. Format result with ACE consensus info
      consensus_summary = Enum.map(final_evidence, fn ev ->
        "#{ev.consensus}/#{successful_runs}"
      end) |> Enum.frequencies()
      consensus_line = Enum.map(consensus_summary, fn {rating, count} ->
        "#{count} items at #{rating}"
      end) |> Enum.join(", ")

      result =
        "## Investigation: " <> topic <> "\n\n" <>
        "**Commitment**: " <> commitment <> "\n" <>
        "**Confidence**: " <> Float.to_string(Float.round(confidence, 3)) <> "\n" <>
        "**Status**: " <> Atom.to_string(status) <> "\n" <>
        "**Literature**: " <> literature_note <> "\n" <>
        "**ACE Ensemble**: #{successful_runs}/3 runs succeeded, consensus: #{consensus_line}\n" <>
        "**Semantic Dedup**: #{total_dupes} duplicates skipped\n\n" <>
        "### Supporting Evidence\n" <> format_evidence_records_with_consensus(supporting_records, final_evidence, successful_runs) <> "\n\n" <>
        "### Opposing Evidence\n" <> format_evidence_records_with_consensus(opposing_records, final_evidence, successful_runs) <> "\n\n" <>
        "### Assumptions\n" <> format_assumptions(assumptions) <> "\n" <>
        conflict_note <>
        "\n" <>
        "### Prior Knowledge\n" <>
        (if prior == [], do: "  None", else: Enum.join(prior, "\n")) <> "\n\n" <>
        "### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
        "*Claim ID: " <> claim.id <> " -- stored in knowledge graph as " <> topic_id <> "*"

      # Build JSON result with consensus data
      json_result = Jason.encode!(%{
        topic: topic,
        commitment: commitment,
        confidence: confidence,
        status: Atom.to_string(status),
        literature: literature_note,
        papers_found: length(papers),
        papers_cited: cited_count,
        ensemble_runs: successful_runs,
        semantic_dupes_skipped: total_dupes,
        supporting: Enum.map(supporting_records, fn ev ->
          consensus = find_consensus(ev, final_evidence)
          %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type,
            direction: ev.direction, consensus: consensus}
        end),
        opposing: Enum.map(opposing_records, fn ev ->
          consensus = find_consensus(ev, final_evidence)
          %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type,
            direction: ev.direction, consensus: consensus}
        end),
        assumptions: Enum.map(assumptions, fn a -> %{text: a.text, risk: a.risk} end),
        claim_id: claim.id,
        investigation_id: topic_id,
        keywords: keywords
      })
      MiosaKnowledge.assert(store, {topic_id, "vaos:json_result", json_result})

      result = result <> "\n\n<!-- VAOS_JSON:" <> json_result <> " -->"

      {:ok, result}
    end
  rescue
    e -> {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- ACE: Add evidence with semantic dedup ---------------------------

  defp add_evidence_with_dedup(evidence_list, claim, direction, existing_evidence) do
    Enum.reduce(evidence_list, {[], 0}, fn ev, {acc, dupe_count} ->
      is_duplicate = Enum.any?(existing_evidence, fn existing ->
        existing.claim_id != claim.id and
          semantically_similar?(existing.summary, ev.summary)
      end)

      if is_duplicate do
        Logger.debug("[investigate] Skipping duplicate evidence: #{String.slice(ev.summary, 0, 50)}")
        {acc, dupe_count + 1}
      else
        raw_strength = ev.llm_strength || evidence_strength(ev.source_type)
        strength = if ev.source_type == :sourced, do: raw_strength, else: raw_strength * 0.5
        case EpistemicLedger.add_evidence(
          [
            claim_id: claim.id,
            summary: ev.summary,
            direction: direction,
            strength: strength,
            confidence: strength,
            source_type: Atom.to_string(ev.source_type)
          ],
          @ledger_name
        ) do
          %Models.Evidence{} = record -> {[record | acc], dupe_count}
          {:error, reason} ->
            Logger.warning("[investigate] Failed to add evidence: #{inspect(reason)}")
            {acc, dupe_count}
        end
      end
    end)
    |> then(fn {records, dupe_count} -> {Enum.reverse(records), dupe_count} end)
  end

  # -- ACE: Semantic similarity for dedup ------------------------------

  defp semantically_similar?(summary1, summary2) do
    words1 = extract_significant_words(summary1)
    words2 = extract_significant_words(summary2)

    set1 = MapSet.new(words1)
    set2 = MapSet.new(words2)
    intersection = MapSet.intersection(set1, set2) |> MapSet.size()
    union_size = MapSet.union(set1, set2) |> MapSet.size()

    if union_size == 0, do: false, else: intersection / union_size >= 0.4
  end

  defp extract_significant_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(10)
  end

  # -- ACE: Parallel ensemble dedup with consensus --------------------

  defp dedup_with_consensus(evidence_list) do
    {deduped, counts} = Enum.reduce(evidence_list, {[], %{}}, fn ev, {acc, counts} ->
      case Enum.find(acc, fn existing -> semantically_similar?(existing.summary, ev.summary) end) do
        nil ->
          {[ev | acc], Map.put(counts, ev.summary, 1)}
        existing ->
          new_count = Map.get(counts, existing.summary, 1) + 1
          {acc, Map.put(counts, existing.summary, new_count)}
      end
    end)

    {Enum.reverse(deduped), counts}
  end

  defp dedup_assumptions(assumptions_list) do
    Enum.reduce(assumptions_list, [], fn a, acc ->
      if Enum.any?(acc, fn existing ->
        semantically_similar?(existing.text, a.text)
      end) do
        acc
      else
        [a | acc]
      end
    end)
    |> Enum.reverse()
  end

  # -- ACE: Helpful counter increment ---------------------------------

  defp increment_helpful_counters(store, prior_entries) do
    Enum.each(prior_entries, fn prior_text ->
      case Regex.run(~r/\(id:\s*(investigate:[a-f0-9]+)\)/, prior_text) do
        [_, prior_id] ->
          query = "SELECT ?ev ?count WHERE { <#{prior_id}> vaos:has_evidence ?ev . ?ev vaos:helpful_count ?count }"
          case MiosaKnowledge.sparql(store, query) do
            {:ok, results} when is_list(results) ->
              for r <- results do
                ev_id = Map.get(r, "ev", "")
                old_count_str = Map.get(r, "count", "0")
                old_count = case Integer.parse(old_count_str) do
                  {n, _} -> n
                  :error -> 0
                end
                MiosaKnowledge.retract(store, {ev_id, "vaos:helpful_count", old_count_str})
                MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", Integer.to_string(old_count + 1)})
                Logger.debug("[investigate] ACE: Incremented helpful count for #{ev_id} to #{old_count + 1}")
              end
            _ -> :ok
          end
        _ -> :ok
      end
    end)
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
    topic_query = "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"
    kw_query = "SELECT ?s ?kw WHERE { ?s vaos:keyword ?kw . ?s rdf:type vaos:Investigation }"

    Logger.debug("[investigate] SPARQL prior search: #{length(keywords)} keywords = #{inspect(keywords)}")

    topic_results = case MiosaKnowledge.sparql(store, topic_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    kw_results = case MiosaKnowledge.sparql(store, kw_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    Logger.debug("[investigate] Found #{length(topic_results)} investigation(s), #{length(kw_results)} keyword triple(s)")

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

    sup_summaries = MapSet.new(Enum.map(supporting, & &1.summary))
    opposing = Enum.reject(opposing, fn ev -> MapSet.member?(sup_summaries, ev.summary) end)

    if opposing == [] and supporting != [] do
      Logger.warning("[investigate] LLM returned identical evidence for both sides -- opposing section was deduplicated to empty")
    end

    {supporting, opposing, assumptions}
  end

  defp parse_evidence_section(section) do
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

  defp format_evidence_records_with_consensus(records, final_evidence, total_runs) do
    if records == [] do
      "  (none)"
    else
      records
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        dir = Atom.to_string(ev.direction)
        consensus = find_consensus(ev, final_evidence)
        "  #{i}. [#{ev.source_type}] #{ev.summary} (strength: #{ev.strength}, direction: #{dir}, consensus: #{consensus}/#{total_runs})"
      end)
      |> Enum.join("\n")
    end
  end

  defp find_consensus(record, final_evidence) do
    case Enum.find(final_evidence, fn fe ->
      semantically_similar?(fe.summary, record.summary)
    end) do
      nil -> 1
      found -> Map.get(found, :consensus, 1)
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
