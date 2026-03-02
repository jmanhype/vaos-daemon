defmodule OptimalSystemAgent.Agent.Orchestrator.AgentRunner do
  @moduledoc """
  Sub-agent spawning and execution for the Orchestrator.

  Responsible for:
  - Spawning sub-agents as `Task.async` tasks
  - Mapping agent roles to model tiers
  - Running the iterative ReAct loop inside each agent task
  - Building role-specific system prompts

  ## Task ownership

  `spawn_agent/4` returns `{agent_id, agent_state, Task.t()}`. The `Task.t()`
  ref MUST be received by the calling GenServer via `handle_info`. The function
  does NOT monitor the task itself — the GenServer owns the monitor.
  """
  require Logger

  alias OptimalSystemAgent.Agent.{Roster, Tier, Orchestrator.SubTask, Orchestrator.AgentState}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @doc """
  Spawn a sub-agent as a `Task.async` and return its identity and task ref.

  Returns `{agent_id, %AgentState{}, %Task{}}`.
  The caller (GenServer) is responsible for receiving the Task's result
  via `handle_info({ref, result}, state)`.
  """
  @spec spawn_agent(SubTask.t(), String.t(), String.t(), list()) ::
          {String.t(), AgentState.t(), Task.t()}
  def spawn_agent(sub_task, task_id, session_id, cached_tools) do
    agent_id = OptimalSystemAgent.Utils.ID.generate("agent")

    system_prompt = build_agent_prompt(sub_task)
    agent_tier = resolve_agent_tier(sub_task)
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    tier_opts = %{
      model: Tier.model_for(agent_tier, provider),
      temperature: Tier.temperature(agent_tier),
      max_iterations: Tier.max_iterations(agent_tier),
      max_response_tokens: Tier.max_response_tokens(agent_tier),
      tier: agent_tier
    }

    agent_state = %AgentState{
      id: agent_id,
      task_id: task_id,
      name: sub_task.name,
      role: sub_task.role,
      status: :running,
      tool_uses: 0,
      tokens_used: 0,
      started_at: DateTime.utc_now()
    }

    Bus.emit(:system_event, %{
      event: :orchestrator_agent_started,
      task_id: task_id,
      session_id: session_id,
      agent_id: agent_id,
      agent_name: sub_task.name,
      role: sub_task.role,
      tier: agent_tier,
      model: tier_opts.model
    })

    subtask_id = "#{task_id}_#{sub_task.name}"

    Bus.emit(:system_event, %{
      event: :task_updated,
      task_id: subtask_id,
      status: "in_progress",
      session_id: session_id
    })

    orchestrator_pid = self()

    task_ref =
      Task.async(fn ->
        run_agent_loop(
          agent_id,
          task_id,
          system_prompt,
          sub_task,
          session_id,
          orchestrator_pid,
          cached_tools,
          tier_opts
        )
      end)

    {agent_id, agent_state, task_ref}
  end

  @doc """
  Resolve which model tier a sub-agent should run at.

  Checks the Roster for a named agent matching the sub-task description first,
  then falls back to role-based defaults.
  """
  @spec resolve_agent_tier(SubTask.t()) :: :elite | :specialist | :utility
  def resolve_agent_tier(sub_task) do
    case Roster.find_by_trigger(sub_task.description) do
      %{tier: tier} ->
        tier

      nil ->
        case sub_task.role do
          :lead -> :elite
          :red_team -> :specialist
          _ -> :specialist
        end
    end
  end

  @doc """
  Main agent execution loop. Runs inside `Task.async`.

  Prepares the initial message list and tool set, then delegates to
  `run_sub_agent_iterations/10` for the iterative ReAct loop.
  """
  @spec run_agent_loop(
          String.t(),
          String.t(),
          String.t(),
          SubTask.t(),
          String.t(),
          pid(),
          list(),
          map()
        ) :: {:ok, String.t()} | {:error, term()}
  def run_agent_loop(
        agent_id,
        task_id,
        system_prompt,
        sub_task,
        _session_id,
        orchestrator_pid,
        cached_tools,
        tier_opts
      ) do
    user_message =
      if sub_task.context do
        """
        ## Task
        #{sub_task.description}

        ## Context from Previous Agents
        #{sub_task.context}
        """
      else
        sub_task.description
      end

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_message}
    ]

    # Use cached tools or read from persistent_term (lock-free).
    # NEVER call Tools.list_tools() here — it goes through the GenServer
    # which is blocked by the Tools.Registry.execute call that started us.
    tools =
      if cached_tools != [] do
        cached_tools
      else
        Tools.list_tools_direct()
      end

    # Strip recursive tools — sub-agents must not spawn further orchestrations
    restricted = ~w(orchestrate create_skill)
    tools = Enum.reject(tools, fn tool -> tool.name in restricted end)

    # Filter tools to only what this agent needs (if specified)
    tools =
      if sub_task.tools_needed != [] do
        Enum.filter(tools, fn tool -> tool.name in sub_task.tools_needed end)
      else
        tools
      end

    max_iters = tier_opts.max_iterations

    run_sub_agent_iterations(
      agent_id,
      task_id,
      messages,
      tools,
      orchestrator_pid,
      0,
      0,
      0,
      tier_opts,
      max_iters
    )
  end

  @doc """
  Iteration limit clause — returns the last assistant message as the result.
  """
  @spec run_sub_agent_iterations(
          String.t(),
          String.t(),
          list(),
          list(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          map(),
          non_neg_integer()
        ) :: {:ok, String.t()} | {:error, term()}
  def run_sub_agent_iterations(
        agent_id,
        task_id,
        messages,
        _tools,
        orchestrator_pid,
        iteration,
        tool_uses,
        tokens_used,
        _tier_opts,
        max_iters
      )
      when iteration >= max_iters do
    Logger.warning("[Orchestrator] Sub-agent #{agent_id} hit max iterations (#{max_iters})")

    GenServer.cast(
      orchestrator_pid,
      {:agent_progress, task_id, agent_id,
       %{
         tool_uses: tool_uses,
         tokens_used: tokens_used,
         current_action: "Completed (max iterations)"
       }}
    )

    last_assistant =
      messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == "assistant" end)

    {:ok,
     (last_assistant && last_assistant.content) ||
       "Agent reached iteration limit without producing a result."}
  end

  # Main iteration clause — calls the LLM, handles tool calls, recurses.
  def run_sub_agent_iterations(
        agent_id,
        task_id,
        messages,
        tools,
        orchestrator_pid,
        iteration,
        tool_uses,
        tokens_used,
        tier_opts,
        max_iters
      ) do
    GenServer.cast(
      orchestrator_pid,
      {:agent_progress, task_id, agent_id,
       %{
         tool_uses: tool_uses,
         tokens_used: tokens_used,
         current_action: "Thinking... (iteration #{iteration + 1}/#{max_iters})"
       }}
    )

    llm_opts = [
      tools: tools,
      temperature: tier_opts.temperature,
      model: tier_opts.model,
      max_tokens: tier_opts.max_response_tokens
    ]

    try do
      case Providers.chat(messages, llm_opts) do
        {:ok, %{content: content, tool_calls: []}} ->
          estimated_tokens = tokens_used + estimate_tokens(content)

          GenServer.cast(
            orchestrator_pid,
            {:agent_progress, task_id, agent_id,
             %{
               tool_uses: tool_uses,
               tokens_used: estimated_tokens,
               current_action: "Done"
             }}
          )

          {:ok, content}

        {:ok, %{content: content, tool_calls: tool_calls}}
        when is_list(tool_calls) and tool_calls != [] ->
          new_tool_uses = tool_uses + length(tool_calls)
          estimated_tokens = tokens_used + estimate_tokens(content)

          messages = messages ++ [%{role: "assistant", content: content, tool_calls: tool_calls}]

          {messages, new_tool_uses_final, estimated_tokens_final} =
            Enum.reduce(
              tool_calls,
              {messages, new_tool_uses, estimated_tokens},
              fn tool_call, {msgs, tu, et} ->
                GenServer.cast(
                  orchestrator_pid,
                  {:agent_progress, task_id, agent_id,
                   %{
                     tool_uses: tu,
                     tokens_used: et,
                     current_action: "Running #{tool_call.name}"
                   }}
                )

                # Use execute_direct to bypass GenServer — Tools.Registry is blocked
                # by the parent execute("orchestrate") call that spawned us.
                result_str =
                  case Tools.execute_direct(tool_call.name, tool_call.arguments) do
                    {:ok, output} -> output
                    {:error, reason} -> "Error: #{reason}"
                  end

                tool_msg = %{role: "tool", tool_call_id: tool_call.id, content: result_str}
                {msgs ++ [tool_msg], tu, et + estimate_tokens(result_str)}
              end
            )

          run_sub_agent_iterations(
            agent_id,
            task_id,
            messages,
            tools,
            orchestrator_pid,
            iteration + 1,
            new_tool_uses_final,
            estimated_tokens_final,
            tier_opts,
            max_iters
          )

        {:ok, %{content: content}} when is_binary(content) and content != "" ->
          {:ok, content}

        {:error, reason} ->
          Logger.error(
            "[Orchestrator] Sub-agent #{agent_id} LLM call failed: #{inspect(reason)}"
          )

          {:error, "LLM call failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[Orchestrator] Sub-agent #{agent_id} crashed: #{Exception.message(e)}")
        {:error, "Agent crashed: #{Exception.message(e)}"}
    end
  end

  @doc """
  Build a role-specific system prompt for a sub-agent.

  Checks the Roster for a named agent matching the sub-task description first,
  then falls back to role-based prompts. Injects tier parameters into the prompt.
  """
  @spec build_agent_prompt(SubTask.t()) :: String.t()
  def build_agent_prompt(sub_task) do
    role_prompt =
      case Roster.find_by_trigger(sub_task.description) do
        %{prompt: prompt} -> prompt
        nil -> Roster.role_prompt(sub_task.role)
      end

    agent_tier =
      case Roster.find_by_trigger(sub_task.description) do
        %{tier: tier} -> tier
        nil -> :specialist
      end

    max_iters = Tier.max_iterations(agent_tier)

    """
    #{role_prompt}

    ## Your Specific Task
    #{sub_task.description}

    ## Available Tools
    #{Enum.join(sub_task.tools_needed || [], ", ")}

    ## Execution Parameters
    - Tier: #{agent_tier}
    - Max iterations: #{max_iters}
    - Token budget: #{Tier.total_budget(agent_tier)}

    ## Rules
    - Focus ONLY on your assigned task
    - Be thorough but efficient
    - Report your results clearly when done
    - If you encounter a blocker, state it clearly and do what you can
    - Match existing codebase patterns and conventions
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp estimate_tokens(nil), do: 0

  defp estimate_tokens(text) when is_binary(text) do
    div(String.length(text), 4)
  end

  defp estimate_tokens(_), do: 0
end
