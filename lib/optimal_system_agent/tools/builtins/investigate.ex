defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool — uses the real Vaos.Ledger.Epistemic.Ledger
  GenServer for claim/evidence tracking with Bayesian confidence.

  Creates claims and evidence through the ledger API, letting IT compute
  confidence via refresh_claim. Prior knowledge search is keyword-based.
  At standard depth, still attempts ONE literature search for the strongest
  verifiable claim.
  """

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @ledger_path "/Users/batmanosama/.openclaw/investigate_ledger.json"
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
    # 1. Start the real epistemic ledger GenServer
    ensure_ledger_started()

    # 2. Extract keywords for prior knowledge search
    keywords = extract_keywords(topic)

    # 3. Prior knowledge search -- keyword-based, not hash-based
    ensure_store_started()
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

    sys_msg = "You are a rigorous epistemic analyst. Produce exactly the requested format. Each evidence line must start with [VERIFIABLE] or [REASONING]."

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
        supporting_records = Enum.map(supporting, fn ev ->
          strength = evidence_strength(ev.source_type)
          EpistemicLedger.add_evidence(
            [
              claim_id: claim.id,
              summary: ev.summary,
              direction: :support,
              strength: strength,
              confidence: strength,
              source_type: Atom.to_string(ev.source_type)
            ],
            @ledger_name
          )
        end)

        opposing_records = Enum.map(opposing, fn ev ->
          strength = evidence_strength(ev.source_type)
          EpistemicLedger.add_evidence(
            [
              claim_id: claim.id,
              summary: ev.summary,
              direction: :contradict,
              strength: strength,
              confidence: strength,
              source_type: Atom.to_string(ev.source_type)
            ],
            @ledger_name
          )
        end)

        # 7. Add assumptions through the real ledger
        Enum.each(assumptions, fn a ->
          risk_val = case a.risk do
            "high" -> 0.9
            "medium" -> 0.5
            "low" -> 0.2
            _ -> 0.5
          end
          EpistemicLedger.add_assumption(
            [claim_id: claim.id, text: a.text, risk: risk_val],
            @ledger_name
          )
        end)

        # 8. Literature search
        #    - deep: enrich ALL verifiable evidence
        #    - standard: try ONE search for the strongest verifiable claim
        all_parsed = supporting ++ opposing

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
        updated_claim = state.claims[claim.id]
        confidence = updated_claim.confidence
        status = updated_claim.status

        # 10. Persist ledger to disk
        EpistemicLedger.save(@ledger_name)

        # 11. Determine commitment level
        all_ev = supporting_records ++ opposing_records
        has_sourced = Enum.any?(all_ev, fn ev -> ev.source_type == "sourced" end)
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
    |> Enum.take(4)
  end

  # -- Prior knowledge search -- keyword-based -------------------------

  defp fetch_prior_by_keywords(store, keywords) do
    # Query ALL investigations from the knowledge graph
    query = "SELECT ?s ?topic WHERE { ?s <vaos:topic> ?topic . ?s <rdf:type> <vaos:Investigation> }"
    case MiosaKnowledge.sparql(store, query) do
      {:ok, results} when is_list(results) ->
        results
        |> Enum.filter(fn bindings ->
          topic_val = Map.get(bindings, "topic", Map.get(bindings, :topic, ""))
          topic_lower = String.downcase(to_string(topic_val))
          # Match if ANY keyword appears in the prior topic
          Enum.any?(keywords, fn kw -> String.contains?(topic_lower, kw) end)
        end)
        |> Enum.map(fn bindings ->
          s = Map.get(bindings, "s", Map.get(bindings, :s, "?"))
          t = Map.get(bindings, "topic", Map.get(bindings, :topic, "?"))
          "  Prior: " <> to_string(t) <> " (id: " <> to_string(s) <> ")"
        end)
      _ -> []
    end
  rescue
    _ -> []
  end

  # -- Literature search -- Semantic Scholar ---------------------------

  defp search_semantic_scholar(query) do
    :inets.start()
    :ssl.start()
    url = "https://api.semanticscholar.org/graph/v1/paper/search?query=#{URI.encode(query)}&limit=3&fields=title,abstract,citationCount,year"
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, Jason.decode!(List.to_string(body))["data"] || []}
      _ -> {:error, :search_failed}
    end
  rescue
    _ -> {:error, :search_failed}
  end

  # Deep: enrich ALL verifiable evidence with literature
  defp enrich_all_with_literature(parsed_list, claim_id) do
    parsed_list
    |> Enum.with_index()
    |> Enum.reduce(0, fn {parsed, idx}, count ->
      if parsed.source_type == :verifiable do
        case search_semantic_scholar(parsed.summary) do
          {:ok, papers} when papers != [] ->
            paper = List.first(papers)
            source_ref = "#{paper["title"]} (#{paper["year"]}, citations: #{paper["citationCount"]})"
            direction = if idx < 3, do: :support, else: :contradict
            EpistemicLedger.add_evidence(
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
            )
            count + 1
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
            source_ref = "#{paper["title"]} (#{paper["year"]}, citations: #{paper["citationCount"]})"
            # Add sourced evidence to the ledger
            EpistemicLedger.add_evidence(
              [
                claim_id: claim_id,
                summary: best_parsed.summary <> " [grounded: " <> source_ref <> "]",
                direction: :support,
                strength: 0.8,
                confidence: 0.8,
                source_type: "sourced",
                source_ref: source_ref
              ],
              @ledger_name
            )
            "1 evidence item grounded: " <> source_ref
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
    ~r/\d+\.\s*\[(VERIFIABLE|REASONING)\]\s*(.+)/i
    |> Regex.scan(section)
    |> Enum.map(fn [_, type, summary] ->
      source_type = if String.upcase(type) == "VERIFIABLE", do: :verifiable, else: :reasoning
      %{summary: String.trim(summary), source_type: source_type}
    end)
  end

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

  defp store_ref, do: Vaos.Knowledge.store_ref("osa_default")

  defp ensure_store_started do
    case Vaos.Knowledge.open("osa_default") do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end
end
