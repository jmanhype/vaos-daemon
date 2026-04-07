defmodule Daemon.Agent.Context do
  @moduledoc """
  Two-tier token-budgeted system prompt assembly.

  ## Architecture

  The context builder operates in two tiers:

      Tier 1 — Static Base (cached, from Soul.static_base/0)
        SYSTEM.md interpolated with {{TOOL_DEFINITIONS}}, {{RULES}}, {{USER_PROFILE}}.
        Cached in persistent_term. Never recomputed within a session.
        Includes Signal Theory instructions — the LLM self-classifies signals.

      Tier 2 — Dynamic Context (per-request, token-budgeted)
        Runtime, environment, plan mode, memory, tasks, workflow.
        All blocks are budget-fitted to prevent overflow.

  No code-level signal classification on the hot path. The LLM reads the
  Signal Theory tables in SYSTEM.md and applies Mode/Genre/Weight behavior
  natively — same pattern as Claude Code, Cursor, Windsurf.

  ## Token Budget

      dynamic_budget = max_tokens - static_tokens - conversation_tokens - reserve

  ## Provider Cache Hints

  For Anthropic, the system message is split into 2 content blocks:
    - Static base with `cache_control: %{type: "ephemeral"}` (~90% cache hit)
    - Dynamic context (per-request, uncached)

  ## Public API

      build(state)         — returns %{messages: [system_msg | conversation]}
      token_budget(state)  — returns token usage breakdown map
  """

  require Logger

  alias Daemon.Agent.Scratchpad
  alias Daemon.Agent.Tasks
  alias Daemon.Agent.Memory.Episodic
  alias Daemon.Agent.Memory.Injector
  alias Daemon.Agent.Memory.Taxonomy
  alias Daemon.Soul

  @response_reserve 8_192

  defp max_tokens, do: Application.get_env(:daemon, :max_context_tokens, 128_000)
  defp max_tokens(model), do: MiosaProviders.Registry.context_window(model)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds the full message list (system prompt + conversation history) within
  the configured token budget.

  Returns `%{messages: [system_msg | conversation_messages]}`.
  """
  @spec build(map()) :: %{messages: [map()]}
  def build(state, _signal), do: build(state)

  def build(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = case Map.get(state, :model) do
      nil -> max_tokens()
      "" -> max_tokens()
      model -> max_tokens(model)
    end

    # Tier 1: Cached static base
    static_base = Soul.static_base()
    static_tokens = Soul.static_token_count()

    # Tier 2: Dynamic context
    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, dynamic_budget)

    dynamic_tokens = estimate_tokens(dynamic_context)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + @response_reserve

    Logger.debug(
      "Context.build: static=#{static_tokens} dynamic=#{dynamic_tokens} " <>
        "conversation=#{conversation_tokens} reserve=#{@response_reserve} " <>
        "total=#{total_tokens}/#{max_tok} (#{Float.round(total_tokens / max_tok * 100, 1)}%)"
    )

    system_msg = build_system_message(static_base, dynamic_context)
    %{messages: [system_msg | conversation]}
  end

  @doc """
  Returns a token usage breakdown for debugging purposes.
  """
  @spec token_budget(map()) :: map()
  def token_budget(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    max_tok = max_tokens()
    static_tokens = Soul.static_token_count()

    # Gather dynamic blocks for individual cost breakdown
    blocks = gather_dynamic_blocks(state)

    block_details =
      Enum.map(blocks, fn {content, priority, label} ->
        %{
          label: label,
          priority: priority,
          tokens: estimate_tokens(content || "")
        }
      end)

    dynamic_budget = max(max_tok - @response_reserve - conversation_tokens - static_tokens, 1_000)
    dynamic_context = assemble_dynamic_context(state, dynamic_budget)
    dynamic_tokens = estimate_tokens(dynamic_context)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + @response_reserve

    %{
      max_tokens: max_tok,
      response_reserve: @response_reserve,
      conversation_tokens: conversation_tokens,
      static_base_tokens: static_tokens,
      dynamic_context_tokens: dynamic_tokens,
      system_prompt_budget: max_tok - @response_reserve - conversation_tokens,
      system_prompt_actual: static_tokens + dynamic_tokens,
      total_tokens: total_tokens,
      utilization_pct: Float.round(total_tokens / max_tok * 100, 1),
      headroom: max_tok - total_tokens,
      blocks: block_details
    }
  end

  # ---------------------------------------------------------------------------
  # System message construction
  # ---------------------------------------------------------------------------

  defp build_system_message(static_base, dynamic_context) do
    provider = Application.get_env(:daemon, :default_provider, :unknown)

    if provider == :anthropic and dynamic_context != "" do
      # Anthropic cache hint: split into 2 content blocks.
      # The static base gets cache_control for ~90% input token savings after first call.
      %{
        role: "system",
        content: [
          %{type: "text", text: static_base, cache_control: %{type: "ephemeral"}},
          %{type: "text", text: dynamic_context}
        ]
      }
    else
      # All other providers: single concatenated string
      full_prompt =
        if dynamic_context == "" do
          static_base
        else
          static_base <> "\n\n" <> dynamic_context
        end

      %{role: "system", content: full_prompt}
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic context assembly
  # ---------------------------------------------------------------------------

  defp assemble_dynamic_context(state, budget) do
    blocks = gather_dynamic_blocks(state)

    # All blocks are tier 1 (always included) — just fit within budget
    {parts, _used} = fit_blocks(blocks, budget)

    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # ---------------------------------------------------------------------------
  # Dynamic block gathering — each returns {content, priority, label}
  # ---------------------------------------------------------------------------

  defp gather_dynamic_blocks(state) do
    blocks_spec = [
      {:tool_process, 1, fn -> tool_process_block(state) end},
      {:runtime, 1, fn -> runtime_block(state) end},
      {:environment, 1, fn -> environment_block(state) end},
      {:plan_mode, 1, fn -> plan_mode_block(state) end},
      {:memory, 1, fn -> memory_block_relevant(state) end},
      {:episodic, 1, fn -> episodic_block(state) end},
      {:task_state, 1, fn -> task_state_block(state) end},
      {:workflow, 1, fn -> workflow_block(state) end},
      {:skills, 2, fn -> skills_block(state) end},
      {:scratchpad, 1, fn -> scratchpad_block(state) end},
      {:vault, 2, fn -> vault_block(state) end},
      {:knowledge, 2, fn -> knowledge_block(state) end},
      {:decision_intelligence, 2, fn -> decision_intelligence_block(state) end}
    ]

    blocks_spec
    |> Enum.map(fn {label, priority, fun} ->
      content = fun.()
      {content, priority, to_string(label)}
    end)
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
  end

  # ---------------------------------------------------------------------------
  # Fitting blocks into a budget
  # ---------------------------------------------------------------------------

  defp fit_blocks(_blocks, budget) when budget <= 0, do: {[], 0}

  defp fit_blocks(blocks, budget) do
    {parts, used} =
      Enum.reduce(blocks, {[], 0}, fn {content, _priority, _label}, {acc, tokens_used} ->
        block_tokens = estimate_tokens(content)
        available = budget - tokens_used

        cond do
          available <= 0 ->
            {acc, tokens_used}

          block_tokens <= available ->
            {acc ++ [content], tokens_used + block_tokens}

          true ->
            truncated = truncate_to_tokens(content, available)
            truncated_tokens = estimate_tokens(truncated)
            {acc ++ [truncated], tokens_used + truncated_tokens}
        end
      end)

    {parts, used}
  end

  # ---------------------------------------------------------------------------
  # Token estimation
  # ---------------------------------------------------------------------------

  @doc """
  Estimates the number of tokens in a text string.

  Uses the Go tokenizer for accurate BPE counting when available,
  falling back to a word + punctuation heuristic.
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    case Daemon.Go.Tokenizer.count_tokens(text) do
      {:ok, count} -> count
      {:error, _} -> estimate_tokens_heuristic(text)
    end
  catch
    _, _ -> estimate_tokens_heuristic(text)
  end

  defp estimate_tokens_heuristic(text),
    do: Daemon.Utils.Tokens.estimate(text)

  @doc """
  Estimates token count for a list of messages.
  """
  @spec estimate_tokens_messages([map()]) :: non_neg_integer()
  def estimate_tokens_messages([]), do: 0

  def estimate_tokens_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = estimate_tokens(safe_to_string(Map.get(msg, :content)))

      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn
              tc, tc_acc when is_map(tc) ->
                name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
                arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
                tc_acc + name_tokens + arg_tokens + 4

              _, tc_acc ->
                tc_acc
            end)
        end

      acc + content_tokens + tool_call_tokens + 4
    end)
  end

  defp safe_to_string(val),
    do: Daemon.Utils.Text.safe_to_string(val)

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  defp truncate_to_tokens(_text, target_tokens) when target_tokens <= 0, do: ""

  defp truncate_to_tokens(text, target_tokens) do
    words = String.split(text, ~r/\s+/, trim: true)
    max_words = max(round(target_tokens / 1.3), 1)

    if length(words) <= max_words do
      text
    else
      truncated =
        words
        |> Enum.take(max_words)
        |> Enum.join(" ")

      truncated <> "\n\n[...truncated...]"
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic block builders
  # ---------------------------------------------------------------------------

  defp memory_block_relevant(state) do
    latest_user_msg = find_latest_user_message(state.messages)
    content =
      if latest_user_msg do
        try do
          recall_relevant(latest_user_msg)
        rescue
          _ -> full_recall()
        catch
          :exit, _ -> full_recall()
        end
      else
        full_recall()
      end

    # Append taxonomy-classified memories via Injector (if available)
    taxonomy_addendum = taxonomy_inject(state, latest_user_msg)

    combined =
      case {content, taxonomy_addendum} do
        {nil, nil} -> nil
        {nil, add} -> add
        {text, nil} -> text
        {text, add} -> text <> "\n\n" <> add
      end

    case combined do
      nil -> nil
      "" -> nil
      text -> "## Long-term Memory\n#{text}"
    end
  end

  defp taxonomy_inject(state, latest_user_msg) do
    session_id = Map.get(state, :session_id, "default")
    working_dir = Map.get(state, :working_dir) || File.cwd!()

    # Attempt to load taxonomy entries from the learning engine
    taxonomy_entries =
      try do
        patterns_map = Daemon.Agent.Learning.patterns()
        solutions_map = Daemon.Agent.Learning.solutions()

        pattern_entries =
          patterns_map
          |> Enum.map(fn {key, val} ->
            content = "#{key}: #{inspect(val)}"
            Taxonomy.new(content, category: :pattern, scope: :workspace)
          end)

        solution_entries =
          solutions_map
          |> Enum.map(fn {key, val} ->
            correction = Map.get(val, :correction, inspect(val))
            content = "#{key} -> #{correction}"
            Taxonomy.new(content, category: :solution, scope: :workspace)
          end)

        pattern_entries ++ solution_entries
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    if taxonomy_entries == [] do
      nil
    else
      # Guard nil working_dir before entering file operations
      working_dir = if is_binary(working_dir), do: working_dir, else: File.cwd!()

      try do
        # Build files list from working dir (top-level only, for context)
        files =
          try do
            working_dir
            |> File.ls!()
            |> Enum.take(20)
            |> Enum.map(&Path.join(working_dir, &1))
          rescue
            _ -> []
          end

        context = %{
          files: files,
          task: latest_user_msg || "",
          session_id: session_id
        }

        injected = Injector.inject_relevant(taxonomy_entries, context)

        case injected do
          [] -> nil
          entries -> Injector.format_for_prompt(entries)
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    end
  end

  defp find_latest_user_message(nil), do: nil
  defp find_latest_user_message([]), do: nil

  defp find_latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if to_string(Map.get(msg, :role)) == "user" do
        safe_to_string(Map.get(msg, :content, ""))
      end
    end)
  end

  defp recall_relevant(query) do
    full = full_recall()

    case full do
      nil ->
        nil

      "" ->
        nil

      text ->
        query_words =
          query
          |> String.downcase()
          |> String.split(~r/\s+/, trim: true)
          |> Enum.reject(&(String.length(&1) < 3))
          |> MapSet.new()

        if MapSet.size(query_words) == 0 do
          text
        else
          sections = String.split(text, ~r/\n(?=## )/, trim: true)

          relevant =
            sections
            |> Enum.filter(fn section ->
              section_words =
                section
                |> String.downcase()
                |> String.split(~r/\s+/, trim: true)
                |> MapSet.new()

              overlap = MapSet.intersection(query_words, section_words) |> MapSet.size()
              overlap >= 2 or overlap >= MapSet.size(query_words) * 0.2
            end)

          case relevant do
            [] -> nil
            _ -> Enum.join(relevant, "\n\n")
          end
        end
    end
  end

  defp full_recall do
    try do
      content = Daemon.Agent.Memory.recall()
      if content == "", do: nil, else: content
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp episodic_block(state) do
    session_id = Map.get(state, :session_id, "default")

    events =
      try do
        Episodic.recent(session_id, 10)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case events do
      [] ->
        nil

      events ->
        lines =
          Enum.map(events, fn event ->
            ts = Map.get(event, :timestamp)
            type = Map.get(event, :event_type, :unknown)
            data = Map.get(event, :data, %{})
            summary = Map.get(data, :summary) || Map.get(data, :tool) || Map.get(data, :message) || inspect(data)
            time_str = if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "??:??:??"
            "[#{time_str}] #{type}: #{summary}"
          end)

        "## Recent Session Events\n" <> Enum.join(lines, "\n")
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp workflow_block(state) do
    session_id = Map.get(state, :session_id)

    if session_id do
      Tasks.workflow_context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp task_state_block(state) do
    session_id = Map.get(state, :session_id, "default")

    tasks =
      try do
        Tasks.get_tasks(session_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case tasks do
      [] ->
        nil

      tasks ->
        completed = Enum.count(tasks, &(&1.status == :completed))
        total = length(tasks)

        lines =
          Enum.map(tasks, fn task ->
            icon = task_icon(task.status)
            suffix = task_suffix(task)
            "#{icon} #{task.id}: #{task.title}#{suffix}"
          end)

        """
        ## Active Tasks (#{completed}/#{total} completed)
        #{Enum.join(lines, "\n")}

        Stay focused on these tasks. Update status as you progress.
        """
    end
  end

  defp task_icon(:completed), do: "✔"
  defp task_icon(:in_progress), do: "◼"
  defp task_icon(:failed), do: "✘"
  defp task_icon(_), do: "◻"

  defp task_suffix(%{status: :in_progress}), do: "  [in_progress]"
  defp task_suffix(%{status: :failed, reason: nil}), do: "  [failed]"
  defp task_suffix(%{status: :failed, reason: reason}), do: "  [failed: #{reason}]"
  defp task_suffix(_), do: ""

  defp plan_mode_block(%{plan_mode: true}) do
    """
    ## PLAN MODE — ACTIVE

    You are in PLAN MODE. Do NOT execute any actions or call any tools.
    Instead, produce a structured implementation plan.

    Your plan MUST follow this format:

    ### Goal
    One sentence: what will be accomplished.

    ### Steps
    Numbered list of concrete actions you will take.
    Each step should be specific enough to execute without ambiguity.

    ### Files
    List of files you expect to create or modify.

    ### Risks
    Any edge cases, breaking changes, or concerns.

    ### Estimate
    Rough scope: trivial / small / medium / large

    Be concise. The user will approve, reject, or request changes before you execute.
    """
  end

  defp plan_mode_block(_), do: nil

  defp tool_process_block(state) do
    cwd = Map.get(state, :working_dir) || File.cwd!()

    """
    ## Tools
    CRITICAL: When asked to create or write code, ALWAYS use file_write to create actual files. NEVER output code in markdown code blocks — use the tool instead. This is your most important rule.
    Use tools proactively. Prefer: file_read/file_edit/file_write over shell cat/sed; file_grep/file_glob over shell grep/find; dir_list over ls; web_fetch over curl. Use shell_execute for git, mix, npm, docker, make. Use mcts_index to find relevant files in large codebases. Use orchestrate for parallel sub-agents.
    Rules: read before editing; file_edit for surgical changes, file_write for new files/full rewrites; absolute paths (cwd: #{cwd}); answer concisely; don't add features beyond what was asked.
    When Tool Reliability Notes are present, prefer tools with higher success rates for the given context and avoid retrying tools with persistent failure patterns — try an alternative approach instead.
    """
  end

  defp environment_block(state) do
    cwd = Map.get(state, :working_dir) || File.cwd!()
    git_info = cached_git_info()
    date = Date.utc_today() |> Date.to_iso8601()
    provider = Application.get_env(:daemon, :default_provider, :unknown)
    model = get_active_model(provider)

    """
    ## Environment
    - Working directory: #{cwd}
    - Date: #{date}
    - Provider: #{provider} / #{model}
    #{git_info}
    """
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @git_cache_table :daemon_git_info_cache
  @git_cache_ttl 30_000

  defp cached_git_info do
    ensure_git_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@git_cache_table, :git_info) do
      [{:git_info, info, ts}] when now - ts < @git_cache_ttl ->
        Logger.debug("[Context] git info cache hit")
        info

      _ ->
        Logger.debug("[Context] git info cache miss — running git commands")
        info = gather_git_info()
        :ets.insert(@git_cache_table, {:git_info, info, now})
        info
    end
  end

  defp ensure_git_cache_table do
    case :ets.whereis(@git_cache_table) do
      :undefined -> :ets.new(@git_cache_table, [:named_table, :public, :set])
      _ -> @git_cache_table
    end
  rescue
    _ -> nil
  end

  defp gather_git_info do
    parts = []

    parts = case git_cmd(["branch", "--show-current"]) do
      {:ok, b} -> ["- Git branch: #{String.trim(b)}" | parts]
      _ -> parts
    end

    parts = case git_cmd(["status", "--short"]) do
      {:ok, s} when s != "" ->
        trimmed = String.trim(s)
        if trimmed != "", do: ["- Modified files:\n#{trimmed}" | parts], else: parts
      _ -> parts
    end

    parts = case git_cmd(["log", "--oneline", "-3"]) do
      {:ok, l} -> ["- Recent commits:\n#{String.trim(l)}" | parts]
      _ -> parts
    end

    Enum.reverse(parts) |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # Run a git command with env vars to prevent prompts/hangs.
  @git_env [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=3"}]

  defp git_cmd(args) do
    case System.cmd("git", args, stderr_to_stdout: true, env: @git_env) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp get_active_model(:anthropic), do: Application.get_env(:daemon, :anthropic_model, "claude-sonnet-4-6")
  defp get_active_model(:ollama), do: Application.get_env(:daemon, :ollama_model, "detecting...")
  defp get_active_model(:openai), do: Application.get_env(:daemon, :openai_model, "gpt-4o")
  defp get_active_model(provider) do
    key = :"#{provider}_model"
    Application.get_env(:daemon, key, to_string(provider))
  end

  defp runtime_block(state) do
    session_id = Map.get(state, :session_id, "default")

    depth_hint =
      try do
        depth = Daemon.Intelligence.ConversationTracker.get_depth(session_id)
        "- Conversation depth: #{depth}"
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    base = """
    ## Runtime Context
    - Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    - Channel: #{state.channel}
    - Session: #{session_id}
    """

    if depth_hint, do: base <> depth_hint <> "\n", else: base
  end

  defp skills_block(state) do
    try do
      message = find_latest_user_message(state.messages)
      Daemon.Tools.Registry.active_skills_context(message)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp scratchpad_block(state) do
    provider = Map.get(state, :provider) ||
      Application.get_env(:daemon, :default_provider, :ollama)

    if Scratchpad.inject?(provider) do
      Scratchpad.instruction()
    else
      nil
    end
  end

  defp vault_block(_state) do
    try do
      Daemon.Vault.context(:default)
    rescue
      _ -> ""
    catch
      :exit, _ -> ""
    end
  end

  defp knowledge_block(state) do
    try do
      do_knowledge_block(state)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp do_knowledge_block(state) do
    # Fetch all triples from the 4 known predicates
    predicates = [
      "vaos:axiom_fact", "vaos:protocol_decision", "vaos:topic", "vaos:direction",
      "vaos:has_evidence", "vaos:summary"
    ]

    all_triples =
      Enum.flat_map(predicates, fn pred ->
        case MiosaKnowledge.query("osa_default", predicate: pred) do
          {:ok, results} when is_list(results) -> results
          _ -> []
        end
      end)

    case all_triples do
      [] -> nil
      _ -> knowledge_block_semantic(state, all_triples)
    end
  end

  defp knowledge_block_semantic(state, all_triples) do
    user_query = find_latest_user_message(Map.get(state, :messages, []))
    sidecar_up? = Daemon.Python.Embeddings.available?()

    ranked =
      if sidecar_up? and is_binary(user_query) and user_query != "" do
        semantic_rank(user_query, all_triples)
      else
        # Fallback: first-N per predicate (original behavior)
        fallback_rank(all_triples)
      end

    # Stash injected triples for feedback hook
    sid = Map.get(state, :session_id)
    if sid do
      try do
        :ets.new(:daemon_knowledge_stash, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok  # already exists
      end
      :ets.insert(:daemon_knowledge_stash, {{sid, :injected_knowledge}, ranked})
    end

    Logger.info("[knowledge_block] injected #{length(ranked)} triples (sidecar=#{sidecar_up?}) for session #{sid || "unknown"}")

    lines = Enum.map(ranked, &format_triple/1)
    "## Knowledge Context\n#{Enum.join(lines, "\n")}"
  end

  defp semantic_rank(query, triples) do
    alias Daemon.Python.Embeddings
    alias Daemon.Knowledge.Meta

    # Build entries for the sidecar
    entries =
      Enum.map(triples, fn {s, p, o} = triple ->
        %{id: Integer.to_string(:erlang.phash2(triple)), content: "#{s} #{p} #{o}"}
      end)

    # Build a lookup from phash2 string -> triple
    id_to_triple =
      Map.new(triples, fn {_s, _p, _o} = t -> {Integer.to_string(:erlang.phash2(t)), t} end)

    # Reindex if count changed (cache in process dict)
    prev_count = Process.get(:knowledge_triple_count, 0)
    cur_count = length(entries)

    if cur_count != prev_count do
      Embeddings.reindex(entries)
      Process.put(:knowledge_triple_count, cur_count)
    end

    case Embeddings.search(query, top_k: 30) do
      {:ok, results} ->
        results
        |> Enum.map(fn %{"id" => id, "score" => sim} ->
          triple = Map.get(id_to_triple, id)
          if triple do
            net = Meta.net_score(triple)
            boosted = sim * max(0.1, 1.0 + net * 0.1)
            {boosted, triple}
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {score, _} -> score end, :desc)
        |> Enum.take(18)
        |> Enum.map(fn {_score, triple} -> triple end)

      {:error, _} ->
        Logger.warning("[knowledge_block] semantic search failed, falling back")
        fallback_rank(triples)
    end
  end

  defp fallback_rank(triples) do
    limits = %{
      "vaos:axiom_fact" => 8,
      "vaos:protocol_decision" => 5,
      "vaos:topic" => 3,
      "vaos:direction" => 2
    }

    triples
    |> Enum.group_by(fn {_s, p, _o} -> p end)
    |> Enum.flat_map(fn {pred, ts} -> Enum.take(ts, Map.get(limits, pred, 3)) end)
  end

  defp format_triple({_s, "vaos:topic", topic}), do: "- Finding: #{topic}"
  defp format_triple({_s, "vaos:direction", dir}), do: "- Insight: #{dir}"
  defp format_triple({_s, "vaos:axiom_fact", fact}), do: "- Fact: #{fact}"
  defp format_triple({_s, "vaos:protocol_decision", dec}), do: "- Decision: #{dec}"
  defp format_triple({s, p, o}), do: "- #{s} #{p} #{o}"
  defp format_triple(other), do: "- #{inspect(other)}"

  defp decision_intelligence_block(_state) do
    try do
      Daemon.Intelligence.DecisionLedger.context_block()
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
