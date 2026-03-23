defmodule OptimalSystemAgent.Tools.Builtins.Investigate do
  @moduledoc """
  Epistemic investigation tool - triggers a full analysis cycle on any claim.

  One mandatory LLM call generates structured supporting/opposing evidence and
  hidden assumptions. Results are persisted to the knowledge graph and a local
  epistemic ledger (JSON). Optional literature search at deep depth.
  """

  @behaviour MiosaTools.Behaviour

  alias MiosaProviders.Registry, as: Providers

  @ledger_path "/Users/batmanosama/.openclaw/investigate_ledger.json"

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "investigate"

  @impl true
  def description do
    "Investigate a claim or topic: generates structured supporting/opposing evidence, " <>
      "tracks epistemic confidence, and stores results in the knowledge graph."
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
          "description" => "standard = LLM analysis only; deep = also searches literature"
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

  defp run_investigation(topic, depth) do
    topic_hash = Base.encode16(:crypto.hash(:sha256, topic), case: :lower) |> String.slice(0, 16)
    topic_id = "investigate:" <> topic_hash
    claim_id = "claim_" <> topic_hash

    # 1. Prior check - SPARQL the knowledge graph
    ensure_store_started()
    store = store_ref()
    prior = fetch_prior(store, topic_id)

    # 2. LLM call - structured evidence generation
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

        # Optional literature search (deep depth)
        supporting = if depth == "deep", do: enrich_with_literature(supporting), else: supporting
        opposing = if depth == "deep", do: enrich_with_literature(opposing), else: opposing

        # Compute confidence
        has_sourced = Enum.any?(supporting ++ opposing, &(&1.source_type == :sourced))
        support_str = supporting |> Enum.map(& &1.strength) |> Enum.sum()
        oppose_str = opposing |> Enum.map(& &1.strength) |> Enum.sum()
        total = support_str + oppose_str
        confidence = if total > 0, do: Float.round(support_str / total, 3), else: 0.5

        status = cond do
          confidence >= 0.7 -> "supported"
          confidence <= 0.3 -> "contested"
          true -> "uncertain"
        end

        commitment = if has_sourced, do: "committed", else: "belief_only"

        # Update ledger
        evidence_records =
          Enum.map(supporting, &evidence_to_map(&1, :support)) ++
          Enum.map(opposing, &evidence_to_map(&1, :contradict))

        assumption_records = Enum.map(assumptions, &assumption_to_map/1)

        claim = %{
          "id" => claim_id,
          "title" => String.slice(topic, 0, 100),
          "statement" => topic,
          "tags" => ["investigate", "auto"],
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "evidence" => evidence_records,
          "assumptions" => assumption_records,
          "confidence" => confidence,
          "status" => status
        }

        ledger = load_ledger()
        ledger = Map.put(ledger, claim_id, claim)
        save_ledger(ledger)

        # Store in knowledge graph
        triples = [
          {topic_id, "rdf:type", "vaos:Investigation"},
          {topic_id, "vaos:topic", topic},
          {topic_id, "vaos:confidence", Float.to_string(confidence)},
          {topic_id, "vaos:status", status},
          {topic_id, "vaos:commitment", commitment},
          {topic_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
        ]

        sourced_triples =
          (supporting ++ opposing)
          |> Enum.with_index()
          |> Enum.map(fn {ev, i} ->
            ev_id = topic_id <> ":ev" <> Integer.to_string(i)
            kind = if ev.source_type == :sourced, do: "vaos:GroundedEvidence", else: "vaos:BeliefEvidence"
            {ev_id, "rdf:type", kind}
          end)

        for triple <- triples ++ sourced_triples do
          MiosaKnowledge.assert(store, triple)
        end

        # Format result
        result =
          "## Investigation: " <> topic <> "\n\n" <>
          "**Commitment**: " <> commitment <> "\n" <>
          "**Confidence**: " <> Float.to_string(confidence) <> "\n" <>
          "**Status**: " <> status <> "\n\n" <>
          "### Supporting Evidence\n" <> format_evidence(supporting) <> "\n\n" <>
          "### Opposing Evidence\n" <> format_evidence(opposing) <> "\n\n" <>
          "### Assumptions\n" <> format_assumptions(assumptions) <> "\n\n" <>
          "### Prior Knowledge\n" <>
          (if prior == [], do: "  None", else: Enum.join(prior, "\n")) <> "\n\n" <>
          "*Claim ID: " <> claim_id <> " -- stored in knowledge graph as " <> topic_id <> "*"

        {:ok, result}

      {:ok, _} ->
        {:error, "LLM returned empty or unexpected response"}

      {:error, reason} ->
        {:error, "LLM call failed: " <> inspect(reason)}
    end
  rescue
    e -> {:error, "Investigation failed: " <> Exception.message(e)}
  end

  # --- Parsing ---

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
      %{
        summary: String.trim(summary),
        source_type: source_type,
        strength: if(source_type == :verifiable, do: 0.6, else: 0.5),
        sourced: false
      }
    end)
  end

  defp parse_assumptions_section(section) do
    ~r/\d+\.\s*(.+?)\s*\(risk:\s*(high|medium|low)\)/i
    |> Regex.scan(section)
    |> Enum.map(fn [_, text, risk] ->
      %{text: String.trim(text), risk: String.downcase(risk)}
    end)
  end

  # --- Literature enrichment (deep depth) ---

  defp enrich_with_literature(evidence_list) do
    Enum.map(evidence_list, fn ev ->
      if ev.source_type == :verifiable do
        case search_literature(ev.summary) do
          {:ok, _papers} -> %{ev | source_type: :sourced, strength: 0.8, sourced: true}
          _ -> ev
        end
      else
        ev
      end
    end)
  end

  defp search_literature(query) do
    encoded = URI.encode(query)
    url = "https://api.semanticscholar.org/graph/v1/paper/search?query=" <> encoded <> "&limit=3&fields=title,year,citationCount"

    case Req.get(url, headers: [{"user-agent", "OSA/1.0"}], receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => papers}}} when papers != [] ->
        {:ok, papers}
      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  # --- Formatting ---

  defp format_evidence(items) do
    if items == [] do
      "  (none)"
    else
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} ->
        tag = case ev.source_type do
          :sourced -> "SOURCED"
          :verifiable -> "VERIFIABLE"
          _ -> "REASONING"
        end
        "  " <> Integer.to_string(i) <> ". [" <> tag <> "] " <> ev.summary <> " (strength: " <> Float.to_string(ev.strength) <> ")"
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
        "  " <> Integer.to_string(i) <> ". " <> a.text <> " (risk: " <> a.risk <> ")"
      end)
      |> Enum.join("\n")
    end
  end

  # --- Ledger persistence ---

  defp load_ledger do
    case File.read(@ledger_path) do
      {:ok, data} -> Jason.decode!(data)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save_ledger(ledger) do
    File.mkdir_p!(Path.dirname(@ledger_path))
    File.write!(@ledger_path, Jason.encode!(ledger, pretty: true))
  end

  defp evidence_to_map(ev, direction) do
    %{
      "summary" => ev.summary,
      "direction" => Atom.to_string(direction),
      "strength" => ev.strength,
      "source_type" => Atom.to_string(ev.source_type),
      "sourced" => ev.sourced
    }
  end

  defp assumption_to_map(a) do
    %{"text" => a.text, "risk" => a.risk}
  end

  # --- Knowledge graph helpers ---

  defp store_ref, do: Vaos.Knowledge.store_ref("osa_default")

  defp ensure_store_started do
    case Vaos.Knowledge.open("osa_default") do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end

  defp fetch_prior(store, topic_id) do
    query = "SELECT ?p ?o WHERE { <" <> topic_id <> "> ?p ?o }"
    case MiosaKnowledge.sparql(store, query) do
      {:ok, results} when is_list(results) ->
        Enum.map(results, fn bindings ->
          p = Map.get(bindings, "p", Map.get(bindings, :p, "?"))
          o = Map.get(bindings, "o", Map.get(bindings, :o, "?"))
          "  " <> to_string(p) <> " = " <> to_string(o)
        end)
      _ -> []
    end
  rescue
    _ -> []
  end
end
