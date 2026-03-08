defmodule OptimalSystemAgent.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles permission tier enforcement, hook pipeline invocation,
  parallel tool dispatch, and read-before-write nudge injection.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus

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
  def permission_tier_allows?(:workspace, tool), do: tool in (@read_only_tools ++ @workspace_tools)
  def permission_tier_allows?(_, _), do: true

  @doc """
  Execute a single tool call — used by parallel Task.async_stream.
  Returns {tool_msg, result_str} tuple.
  """
  def execute_tool_call(tool_call, state) do
    max_tool_output_bytes = Application.get_env(:optimal_system_agent, :max_tool_output_bytes, 10_240)
    arg_hint = tool_call_hint(tool_call.arguments)
    Bus.emit(:tool_call, %{name: tool_call.name, phase: :start, args: arg_hint, session_id: state.session_id})
    start_time_tool = System.monotonic_time(:millisecond)

    # Run pre_tool_use hooks sync (security_check/spend_guard can block)
    pre_payload = %{
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      session_id: state.session_id
    }

    tool_result =
      if not permission_tier_allows?(state.permission_tier, tool_call.name) do
        Logger.warning("[loop] Permission denied: tier=#{state.permission_tier} blocked #{tool_call.name} (session: #{state.session_id})")
        "Blocked: #{state.permission_tier} mode — #{tool_call.name} is not permitted at this permission level"
      else
      case run_hooks(:pre_tool_use, pre_payload) do
        {:blocked, reason} ->
          "Blocked: #{reason}"

        {:error, :hooks_unavailable} ->
          # Hooks GenServer is down — fail closed. Never execute a tool when
          # security_check and spend_guard are unreachable.
          Logger.error("[loop] Blocking tool #{tool_call.name} — pre_tool_use hooks unavailable (session: #{state.session_id})")
          "Blocked: security pipeline unavailable"

        _ ->
          case Tools.execute(tool_call.name, tool_call.arguments) do
            {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
              {:image, mt, b64, p}

            {:ok, content} ->
              content

            {:error, reason} ->
              "Error: #{reason}"
          end
      end
      end

    tool_duration_ms = System.monotonic_time(:millisecond) - start_time_tool

    # Normalize result for hooks/events
    result_str =
      case tool_result do
        {:image, _mt, _b64, path} -> "[image: #{path}]"
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    # Run post_tool_use hooks async (cost tracker, telemetry, learning)
    post_payload = %{
      tool_name: tool_call.name,
      result: result_str,
      duration_ms: tool_duration_ms,
      session_id: state.session_id
    }

    run_hooks_async(:post_tool_use, post_payload)

    Bus.emit(:tool_call, %{
      name: tool_call.name,
      phase: :end,
      duration_ms: tool_duration_ms,
      args: arg_hint,
      session_id: state.session_id
    })

    Bus.emit(:tool_result, %{
      name: tool_call.name,
      result: String.slice(result_str, 0, 500),
      success: !match?({:error, _}, tool_result),
      session_id: state.session_id
    })

    # Build tool message — images get structured content blocks
    tool_msg =
      case tool_result do
        {:image, media_type, b64, path} ->
          %{
            role: "tool",
            tool_call_id: tool_call.id,
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
              truncated <> "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{limit} bytes]"
            else
              result_str
            end

          %{role: "tool", tool_call_id: tool_call.id, content: content}
      end

    {tool_msg, result_str}
  end

  @doc """
  Inject system nudge when file_edit/file_write targeted files that weren't read first.
  Checks the :osa_files_read ETS table for nudge flags set by the read_before_write hook.
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
          content: "[System: You modified #{paths_str} without reading #{if length(nudged_paths) == 1, do: "it", else: "them"} first. " <>
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
      case :ets.lookup(:osa_files_read, {session_id, path}) do
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
      case :ets.lookup(:osa_files_read, nudge_key) do
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

  # Async hooks — fire-and-forget for post-event hooks (post_tool_use).
  # Pre-tool hooks stay sync so security_check/spend_guard can block.
  # Logs a warning if the Hooks GenServer is down so the issue is visible,
  # but does not block — post-event side effects are non-critical.
  defp run_hooks_async(event, payload) do
    try do
      Hooks.run_async(event, payload)
    catch
      :exit, reason ->
        Logger.warning("[loop] Hooks GenServer unreachable for async #{event} (#{inspect(reason)})")
        :ok
    end
  end
end
