defmodule Daemon.Agent.Orchestrator.AgentRunner do
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

  alias Daemon.Agent.{Roster, Tier, Memory, Orchestrator.SubTask, Orchestrator.AgentState, Orchestrator.GitVersioning}
  alias Daemon.Events.Bus
  alias MiosaProviders.Registry, as: Providers
  alias Daemon.Tools.Registry, as: Tools

  # Three confidence tiers for agent selection:
  # High (>= 4.0): Strong match — use named agent prompt directly
  # Medium (2.0-4.0): Blended — dynamic task framing + named agent expertise
  # Low (< 2.0): No good match — pure dynamic prompt, fully task-adapted
  @high_confidence_threshold 4.0
  @low_confidence_threshold 2.0

  # Only block tools that would cause infinite recursion.
  # Everything else is available to every agent — maximum capability.
  @blocked_tools ~w(orchestrate)

  # LLM retry config — transient failures shouldn't kill an agent.
  @max_retries 2
  @retry_base_ms 1_000

  @doc """
  Spawn a sub-agent as a `Task.async` and return its identity and task ref.

  Returns `{agent_id, %AgentState{}, %Task{}}`.
  The caller (GenServer) is responsible for receiving the Task's result
  via `handle_info({ref, result}, state)`.
  """
  @spec spawn_agent(SubTask.t(), String.t(), String.t(), list(), keyword()) ::
          {String.t(), AgentState.t(), Task.t()}
  def spawn_agent(sub_task, task_id, session_id, cached_tools, opts \\ []) do
    agent_id = Daemon.Utils.ID.generate("agent")

    system_prompt = build_agent_prompt(sub_task)
    agent_tier = resolve_agent_tier(sub_task)
    provider = Application.get_env(:daemon, :default_provider, :ollama)

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

    batch_id = Keyword.get(opts, :batch_id)

    Bus.emit(:system_event, %{
      event: :orchestrator_agent_started,
      task_id: task_id,
      session_id: session_id,
      agent_id: agent_id,
      agent_name: sub_task.name,
      role: sub_task.role,
      tier: agent_tier,
      model: tier_opts.model,
      batch_id: batch_id,
      description: sub_task.description || ""
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

  Uses `Roster.select_for_task/1` to find the best matching named agent and
  inherit its tier. Falls back to role-based defaults when no match is found.
  """
  @spec resolve_agent_tier(SubTask.t()) :: :elite | :specialist | :utility
  def resolve_agent_tier(sub_task) do
    case Roster.select_for_task_scored(sub_task.description) do
      [{best_name, score} | _] when score >= @low_confidence_threshold ->
        case Roster.get(best_name) do
          %{tier: tier} -> tier
          _ -> role_default_tier(sub_task.role)
        end

      _ ->
        role_default_tier(sub_task.role)
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

    # Inject relevant memories into system context so the sub-agent is aware
    # of past decisions, preferences, and patterns related to its task.
    system_prompt_with_memory =
      case Memory.recall_relevant(sub_task.description, 1000) do
        "" ->
          system_prompt

        relevant_memories ->
          """
          #{system_prompt}

          ## Relevant Memory Context
          The following past decisions and preferences are relevant to your task.
          Use them to stay consistent with established patterns:

          #{relevant_memories}
          """
      end

    messages = [
      %{role: "system", content: system_prompt_with_memory},
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

    # Only block recursive tools that would cause infinite orchestration loops.
    # Every agent gets ALL other tools — maximum capability, no artificial limits.
    tools = Enum.reject(tools, fn tool -> tool.name in @blocked_tools end)

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

    case chat_with_retry(agent_id, messages, llm_opts) do
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

              result_str = safe_execute_tool(agent_id, tool_call)

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
          "[Orchestrator] Sub-agent #{agent_id} LLM call failed after retries: #{inspect(reason)}"
        )

        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Build an intelligent system prompt for a sub-agent.

  Uses multi-factor scoring (`Roster.select_for_task/1`) to pick the optimal
  named agent from the 52-agent roster. When a named agent matches, loads the
  full `.md` definition from `priv/agents/` for a rich, specialized prompt.
  Falls back to role-based prompts when no named agent matches well enough.

  Also injects:
  - Skills context (triggered by task description keywords)
  - Environment context (working directory, git branch)
  """
  @spec build_agent_prompt(SubTask.t()) :: String.t()
  def build_agent_prompt(sub_task) do
    {agent_prompt, agent_name, agent_tier} = select_optimal_agent(sub_task)

    max_iters = Tier.max_iterations(agent_tier)

    # Inject skills: match by task description AND include parent-inherited skills.
    inherited_block =
      case Map.get(sub_task, :inherited_skills, []) do
        [] -> nil
        names ->
          skills = :persistent_term.get({Daemon.Tools.Registry, :skills}, %{})
          ctx =
            names
            |> Enum.flat_map(fn name ->
              case Map.get(skills, to_string(name)) do
                nil -> []
                skill ->
                  inst = skill.instructions |> to_string() |> String.trim()
                  if inst != "", do: ["### Inherited Skill: #{skill.name}\n\n#{inst}"], else: []
              end
            end)
            |> Enum.join("\n\n")
          if ctx == "", do: nil, else: ctx
      end

    matched_block = Tools.active_skills_context(sub_task.description)

    skills_block =
      case {matched_block, inherited_block} do
        {nil, nil} -> ""
        {nil, i} -> "\n## Active Skills\n#{i}\n"
        {m, nil} -> "\n## Active Skills\n#{m}\n"
        {m, i} -> "\n## Active Skills\n#{m}\n\n#{i}\n"
      end

    # Environment context so the agent knows where it's working
    env_block = build_environment_context()

    # Dependency and context sections — apply to ALL agents (named + dynamic)
    deps_section =
      case sub_task.depends_on do
        [] -> ""
        nil -> ""
        deps -> "\n## Dependencies\nThis task depends on outputs from: #{Enum.join(deps, ", ")}. Incorporate their results.\n"
      end

    context_section =
      case sub_task.context do
        nil -> ""
        "" -> ""
        ctx -> "\n## Context from Previous Agents\n#{ctx}\n"
      end

    """
    #{agent_prompt}

    ## Your Specific Task
    #{sub_task.description}
    #{deps_section}#{context_section}
    ## Available Tools
    #{Enum.join(sub_task.tools_needed || [], ", ")}
    #{skills_block}
    #{env_block}
    ## Execution Parameters
    - Agent: #{agent_name || "role-based (#{sub_task.role})"}
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

  # Select the optimal named agent using 3-tier graduated confidence:
  #
  # HIGH (>= 4.0): Named agent prompt leads. The agent's full expertise
  #   drives the response, task description is injected as context.
  #
  # MEDIUM (2.0-4.0): Blended prompt. Dynamic task-optimized framing leads,
  #   but the named agent's expertise is injected as reference material.
  #   Best of both worlds — task focus + domain knowledge.
  #
  # LOW (< 2.0): Pure dynamic prompt. Fully adapted to the specific task
  #   with no named agent involvement (they'd add noise, not signal).
  #
  # Returns {prompt_string, agent_name | nil, tier_atom}.
  defp select_optimal_agent(sub_task) do
    case Roster.select_for_task_scored(sub_task.description) do
      [{best_name, score} | _] when score >= @high_confidence_threshold ->
        # HIGH confidence — named agent leads
        agent = Roster.get(best_name)

        prompt =
          case Roster.load_definition(best_name) do
            {:ok, md_content} -> md_content
            {:error, _} -> Roster.prompt(best_name) || Roster.role_prompt(sub_task.role)
          end

        tier = (agent && agent.tier) || :specialist

        Logger.debug(
          "[AgentRunner] HIGH confidence: '#{best_name}' (#{score}) for: #{String.slice(sub_task.description, 0, 60)}"
        )

        {prompt, best_name, tier}

      [{best_name, score} | _] when score >= @low_confidence_threshold ->
        # MEDIUM confidence — blend dynamic prompt with named agent expertise
        agent = Roster.get(best_name)
        tier = (agent && agent.tier) || :specialist

        # Get the agent's expertise to inject as reference
        agent_expertise =
          case Roster.load_definition(best_name) do
            {:ok, md_content} -> md_content
            {:error, _} -> Roster.prompt(best_name) || ""
          end

        prompt = build_blended_prompt(sub_task, best_name, agent_expertise)

        Logger.debug(
          "[AgentRunner] MEDIUM confidence: blending '#{best_name}' (#{score}) for: #{String.slice(sub_task.description, 0, 60)}"
        )

        {prompt, best_name, tier}

      scored ->
        # LOW confidence — pure dynamic prompt
        top_info =
          case scored do
            [{name, score} | _] -> "(best was '#{name}' at #{score})"
            [] -> "(no candidates)"
          end

        Logger.debug(
          "[AgentRunner] LOW confidence #{top_info} — dynamic prompt for: #{String.slice(sub_task.description, 0, 60)}"
        )

        tier = role_default_tier(sub_task.role)
        prompt = build_dynamic_prompt(sub_task)
        {prompt, nil, tier}
    end
  end

  # Build a blended prompt: dynamic task-optimized framing + named agent expertise.
  # Used for medium-confidence matches where the agent is relevant but not a
  # perfect fit. The task framing leads so intent is encoded precisely, while
  # the agent's domain expertise provides depth and methodology.
  defp build_blended_prompt(sub_task, agent_name, agent_expertise) do
    role_name = sub_task.role |> to_string() |> String.replace("_", " ") |> String.capitalize()

    # Truncate expertise to prevent bloating the context — keep the most
    # valuable first ~2000 chars (identity, approach, key skills)
    expertise_excerpt =
      if String.length(agent_expertise) > 2000 do
        String.slice(agent_expertise, 0, 2000) <> "\n[...expertise truncated for focus...]"
      else
        agent_expertise
      end

    """
    # #{role_name} Agent — Task-Optimized with #{agent_name} Expertise

    You are a specialized #{role_name} agent executing a specific task within a
    multi-agent orchestration. Your primary focus is the task below, but you also
    draw on the domain expertise of the #{agent_name} specialist agent.

    ## Your Task (PRIMARY FOCUS)
    #{sub_task.description}

    ## Domain Expertise Reference
    The following expertise from the #{agent_name} agent is relevant to your task.
    Use it to inform your approach, methodology, and quality standards:

    #{expertise_excerpt}

    ## Approach
    1. Focus on YOUR specific task — don't wander into adjacent territory
    2. Apply the domain expertise above where it helps solve your task
    3. Use available tools proactively to gather information and make changes
    4. Follow existing codebase patterns and conventions
    5. Validate your work before reporting completion

    ## Output
    When complete, provide a clear summary of:
    - What you did
    - What files were changed (if any)
    - Any issues or blockers encountered
    - Verification that your changes are correct
    """
  end

  # Build a focused, task-specific system prompt when no named agent
  # matches well enough. This is a one-off prompt optimized for the exact
  # sub-task, giving the agent clear identity, domain focus, and methodology.
  defp build_dynamic_prompt(sub_task) do
    role_name = sub_task.role |> to_string() |> String.replace("_", " ") |> String.capitalize()

    tools_section =
      case sub_task.tools_needed do
        [] -> ""
        tools -> "\nYou have access to: #{Enum.join(tools, ", ")}. Use them proactively.\n"
      end

    context_section =
      case sub_task.context do
        nil -> ""
        "" -> ""
        ctx ->
          """

          ## Context from Previous Agents
          #{ctx}
          """
      end

    deps_section =
      case sub_task.depends_on do
        [] -> ""
        deps -> "\nThis task depends on outputs from: #{Enum.join(deps, ", ")}. Incorporate their results.\n"
      end

    """
    # #{role_name} Agent — Dynamic Task Specialist

    You are a specialized #{role_name} agent created for a specific task within a
    multi-agent orchestration. You have the full capabilities of the system at your
    disposal including all tools, skills, and context.

    ## Your Identity
    - Role: #{role_name}
    - Specialization: #{sub_task.description}
    - You are one agent in a coordinated team. Focus exclusively on YOUR task.

    ## Approach
    1. Analyze the task requirements thoroughly before acting
    2. Use available tools to gather information and make changes
    3. Follow existing codebase patterns and conventions
    4. Validate your work before reporting completion
    5. Be precise and thorough — quality over speed
    #{tools_section}#{deps_section}#{context_section}
    ## Output
    When complete, provide a clear summary of:
    - What you did
    - What files were changed (if any)
    - Any issues or blockers encountered
    - Verification that your changes are correct
    """
  end

  defp role_default_tier(:lead), do: :elite
  defp role_default_tier(:red_team), do: :specialist
  defp role_default_tier(:explorer), do: :specialist
  defp role_default_tier(_), do: :specialist

  defp build_environment_context do
    cwd = File.cwd!()

    git_branch =
      case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd, stderr_to_stdout: true) do
        {branch, 0} -> String.trim(branch)
        _ -> "unknown"
      end

    git_log = GitVersioning.recent_log(cwd, 5)

    log_section =
      if git_log not in ["(git log unavailable)", "(not a git repository)"] do
        "\n- Recent commits:\n#{git_log}"
      else
        ""
      end

    """
    ## Environment
    - Working directory: #{cwd}
    - Git branch: #{git_branch}#{log_section}
    """
  end

  # ── LLM retry ───────────────────────────────────────────────────────

  # Retries transient LLM failures (rate limits, timeouts, 5xx) with
  # exponential backoff. Permanent errors (auth, bad request) fail immediately.
  defp chat_with_retry(agent_id, messages, llm_opts, attempt \\ 0) do
    try do
      case Providers.chat(messages, llm_opts) do
        {:error, reason} ->
          if attempt < @max_retries and retryable?(reason) do
            delay = @retry_base_ms * :math.pow(2, attempt) |> trunc()

            Logger.warning(
              "[AgentRunner] Agent #{agent_id} LLM error (attempt #{attempt + 1}/#{@max_retries + 1}), retrying in #{delay}ms: #{inspect(reason)}"
            )

            Process.sleep(delay)
            chat_with_retry(agent_id, messages, llm_opts, attempt + 1)
          else
            {:error, reason}
          end

        other ->
          other
      end
    rescue
      e ->
        if attempt < @max_retries do
          delay = @retry_base_ms * :math.pow(2, attempt) |> trunc()

          Logger.warning(
            "[AgentRunner] Agent #{agent_id} LLM crash (attempt #{attempt + 1}), retrying in #{delay}ms: #{Exception.message(e)}"
          )

          Process.sleep(delay)
          chat_with_retry(agent_id, messages, llm_opts, attempt + 1)
        else
          {:error, "Agent crashed: #{Exception.message(e)}"}
        end
    end
  end

  defp retryable?(reason) when is_binary(reason) do
    lower = String.downcase(reason)

    String.contains?(lower, "rate") or
      String.contains?(lower, "timeout") or
      String.contains?(lower, "429") or
      String.contains?(lower, "500") or
      String.contains?(lower, "502") or
      String.contains?(lower, "503") or
      String.contains?(lower, "overloaded")
  end

  defp retryable?(%{status: status}) when status in [429, 500, 502, 503, 529], do: true
  defp retryable?(_), do: false

  # ── Safe tool execution ────────────────────────────────────────────

  # Wraps tool execution so a single crashing tool doesn't kill the agent.
  # The error message goes back to the LLM so it can adapt.
  defp safe_execute_tool(agent_id, tool_call) do
    try do
      case Tools.execute_direct(tool_call.name, tool_call.arguments) do
        {:ok, output} -> output
        {:error, reason} -> "Error executing #{tool_call.name}: #{reason}"
      end
    rescue
      e ->
        Logger.warning(
          "[AgentRunner] Agent #{agent_id} tool '#{tool_call.name}' crashed: #{Exception.message(e)}"
        )

        "Error: tool '#{tool_call.name}' crashed — #{Exception.message(e)}. Try an alternative approach."
    catch
      :exit, reason ->
        Logger.warning(
          "[AgentRunner] Agent #{agent_id} tool '#{tool_call.name}' exited: #{inspect(reason)}"
        )

        "Error: tool '#{tool_call.name}' exited unexpectedly. Try an alternative approach."
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp estimate_tokens(nil), do: 0

  defp estimate_tokens(text) when is_binary(text) do
    div(String.length(text), 4)
  end

  defp estimate_tokens(_), do: 0
end
