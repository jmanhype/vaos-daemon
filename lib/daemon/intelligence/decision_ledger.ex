defmodule Daemon.Intelligence.DecisionLedger do
  @moduledoc """
  Epistemically-grounded runtime decision memory.

  Subscribes to `:tool_call` and `:tool_result` events on the Bus, correlates
  decisions with outcomes, builds per-tool reliability patterns, creates
  epistemic claims when evidence accumulates, and injects tool performance
  summaries into the LLM's system prompt via `context_block/0`.

  Architecture: GenServer serializes writes + event dispatch; ETS provides
  concurrent reads (same pattern as Vault.FactStore). JSONL for crash-safe
  persistence. Knowledge graph sync every 60 s (same pattern as KnowledgeBridge).
  """

  use GenServer
  require Logger

  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @ets_table :daemon_decision_ledger
  @ets_pairs_table :daemon_decision_pairs
  @store_dir Path.expand("~/.daemon/intelligence")
  @jsonl_filename "decisions.jsonl"
  @max_patterns 500
  @max_pairs 200
  @max_recent_errors 3
  @max_jsonl_bytes 10 * 1024 * 1024
  @min_observations 5
  @min_pair_observations 3
  @max_context_tools 8
  @max_context_pairs 4
  @sync_interval_ms 60_000
  @knowledge_store "osa_default"
  @ledger_name :investigate_ledger

  # Tools that read/write knowledge or memory — excluded to prevent feedback loops
  @meta_tools ~w(knowledge memory_recall memory_save knowledge_query knowledge_assert)

  # ── Public API (all read from ETS — no GenServer bottleneck) ───────────────

  @doc "List patterns with at least `min_observations` total observations, sorted by count desc."
  @spec patterns(keyword()) :: [map()]
  def patterns(opts \\ []) do
    min_obs = Keyword.get(opts, :min_observations, @min_observations)

    try do
      :ets.tab2list(ets_table_name())
      |> Enum.map(fn {_key, pattern} -> pattern end)
      |> Enum.filter(fn p -> p.success_count + p.failure_count >= min_obs end)
      |> Enum.sort_by(fn p -> -(p.success_count + p.failure_count) end)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Aggregated stats across all contexts for a single tool."
  @spec tool_summary(String.t()) :: map() | nil
  def tool_summary(tool_name) do
    try do
      entries =
        :ets.tab2list(ets_table_name())
        |> Enum.map(fn {_key, p} -> p end)
        |> Enum.filter(fn p -> p.tool_name == tool_name end)

      case entries do
        [] ->
          nil

        list ->
          total_s = Enum.sum(Enum.map(list, & &1.success_count))
          total_f = Enum.sum(Enum.map(list, & &1.failure_count))
          total = total_s + total_f
          total_dur = Enum.sum(Enum.map(list, & &1.total_duration_ms))

          %{
            tool_name: tool_name,
            success_count: total_s,
            failure_count: total_f,
            total_observations: total,
            success_rate: if(total > 0, do: Float.round(total_s / total * 100, 1), else: 0.0),
            avg_duration_ms: if(total > 0, do: Float.round(total_dur / total, 0), else: 0.0),
            contexts: Enum.map(list, & &1.context_type)
          }
      end
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Given the last tool+context used, returns the most successful next tools
  as `[%{tool: "file_edit", context: "lib/", success_rate: 92.0, n: 12}, ...]`.
  """
  @spec best_next_tools(String.t()) :: [map()]
  def best_next_tools(current_pattern_key) do
    try do
      :ets.tab2list(pairs_table_name())
      |> Enum.filter(fn {pair_key, p} ->
        String.starts_with?(pair_key, current_pattern_key <> "->") and
          p.success_count + p.failure_count >= @min_pair_observations
      end)
      |> Enum.map(fn {pair_key, p} ->
        [_, next] = String.split(pair_key, "->", parts: 2)
        total = p.success_count + p.failure_count
        %{
          tool_context: next,
          success_rate: Float.round(p.success_count / total * 100, 1),
          n: total
        }
      end)
      |> Enum.sort_by(& &1.success_rate, :desc)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Formatted text block for system prompt injection (~200 tokens max).
  Returns `nil` if insufficient data.
  """
  @spec context_block() :: String.t() | nil
  def context_block do
    significant = patterns(min_observations: @min_observations)

    case significant do
      [] ->
        nil

      list ->
        tool_lines =
          list
          |> Enum.take(@max_context_tools)
          |> Enum.map(fn p ->
            total = p.success_count + p.failure_count
            rate = Float.round(p.success_count / total * 100, 0) |> trunc()
            avg = trunc(p.avg_duration_ms)

            error_suffix =
              case p.recent_errors do
                [latest | _] -> ", recent error: #{latest}"
                _ -> ""
              end

            "- #{p.tool_name} (#{p.context_type}): #{rate}% success (n=#{total}), avg #{avg}ms#{error_suffix}"
          end)

        pair_lines = build_pair_context_lines()

        sections = ["## Tool Reliability Notes" | tool_lines]
        sections = if pair_lines != [], do: sections ++ ["Effective sequences:" | pair_lines], else: sections

        Enum.join(sections, "\n")
    end
  rescue
    _ -> nil
  end

  defp build_pair_context_lines do
    try do
      :ets.tab2list(pairs_table_name())
      |> Enum.filter(fn {_key, p} ->
        total = p.success_count + p.failure_count
        total >= @min_pair_observations
      end)
      |> Enum.sort_by(fn {_key, p} ->
        total = p.success_count + p.failure_count
        -(p.success_count / total)
      end)
      |> Enum.take(@max_context_pairs)
      |> Enum.map(fn {pair_key, p} ->
        total = p.success_count + p.failure_count
        rate = Float.round(p.success_count / total * 100, 0) |> trunc()
        "- #{pair_key}: #{rate}% success (n=#{total})"
      end)
    rescue
      _ -> []
    end
  end

  @doc "Derive the context type from a tool name and argument hint. Public for testing."
  @spec derive_context(String.t(), String.t() | nil) :: String.t()
  def derive_context(tool_name, args_hint) do
    args = args_hint || ""

    cond do
      tool_name == "shell_execute" and String.starts_with?(args, "git ") -> "git"
      tool_name == "shell_execute" and String.starts_with?(args, "mix ") -> "mix"
      tool_name == "shell_execute" and String.starts_with?(args, "npm ") -> "npm"
      tool_name == "shell_execute" and String.starts_with?(args, "docker ") -> "docker"
      tool_name in ~w(file_read file_edit file_write file_glob file_grep dir_list) and String.starts_with?(args, "lib/") -> "lib/"
      tool_name in ~w(file_read file_edit file_write file_glob file_grep dir_list) and String.starts_with?(args, "test/") -> "test/"
      tool_name == "investigate" -> "research"
      tool_name in ~w(web_fetch web_search) -> "web"
      true -> "general"
    end
  end

  # ── GenServer lifecycle ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    if Keyword.get(opts, :test_mode, false) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl true
  def init(opts) do
    test_mode = Keyword.get(opts, :test_mode, false)

    {table_name, pairs_name, store_dir} =
      if test_mode do
        suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
        table = :"daemon_decision_ledger_test_#{suffix}"
        pairs = :"daemon_decision_pairs_test_#{suffix}"
        dir = Path.join(System.tmp_dir!(), "decision_ledger_test_#{suffix}")
        {table, pairs, dir}
      else
        {@ets_table, @ets_pairs_table, @store_dir}
      end

    :ets.new(table_name, [:set, :named_table, :public, read_concurrency: true])
    :ets.new(pairs_name, [:set, :named_table, :public, read_concurrency: true])
    File.mkdir_p!(store_dir)

    jsonl_path = Path.join(store_dir, @jsonl_filename)
    load_from_jsonl(jsonl_path, table_name)

    unless test_mode do
      Process.send_after(self(), :subscribe, 5_000)
    end

    sync_timer = unless test_mode do
      Process.send_after(self(), :sync_to_knowledge, @sync_interval_ms)
    end

    {:ok,
     %{
       event_refs: [],
       pending_calls: %{},
       claim_cache: %{},
       last_iteration: %{},
       jsonl_path: jsonl_path,
       sync_timer: sync_timer,
       ets_table: table_name,
       pairs_table: pairs_name,
       test_mode: test_mode
     }}
  end

  @impl true
  def handle_info(:subscribe, state) do
    ref1 = Daemon.Events.Bus.register_handler(:tool_call, &handle_tool_call_event/1)
    ref2 = Daemon.Events.Bus.register_handler(:tool_result, &handle_tool_result_event/1)
    Logger.info("[DecisionLedger] Subscribed to :tool_call and :tool_result events")
    {:noreply, %{state | event_refs: [ref1, ref2]}}
  rescue
    e ->
      Logger.debug("[DecisionLedger] Bus subscription failed: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info(:sync_to_knowledge, state) do
    sync_to_knowledge(state.ets_table)

    # Prune stale session state to prevent memory leaks.
    # last_iteration and pending_calls grow per-session — cap at 50 entries,
    # evicting the oldest by iteration number.
    last_iteration = prune_session_map(state.last_iteration, 50)
    pending_calls = prune_session_map(state.pending_calls, 50)

    timer = Process.send_after(self(), :sync_to_knowledge, @sync_interval_ms)
    {:noreply, %{state | sync_timer: timer, last_iteration: last_iteration, pending_calls: pending_calls}}
  end

  def handle_info({:tool_call_start, payload}, state) do
    key = {payload[:session_id] || "default", payload[:name]}

    pending = Map.put(state.pending_calls, key, %{
      start_time: System.monotonic_time(:millisecond),
      args_hint: payload[:args]
    })

    {:noreply, %{state | pending_calls: pending}}
  end

  def handle_info({:tool_call_end, payload}, state) do
    key = {payload[:session_id] || "default", payload[:name]}

    pending =
      case Map.get(state.pending_calls, key) do
        nil ->
          state.pending_calls

        meta ->
          duration = payload[:duration_ms] || (System.monotonic_time(:millisecond) - meta.start_time)
          Map.put(state.pending_calls, key, Map.put(meta, :duration_ms, duration))
      end

    {:noreply, %{state | pending_calls: pending}}
  end

  def handle_info({:tool_outcome, payload}, state) do
    tool_name = to_string(payload[:name] || "unknown")

    # Skip meta tools to prevent feedback loops
    if tool_name in @meta_tools do
      {:noreply, state}
    else
      key = {payload[:session_id] || "default", tool_name}
      pending_meta = Map.get(state.pending_calls, key, %{})
      args_hint = pending_meta[:args_hint] || payload[:args]
      duration_ms = pending_meta[:duration_ms] || payload[:duration_ms] || 0
      success = payload[:success] != false

      context_type = derive_context(tool_name, to_string(args_hint || ""))
      pattern_key = "#{tool_name}:#{context_type}"

      # Update ETS pattern
      upsert_pattern(state.ets_table, pattern_key, tool_name, context_type, success, duration_ms, payload)

      # Update pair tracking (iteration-aware sequence tracking)
      session_id = payload[:session_id] || "default"
      iteration = payload[:iteration] || 0
      state = track_pair(state, session_id, iteration, pattern_key, success)

      # Append to JSONL
      append_to_jsonl(state.jsonl_path, %{
        pattern_key: pattern_key,
        tool_name: tool_name,
        context_type: context_type,
        success: success,
        duration_ms: duration_ms,
        error: if(!success, do: String.slice(to_string(payload[:result] || ""), 0, 100)),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

      # Epistemic integration
      state = maybe_create_or_update_claim(state, pattern_key, tool_name, context_type, success)

      # Enforce max patterns
      enforce_max_patterns(state.ets_table)

      # Clean up pending
      pending = Map.delete(state.pending_calls, key)
      {:noreply, %{state | pending_calls: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{event_refs: refs}) when is_list(refs) do
    for ref <- refs do
      try do
        Daemon.Events.Bus.unregister_handler(:tool_call, ref)
        Daemon.Events.Bus.unregister_handler(:tool_result, ref)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def terminate(_, _), do: :ok

  # ── Event handler callbacks (run in Bus task, dispatch to GenServer) ────────

  defp handle_tool_call_event(%{data: data}) when is_map(data) do
    case data[:phase] do
      :start -> send(__MODULE__, {:tool_call_start, data})
      :end -> send(__MODULE__, {:tool_call_end, data})
      _ -> :ok
    end
  end

  # Fallback: some Bus configurations flatten the event map
  defp handle_tool_call_event(meta) when is_map(meta) do
    case meta[:phase] do
      :start -> send(__MODULE__, {:tool_call_start, meta})
      :end -> send(__MODULE__, {:tool_call_end, meta})
      _ -> :ok
    end
  end

  defp handle_tool_call_event(_), do: :ok

  defp handle_tool_result_event(%{data: data}) when is_map(data) do
    send(__MODULE__, {:tool_outcome, data})
  end

  # Fallback: handle flattened event maps
  defp handle_tool_result_event(meta) when is_map(meta) and is_map_key(meta, :name) do
    send(__MODULE__, {:tool_outcome, meta})
  end

  defp handle_tool_result_event(_), do: :ok

  # ── ETS pattern upsert ─────────────────────────────────────────────────────

  defp upsert_pattern(table, pattern_key, tool_name, context_type, success, duration_ms, payload) do
    now = DateTime.utc_now()

    existing =
      case :ets.lookup(table, pattern_key) do
        [{_, p}] -> p
        _ -> nil
      end

    pattern =
      if existing do
        total = existing.success_count + existing.failure_count + 1
        new_total_dur = existing.total_duration_ms + duration_ms

        base = %{
          existing
          | total_duration_ms: new_total_dur,
            avg_duration_ms: new_total_dur / total,
            last_observed_at: now
        }

        if success do
          %{base | success_count: existing.success_count + 1, last_success_at: now}
        else
          error_msg = String.slice(to_string(payload[:result] || "error"), 0, 100)

          recent =
            [error_msg | existing.recent_errors]
            |> Enum.take(@max_recent_errors)

          %{base | failure_count: existing.failure_count + 1, last_failure_at: now, recent_errors: recent}
        end
      else
        %{
          tool_name: tool_name,
          context_type: context_type,
          success_count: if(success, do: 1, else: 0),
          failure_count: if(success, do: 0, else: 1),
          total_duration_ms: duration_ms,
          avg_duration_ms: duration_ms * 1.0,
          last_success_at: if(success, do: now, else: nil),
          last_failure_at: if(success, do: nil, else: now),
          recent_errors:
            if(success,
              do: [],
              else: [String.slice(to_string(payload[:result] || "error"), 0, 100)]
            ),
          first_observed_at: now,
          last_observed_at: now,
          claim_id: nil
        }
      end

    :ets.insert(table, {pattern_key, pattern})
  end

  # ── Pair (sequence) tracking — iteration-aware ──────────────────────────
  #
  # Tools within the same iteration run in parallel (Task.async_stream,
  # max_concurrency: 10). Their arrival order at the Bus is non-deterministic.
  # We only create pairs BETWEEN iterations: if iteration N had exactly one
  # tool (unambiguous predecessor), we pair it with each tool in iteration N+1.
  # Multi-tool iterations are tracked but don't create pairs as predecessors
  # — the LLM chose them as a batch, so there's no causal A→B signal.

  defp track_pair(state, session_id, iteration, current_pattern_key, success) do
    prev = Map.get(state.last_iteration, session_id)

    case prev do
      nil ->
        # First tool for this session — start tracking this iteration
        new_iter = %{iteration: iteration, tools: [current_pattern_key]}
        %{state | last_iteration: Map.put(state.last_iteration, session_id, new_iter)}

      %{iteration: ^iteration, tools: tools} ->
        # Same iteration — just accumulate (parallel tools arriving)
        updated = %{prev | tools: [current_pattern_key | tools]}
        %{state | last_iteration: Map.put(state.last_iteration, session_id, updated)}

      %{iteration: prev_iter, tools: prev_tools} when iteration > prev_iter ->
        # New iteration — create pairs from previous iteration IF unambiguous
        if length(prev_tools) == 1 do
          [prev_key] = prev_tools
          pair_key = "#{prev_key}->#{current_pattern_key}"
          upsert_pair(state.pairs_table, pair_key, success)
          enforce_max_pairs(state.pairs_table)
        end

        new_iter = %{iteration: iteration, tools: [current_pattern_key]}
        %{state | last_iteration: Map.put(state.last_iteration, session_id, new_iter)}

      _ ->
        # Edge case: iteration went backwards (shouldn't happen) — reset
        new_iter = %{iteration: iteration, tools: [current_pattern_key]}
        %{state | last_iteration: Map.put(state.last_iteration, session_id, new_iter)}
    end
  end

  defp upsert_pair(table, pair_key, success) do
    existing =
      case :ets.lookup(table, pair_key) do
        [{_, p}] -> p
        _ -> nil
      end

    pair =
      if existing do
        if success do
          %{existing | success_count: existing.success_count + 1}
        else
          %{existing | failure_count: existing.failure_count + 1}
        end
      else
        %{
          success_count: if(success, do: 1, else: 0),
          failure_count: if(success, do: 0, else: 1)
        }
      end

    :ets.insert(table, {pair_key, pair})
  end

  defp enforce_max_pairs(table) do
    all = :ets.tab2list(table)

    if length(all) > @max_pairs do
      sorted =
        all
        |> Enum.sort_by(fn {_key, p} -> p.success_count + p.failure_count end)
        |> Enum.take(length(all) - @max_pairs)

      for {key, _} <- sorted do
        :ets.delete(table, key)
      end
    end
  rescue
    _ -> :ok
  end

  # ── Epistemic integration ──────────────────────────────────────────────────

  defp maybe_create_or_update_claim(state, pattern_key, tool_name, context_type, success) do
    case :ets.lookup(state.ets_table, pattern_key) do
      [{_, pattern}] ->
        total = pattern.success_count + pattern.failure_count

        if total >= @min_observations do
          case Map.get(state.claim_cache, pattern_key) do
            nil ->
              # Create new claim
              claim_id = create_epistemic_claim(tool_name, context_type, pattern)

              if claim_id do
                # Update ETS with claim_id
                :ets.insert(state.ets_table, {pattern_key, %{pattern | claim_id: claim_id}})
                %{state | claim_cache: Map.put(state.claim_cache, pattern_key, claim_id)}
              else
                state
              end

            claim_id ->
              # Add evidence to existing claim
              add_evidence_to_claim(claim_id, success)
              state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp create_epistemic_claim(tool_name, context_type, pattern) do
    total = pattern.success_count + pattern.failure_count
    rate = Float.round(pattern.success_count / total * 100, 1)

    claim =
      EpistemicLedger.add_claim(
        [
          title: "Tool #{tool_name} reliability in #{context_type}",
          statement: "#{tool_name} has #{rate}% success in #{context_type} (n=#{total})",
          tags: ["decision_ledger", "tool_reliability", tool_name]
        ],
        @ledger_name
      )

    case claim do
      %{id: id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp add_evidence_to_claim(claim_id, success) do
    {direction, strength} =
      if success, do: {:support, 0.7}, else: {:contradict, 0.6}

    EpistemicLedger.add_evidence(
      [
        claim_id: claim_id,
        summary: "Tool execution #{if success, do: "succeeded", else: "failed"}",
        direction: direction,
        strength: strength,
        confidence: strength,
        source_type: "observation"
      ],
      @ledger_name
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Knowledge graph sync ───────────────────────────────────────────────────

  defp sync_to_knowledge(table) do
    store_ref = Vaos.Knowledge.store_ref(@knowledge_store)
    store_via = {:via, Registry, {Vaos.Knowledge.Registry, @knowledge_store}}

    case GenServer.whereis(store_via) do
      nil ->
        Logger.debug("[DecisionLedger] Knowledge store not running, skipping sync")
        :ok

      _pid ->
        triples = build_knowledge_triples(table)

        if triples != [] do
          MiosaKnowledge.assert_many(store_ref, triples)
        end

        :ok
    end
  rescue
    e ->
      Logger.debug("[DecisionLedger] Knowledge sync skipped: #{Exception.message(e)}")
      :ok
  end

  defp build_knowledge_triples(table) do
    :ets.tab2list(table)
    |> Enum.flat_map(fn {pattern_key, p} ->
      total = p.success_count + p.failure_count

      if total >= @min_observations do
        rate = Float.round(p.success_count / total, 2) |> to_string()
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        [
          {pattern_key, "rdf:type", "vaos:DecisionPattern"},
          {pattern_key, "vaos:toolName", p.tool_name},
          {pattern_key, "vaos:successRate", rate},
          {pattern_key, "vaos:observationCount", to_string(total)},
          {pattern_key, "vaos:avgDurationMs", to_string(trunc(p.avg_duration_ms))},
          {pattern_key, "vaos:timestamp", now}
        ]
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  # ── JSONL persistence ──────────────────────────────────────────────────────

  defp load_from_jsonl(path, table) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case Jason.decode(line) do
            {:ok, entry} ->
              pattern_key = entry["pattern_key"]
              tool_name = entry["tool_name"]
              context_type = entry["context_type"]
              success = entry["success"]
              duration_ms = entry["duration_ms"] || 0

              if pattern_key && tool_name do
                upsert_pattern(table, pattern_key, tool_name, context_type, success, duration_ms, %{
                  result: entry["error"]
                })
              end

            {:error, _} ->
              Logger.debug("[DecisionLedger] Skipping malformed JSONL line")
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[DecisionLedger] Failed to load JSONL: #{inspect(reason)}")
    end
  end

  defp append_to_jsonl(path, entry) do
    maybe_rotate_jsonl(path)
    line = Jason.encode!(entry) <> "\n"
    File.write(path, line, [:append])
  rescue
    e ->
      Logger.debug("[DecisionLedger] JSONL write failed: #{Exception.message(e)}")
  end

  defp maybe_rotate_jsonl(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= @max_jsonl_bytes ->
        backup = path <> ".bak"
        File.rename(path, backup)

      _ ->
        :ok
    end
  end

  # ── Bounds enforcement ─────────────────────────────────────────────────────

  defp enforce_max_patterns(table) do
    all = :ets.tab2list(table)

    if length(all) > @max_patterns do
      # Evict least-recently-observed entries
      sorted =
        all
        |> Enum.sort_by(fn {_key, p} -> p.last_observed_at end, DateTime)
        |> Enum.take(length(all) - @max_patterns)

      for {key, _} <- sorted do
        :ets.delete(table, key)
      end
    end
  rescue
    _ -> :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Prune a session-keyed map to at most `max` entries.
  # Keeps the most recent entries (by map size — no timestamp needed since
  # active sessions get re-added on next event).
  defp prune_session_map(map, max) when map_size(map) <= max, do: map

  defp prune_session_map(map, max) do
    map
    |> Enum.to_list()
    |> Enum.take(-max)
    |> Map.new()
  rescue
    _ -> map
  end

  # Production always uses the module-level constant. Test mode uses isolated
  # tables directly via the GenServer state — tests read ETS by table name,
  # not through the public API which targets the production table.
  defp ets_table_name, do: @ets_table
  defp pairs_table_name, do: @ets_pairs_table
end
