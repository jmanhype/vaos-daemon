defmodule OptimalSystemAgent.Tools.Builtins.Delegate do
  @moduledoc """
  Lightweight subagent spawning — research and explore without full orchestration.

  Spawns a focused agent that autonomously chains tool calls to complete a task.
  Skips the orchestrator's complexity analysis. Returns the agent's findings.

  Progress events emitted so TUI shows live status:
    Delegate(explore codebase) — 12 tool uses · 45k tokens
  """
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @max_iterations 20

  # Read-only tools safe for research delegates
  @read_only_tools ~w(file_read file_grep file_glob dir_list web_search web_fetch memory_recall session_search)

  @impl true
  def name, do: "delegate"

  @impl true
  def description do
    "Spawn a focused research agent to autonomously explore a question. Returns findings."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "What the subagent should investigate or accomplish"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Restrict to specific tools (default: read-only tools)"
        },
        "tier" => %{
          "type" => "string",
          "enum" => ["utility", "specialist", "elite"],
          "description" => "Model tier — utility=fast/cheap, specialist=balanced, elite=best (default: utility)"
        }
      },
      "required" => ["task"]
    }
  end

  @impl true
  def execute(%{"task" => task} = params) do
    tier = parse_tier(params["tier"] || "utility")
    allowed_tools = params["tools"] || @read_only_tools
    agent_id = OptimalSystemAgent.Utils.ID.generate("dlg")

    # Resolve tools via persistent_term — lock-free, no GenServer deadlock
    all_tools = Tools.list_tools_direct()
    tools = Enum.filter(all_tools, fn t -> t.name in allowed_tools end)

    # Never allow recursion
    tools = Enum.reject(tools, fn t -> t.name in ~w(delegate orchestrate create_skill) end)

    Bus.emit(:system_event, %{
      event: :delegate_started,
      agent_id: agent_id,
      task: String.slice(task, 0, 100)
    })

    start_time = System.monotonic_time(:millisecond)

    # Resolve model from tier
    model = resolve_model(tier)
    opts = if model, do: [model: model], else: []

    system_prompt = """
    You are a focused research agent. Complete the following task using the tools available to you.
    Be thorough but efficient. Return your findings in a clear, structured format.
    Do NOT ask for user input. Work autonomously with available tools.
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: task}
    ]

    # Run autonomous ReAct loop
    {result, tool_uses, tokens_used} = run_delegate_loop(agent_id, messages, tools, opts, 0, 0, 0)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    Bus.emit(:system_event, %{
      event: :delegate_completed,
      agent_id: agent_id,
      tool_uses: tool_uses,
      tokens_used: tokens_used,
      duration_ms: duration_ms
    })

    {:ok, result}
  rescue
    e ->
      Logger.error("[Delegate] Error: #{Exception.message(e)}")
      {:error, "Delegate failed: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "Missing required parameter: task"}

  # --- Private ---

  defp run_delegate_loop(_agent_id, _messages, _tools, _opts, iter, tool_uses, tokens)
       when iter >= @max_iterations do
    {"Delegate reached iteration limit (#{@max_iterations}). Partial results may be available.",
     tool_uses, tokens}
  end

  defp run_delegate_loop(agent_id, messages, tools, opts, iter, tool_uses, tokens) do
    llm_opts = [tools: tools, temperature: 0.3] ++ opts

    case Providers.chat(messages, llm_opts) do
      {:ok, %{content: content, tool_calls: []}} ->
        {content, tool_uses, tokens}

      {:ok, %{content: content, tool_calls: tool_calls} = resp} when is_list(tool_calls) ->
        new_tokens = get_tokens(resp)

        # Execute tool calls
        assistant_msg = %{role: "assistant", content: content, tool_calls: tool_calls}
        messages = messages ++ [assistant_msg]

        tool_results =
          Enum.map(tool_calls, fn tc ->
            result =
              case Tools.execute_direct(tc.name, tc.arguments) do
                {:ok, r} -> r
                {:error, r} -> "Error: #{r}"
              end

            Bus.emit(:system_event, %{
              event: :delegate_progress,
              agent_id: agent_id,
              tool_name: tc.name,
              tool_uses: tool_uses + 1,
              tokens_used: tokens + new_tokens
            })

            %{role: "tool", tool_call_id: tc.id, content: truncate_result(result)}
          end)

        messages = messages ++ tool_results
        new_tool_uses = tool_uses + length(tool_calls)

        run_delegate_loop(
          agent_id,
          messages,
          tools,
          opts,
          iter + 1,
          new_tool_uses,
          tokens + new_tokens
        )

      {:ok, %{content: content}} ->
        # Response with content but no tool_calls key (or nil)
        new_tokens = 0
        {content, tool_uses, tokens + new_tokens}

      {:error, reason} ->
        {"Delegate LLM error: #{inspect(reason)}", tool_uses, tokens}
    end
  end

  defp get_tokens(%{usage: %{input_tokens: inp, output_tokens: out}})
       when is_integer(inp) and is_integer(out),
       do: inp + out

  defp get_tokens(%{usage: usage}) when is_map(usage) do
    Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
  end

  defp get_tokens(_), do: 0

  defp truncate_result(result) when is_binary(result) and byte_size(result) > 10_240 do
    binary_part(result, 0, 10_240) <> "\n[truncated]"
  end

  defp truncate_result(result) when is_binary(result), do: result
  defp truncate_result(result), do: inspect(result)

  defp parse_tier("elite"), do: :elite
  defp parse_tier("specialist"), do: :specialist
  defp parse_tier(_), do: :utility

  defp resolve_model(tier) do
    case tier do
      :elite ->
        Application.get_env(:optimal_system_agent, :elite_model) ||
          Application.get_env(:optimal_system_agent, :anthropic_model)

      :specialist ->
        Application.get_env(:optimal_system_agent, :specialist_model)

      :utility ->
        Application.get_env(:optimal_system_agent, :utility_model)
    end
  end
end
