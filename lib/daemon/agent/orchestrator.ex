defmodule Daemon.Agent.Orchestrator do
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

  alias Daemon.Agent.{Appraiser, Loop, Roster, Tasks}
  alias Daemon.Agent.Orchestrator.{Complexity, SkillManager, Decomposer, AgentRunner, WaveExecutor, GitVersioning, ComplexityScaler, StateMachine, Negotiation}
  alias Daemon.Events.Bus
  alias Daemon.Tools.Registry, as: Tools
  alias MiosaProviders.Registry, as: Providers

  defstruct tasks: %{},
            agent_pool: %{},
            skill_cache: %{},
            machines: %{}

  # ── Sub-task struct ──────────────────────────────────────────────────

  defmodule SubTask do
    @moduledoc "A decomposed sub-task to be executed by a sub-agent."
    defstruct [
      :name,
      :description,
      :role,
      :tools_needed,
      depends_on: [],
      context: nil,
      inherited_skills: []
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
      cached_tools: [],
      max_iterations_override: nil
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
    GenServer.call(__MODULE__, {:execute, message, session_id, opts}, 600_000)
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

  Smart skill management that prevents duplicates by searching first.
  If high-relevance matches (relevance > 0.5) exist, returns them for
  user confirmation. Otherwise creates the new skill automatically.

  ## Parameters
    - `name` - Skill name (kebab-case, e.g., "data-analyzer")
    - `description` - What this skill does (used for matching)
    - `instructions` - Detailed prompt for executing the skill
    - `tools` - List of tool names the skill needs (default: [])

  ## Returns
    - `{:existing_matches, [%{name: String.t(), relevance: float(), description: String.t()}]}`
      - Found similar skills with relevance > 0.5
      - User should confirm whether to use existing or create new
    - `{:created, skill_name}` - No high-relevance matches, skill created
    - `{:error, reason}` - Creation failed

  ## Decision Flow
      1. Search for skills matching description
      2. Filter for relevance > 0.5
      3. If matches exist → return {:existing_matches, matches}
      4. Otherwise → create skill and return {:created, name}

  ## Examples
      {:existing_matches, [skill]} = Orchestrator.suggest_or_create_skill(
        "csv-parser",
        "Parse CSV files",
        "Load and parse CSV...",
        ["file_read"]
      )

      {:created, "deploy-bot"} = Orchestrator.suggest_or_create_skill(
        "deploy-bot",
        "Deploy application to production",
        "Build container, push to registry, update k8s...",
        ["shell_execute", "git"]
      )

  ## Relevance Threshold
    - `> 0.7` - Strong match, almost certainly what you need
    - `0.5 - 0.7` - Moderate match, may be worth considering
    - `< 0.5` - Weak match, ignored (skill will be created)

  ## Use Cases
    - Interactive CLI: "Should I use existing skill X or create new?"
    - Auto-pilot: Automatically deduplicate skills
    - API responses: Return options for user to choose

  ## Notes
    - This is the recommended way to create skills in production
    - Combines `find_matching_skills/1` + `create_skill/4` in one call
    - Prevents skill sprawl (too many similar skills)
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
    force_simple = Keyword.get(opts, :force_simple, false)
    max_iterations_override = Keyword.get(opts, :max_iterations)
    # Tools may be pre-cached by the caller to avoid GenServer deadlock
    cached_tools = Keyword.get(opts, :cached_tools, [])

    Bus.emit(:system_event, %{
      event: :orchestrator_task_started,
      task_id: task_id,
      session_id: session_id,
      message_preview: String.slice(message, 0, 200)
    })

    # PACT strategy: delegate to Negotiation.execute_pact/2 and return immediately.
    # PACT runs its own Planning→Action→Coordination→Testing loop and emits its own
    # progress events on the Bus. We record the final output as a completed TaskState
    # so callers that poll progress/1 or wait on :orchestrator_task_completed get a result.
    if strategy == "pact" do
      pact_opts = Keyword.take(opts, [:quality_threshold, :timeout_ms, :max_action_agents, :rollback_on_failure])

      task_state = %TaskState{
        id: task_id,
        message: message,
        session_id: session_id,
        strategy: strategy,
        status: :running,
        started_at: DateTime.utc_now(),
        cached_tools: cached_tools
      }

      state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

      # Run PACT in a detached Task so the GenServer stays responsive.
      orchestrator_pid = self()
      Task.start(fn ->
        {synthesis, status} =
          case Negotiation.execute_pact(message, pact_opts) do
            {:ok, %{final_output: out}} when is_binary(out) -> {out, :completed}
            {:ok, _result} -> {"PACT workflow completed.", :completed}
            {:error, %{phases: phases}} ->
              summary = "PACT workflow failed. Phases: #{Enum.map_join(phases, ", ", & "#{&1.phase}:#{&1.status}")}"
              {summary, :failed}
          end

        GenServer.cast(orchestrator_pid, {:pact_complete, task_id, session_id, synthesis, status})
      end)

      {:reply, {:ok, task_id}, state}

    # force_simple: single agent, no decomposition, optional iteration override.
    # Used by WorkDirector to avoid shattering sequential workflows across sub-agents.
    else if force_simple do
      tier = Keyword.get(opts, :tier, :elite)

      sub_tasks = [
        %SubTask{
          name: "execute",
          description: message,
          role: :lead,
          tools_needed: ["file_read", "file_write", "file_edit", "shell_execute", "git", "code_symbols"],
          depends_on: []
        }
      ]

      task_state = %TaskState{
        id: task_id,
        message: message,
        session_id: session_id,
        strategy: "force_simple",
        status: :running,
        sub_tasks: sub_tasks,
        started_at: DateTime.utc_now(),
        cached_tools: cached_tools,
        max_iterations_override: max_iterations_override
      }

      machine = StateMachine.new(task_id)
      {:ok, machine} = StateMachine.transition(machine, :start_planning)
      plan = %{sub_tasks: sub_tasks, complexity_score: 3, estimated_tokens: 0}
      {:ok, machine} = StateMachine.set_plan(machine, plan)
      {:ok, machine} = StateMachine.transition(machine, :approve_plan)

      state = %{state | tasks: Map.put(state.tasks, task_id, task_state), machines: Map.put(state.machines, task_id, machine)}

      Logger.info("[Orchestrator] Force-simple execution: task=#{task_id}, tier=#{tier}, max_iter=#{max_iterations_override || "default"}")

      {:reply, {:ok, task_id}, state,
       {:continue, {:start_execution, task_id}}}

    else

    # For complex tasks (score >= 7), ask clarifying questions before decomposition
    message_with_context =
      case Complexity.quick_score(message) do
        score when score >= 7 ->
          survey_id = "orchestrator-#{task_id}"
          questions = Decomposer.generate_questions(message)

          case Loop.ask_user_question(session_id, survey_id, questions,
                 skippable: true,
                 timeout: 60_000
               ) do
            {:ok, answers} ->
              context =
                answers
                |> Enum.map(fn a ->
                  selected = Map.get(a, "selected", []) |> Enum.join(", ")
                  free = Map.get(a, "free_text", "")
                  text = if free != "", do: free, else: selected
                  "#{Map.get(a, "question_text", "")}: #{text}"
                end)
                |> Enum.join("\n")

              message <> "\n\n## User Preferences\n" <> context

            {:skipped} ->
              message

            {:error, _} ->
              message
          end

        _ ->
          message
      end

    # Detect user intent for agent count override
    user_override = ComplexityScaler.detect_agent_count_intent(message_with_context)
    decompose_opts = if user_override, do: [max_agents: user_override], else: []

    # Decompose is sync (needs LLM), but execution is async via handle_continue
    case Decomposer.decompose_task(message_with_context, decompose_opts) do
      {:ok, sub_tasks, %{estimated_tokens: estimated_tokens, complexity_score: complexity_score}} when is_list(sub_tasks) and length(sub_tasks) > 0 ->
        tier = Keyword.get(opts, :tier, :specialist)
        optimal = ComplexityScaler.optimal_agent_count(complexity_score, tier, user_override)
        sub_tasks = Enum.take(sub_tasks, optimal)

        Bus.emit(:system_event, %{
          event: :orchestrator_task_decomposed,
          task_id: task_id,
          session_id: session_id,
          sub_task_count: length(sub_tasks),
          estimated_tokens: estimated_tokens,
          complexity_score: complexity_score,
          optimal_agent_count: optimal
        })

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

        # Enqueue sub-tasks into Tasks queue (best-effort)
        try do
          Enum.each(sub_tasks, fn st ->
            subtask_id = "#{task_id}_#{st.name}"

            Tasks.enqueue(subtask_id, session_id, %{
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

        # Initialize state machine and transition: idle → planning → executing
        machine = StateMachine.new(task_id)
        {:ok, machine} = StateMachine.transition(machine, :start_planning)
        plan = %{sub_tasks: sub_tasks, complexity_score: complexity_score, estimated_tokens: estimated_tokens}
        {:ok, machine} = StateMachine.set_plan(machine, plan)
        {:ok, machine} = StateMachine.transition(machine, :approve_plan)

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state), machines: Map.put(state.machines, task_id, machine)}

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

      {:ok, [], _meta} ->
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

        # Initialize machine and record error: idle → planning → error_recovery
        machine = StateMachine.new(task_id)
        state = case StateMachine.transition(machine, :start_planning) do
          {:ok, m} -> %{state | machines: Map.put(state.machines, task_id, m)}
          _ -> state
        end

        Bus.emit(:system_event, %{
          event: :orchestrator_task_failed,
          task_id: task_id,
          session_id: session_id,
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
    end  # end force_simple else
    end  # end pact if
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
          error: task_state.error,
          machine_phase: case Map.get(state.machines, task_id) do
            nil -> nil
            machine -> StateMachine.current_phase(machine)
          end
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

            description =
              case Enum.find(task_state.sub_tasks, fn st -> st.name == agent.name end) do
                %{description: d} when is_binary(d) -> d
                _ -> ""
              end

            Bus.emit(:system_event, %{
              event: :orchestrator_agent_progress,
              task_id: task_id,
              session_id: task_state.session_id,
              agent_id: agent_id,
              agent_name: agent.name,
              role: agent.role,
              tool_uses: updated_agent.tool_uses,
              tokens_used: updated_agent.tokens_used,
              current_action: updated_agent.current_action,
              description: description
            })

            {:noreply, state}
        end
    end
  end

  # Receives the final result from a PACT Task and marks the task completed.
  @impl true
  def handle_cast({:pact_complete, task_id, session_id, synthesis, status}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        task_state = %{task_state | status: status, synthesis: synthesis, completed_at: DateTime.utc_now()}
        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        event = if status == :completed, do: :orchestrator_task_completed, else: :orchestrator_task_failed

        Bus.emit(:system_event, %{
          event: event,
          task_id: task_id,
          session_id: session_id,
          agent_count: 0,
          result_preview: String.slice(synthesis || "", 0, 200)
        })

        Logger.info("[Orchestrator] PACT task #{task_id} #{status}")
        {:noreply, state}
    end
  end

  # ── Handle Continue — Non-blocking wave execution ──────────────────

  @impl true
  def handle_continue({:start_execution, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        # Checkpoint in a separate task to avoid blocking the GenServer.
        # git operations can be slow (seconds) — running them inline would
        # stall all other orchestrator calls for that duration.
        Task.start(fn -> GitVersioning.checkpoint(task_id) end)

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
        # All waves done — transition machine: executing → verifying
        state = transition_machine(state, task_id, :waves_complete)
        {:noreply, state, {:continue, {:synthesize, task_id}}}

      %{pending_waves: [wave | rest]} = task_state ->
        wave_number = task_state.current_wave + 1
        total_waves = wave_number + length(rest)

        Bus.emit(:system_event, %{
          event: :orchestrator_wave_started,
          task_id: task_id,
          session_id: task_state.session_id,
          wave_number: wave_number,
          total_waves: total_waves,
          agent_count: length(wave)
        })

        session_id = task_state.session_id
        cached_tools = task_state.cached_tools
        batch_id = "wave-#{wave_number}"

        # Get permission tier from state machine to enforce tool access constraints
        permission_tier = case Map.get(state.machines, task_id) do
          nil -> :full
          machine ->
            try do
              StateMachine.permission_tier(machine)
            rescue
              _ -> :full
            end
        end

        # Resolve skills triggered by the parent session's original message.
        # These are propagated to ALL sub-agents regardless of their task description,
        # so skills that were relevant to the overall goal remain available.
        parent_triggered_skills =
          case task_state do
            %{message: msg} when is_binary(msg) and msg != "" ->
              matched = Tools.match_skill_triggers(msg)
              Enum.map(matched, fn {name, _} -> name end)
            _ -> []
          end

        # Spawn all agents in this wave, collecting refs and agent states
        spawn_results =
          Enum.map(wave, fn sub_task ->
            dep_context = Decomposer.build_dependency_context(sub_task.depends_on, task_state.results)
            sub_task_with_context = %{sub_task | context: dep_context, inherited_skills: parent_triggered_skills}

            spawn_opts = [
              batch_id: batch_id,
              permission_tier: permission_tier,
              max_iterations_override: task_state.max_iterations_override
            ]

            {agent_id, agent_state, task_ref} =
              AgentRunner.spawn_agent(sub_task_with_context, task_id, session_id, cached_tools, spawn_opts)

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
            current_wave: wave_number,
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
        synthesis = WaveExecutor.synthesize_results(task_id, task_state.results, task_state.message, task_state.session_id)

        # Commit outcome in a detached Task — git can be slow and must not block the GenServer.
        if is_binary(synthesis) and synthesis != "" do
          summary = String.slice(synthesis, 0, 72)
          Task.start(fn -> GitVersioning.commit_outcome(task_id, summary) end)
        end

        # Transition machine: verifying → completed
        state = update_machine(state, task_id, fn machine ->
          verification = %{synthesis: true, completed_at: DateTime.utc_now()}
          machine = case StateMachine.set_verification(machine, verification) do
            {:ok, m} -> m
            {:error, _} -> machine
          end
          case StateMachine.transition(machine, :verification_passed) do
            {:ok, m} -> m
            {:error, _} -> machine
          end
        end)

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

    case WaveExecutor.find_task_by_ref(ref, state.tasks) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text =
          case result do
            {:ok, text} -> text
            {:error, reason} -> "FAILED: #{reason}"
            text when is_binary(text) -> text
            other ->
              Logger.warning("[Orchestrator] Unexpected task result: #{inspect(other)}")
              "FAILED: unexpected result format"
          end

        state = WaveExecutor.record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, result)

        # Track result in state machine (best-effort, ignore phase mismatch)
        state = update_machine(state, task_id, fn machine ->
          case StateMachine.add_wave_result(machine, %{agent: agent_name, result: result_text}) do
            {:ok, m} -> m
            {:error, _} -> machine
          end
        end)

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
    case WaveExecutor.find_task_by_ref(ref, state.tasks) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text = "FAILED: Agent crashed: #{inspect(reason)}"
        state = WaveExecutor.record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, {:error, result_text})

        # Record failure in state machine
        state = update_machine(state, task_id, fn machine ->
          case StateMachine.add_wave_result(machine, %{agent: agent_name, result: result_text, crashed: true}) do
            {:ok, m} -> m
            {:error, _} -> machine
          end
        end)

        task_state = Map.get(state.tasks, task_id)

        if map_size(task_state.wave_refs) == 0 do
          {:noreply, state, {:continue, {:execute_wave, task_id}}}
        else
          {:noreply, state}
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
    do: Daemon.Utils.ID.generate(prefix)

  # ── State Machine Helpers ──────────────────────────────────────────

  # Apply a transition event to a task's state machine (best-effort, no crash on invalid)
  defp transition_machine(state, task_id, event) do
    update_machine(state, task_id, fn machine ->
      case StateMachine.transition(machine, event) do
        {:ok, m} -> m
        {:error, _} -> machine
      end
    end)
  end

  # Update a task's state machine via a transformation function
  defp update_machine(state, task_id, fun) when is_function(fun, 1) do
    case Map.get(state.machines, task_id) do
      nil -> state
      machine -> %{state | machines: Map.put(state.machines, task_id, fun.(machine))}
    end
  end
end
