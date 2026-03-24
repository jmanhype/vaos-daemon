defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — adversarial dual-prompt architecture.

  EVIDENCE QUALITY PIPELINE: Paper type classification + evidence hierarchy scoring.
  Every citation is verified against paper abstracts AND classified by type
  (systematic review, RCT, observational study, other).

  Scores come from: verification status * evidence hierarchy weight * citation bonus.
  - Systematic reviews/meta-analyses score 3x
  - RCTs/experiments score 2x
  - Observational studies score 1.5x
  - Unclassified score 1x

  PAPER-FIRST DESIGN: Runs THREE parallel paper search pairs (FOR, AGAINST, and
  SYSTEMATIC REVIEWS), then feeds merged papers to TWO adversarial LLM prompts.

  Multi-source literature search: Semantic Scholar + OpenAlex + alphaXiv.
  Uses vaos-ledger's Literature module for Semantic Scholar and OpenAlex,
  with alphaXiv MCP for embedding-based arXiv search.

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
      "FOR, AGAINST, and REVIEWS), then dual adversarial LLM analysis with citation verification " <>
      "and evidence hierarchy scoring (review > trial > study > other)."
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
    #    Now includes a THIRD pair specifically for systematic reviews / meta-analyses
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

    # 8a. Build paper map for citation verification
    paper_map = all_papers
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {i, p} end)

    # 8b. Handle partial results honestly
    cond do
      supporting == [] and opposing == [] ->
        {:error, "Both adversarial LLM calls failed"}

      supporting == [] ->
        # Only AGAINST succeeded — verify what we have
        verified_opposing = verify_citations(opposing, paper_map)
        result = "## Investigation: #{topic}\n\n" <>
          "**Status: PARTIAL** -- Only the case AGAINST was analyzed (FOR advocate failed)\n" <>
          "**Cannot determine direction from one-sided analysis**\n\n" <>
          format_verified_evidence(verified_opposing, "Case Against") <>
          "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)
        {:ok, result}

      opposing == [] ->
        # Only FOR succeeded — verify what we have
        verified_supporting = verify_citations(supporting, paper_map)
        result = "## Investigation: #{topic}\n\n" <>
          "**Status: PARTIAL** -- Only the case FOR was analyzed (AGAINST advocate failed)\n" <>
          "**Cannot determine direction from one-sided analysis**\n\n" <>
          format_verified_evidence(verified_supporting, "Case For") <>
          "\n\n### Papers Consulted\n" <> format_paper_list(all_papers)
        {:ok, result}

      true ->
        # Both succeeded — full analysis with citation verification
        run_full_analysis(topic, supporting, opposing, all_papers, paper_map,
                          source_counts, keywords, prior_evidence, store)
    end
  rescue
    e -> {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # -- Full analysis (both sides succeeded) ------------------------------

  defp run_full_analysis(topic, supporting_raw, opposing_raw, all_papers, paper_map,
                         source_counts, keywords, prior_evidence, store) do
    # 9. CITATION VERIFICATION + PAPER TYPE CLASSIFICATION — the evidence quality step
    # Run all verification calls in parallel via Task.async
    verified_supporting = verify_citations(supporting_raw, paper_map)
    verified_opposing = verify_citations(opposing_raw, paper_map)

    # 10. Compute direction from hierarchy-weighted scores
    verified_for = Enum.count(verified_supporting, & &1.verified)
    verified_against = Enum.count(verified_opposing, & &1.verified)
    total_for_score = Enum.sum(Enum.map(verified_supporting, & &1.score))
    total_against_score = Enum.sum(Enum.map(verified_opposing, & &1.score))

    for_total = total_for_score
    against_total = total_against_score

    direction = cond do
      for_total > against_total * 1.3 -> "supporting"
      against_total > for_total * 1.3 -> "opposing"
      true -> "genuinely_contested"
    end

    # Count fraudulent citations
    fraudulent_count = Enum.count(verified_supporting ++ verified_opposing,
      fn ev -> ev.verification == "unverified" end)

    reasoning_for = Enum.count(verified_supporting,
      fn ev -> ev.verification == "no_citation" end)
    reasoning_against = Enum.count(verified_opposing,
      fn ev -> ev.verification == "no_citation" end)

    # Count paper types across all evidence
    all_evidence = verified_supporting ++ verified_opposing
    review_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :review end)
    trial_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :trial end)
    study_count = Enum.count(all_evidence, fn ev -> ev.paper_type == :study end)

    # 11. Create claim and add evidence to ledger
    claim = EpistemicLedger.add_claim(
      [title: String.slice(topic, 0, 100), statement: topic, tags: ["investigate", "auto", "adversarial"]],
      @ledger_name
    )

    # Add FOR arguments as supporting evidence (using hierarchy-weighted score)
    supporting_records = add_evidence_to_ledger(verified_supporting, claim, :support)

    # Add AGAINST arguments as BOTH attacks AND contradicting evidence
    _contra_records = add_evidence_to_ledger(verified_opposing, claim, :contradict)
    opposing_records = add_attacks_to_ledger(verified_opposing, claim)

    # Refresh claim to recompute metrics
    EpistemicLedger.refresh_claim(claim.id, @ledger_name)

    # Get ledger metrics for supplementary display
    metrics = EpistemicLedger.claim_metrics(claim.id, @ledger_name)
    belief = metrics["belief"]
    uncertainty = metrics["uncertainty"]

    # 12. Persist ledger to disk
    EpistemicLedger.save(@ledger_name)

    # 13. Store in knowledge graph
    topic_id = "investigate:" <> short_hash(topic)
    claim_id = claim.id

    json_result = Jason.encode!(%{
      topic: topic,
      claim_id: claim_id,
      direction: direction,
      verified_for: verified_for,
      verified_against: verified_against,
      reasoning_for: reasoning_for,
      reasoning_against: reasoning_against,
      for_score: Float.round(for_total * 1.0, 3),
      against_score: Float.round(against_total * 1.0, 3),
      fraudulent_citations: fraudulent_count,
      belief: Float.round(belief * 1.0, 3),
      uncertainty: Float.round(uncertainty * 1.0, 3),
      evidence_quality: %{
        reviews: review_count,
        trials: trial_count,
        studies: study_count
      },
      supporting: Enum.map(verified_supporting, fn ev ->
        %{summary: ev.summary, score: ev.score, verified: ev.verified,
          verification: ev.verification, paper_type: Atom.to_string(ev.paper_type),
          citation_count: ev.citation_count, strength_display: ev.strength}
      end),
      opposing: Enum.map(verified_opposing, fn ev ->
        %{summary: ev.summary, score: ev.score, verified: ev.verified,
          verification: ev.verification, paper_type: Atom.to_string(ev.paper_type),
          citation_count: ev.citation_count, strength_display: ev.strength}
      end),
      papers_found: length(all_papers),
      source_counts: source_counts,
      papers_detail: Enum.map(all_papers, fn p ->
        %{title: p["title"], year: p["year"],
          citations: p["citation_count"] || p["citationCount"] || 0,
          source: p["source"] || "unknown"}
      end),
      investigation_id: topic_id
    })

    triples = [
      {topic_id, "rdf:type", "vaos:Investigation"},
      {topic_id, "vaos:topic", topic},
      {topic_id, "vaos:direction", direction},
      {topic_id, "vaos:verified_for", Integer.to_string(verified_for)},
      {topic_id, "vaos:verified_against", Integer.to_string(verified_against)},
      {topic_id, "vaos:fraudulent_citations", Integer.to_string(fraudulent_count)},
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

    # Store helpful/harmful counters for supporting evidence
    Enum.each(supporting_records, fn ev ->
      ev_id = "evidence:" <> ev.id
      MiosaKnowledge.assert(store, {topic_id, "vaos:has_evidence", ev_id})
      MiosaKnowledge.assert(store, {ev_id, "vaos:helpful_count", "0"})
      MiosaKnowledge.assert(store, {ev_id, "vaos:harmful_count", "0"})
      MiosaKnowledge.assert(store, {ev_id, "vaos:summary", ev.summary})
    end)

    # Store attack records in knowledge graph
    Enum.each(opposing_records, fn atk ->
      atk_id = "attack:" <> atk.id
      MiosaKnowledge.assert(store, {topic_id, "vaos:has_attack", atk_id})
      MiosaKnowledge.assert(store, {atk_id, "vaos:helpful_count", "0"})
      MiosaKnowledge.assert(store, {atk_id, "vaos:harmful_count", "0"})
      MiosaKnowledge.assert(store, {atk_id, "vaos:summary", atk.description})
    end)

    # Increment helpful counters for prior evidence that was independently regenerated
    increment_helpful_for_reused_evidence(store, prior_evidence, verified_supporting ++ verified_opposing)

    # 14. Cross-investigation contradiction detection
    conflicts = detect_contradictions(store, topic_id, direction, keywords)
    conflict_note = if conflicts == [] do
      ""
    else
      conflict_lines = Enum.map(conflicts, fn c ->
        "  - #{c.prior_topic} (#{c.prior_id}): #{c.prior_direction} vs current #{direction}"
      end)
      "\n### Cross-Investigation Conflicts\n" <> Enum.join(conflict_lines, "\n") <> "\n"
    end

    # 15. Format result with verification status and evidence quality
    for_arguments = format_verified_evidence(verified_supporting, "Case For (score: #{Float.round(for_total * 1.0, 2)})")
    against_arguments = format_verified_evidence(verified_opposing, "Case Against (score: #{Float.round(against_total * 1.0, 2)})")

    paper_list = format_paper_list(all_papers)

    result =
      "## Investigation: #{topic}\n\n" <>
      "**Direction: #{direction}**\n" <>
      "**Verified citations for: #{verified_for} | Verified citations against: #{verified_against}**\n" <>
      "**Fraudulent citations detected: #{fraudulent_count}**\n" <>
      "**Evidence quality: #{review_count} reviews, #{trial_count} trials, #{study_count} studies**\n" <>
      "**Score: #{Float.round(for_total * 1.0, 2)} for vs #{Float.round(against_total * 1.0, 2)} against**\n" <>
      "**Ledger belief: #{Float.round(belief * 1.0, 3)}, uncertainty: #{Float.round(uncertainty * 1.0, 3)}**\n" <>
      "**Papers found:** #{length(all_papers)} (#{format_source_counts(source_counts)})\n\n" <>
      "### #{for_arguments}\n\n" <>
      "### #{against_arguments}\n\n" <>
      "### Papers Consulted\n#{paper_list}\n" <>
      conflict_note <>
      (if prior_evidence != [], do: "\n### Prior Evidence (related topics)\n" <> Enum.join(prior_evidence, "\n") <> "\n", else: "") <>
      "\n### Keywords\n  " <> Enum.join(keywords, ", ") <> "\n\n" <>
      "*Claim ID: #{claim_id} -- stored in knowledge graph as #{topic_id}*" <>
      "\n\n<!-- VAOS_JSON:#{json_result} -->"

    {:ok, result}
  end

  # -- Citation Verification + Paper Type Classification ------------------

  defp verify_citations(evidence_list, paper_map) do
    # Split into items that need LLM verification and those that don't
    {need_llm, no_llm} = Enum.split_with(evidence_list, fn ev ->
      case extract_paper_ref(ev.summary) do
        nil -> false
        n -> Map.has_key?(paper_map, n)
      end
    end)

    # Handle non-LLM items immediately
    no_llm_verified = Enum.map(no_llm, fn ev ->
      case extract_paper_ref(ev.summary) do
        nil -> %{ev | verified: false, verification: "no_citation", paper_type: :reasoning, citation_count: 0, score: 0.15}
        _n -> %{ev | verified: false, verification: "invalid_ref", paper_type: :other, citation_count: 0, score: 0.0}
      end
    end)

    # Run LLM verification in batches of 3 to avoid rate limits
    llm_verified = need_llm
      |> Enum.chunk_every(3)
      |> Enum.flat_map(fn batch ->
        tasks = Enum.map(batch, fn ev ->
          Task.async(fn ->
            paper_num = extract_paper_ref(ev.summary)
            paper = Map.get(paper_map, paper_num)
            citation_count = paper["citation_count"] || paper["citationCount"] || 0

            case verify_single_citation(ev, paper) do
              {verification, paper_type} ->
                score = compute_evidence_score(verification, paper_type, citation_count)
                verified = verification in [:verified, :partial]
                verification_str = Atom.to_string(verification)
                %{ev | verified: verified, verification: verification_str, paper_type: paper_type, citation_count: citation_count, score: score}
            end
          end)
        end)
        results = Task.await_many(tasks, 120_000)
        # Small pause between batches to avoid rate limits
        if length(need_llm) > 3, do: Process.sleep(1_000)
        results
      end)

    # Recombine in original order by matching on summary
    original_order = Enum.map(evidence_list, fn ev ->
      Enum.find(llm_verified ++ no_llm_verified, fn v -> v.summary == ev.summary end) || ev
    end)

    original_order
  end

  defp extract_paper_ref(summary) do
    case Regex.run(~r/\[Paper (\d+)\]/, summary) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  defp verify_single_citation(evidence, paper) do
    abstract = Map.get(paper, "abstract", "") || ""
    title = Map.get(paper, "title", "") || ""

    prompt = """
    Paper title: #{title}
    Paper abstract: #{String.slice(to_string(abstract), 0, 500)}

    Claim: #{evidence.summary}

    Two questions:
    1. Does this paper's abstract support the specific claim? VERIFIED / PARTIAL / UNVERIFIED
    2. Paper type? REVIEW (systematic review/meta-analysis), TRIAL (RCT/experiment), STUDY (observational/single study), OTHER

    Answer format: WORD WORD (e.g., VERIFIED REVIEW or UNVERIFIED STUDY)
    """

    messages = [%{role: "user", content: prompt}]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    verify_opts = [temperature: 0.0, max_tokens: 15]
    verify_opts = if model, do: Keyword.put(verify_opts, :model, model), else: verify_opts

    case Providers.chat(messages, verify_opts) do
      {:ok, %{content: response}} when is_binary(response) ->
        response_clean = String.trim(response) |> String.upcase()

        verification = cond do
          String.contains?(response_clean, "UNVERIFIED") -> :unverified
          String.contains?(response_clean, "PARTIAL") -> :partial
          String.contains?(response_clean, "VERIFIED") -> :verified
          true -> :unverified
        end

        paper_type = cond do
          String.contains?(response_clean, "REVIEW") -> :review
          String.contains?(response_clean, "TRIAL") -> :trial
          String.contains?(response_clean, "STUDY") -> :study
          true -> :other
        end

        {verification, paper_type}
      _ -> {:unverified, :other}
    end
  end

  # -- Evidence hierarchy scoring -----------------------------------------

  defp compute_evidence_score(verification, paper_type, citation_count) do
    # Base score from verification
    base = case verification do
      :verified -> 1.0
      :partial -> 0.5
      :unverified -> 0.0
    end

    # Evidence hierarchy weight
    type_weight = case paper_type do
      :review -> 3.0    # Systematic review / meta-analysis
      :trial -> 2.0     # RCT / experiment
      :study -> 1.5     # Observational / single study
      :other -> 1.0     # Unclassified
    end

    # Citation count bonus (log scale)
    citation_bonus = :math.log10(max(citation_count, 2))

    # Final score
    base * type_weight * citation_bonus
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
      # Keep LLM-assigned strength for DISPLAY only.
      # Score, verified, paper_type, citation_count filled by verify_citations.
      %{summary: String.trim(summary), source_type: source_type, strength: strength,
        paper_ref: extract_paper_ref(String.trim(summary)),
        verified: false, verification: "pending", paper_type: :other,
        citation_count: 0, score: 0.0}
    end)
  end

  # -- Add evidence to ledger ------------------------------------------

  defp add_evidence_to_ledger(evidence_list, claim, direction) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_strength = ev.score
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

  # -- Add attacks to ledger (AGAINST arguments = falsification attempts) --

  defp add_attacks_to_ledger(evidence_list, claim) do
    Enum.flat_map(evidence_list, fn ev ->
      # Use hierarchy-weighted VERIFICATION score, not LLM strength
      ledger_severity = ev.score
      source = if ev.source_type == :sourced, do: "paper", else: "llm_reasoning"
      case EpistemicLedger.add_attack(
        [
          claim_id: claim.id,
          description: ev.summary,
          target_kind: "claim",
          target_id: claim.id,
          severity: ledger_severity,
          status: :open,
          metadata: %{
            "source" => source,
            "source_type" => Atom.to_string(ev.source_type),
            "raw_strength" => ev.strength,
            "verified" => ev.verified,
            "verification" => ev.verification,
            "paper_type" => Atom.to_string(ev.paper_type),
            "citation_count" => ev.citation_count,
            "score" => ev.score
          }
        ],
        @ledger_name
      ) do
        %Models.Attack{} = record -> [record]
        {:error, reason} ->
          Logger.warning("[investigate] Failed to add attack: #{inspect(reason)}")
          []
      end
    end)
  end

  # -- Format verified evidence for display -----------------------------

  defp format_verified_evidence([], _heading), do: "(none)"
  defp format_verified_evidence(evidence, heading) do
    lines = evidence
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        type_tag = ev.paper_type |> Atom.to_string() |> String.upcase()
        cite_count = ev.citation_count
        score_str = Float.round(ev.score * 1.0, 1) |> to_string()

        {status_icon, detail} = case ev.verification do
          "verified" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"VERIFIED \u2713 #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}
          "partial" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"PARTIAL ~ #{type_tag}", "(#{paper_info}#{cite_str}, score: #{score_str})"}
          "unverified" ->
            paper_info = case ev.paper_ref do
              nil -> ""
              n -> "Paper #{n}, "
            end
            cite_str = format_citation_count(cite_count)
            {"UNVERIFIED \u2717", "(#{paper_info}#{cite_str}, score: #{score_str}) -- FRAUDULENT CITATION"}
          "no_citation" ->
            {"NO CITATION", "(reasoning only, score: #{score_str})"}
          "invalid_ref" ->
            {"INVALID REF", "(score: 0.0 -- cited paper doesn't exist)"}
          _ ->
            {"PENDING", "(score: #{score_str})"}
        end

        "  #{i}. [#{status_icon}] #{detail} #{ev.summary}"
      end)
      |> Enum.join("\n")

    "#{heading}\n#{lines}"
  end

  defp format_citation_count(count) when count >= 1000 do
    "#{Float.round(count / 1000.0, 1)}k citations"
  end
  defp format_citation_count(count), do: "#{count} citations"

  # -- Format paper list for display -----------------------------------

  defp format_paper_list(all_papers) do
    all_papers
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} ->
      citations = p["citation_count"] || p["citationCount"] || 0
      source = p["source"] || "unknown"
      "  [Paper #{i}] #{p["title"]} (#{p["year"]}, #{citations} citations, via #{source})"
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
      # Systematic review / meta-analysis search (highest quality evidence)
      Task.async(fn ->
        case Literature.search_openalex("systematic review OR meta-analysis #{topic}", http_fn, limit: 5) do
          {:ok, papers} -> {:openalex_reviews, papers}
          _ -> {:openalex_reviews, []}
        end
      end),
      Task.async(fn ->
        case Literature.search_semantic_scholar("systematic review meta-analysis #{topic}", http_fn, limit: 5) do
          {:ok, papers} -> {:semantic_scholar_reviews, papers}
          _ -> {:semantic_scholar_reviews, []}
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
        :semantic_scholar_reviews -> :semantic_scholar
        :openalex_for -> :openalex
        :openalex_against -> :openalex
        :openalex_reviews -> :openalex
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
