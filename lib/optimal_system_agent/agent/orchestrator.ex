defmodule OptimalSystemAgent.Agent.Orchestrator do
  @moduledoc """
  Autonomous task orchestration engine.

  When a complex task arrives, the orchestrator:
  1. Analyzes complexity (simple -> single agent, complex -> multi-agent)
  2. Decomposes into parallel sub-tasks
  3. Spawns sub-agents with specialized prompts
  4. Tracks real-time progress (tool uses, tokens, status)
  5. Synthesizes results from all sub-agents
  6. Can dynamically create new skills when existing ones are insufficient

  This is what makes OSA feel like a team of engineers, not a chatbot.

  Progress events are emitted on the event bus so UIs can show:
  Running 3 agents...
     Research agent - 12 tool uses - 45.2k tokens
     Build agent - 28 tool uses - 89.1k tokens
     Test agent - 8 tool uses - 23.4k tokens
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.{Appraiser, Roster, TaskQueue}
  alias OptimalSystemAgent.Agent.Orchestrator.{SkillManager, Decomposer, AgentRunner}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  defstruct tasks: %{},
            agent_pool: %{},
            skill_cache: %{}

  # ── Sub-task struct ──────────────────────────────────────────────────

  defmodule SubTask do
    @moduledoc "A decomposed sub-task to be executed by a sub-agent."
    defstruct [
      :name,
      :description,
      :role,
      :tools_needed,
      depends_on: [],
      context: nil
    ]
  end

  defmodule AgentState do
    @moduledoc "Runtime state for a single sub-agent."
    defstruct [
      :id,
      :task_id,
      :name,
      :role,
      status: :pending,
      tool_uses: 0,
      tokens_used: 0,
      current_action: nil,
      started_at: nil,
      completed_at: nil,
      result: nil,
      error: nil
    ]
  end

  defmodule TaskState do
    @moduledoc "State for an orchestrated task."
    defstruct [
      :id,
      :message,
      :session_id,
      :strategy,
      status: :running,
      agents: %{},
      sub_tasks: [],
      results: %{},
      synthesis: nil,
      started_at: nil,
      completed_at: nil,
      error: nil,
      # Non-blocking execution state
      wave_refs: %{},
      current_wave: 0,
      pending_waves: [],
      cached_tools: []
    ]
  end

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Execute a complex task with multiple sub-agents.
  Returns {:ok, task_id} immediately — execution proceeds asynchronously
  via handle_continue. Poll progress/1 or subscribe to
  :orchestrator_task_completed events for results.
  """
  @spec execute(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(message, session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, message, session_id, opts}, 60_000)
  end

  @doc """
  Get real-time progress for a running task.
  Returns agent statuses, tool use counts, token usage.
  """
  @spec progress(String.t()) :: {:ok, map()} | {:error, :not_found}
  def progress(task_id) do
    GenServer.call(__MODULE__, {:progress, task_id})
  end

  @doc """
  Dynamically create a new skill for a specific task.
  Writes a SKILL.md file and registers it with the Tools.Registry.
  """
  @spec create_skill(String.t(), String.t(), String.t(), list()) ::
          {:ok, String.t()} | {:error, term()}
  def create_skill(name, description, instructions, tools \\ []) do
    GenServer.call(__MODULE__, {:create_skill, name, description, instructions, tools})
  end

  @doc """
  List all tasks (running and recently completed).
  """
  @spec list_tasks() :: list(map())
  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  @doc """
  Search existing skills before creating new ones.
  Takes a task description and returns matching skills with relevance scores.
  """
  @spec find_matching_skills(String.t()) :: {:matches, list(map())} | :no_matches
  def find_matching_skills(task_description) do
    GenServer.call(__MODULE__, {:find_matching_skills, task_description})
  end

  @doc """
  Suggest existing skills or create a new one.
  First checks for matching skills. If matches with relevance > 0.5 exist,
  returns them for user confirmation. Otherwise creates the new skill.
  """
  @spec suggest_or_create_skill(String.t(), String.t(), String.t(), list()) ::
          {:existing_matches, list(map())} | {:created, String.t()} | {:error, term()}
  def suggest_or_create_skill(name, description, instructions, tools \\ []) do
    GenServer.call(__MODULE__, {:suggest_or_create, name, description, instructions, tools})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(state) do
    Logger.info(
      "[Orchestrator] Task orchestration engine started (max_agents=#{Roster.max_agents()})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, message, session_id, opts}, _from, state) do
    task_id = generate_id("task")
    strategy = Keyword.get(opts, :strategy, "auto")
    # Tools may be pre-cached by the caller to avoid GenServer deadlock
    cached_tools = Keyword.get(opts, :cached_tools, [])

    Bus.emit(:system_event, %{
      event: :orchestrator_task_started,
      task_id: task_id,
      session_id: session_id,
      message_preview: String.slice(message, 0, 200)
    })

    # Decompose is sync (needs LLM), but execution is async via handle_continue
    case Decomposer.decompose_task(message) do
      {:ok, sub_tasks} when is_list(sub_tasks) and length(sub_tasks) > 0 ->
        sub_tasks = Enum.take(sub_tasks, Roster.max_agents())

        # Estimate task value via Appraiser (best-effort)
        appraisal =
          try do
            estimates =
              Enum.map(sub_tasks, fn st ->
                role = st.role || :backend
                %{role: role, complexity: length(st.depends_on) + 3}
              end)

            Appraiser.estimate_task(estimates)
          rescue
            _ -> nil
          end

        if appraisal do
          Bus.emit(:system_event, %{
            event: :orchestrator_task_appraised,
            task_id: task_id,
            session_id: session_id,
            estimated_cost_usd: appraisal.total_cost_usd,
            estimated_hours: appraisal.total_hours
          })
        end

        # Enqueue sub-tasks into TaskQueue (best-effort)
        try do
          Enum.each(sub_tasks, fn st ->
            subtask_id = "#{task_id}_#{st.name}"

            TaskQueue.enqueue(subtask_id, session_id, %{
              name: st.name,
              role: st.role,
              description: st.description,
              depends_on: st.depends_on
            })

            # Emit task_created so the TUI task checklist is populated.
            # active_form is the active-voice description shown while in_progress.
            Bus.emit(:system_event, %{
              event: :task_created,
              task_id: subtask_id,
              subject: st.name,
              active_form: String.slice(st.description || st.name, 0, 80),
              session_id: session_id
            })
          end)
        catch
          :exit, _ -> :ok
        end

        task_state = %TaskState{
          id: task_id,
          message: message,
          session_id: session_id,
          strategy: strategy,
          status: :running,
          sub_tasks: sub_tasks,
          started_at: DateTime.utc_now(),
          cached_tools: cached_tools
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_agents_spawning,
          task_id: task_id,
          session_id: session_id,
          agent_count: length(sub_tasks),
          agents: Enum.map(sub_tasks, fn st -> %{name: st.name, role: st.role} end)
        })

        # Reply immediately, continue execution asynchronously
        {:reply, {:ok, task_id}, state,
         {:continue, {:start_execution, task_id}}}

      {:ok, []} ->
        Logger.warning(
          "[Orchestrator] Task decomposition returned no sub-tasks, running as simple"
        )

        result = run_simple(message, session_id)

        task_state = %TaskState{
          id: task_id,
          message: message,
          session_id: session_id,
          strategy: strategy,
          status: :completed,
          synthesis: result,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_task_completed,
          task_id: task_id,
          session_id: session_id,
          agent_count: 0,
          result_preview: String.slice(result || "", 0, 200)
        })

        {:reply, {:ok, task_id}, state}

      {:error, reason} ->
        Logger.error("[Orchestrator] Task decomposition failed: #{inspect(reason)}")

        Bus.emit(:system_event, %{
          event: :orchestrator_task_failed,
          task_id: task_id,
          session_id: session_id,
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:progress, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task_state ->
        progress = %{
          task_id: task_id,
          status: task_state.status,
          started_at: task_state.started_at,
          completed_at: task_state.completed_at,
          agents:
            task_state.agents
            |> Map.values()
            |> Enum.sort_by(& (&1.started_at || DateTime.utc_now()))
            |> Enum.map(fn agent ->
              %{
                id: agent.id,
                name: agent.name,
                role: agent.role,
                status: agent.status,
                tool_uses: agent.tool_uses,
                tokens_used: agent.tokens_used,
                current_action: agent.current_action,
                started_at: agent.started_at,
                completed_at: agent.completed_at
              }
            end),
          synthesis: task_state.synthesis,
          error: task_state.error
        }

        {:reply, {:ok, progress}, state}
    end
  end

  @impl true
  def handle_call({:create_skill, name, description, instructions, tools}, _from, state) do
    result = do_create_skill(name, description, instructions, tools)

    state =
      case result do
        {:ok, _} ->
          %{
            state
            | skill_cache:
                Map.put(state.skill_cache, name, %{
                  description: description,
                  created_at: DateTime.utc_now()
                })
          }

        _ ->
          state
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.map(fn t ->
        agent_count = map_size(t.agents)
        completed_count = t.agents |> Map.values() |> Enum.count(&(&1.status == :completed))

        %{
          id: t.id,
          status: t.status,
          message_preview: String.slice(t.message || "", 0, 100),
          agent_count: agent_count,
          completed_agents: completed_count,
          started_at: t.started_at,
          completed_at: t.completed_at
        }
      end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:find_matching_skills, task_description}, _from, state) do
    result = do_find_matching_skills(task_description)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:suggest_or_create, name, description, instructions, tools}, _from, state) do
    case do_find_matching_skills(description) do
      {:matches, matches} ->
        high_relevance = Enum.filter(matches, fn m -> m.relevance > 0.5 end)

        if high_relevance != [] do
          Logger.info(
            "[Orchestrator] Found #{length(high_relevance)} existing skill(s) matching '#{name}'"
          )

          {:reply, {:existing_matches, high_relevance}, state}
        else
          # Low relevance matches only — proceed to create
          result = do_create_skill(name, description, instructions, tools)

          state =
            case result do
              {:ok, _} ->
                %{
                  state
                  | skill_cache:
                      Map.put(state.skill_cache, name, %{
                        description: description,
                        created_at: DateTime.utc_now()
                      })
                }

              _ ->
                state
            end

          case result do
            {:ok, _} -> {:reply, {:created, name}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        end

      :no_matches ->
        result = do_create_skill(name, description, instructions, tools)

        state =
          case result do
            {:ok, _} ->
              %{
                state
                | skill_cache:
                    Map.put(state.skill_cache, name, %{
                      description: description,
                      created_at: DateTime.utc_now()
                    })
              }

            _ ->
              state
          end

        case result do
          {:ok, _} -> {:reply, {:created, name}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Handle progress updates from sub-agents via cast
  @impl true
  def handle_cast({:agent_progress, task_id, agent_id, update}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        case Map.get(task_state.agents, agent_id) do
          nil ->
            {:noreply, state}

          agent ->
            updated_agent = %{
              agent
              | tool_uses: Map.get(update, :tool_uses, agent.tool_uses),
                tokens_used: Map.get(update, :tokens_used, agent.tokens_used),
                current_action: Map.get(update, :current_action, agent.current_action)
            }

            updated_agents = Map.put(task_state.agents, agent_id, updated_agent)
            updated_task = %{task_state | agents: updated_agents}
            state = %{state | tasks: Map.put(state.tasks, task_id, updated_task)}

            Bus.emit(:system_event, %{
              event: :orchestrator_agent_progress,
              task_id: task_id,
              session_id: task_state.session_id,
              agent_id: agent_id,
              agent_name: agent.name,
              tool_uses: updated_agent.tool_uses,
              tokens_used: updated_agent.tokens_used,
              current_action: updated_agent.current_action
            })

            {:noreply, state}
        end
    end
  end

  # ── Handle Continue — Non-blocking wave execution ──────────────────

  @impl true
  def handle_continue({:start_execution, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        waves = Decomposer.build_execution_waves(task_state.sub_tasks)
        task_state = %{task_state | pending_waves: waves, current_wave: 0}
        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}
        {:noreply, state, {:continue, {:execute_wave, task_id}}}
    end
  end

  @impl true
  def handle_continue({:execute_wave, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      %{pending_waves: []} ->
        {:noreply, state, {:continue, {:synthesize, task_id}}}

      %{pending_waves: [wave | rest]} = task_state ->
        total_waves = task_state.current_wave + 1 + length(rest)

        Bus.emit(:system_event, %{
          event: :orchestrator_wave_started,
          task_id: task_id,
          session_id: task_state.session_id,
          wave_number: task_state.current_wave + 1,
          total_waves: total_waves,
          agent_count: length(wave)
        })

        session_id = task_state.session_id
        cached_tools = task_state.cached_tools

        # Spawn all agents in this wave, collecting refs and agent states
        spawn_results =
          Enum.map(wave, fn sub_task ->
            dep_context = Decomposer.build_dependency_context(sub_task.depends_on, task_state.results)
            sub_task_with_context = %{sub_task | context: dep_context}

            {agent_id, agent_state, task_ref} =
              AgentRunner.spawn_agent(sub_task_with_context, task_id, session_id, cached_tools)

            subtask_id = "#{task_id}_#{sub_task.name}"
            {agent_id, agent_state, task_ref, sub_task.name, subtask_id}
          end)

        # Build wave_refs map: monitor_ref => {agent_name, agent_id, subtask_id}
        wave_refs =
          Enum.reduce(spawn_results, %{}, fn {agent_id, _as, task_ref, name, subtask_id}, refs ->
            Map.put(refs, task_ref.ref, {name, agent_id, subtask_id})
          end)

        # Register all agents into task state
        updated_agents =
          Enum.reduce(spawn_results, task_state.agents, fn {agent_id, agent_state, _, _, _}, agents ->
            Map.put(agents, agent_id, agent_state)
          end)

        task_state = %{
          task_state
          | pending_waves: rest,
            current_wave: task_state.current_wave + 1,
            wave_refs: wave_refs,
            agents: updated_agents
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:synthesize, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        synthesis = synthesize_results(task_id, task_state.results, task_state.message, task_state.session_id)

        task_state = %{
          task_state
          | status: :completed,
            synthesis: synthesis,
            completed_at: DateTime.utc_now()
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_task_completed,
          task_id: task_id,
          session_id: task_state.session_id,
          agent_count: map_size(task_state.agents),
          result_preview: String.slice(synthesis || "", 0, 200)
        })

        Logger.info(
          "[Orchestrator] Task #{task_id} completed — #{map_size(task_state.agents)} agents, synthesis ready"
        )

        {:noreply, state}
    end
  end

  # ── Handle Info — Task.async completion / crash messages ────────────

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task.async completion — demonitor and flush the :DOWN message
    Process.demonitor(ref, [:flush])

    case find_task_by_ref(ref, state) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text =
          case result do
            {:ok, text} -> text
            {:error, reason} -> "FAILED: #{reason}"
            text when is_binary(text) -> text
          end

        state = record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, result)

        # Check if all agents in current wave are done
        task_state = Map.get(state.tasks, task_id)

        if map_size(task_state.wave_refs) == 0 do
          {:noreply, state, {:continue, {:execute_wave, task_id}}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_task_by_ref(ref, state) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text = "FAILED: Agent crashed: #{inspect(reason)}"
        state = record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, {:error, result_text})

        task_state = Map.get(state.tasks, task_id)

        if map_size(task_state.wave_refs) == 0 do
          {:noreply, state, {:continue, {:execute_wave, task_id}}}
        else
          {:noreply, state}
        end
    end
  end

  # ── Non-blocking execution helpers ──────────────────────────────────

  # Find which task owns a given Task.async ref
  defp find_task_by_ref(ref, state) do
    Enum.find_value(state.tasks, fn {task_id, task_state} ->
      case Map.get(task_state.wave_refs, ref) do
        {agent_name, agent_id, subtask_id} ->
          {task_id, agent_name, agent_id, subtask_id}

        nil ->
          nil
      end
    end)
  end

  # Record an agent's result: update agent state, wave_refs, results map, TaskQueue
  defp record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, raw_result) do
    task_state = Map.get(state.tasks, task_id)

    # Update agent status
    {status, agent_result, error} =
      case raw_result do
        {:ok, text} -> {:completed, text, nil}
        {:error, reason} -> {:failed, nil, reason}
        text when is_binary(text) -> {:completed, text, nil}
      end

    updated_agent =
      case Map.get(task_state.agents, agent_id) do
        nil -> nil
        agent ->
          %{agent | status: status, result: agent_result, error: error, completed_at: DateTime.utc_now()}
      end

    updated_agents =
      if updated_agent, do: Map.put(task_state.agents, agent_id, updated_agent), else: task_state.agents

    # Remove ref from wave_refs and store result
    wave_refs = Map.reject(task_state.wave_refs, fn {_ref, {name, _, _}} -> name == agent_name end)

    task_state = %{
      task_state
      | agents: updated_agents,
        wave_refs: wave_refs,
        results: Map.put(task_state.results, agent_name, result_text)
    }

    # TaskQueue complete/fail (best-effort)
    try do
      case status do
        :completed -> TaskQueue.complete(subtask_id, result_text)
        :failed -> TaskQueue.fail(subtask_id, error || result_text)
      end
    catch
      :exit, _ -> :ok
    end

    Bus.emit(:system_event, %{
      event: :orchestrator_agent_completed,
      task_id: task_id,
      session_id: task_state.session_id,
      agent_id: agent_id,
      agent_name: agent_name,
      status: status
    })

    # Emit task_updated so the TUI reflects the final state of this subtask.
    status_str = if status == :completed, do: "completed", else: "failed"
    Bus.emit(:system_event, %{
      event: :task_updated,
      task_id: subtask_id,
      status: status_str,
      session_id: task_state.session_id
    })

    %{state | tasks: Map.put(state.tasks, task_id, task_state)}
  end

  # ── Result Synthesis ────────────────────────────────────────────────

  defp synthesize_results(task_id, results, original_message, session_id) do
    if map_size(results) == 0 do
      "No agents produced results."
    else
      agent_outputs =
        Enum.map(results, fn {name, result} ->
          "## Agent: #{name}\n#{result}"
        end)
        |> Enum.join("\n\n---\n\n")

      prompt = """
      You are synthesizing the work of multiple agents. The original task was:
      "#{String.slice(original_message, 0, 500)}"

      Here are the results from each agent:

      #{agent_outputs}

      Provide a unified response that:
      1. Summarizes what was accomplished
      2. Lists any files created or modified
      3. Notes any issues or follow-up items
      4. Gives a clear status: COMPLETE, PARTIAL, or FAILED
      """

      Bus.emit(:system_event, %{
        event: :orchestrator_synthesizing,
        task_id: task_id,
        session_id: session_id,
        agent_count: map_size(results)
      })

      try do
        case Providers.chat([%{role: "user", content: prompt}],
               temperature: 0.3,
               max_tokens: 2000
             ) do
          {:ok, %{content: synthesis}} when is_binary(synthesis) and synthesis != "" ->
            synthesis

          _ ->
            # Fallback: join all results
            Logger.warning(
              "[Orchestrator] Synthesis LLM call failed -- falling back to joined results"
            )

            Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
              "## #{name}\n#{result}"
            end)
        end
      rescue
        e ->
          Logger.error("[Orchestrator] Synthesis failed: #{Exception.message(e)}")

          Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
            "## #{name}\n#{result}"
          end)
      end
    end
  end

  # ── Simple Execution (single-agent fallback) ────────────────────────

  defp run_simple(message, _session_id) do
    messages = [%{role: "user", content: message}]

    try do
      case Providers.chat(messages, temperature: 0.5, max_tokens: 2000) do
        {:ok, %{content: content}} when is_binary(content) -> content
        _ -> "Failed to process the task."
      end
    rescue
      _ -> "Failed to process the task."
    end
  end

  # ── Dynamic Skill Creation & Discovery ────────────────────────────────
  # Delegated to Orchestrator.SkillManager

  defp do_create_skill(name, description, instructions, tools),
    do: SkillManager.create(name, description, instructions, tools)

  defp do_find_matching_skills(task_description),
    do: SkillManager.find_matches(task_description)

  # ── Helpers ─────────────────────────────────────────────────────────

  defp generate_id(prefix),
    do: OptimalSystemAgent.Utils.ID.generate(prefix)
end
