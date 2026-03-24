defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — adversarial dual-prompt architecture.

  PAPER-FIRST DESIGN: Runs TWO parallel paper searches (evidence FOR and AGAINST),
  then feeds merged papers to TWO adversarial LLM prompts that argue each side.

  Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv.
  Uses vaos-ledger's Literature module for Semantic Scholar and OpenAlex,
  with alphaXiv MCP for embedding-based arXiv search.

  Produces an honest direction label (supporting / opposing / genuinely_contested)
  instead of fake confidence numbers. Each side's strength is labeled
  strong / moderate / weak based on the best argument.

  ACE PATTERN (Agentic Context Engineering):
  - Helpful/Harmful counters on evidence triples in the knowledge graph
  - Compound loop fetches prior EVIDENCE, not prior conclusions
  """

  require Logger

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger
  alias Vaos.Ledger.Epistemic.Models
  alias Vaos.Ledger.Research.Literature

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
    "Investigate a claim or topic: runs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv, " <>
      "FOR and AGAINST), then dual adversarial LLM analysis. Returns honest direction " <>
      "(supporting/opposing/genuinely_contested) with strength labels instead of fake confidence."
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

  defp run_investigation(topic, _depth) do
    :inets.start()
    :ssl.start()

    OptimalSystemAgent.Tools.Builtins.AlphaXivClient.start_link()

    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 2. Extract keywords for prior knowledge search
    keywords = extract_keywords(topic)

    # 3. Prior knowledge search — fetch prior EVIDENCE, not conclusions
    case ensure_store_started() do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[investigate] Knowledge store unavailable: #{inspect(reason)}")
    end
    store = store_ref()
    prior_evidence = fetch_prior_evidence_by_keywords(store, keywords)

    # 4. MULTI-SOURCE PAPER SEARCH: Semantic Scholar + OpenAlex + alphaXiv (parallel)
    {all_papers, source_counts} = search_all_papers(topic)

    Logger.info("[investigate] Papers: #{length(all_papers)} total (#{inspect(source_counts)})")

    # 5. Format papers context for LLM prompts
    papers_context = format_papers(all_papers)

    # 6. Prior evidence context (evidence only, no conclusions)
    prior_text = if prior_evidence == [] do
      ""
    else
      "\n\nPreviously investigated evidence on related topics:\n" <>
        Enum.join(prior_evidence, "\n") <> "\n"
    end

    # 7. TWO ADVERSARIAL LLM CALLS (parallel)
    for_prompt = """
    You are a researcher who genuinely believes the following claim is TRUE.
    Using the papers provided and your knowledge, make the STRONGEST possible case.

    Claim: #{topic}

    #{papers_context}
    #{prior_text}

    Present your 3-5 strongest arguments. For each:
    - Cite a specific paper [Paper N] if one supports your point
    - Rate the argument strength 1-10 honestly (even as an advocate, some arguments are stronger than others)
    - Tag as [SOURCED] if backed by a paper, [REASONING] if from your analysis

    Format:
    1. [SOURCED/REASONING] (strength: N) Your argument here [Paper N if applicable]
    2. ...
    """

    against_prompt = """
    You are a researcher who genuinely believes the following claim is FALSE.
    Using the papers provided and your knowledge, make the STRONGEST possible case AGAINST it.

    Claim: #{topic}

    #{papers_context}
    #{prior_text}

    Present your 3-5 strongest counterarguments. For each:
    - Cite a specific paper [Paper N] if one supports your point
    - Rate the argument strength 1-10 honestly (even as an advocate, some arguments are stronger than others)
    - Tag as [SOURCED] if backed by a paper, [REASONING] if from your analysis

    Format:
    1. [SOURCED/REASONING] (strength: N) Your counterargument here [Paper N if applicable]
    2. ...
    """

    for_messages = [
      %{role: "system", content: "You are an intellectually honest researcher making the strongest case FOR a claim. Vary your strength ratings — not every argument is equally strong."},
      %{role: "user", content: for_prompt}
    ]

    against_messages = [
      %{role: "system", content: "You are an intellectually honest researcher making the strongest case AGAINST a claim. Vary your strength ratings — not every argument is equally strong."},
      %{role: "user", content: against_prompt}
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    llm_opts = [temperature: 0.1, max_tokens: 1500]
    llm_opts = if model, do: Keyword.put(llm_opts, :model, model), else: llm_opts

    llm_tasks = [
      Task.async(fn -> Providers.chat(for_messages, llm_opts) end),
      Task.async(fn -> Providers.chat(against_messages, llm_opts) end)
    ]

    [for_result, against_result] = Task.await_many(llm_tasks, 120_000)

    # 8. Parse both sides
    supporting = case for_result do
      {:ok, %{content: response}} when is_binary(response) ->
        parse_adversarial_evidence(response)
      _ ->
        Logger.warning("[investigate] FOR-side LLM call failed")
        []
    end

    opposing = case against_result do
      {:ok, %{content: response}} when is_binary(response) ->
        parse_adversarial_evidence(response)
      _ ->
        Logger.warning("[investigate] AGAINST-side LLM call failed")
        []
    end

    if supporting == [] and opposing == [] do
      {:error, "Both adversarial LLM calls failed"}
    else
      # 9. Determine direction — average strength + source quality bonus
      #    (more robust than single best argument; prevents one pedantic 10/10 from dominating)
      best_for = Enum.max_by(supporting, fn ev -> ev.strength end, fn -> %{strength: 0, summary: "none"} end)
      best_against = Enum.max_by(opposing, fn ev -> ev.strength end, fn -> %{strength: 0, summary: "none"} end)

      # Average strength for each side (more robust than single best)
      avg_for = if supporting == [], do: 0,
        else: Enum.sum(Enum.map(supporting, & &1.strength)) / length(supporting)
      avg_against = if opposing == [], do: 0,
        else: Enum.sum(Enum.map(opposing, & &1.strength)) / length(opposing)

      # Also count sourced vs reasoning
      sourced_for = Enum.count(supporting, & &1.source_type == :sourced)
      sourced_against = Enum.count(opposing, & &1.source_type == :sourced)

      # Direction: combine average strength + source quality
      # Sourced arguments count more: each sourced item adds 0.5 to that side's score
      for_score = avg_for + (sourced_for * 0.5)
      against_score = avg_against + (sourced_against * 0.5)

      direction = cond do
        for_score >= against_score + 1.5 -> "supporting"
        against_score >= for_score + 1.5 -> "opposing"
        true -> "genuinely_contested"
      end

      for_strength = strength_label(best_for.strength)
      against_strength = strength_label(best_against.strength)

      # 10. Create claim in the real ledger
      claim = EpistemicLedger.add_claim(
        [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto", "adversarial"]],
        @ledger_name
      )

      # 11. Add evidence to ledger
      supporting_records = add_evidence_to_ledger(supporting, claim, :support)
      opposing_records = add_evidence_to_ledger(opposing, claim, :contradict)

      # 12. Refresh claim
      EpistemicLedger.refresh_claim(claim.id, @ledger_name)

      # 13. Persist ledger to disk
      EpistemicLedger.save(@ledger_name)

      # 14. Store in knowledge graph
      topic_id = "investigate:" <> short_hash(topic)
      claim_id = claim.id

      json_result = Jason.encode!(%{
        topic: topic,
        direction: direction,
        for_strength: for_strength,
        against_strength: against_strength,
        best_for_strength: best_for.strength,
        best_against_strength: best_against.strength,
        avg_for: Float.round(avg_for, 2),
        avg_against: Float.round(avg_against, 2),
        for_score: Float.round(for_score, 2),
        against_score: Float.round(against_score, 2),
        sourced_for: sourced_for,
        sourced_against: sourced_against,
        supporting: Enum.map(supporting, fn ev ->
          %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type}
        end),
        opposing: Enum.map(opposing, fn ev ->
          %{summary: ev.summary, strength: ev.strength, source_type: ev.source_type}
        end),
        papers_found: length(all_papers),
        source_counts: source_counts,
        papers_detail: Enum.map(all_papers, fn p ->
          %{title: p["title"], year: p["year"], citations: p["citation_count"] || p["citationCount"] || 0, source: p["source"] || "unknown"}
        end),
        investigation_id: topic_id,
        claim_id: claim_id
      })

      triples = [
        {topic_id, "rdf:type", "vaos:Investigation"},
        {topic_id, "vaos:topic", topic},
        {topic_id, "vaos:direction", direction},
        {topic_id, "vaos:for_strength", for_strength},
        {topic_id, "vaos:against_strength", against_strength},
        {topic_id, "vaos:json_result", json_result},
        {topic_id, "vaos:claim_id", claim_id},
        {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
      ]

      keyword_triples = Enum.map(keywords, fn kw ->
        {topic_id, "vaos:keyword", kw}
      end)

      for triple <- triples ++ keyword_triples do
        MiosaKnowledge.assert(store, triple)
      end

      # Store helpful/harmful counters for each evidence item
      Enum.each(supporting_records ++ opposing_records, fn ev ->
        ev_id = "evidence:" <> ev.id
        MiosaKnowledge.assert(store, {topic_id, "vaos:has_evidence", ev_id})
        MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", "0"})
        MiosaKnowledge.assert(store, {ev_id, "vaos:harmful_count", "0"})
        MiosaKnowledge.assert(store, {ev_id, "vaos:summary", ev.summary})
      end)

      # Increment helpful counters for prior evidence that was independently regenerated
      increment_helpful_for_reused_evidence(store, prior_evidence, supporting ++ opposing)

      # 15. Cross-investigation contradiction detection
      conflicts = detect_contradictions(store, topic_id, direction, keywords)
      conflict_note = if conflicts == [] do
        ""
      else
        conflict_lines = Enum.map(conflicts, fn c ->
          "  - #{c.prior_topic} (#{c.prior_id}): #{c.prior_direction} vs current #{direction}"
        end)
        "\n### Cross-Investigation Conflicts\n" <> Enum.join(conflict_lines, "\n") <> "\n"
      end

      # 16. Format result
      for_arguments = format_adversarial_evidence(supporting)
      against_arguments = format_adversarial_evidence(opposing)

      paper_list = all_papers
        |> Enum.with_index(1)
        |> Enum.map(fn {p, i} ->
          citations = p["citation_count"] || p["citationCount"] || 0
          source = p["source"] || "unknown"
          "  [Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})"
        end)
        |> Enum.join("\n")

      result =
        "## Investigation: #{topic}\n\n" <>
        "**Direction:** #{direction}\n" <>
        "**Case for:** #{for_strength} (best: #{best_for.strength}/10, avg: #{Float.round(avg_for, 1)}, sourced: #{sourced_for}, score: #{Float.round(for_score, 1)})\n" <>
        "**Case against:** #{against_strength} (best: #{best_against.strength}/10, avg: #{Float.round(avg_against, 1)}, sourced: #{sourced_against}, score: #{Float.round(against_score, 1)})\n" <>
        "**Papers found:** #{length(all_papers)} (#{format_source_counts(source_counts)})\n\n" <>
        "### Strongest Case FOR\n#{for_arguments}\n\n" <>
        "### Strongest Case AGAINST\n#{against_arguments}\n\n" <>
        "### Papers Consulted\n#{paper_list}\n" <>
        conflict_note <>
        (if prior_evidence != [], do: "\n### Prior Evidence (related topics)\n" <> Enum.join(prior_evidence, "\n") <> "\n", else: "") <>
        "\n### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
        "*Claim ID: #{claim_id} -- stored in knowledge graph as #{topic_id}*" <>
        "\n\n<!-- VAOS_JSON:#{json_result} -->"

      {:ok, result}
    end
  rescue
    e -> {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- Balanced paper merge with title dedup ----------------------------

  defp merge_papers(papers) when is_list(papers) do
    Enum.uniq_by(papers, fn p ->
      p["title"]
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 4))
      |> Enum.sort()
      |> Enum.take(5)
      |> Enum.join(" ")
    end)
  end

  # -- Format papers for LLM context -----------------------------------

  defp format_papers([]), do: "No relevant papers found. Base your arguments on your training knowledge, but mark everything as [REASONING]."
  defp format_papers(papers) do
    papers_text = papers
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        citations = p["citation_count"] || p["citationCount"] || 0
        source = p["source"] || "unknown"
        abstract = String.slice(to_string(p["abstract"] || ""), 0, 500)
        "[Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})\nAbstract: #{abstract}"
      end)
      |> Enum.join("\n\n")

    "RELEVANT PAPERS FOUND:\n" <> papers_text <>
      "\n\nPapers are sorted by citation count. Higher-cited papers are more established." <>
      "\nWhen citing, prefer papers with more citations for stronger arguments." <>
      "\nYou MUST cite specific papers by number [Paper N] when your arguments are based on them."
  end

  # -- Adversarial evidence parsing ------------------------------------

  defp parse_adversarial_evidence(text) do
    ~r/\d+\.\s*\[(SOURCED|REASONING)\]\s*\(strength:\s*(\d+)\)\s*(.+)/i
    |> Regex.scan(text)
    |> Enum.map(fn [_, type, strength_str, summary] ->
      source_type = case String.upcase(type) do
        "SOURCED" -> :sourced
        _ -> :reasoning
      end
      strength = case Integer.parse(strength_str) do
        {n, _} when n >= 1 and n <= 10 -> n
        {n, _} when n > 10 -> 10
        {n, _} when n < 1 -> 1
        _ -> 5
      end
      %{summary: String.trim(summary), source_type: source_type, strength: strength}
    end)
  end

  # -- Strength label ---------------------------------------------------

  defp strength_label(s) when s >= 8, do: "strong"
  defp strength_label(s) when s >= 5, do: "moderate"
  defp strength_label(_), do: "weak"

  # -- Add evidence to ledger ------------------------------------------

  defp add_evidence_to_ledger(evidence_list, claim, direction) do
    Enum.flat_map(evidence_list, fn ev ->
      ledger_strength = ev.strength / 10.0
      case EpistemicLedger.add_evidence(
        [
          claim_id: claim.id,
          summary: ev.summary,
          direction: direction,
          strength: ledger_strength,
          confidence: ledger_strength,
          source_type: Atom.to_string(ev.source_type)
        ],
        @ledger_name
      ) do
        %Models.Evidence{} = record -> [record]
        {:error, reason} ->
          Logger.warning("[investigate] Failed to add evidence: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Format adversarial evidence for display -------------------------

  defp format_adversarial_evidence([]), do: "  (none)"
  defp format_adversarial_evidence(evidence) do
    evidence
    |> Enum.with_index(1)
    |> Enum.map(fn {ev, i} ->
      tag = if ev.source_type == :sourced, do: "SOURCED", else: "REASONING"
      "  #{i}. [#{tag}] (strength: #{ev.strength}/10) #{ev.summary}"
    end)
    |> Enum.join("\n")
  end

  # -- Helpful counter increment (compound loop) -----------------------

  defp increment_helpful_for_reused_evidence(store, prior_evidence_texts, current_evidence) do
    # Only increment helpful counter when prior evidence is independently regenerated
    Enum.each(prior_evidence_texts, fn prior_text ->
      # Check if any current evidence covers the same ground
      was_reused = Enum.any?(current_evidence, fn ev ->
        prior_words = significant_words(prior_text)
        ev_words = significant_words(ev.summary)
        set1 = MapSet.new(prior_words)
        set2 = MapSet.new(ev_words)
        intersection = MapSet.intersection(set1, set2) |> MapSet.size()
        union_size = MapSet.union(set1, set2) |> MapSet.size()
        union_size > 0 and intersection / union_size >= 0.3
      end)

      if was_reused do
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
                  Logger.debug("[investigate] Incremented helpful count for #{ev_id} to #{old_count + 1}")
                end
              _ -> :ok
            end
          _ -> :ok
        end
      end
    end)
  end

  defp significant_words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(10)
  end



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

  # -- Prior knowledge search — fetches EVIDENCE, not conclusions ------

  defp fetch_prior_evidence_by_keywords(store, keywords) do
    # Find prior investigations that match keywords
    topic_query = "SELECT ?s ?topic WHERE { ?s vaos:topic ?topic . ?s rdf:type vaos:Investigation }"
    kw_query = "SELECT ?s ?kw WHERE { ?s vaos:keyword ?kw . ?s rdf:type vaos:Investigation }"

    topic_results = case MiosaKnowledge.sparql(store, topic_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    kw_results = case MiosaKnowledge.sparql(store, kw_query) do
      {:ok, results} when is_list(results) -> results
      _ -> []
    end

    kw_matched_ids =
      kw_results
      |> Enum.filter(fn bindings ->
        stored_kw = Map.get(bindings, "kw", "") |> to_string() |> String.downcase()
        Enum.any?(keywords, fn kw -> kw == stored_kw or String.contains?(stored_kw, kw) or String.contains?(kw, stored_kw) end)
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)
      |> MapSet.new()

    matched_ids = topic_results
      |> Enum.filter(fn bindings ->
        s = Map.get(bindings, "s", "") |> to_string()
        topic_val = Map.get(bindings, "topic", Map.get(bindings, :topic, ""))
        topic_lower = String.downcase(to_string(topic_val))
        topic_match = Enum.any?(keywords, fn kw -> String.contains?(topic_lower, kw) end)
        kw_match = MapSet.member?(kw_matched_ids, s)
        topic_match or kw_match
      end)
      |> Enum.map(fn bindings -> Map.get(bindings, "s", "") |> to_string() end)

    # For each matched investigation, fetch the EVIDENCE summaries (not conclusions)
    Enum.flat_map(matched_ids, fn inv_id ->
      ev_query = "SELECT ?ev ?summary WHERE { <#{inv_id}> vaos:has_evidence ?ev . ?ev vaos:summary ?summary }"
      case MiosaKnowledge.sparql(store, ev_query) do
        {:ok, results} when is_list(results) ->
          Enum.map(results, fn r ->
            summary = Map.get(r, "summary", "")
            "  - #{summary} (id: #{inv_id})"
          end)
        _ -> []
      end
    end)
    |> Enum.take(20)  # Limit to avoid prompt bloat
  rescue
    e ->
      Logger.warning("[investigate] fetch_prior_evidence_by_keywords failed: #{Exception.message(e)}")
      []
  end

  # -- Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv --

  defp search_all_papers(topic) do
    http_fn = literature_http_fn()

    tasks = [
      # Semantic Scholar - supporting evidence
      Task.async(fn ->
        case Literature.search_semantic_scholar("evidence supporting #{topic}", http_fn, limit: 5) do
          {:ok, papers} -> {:semantic_scholar_for, papers}
          _ -> {:semantic_scholar_for, []}
        end
      end),
      # Semantic Scholar - opposing evidence
      Task.async(fn ->
        case Literature.search_semantic_scholar("evidence against #{topic}", http_fn, limit: 5) do
          {:ok, papers} -> {:semantic_scholar_against, papers}
          _ -> {:semantic_scholar_against, []}
        end
      end),
      # OpenAlex - supporting evidence
      Task.async(fn ->
        case Literature.search_openalex("#{topic} supporting evidence", http_fn, limit: 5) do
          {:ok, papers} -> {:openalex_for, papers}
          _ -> {:openalex_for, []}
        end
      end),
      # OpenAlex - opposing evidence
      Task.async(fn ->
        case Literature.search_openalex("#{topic} opposing evidence", http_fn, limit: 5) do
          {:ok, papers} -> {:openalex_against, papers}
          _ -> {:openalex_against, []}
        end
      end),
      # alphaXiv - embedding search (general, covers both sides)
      Task.async(fn ->
        alias OptimalSystemAgent.Tools.Builtins.AlphaXivClient
        case AlphaXivClient.embedding_search(topic) do
          {:ok, papers} when papers != [] ->
            Logger.debug("[investigate] alphaXiv returned #{length(papers)} papers")
            {:alphaxiv, papers}
          _ ->
            Logger.debug("[investigate] alphaXiv unavailable")
            {:alphaxiv, []}
        end
      end)
    ]

    results = Task.await_many(tasks, 30_000)

    # Collect source counts
    source_counts = Enum.reduce(results, %{}, fn {source, papers}, acc ->
      source_key = case source do
        :semantic_scholar_for -> :semantic_scholar
        :semantic_scholar_against -> :semantic_scholar
        :openalex_for -> :openalex
        :openalex_against -> :openalex
        :alphaxiv -> :alphaxiv
      end
      Map.update(acc, source_key, length(papers), &(&1 + length(papers)))
    end)

    # Normalize all papers to common string-key format
    all_raw = Enum.flat_map(results, fn {_source, papers} ->
      Enum.map(papers, &normalize_paper_format/1)
    end)

    # Dedup by title similarity
    deduped = merge_papers(all_raw)

    # Sort by citation count (most cited first)
    sorted = Enum.sort_by(deduped, fn p ->
      -(p["citation_count"] || p["citationCount"] || 0)
    end)
    |> Enum.take(15)

    {sorted, source_counts}
  end

  # Normalize Literature module structs (atom keys) to the string-key format
  # used throughout investigate.ex
  defp normalize_paper_format(%{title: t, source: src} = paper) do
    %{
      "title" => to_string(t || "Unknown"),
      "abstract" => to_string(paper[:abstract] || ""),
      "year" => to_string(paper[:year] || "unknown"),
      "citation_count" => paper[:citation_count] || 0,
      "citationCount" => paper[:citation_count] || 0,
      "source" => to_string(src),
      "authors" => Enum.join(paper[:authors] || [], ", "),
      "paper_id" => to_string(paper[:paper_id] || ""),
      "url" => to_string(paper[:url] || "")
    }
  end

  # Already string-keyed (from alphaXiv or legacy formats)
  defp normalize_paper_format(%{"title" => _} = paper) do
    Map.merge(%{
      "citation_count" => 0,
      "citationCount" => 0,
      "source" => "alphaxiv",
      "authors" => "",
      "abstract" => "",
      "year" => "unknown"
    }, paper)
    |> Map.update("citation_count", 0, fn v -> v || 0 end)
    |> Map.update("citationCount", 0, fn v -> v || 0 end)
  end

  defp normalize_paper_format(other) do
    Logger.warning("[investigate] Unknown paper format: #{inspect(other) |> String.slice(0, 200)}")
    %{"title" => "Unknown", "abstract" => "", "year" => "unknown",
      "citation_count" => 0, "citationCount" => 0, "source" => "unknown"}
  end

  # HTTP adapter for vaos-ledger Literature module — uses Req
  defp literature_http_fn do
    fn url, opts ->
      params = Keyword.get(opts, :params, [])
      headers = Keyword.get(opts, :headers, [])

      # Build query string from params
      query_string = case params do
        [] -> ""
        kv_list ->
          kv_list
          |> Enum.map(fn
            {k, v} -> "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
            other -> to_string(other)
          end)
          |> Enum.join("&")
      end

      full_url = if query_string == "", do: url, else: "#{url}?#{query_string}"
      req_headers = Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

      case Req.get(full_url, headers: req_headers, receive_timeout: 15_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            err -> {:error, {:json_decode_failed, err}}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[investigate] HTTP #{status} from #{url}: #{inspect(body) |> String.slice(0, 200)}")
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.warning("[investigate] HTTP request failed for #{url}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp format_source_counts(counts) do
    counts
    |> Enum.map(fn {source, count} -> "#{count} via #{source}" end)
    |> Enum.join(", ")
  end

  # -- Cross-investigation contradiction detection ---------------------

  defp detect_contradictions(store, current_id, current_direction, current_keywords) do
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

          case MiosaKnowledge.sparql(store, "SELECT ?dir WHERE { <#{prior_id}> vaos:direction ?dir }") do
            {:ok, [prior | _]} ->
              prior_direction = Map.get(prior, "dir", "unknown")

              is_conflict =
                (current_direction == "supporting" and prior_direction in ["opposing", "genuinely_contested"]) or
                (current_direction == "opposing" and prior_direction in ["supporting", "genuinely_contested"]) or
                (current_direction != prior_direction and current_direction != "genuinely_contested" and prior_direction != "genuinely_contested")

              if is_conflict do
                MiosaKnowledge.assert(store, {current_id, "vaos:contradicts", prior_id})
                MiosaKnowledge.assert(store, {prior_id, "vaos:contradictedBy", current_id})
                Logger.warning("[investigate] Epistemic tension: #{current_id} contradicts #{prior_id}")
                [%{prior_id: prior_id, prior_topic: prior_topic, prior_direction: prior_direction}]
              else
                []
              end
            _ -> []
          end
        end)
      _ -> []
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
