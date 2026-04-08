defmodule Daemon.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles permission tier enforcement, hook pipeline invocation,
  parallel tool dispatch, and read-before-write nudge injection.
  """
  require Logger

  alias Daemon.Agent.Hooks
  alias Daemon.Tools.Registry, as: Tools
  alias Daemon.Events.Bus

  # Tools allowed in :read_only mode (no side-effects, no writes)
  @read_only_tools ~w(
    file_read file_glob dir_list file_grep file_search
    memory_recall session_search semantic_search
    code_symbols web_fetch web_search
    list_dir read_file grep_search
  )

  # Additional tools unlocked in :workspace mode (local writes only)
  @workspace_tools ~w(
    file_write file_edit multi_file_edit file_create file_delete file_move
    git task_write memory_write
  )

  @doc false
  def permission_tier_allows?(:full, _tool), do: true
  def permission_tier_allows?(:read_only, tool), do: tool in @read_only_tools

  def permission_tier_allows?(:workspace, tool),
    do: tool in (@read_only_tools ++ @workspace_tools)

  def permission_tier_allows?(tier, tool) do
    Logger.warning(
      "[loop] Unknown permission tier #{inspect(tier)} denied #{tool} — defaulting to deny"
    )

    false
  end

  @doc """
  Execute a single tool call — used by parallel Task.async_stream.
  Returns {tool_msg, result_str} tuple.
  """
  def execute_tool_call(tool_call, state) do
    max_tool_output_bytes = Application.get_env(:daemon, :max_tool_output_bytes, 10_240)
    arg_hint = tool_call_hint(tool_call.arguments)

    Bus.emit(:tool_call, %{
      name: tool_call.name,
      phase: :start,
      args: arg_hint,
      session_id: state.session_id,
      agent: state.session_id,
      iteration: state.iteration,
      tool_call_id: tool_call.id
    })

    start_time_tool = System.monotonic_time(:millisecond)

    # Run pre_tool_use hooks sync (security_check/spend_guard can block)
    pre_payload = %{
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      session_id: state.session_id
    }

    tool_result =
      if not permission_tier_allows?(state.permission_tier, tool_call.name) do
        Logger.warning(
          "[loop] Permission denied: tier=#{state.permission_tier} blocked #{tool_call.name} (session: #{state.session_id})"
        )

        "Blocked: #{state.permission_tier} mode — #{tool_call.name} is not permitted at this permission level"
      else
        case run_hooks(:pre_tool_use, pre_payload) do
          {:blocked, reason} ->
            "Blocked: #{reason}"

          {:error, :hooks_unavailable} ->
            # Hooks GenServer is down — fail closed. Never execute a tool when
            # security_check and spend_guard are unreachable.
            Logger.error(
              "[loop] Blocking tool #{tool_call.name} — pre_tool_use hooks unavailable (session: #{state.session_id})"
            )

            "Blocked: security pipeline unavailable"

          _ ->
            # Inject session_id so tools like ask_user can register pending state
            enriched_args = Map.put(tool_call.arguments, "__session_id__", state.session_id)

            case Tools.execute(tool_call.name, enriched_args) do
              {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
                {:image, mt, b64, p}

              {:ok, content} ->
                content

              {:error, reason} ->
                case Tools.suggest_fallback_tool(tool_call.name) do
                  {:ok, alt_tool} ->
                    Logger.info(
                      "[loop] Tool '#{tool_call.name}' failed (#{inspect(reason)}), trying fallback '#{alt_tool}'"
                    )

                    case Tools.execute(alt_tool, enriched_args) do
                      {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
                        {:image, mt, b64, p}

                      {:ok, alt_content} ->
                        "[used #{alt_tool} as fallback for #{tool_call.name}]\n#{alt_content}"

                      {:error, _alt_reason} ->
                        "Error: #{reason}"
                    end

                  :no_alternative ->
                    "Error: #{reason}"
                end
            end
        end
      end

    tool_duration_ms = System.monotonic_time(:millisecond) - start_time_tool

    # Normalize result for hooks/events
    result_str =
      case tool_result do
        {:image, _mt, _b64, path} -> "[image: #{path}]"
        text when is_binary(text) -> sanitize_utf8(text)
        other -> inspect(other)
      end

    # Annotate result with reliability context from DecisionLedger
    result_str =
      maybe_annotate_with_reliability(result_str, tool_call.name, arg_hint, state.session_id)

    # Run post_tool_use hooks async (cost tracker, telemetry, learning)
    post_payload = %{
      tool_name: tool_call.name,
      result: result_str,
      duration_ms: tool_duration_ms,
      session_id: state.session_id
    }

    run_hooks_async(:post_tool_use, post_payload)

    # Emit audit receipt to kernel (fire-and-forget, never crashes tool execution)
    try do
      bundle = Daemon.Receipt.Bundle.from_tool_call(tool_call, post_payload)
      Daemon.Receipt.Emitter.emit_async(bundle)
    catch
      _, _ -> :ok
    end

    Bus.emit(:tool_call, %{
      name: tool_call.name,
      phase: :end,
      duration_ms: tool_duration_ms,
      args: arg_hint,
      session_id: state.session_id,
      agent: state.session_id,
      iteration: state.iteration,
      tool_call_id: tool_call.id
    })

    tool_success =
      not (String.starts_with?(result_str, "Error:") or
             String.starts_with?(result_str, "Blocked:"))

    Bus.emit(:tool_result, %{
      name: tool_call.name,
      args: arg_hint,
      result: String.slice(result_str, 0, 500),
      success: tool_success,
      session_id: state.session_id,
      agent: state.session_id,
      iteration: state.iteration,
      tool_call_id: tool_call.id
    })

    # Feed failures to CrashLearner so SelfDiagnosis can detect recurring patterns
    unless tool_success do
      try do
        Vaos.Ledger.ML.CrashLearner.report_crash(
          :daemon_crash_learner,
          "tool_#{tool_call.name}_#{state.session_id}",
          String.slice(result_str, 0, 200),
          nil,
          %{tool: tool_call.name, session_id: state.session_id, iteration: state.iteration}
        )
      catch
        _, _ -> :ok
      end
    end

    # Build tool message — images get structured content blocks.
    # Both branches include `name: tool_call.name` so that on iteration 2+
    # every provider's format_messages/1 can attribute the result back to
    # the exact tool that was called (required by Ollama and OpenAI-compat).
    tool_msg =
      case tool_result do
        {:image, media_type, b64, path} ->
          %{
            role: "tool",
            tool_call_id: tool_call.id,
            name: tool_call.name,
            content: [
              %{type: "text", text: "Image: #{path}"},
              %{type: "image", source: %{type: "base64", media_type: media_type, data: b64}}
            ]
          }

        _ ->
          limit = max_tool_output_bytes

          content =
            if byte_size(result_str) > limit do
              truncated = binary_part(result_str, 0, limit)

              truncated <>
                "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{limit} bytes]"
            else
              result_str
            end

          %{role: "tool", tool_call_id: tool_call.id, name: tool_call.name, content: content}
      end

    {tool_msg, result_str}
  end

  @doc """
  Inject system nudge when file_edit/file_write targeted files that weren't read first.
  Checks the :daemon_files_read ETS table for nudge flags set by the read_before_write hook.
  Nudges max 2 times per session per file to prevent doom loops.
  """
  def inject_read_nudges(state, tool_calls) do
    write_tools = Enum.filter(tool_calls, fn tc -> tc.name in ["file_edit", "file_write"] end)

    if write_tools == [] do
      state
    else
      nudged_paths =
        write_tools
        |> Enum.map(fn tc -> tc.arguments["path"] end)
        |> Enum.filter(fn path ->
          is_binary(path) and File.exists?(path) and
            not file_was_read?(state.session_id, path) and
            get_nudge_count(state.session_id, path) < 2
        end)
        |> Enum.uniq()

      if nudged_paths == [] do
        state
      else
        paths_str = Enum.join(nudged_paths, ", ")

        nudge_msg = %{
          role: "system",
          content:
            "[System: You modified #{paths_str} without reading #{if length(nudged_paths) == 1, do: "it", else: "them"} first. " <>
              "Always call file_read before file_edit/file_write on existing files to understand current content.]"
        }

        %{state | messages: state.messages ++ [nudge_msg]}
      end
    end
  rescue
    _ -> state
  end

  # --- Private helpers ---

  defp tool_call_hint(%{"command" => cmd}), do: String.slice(cmd, 0, 60)
  defp tool_call_hint(%{"path" => p}), do: p
  defp tool_call_hint(%{"query" => q}), do: String.slice(q, 0, 60)

  defp tool_call_hint(args) when is_map(args) and map_size(args) > 0 do
    args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")
  end

  defp tool_call_hint(_), do: ""

  defp file_was_read?(session_id, path) do
    try do
      case :ets.lookup(:daemon_files_read, {session_id, path}) do
        [{_, true}] -> true
        _ -> false
      end
    rescue
      ArgumentError -> false
    end
  end

  defp get_nudge_count(session_id, path) do
    try do
      nudge_key = {session_id, :nudge_count, path}

      case :ets.lookup(:daemon_files_read, nudge_key) do
        [{^nudge_key, n}] -> n
        _ -> 0
      end
    rescue
      ArgumentError -> 0
    end
  end

  # Run hooks with fault isolation.
  #
  # Returns {:error, :hooks_unavailable} when the Hooks GenServer is down,
  # rather than {:ok, payload}. This is intentional: pre_tool_use callers
  # MUST fail closed (block execution) when the security pipeline is
  # unreachable. post_tool_use callers may choose to warn and continue.
  defp run_hooks(event, payload) do
    try do
      Hooks.run(event, payload)
    catch
      :exit, reason ->
        Logger.warning("[loop] Hooks GenServer unreachable for #{event} (#{inspect(reason)})")
        {:error, :hooks_unavailable}
    end
  end

  # Closed-loop steering: annotate tool results with session-level and
  # historical reliability data, plus next-tool suggestions when applicable.
  # Three annotation levels (most urgent first, max ~240 chars total):
  #   1. Session circuit breaker (3+ consecutive failures)
  #   2. Historical reliability (<50% with n>=5)
  #   3. Next-tool suggestion (only when problem detected AND strong pair data)
  defp maybe_annotate_with_reliability(result_str, tool_name, args_hint, session_id) do
    context_type =
      Daemon.Intelligence.DecisionLedger.derive_context(tool_name, to_string(args_hint || ""))

    pattern_key = "#{tool_name}:#{context_type}"

    annotations = []
    annotations = check_session_circuit_breaker(annotations, session_id, pattern_key)
    annotations = check_historical_reliability(annotations, pattern_key, context_type)
    annotations = maybe_suggest_next(annotations, pattern_key)

    format_annotations(result_str, annotations)
  rescue
    _ -> result_str
  end

  defp check_session_circuit_breaker(annotations, session_id, pattern_key) do
    case Daemon.Intelligence.DecisionLedger.session_failures(session_id, pattern_key) do
      %{consecutive: n} = stats when n >= 3 ->
        # Escalate to SelfDiagnosis if failure rate is 2x+ above historical average
        maybe_escalate_to_self_diagnosis(pattern_key, n, stats)

        [
          {:session,
           "[session: #{n} consecutive failures — likely transient issue, try a different approach]"}
          | annotations
        ]

      _ ->
        annotations
    end
  rescue
    _ -> annotations
  end

  defp maybe_escalate_to_self_diagnosis(pattern_key, consecutive, session_stats) do
    # Only escalate at exactly 3 and 6 failures to avoid spamming
    unless consecutive in [3, 6], do: throw(:skip)

    # Get historical failure rate for comparison
    case :ets.lookup(:daemon_decision_ledger, pattern_key) do
      [{_, pattern}] ->
        total = pattern.success_count + pattern.failure_count

        if total >= 5 do
          historical_failure_rate = pattern.failure_count / total * 100
          session_total = session_stats.total_failures + consecutive

          session_failure_rate =
            if session_total > 0, do: consecutive / session_total * 100, else: 100.0

          # Escalate if session failure rate is 2x+ historical OR historical is already bad (>50%)
          if session_failure_rate > historical_failure_rate * 2 or historical_failure_rate > 50 do
            try do
              Daemon.Intelligence.DecisionJournal.record_adaptation(
                :reliability,
                :tool_failure_escalated,
                %{
                  pattern_key: pattern_key,
                  session_failures: consecutive,
                  historical_rate: Float.round(historical_failure_rate, 1),
                  session_rate: Float.round(session_failure_rate, 1),
                  authority_domain: :reliability
                }
              )

              Daemon.Investigation.SelfDiagnosis.trigger_diagnosis(pattern_key, %{
                session_failures: consecutive,
                historical_rate: Float.round(historical_failure_rate, 1),
                session_rate: Float.round(session_failure_rate, 1),
                recent_errors: pattern.recent_errors
              })
            rescue
              _ -> :ok
            catch
              :exit, _ -> :ok
            end
          end
        end

      _ ->
        :ok
    end
  catch
    :skip -> :ok
    _ -> :ok
  end

  defp check_historical_reliability(annotations, pattern_key, context_type) do
    case :ets.lookup(:daemon_decision_ledger, pattern_key) do
      [{_, pattern}] ->
        total = pattern.success_count + pattern.failure_count

        if total >= 5 do
          rate = pattern.success_count / total * 100

          cond do
            rate < 30 ->
              [
                {:reliability,
                 "[reliability: #{trunc(rate)}% success in #{context_type} (n=#{total}) — consider an alternative tool]"}
                | annotations
              ]

            rate < 50 ->
              [
                {:reliability,
                 "[reliability: #{trunc(rate)}% success in #{context_type} (n=#{total}) — may be unreliable]"}
                | annotations
              ]

            true ->
              annotations
          end
        else
          annotations
        end

      _ ->
        annotations
    end
  rescue
    _ -> annotations
  end

  # Only suggest next tool when a problem was already detected (annotations non-empty)
  # AND strong pair data exists (n >= 5, rate >= 75%)
  defp maybe_suggest_next([], _pattern_key), do: []

  defp maybe_suggest_next(annotations, pattern_key) do
    case Daemon.Intelligence.DecisionLedger.best_next_tools(pattern_key) do
      [%{tool_context: next, success_rate: rate, n: n} | _] when n >= 5 and rate >= 75.0 ->
        [{:suggestion, "[suggested next: #{next} (#{rate}% success, n=#{n})]"} | annotations]

      _ ->
        annotations
    end
  rescue
    _ -> annotations
  end

  defp format_annotations(result_str, []), do: result_str

  defp format_annotations(result_str, annotations) do
    # Reverse to maintain priority order (most urgent first)
    lines = annotations |> Enum.reverse() |> Enum.map(fn {_type, text} -> text end)
    result_str <> "\n" <> Enum.join(lines, "\n")
  end

  # Async hooks — fire-and-forget for post-event hooks (post_tool_use).
  # Pre-tool hooks stay sync so security_check/spend_guard can block.
  # Logs a warning if the Hooks GenServer is down so the issue is visible,
  # but does not block — post-event side effects are non-critical.
  defp sanitize_utf8(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8) do
      {:error, valid, _} -> valid
      {:incomplete, valid, _} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp sanitize_utf8(other), do: to_string(other)

  defp run_hooks_async(event, payload) do
    try do
      Hooks.run_async(event, payload)
    catch
      :exit, reason ->
        Logger.warning(
          "[loop] Hooks GenServer unreachable for async #{event} (#{inspect(reason)})"
        )

        :ok
    end
  end
end
