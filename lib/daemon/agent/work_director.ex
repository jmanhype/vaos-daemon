defmodule Daemon.Agent.WorkDirector do
  @moduledoc """
  Autonomous work loop that continuously picks tasks, dispatches them via
  Orchestrator PACT, ships draft PRs, and learns from merge/reject signals.

  Unifies five work sources under Thompson Sampling:
  - VISION.md strategic goals
  - GitHub Issues
  - Investigation findings
  - Fitness function violations
  - Manual submissions

  Coexists with InsightActuator (insight/ branches) and ConvergenceEngine
  (convergence/ branches). WorkDirector uses workdir/ branches.
  """
  use GenServer
  require Logger

  alias Daemon.Agent.WorkDirector.Backlog
  alias Daemon.Agent.WorkDirector.Backlog.WorkItem
  alias Daemon.Agent.WorkDirector.DispatchIntelligence
  alias Daemon.Agent.WorkDirector.GroundedVerifier
  alias Daemon.Agent.WorkDirector.Source
  alias Daemon.Agent.Orchestrator
  alias Daemon.Intelligence.DecisionJournal

  # -- Pipeline upgrade aliases --
  alias Daemon.Vault
  alias Daemon.Agent.AutoFixer
  alias Daemon.Agent.Roster
  alias Daemon.Agent.Orchestrator.SwarmMode
  alias Daemon.Agent.Debate
  alias Daemon.Agent.SkillEvolution
  alias Daemon.Agent.Appraiser
  alias Daemon.Agent.CodeIntrospector
  alias Daemon.Agent.ActiveLearner

  @backlog_refresh_ms :timer.minutes(10)
  @pr_poll_ms :timer.hours(1)
  @initial_delay_ms :timer.seconds(60)
  @max_dispatches_per_day 999
  @max_completed_prs 50
  @circuit_breaker_threshold 5
  @circuit_breaker_ms :timer.minutes(30)
  @daemon_repo "jmanhype/vaos-daemon"

  # -- Feature Flags (pipeline upgrades) --
  # Enable one at a time. Each is independently safe to enable.
  @enable_vault_context true         # Stage 0.5: inject prior dispatch memories from Vault
  @enable_knowledge_context false    # Stage 0.5: query knowledge store for codebase patterns
  @enable_investigation_pre false    # Stage 0.5: run Investigate.execute before dispatch (high cost)
  @enable_appraiser false            # Stage 0.5: estimate complexity/cost via Appraiser
  @enable_specialist_routing false   # Stage 1: Roster agent selection vs force_simple
  @enable_swarm_dispatch false       # Stage 1: SwarmMode patterns for complex tasks
  @enable_substance_check true       # Stage 1.9: reject stubs (hard gate)
  @enable_autofixer false            # Stage 2: AutoFixer instead of simple 2-attempt loop
  @enable_test_gate true             # Stage 2.75: mix test --max-failures 5 (soft gate)
  @enable_code_review false          # Stage 2.9: debate/review pattern before shipping
  @enable_vault_remember true        # Stage 3.5: store dispatch outcome in Vault
  @enable_knowledge_remember false   # Stage 3.5: store patterns in knowledge graph
  @enable_skill_evolution false      # Stage 3.5: feed failures to SkillEvolution
  @enable_introspector_feed false    # Stage 0.5: pull CodeIntrospector/ActiveLearner insights

  @protected_path_patterns [
    "^lib/daemon/application\\.ex$",
    "^lib/daemon/supervisors/",
    "^lib/daemon/security/",
    "^lib/daemon/agent/loop\\.ex$",
    "^config/runtime\\.exs$",
    "^mix\\.exs$",
    "^mix\\.lock$"
  ]

  @source_modules [
    Source.Vision,
    Source.Issues,
    Source.Fitness
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current stats: backlog size, dispatch counts, arm means, circuit breaker status."
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{status: :not_running}
    catch
      :exit, _ -> %{status: :not_running}
    end
  end

  @doc "Enable the work loop."
  def enable do
    try do
      GenServer.cast(__MODULE__, :enable)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Disable the work loop."
  def disable do
    try do
      GenServer.cast(__MODULE__, :disable)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Submit a manual work item."
  def submit(title, description, priority \\ 0.5) do
    try do
      GenServer.cast(__MODULE__, {:submit, title, description, priority})
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Force immediate backlog refresh and dispatch attempt."
  def force_cycle do
    try do
      GenServer.cast(__MODULE__, :force_cycle)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "List all backlog items (debugging)."
  def backlog do
    try do
      GenServer.call(__MODULE__, :backlog)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      enabled: enabled,
      backlog: %{},
      arms: default_arms(),
      current_dispatch: nil,
      completed_prs: [],
      dispatches_today: 0,
      last_day_reset: Date.utc_today(),
      consecutive_failures: 0,
      circuit_breaker_until: nil,
      total_dispatches: 0,
      total_merged: 0,
      total_rejected: 0,
      investigation_buffer: nil,
      manual_buffer: nil,
      investigation_ref: nil,
      blocked_regexes: Enum.map(@protected_path_patterns, &Regex.compile!/1)
    }

    # Load persisted arms (survive restarts)
    state = load_persisted_arms(state)

    if enabled do
      Logger.info("[WorkDirector] Started (enabled=true, arms=#{inspect(Map.keys(state.arms))})")
      Process.send_after(self(), :bootstrap, @initial_delay_ms)
    else
      Logger.info("[WorkDirector] Started (enabled=false)")
    end

    {:ok, state}
  end

  defp default_arms do
    %{
      vision: %{alpha: 1.0, beta: 1.0},
      issues: %{alpha: 1.0, beta: 1.0},
      investigation: %{alpha: 1.0, beta: 1.0},
      fitness: %{alpha: 1.0, beta: 1.0},
      manual: %{alpha: 2.0, beta: 1.0}
    }
  end

  @impl true
  def handle_info(:bootstrap, state) do
    Logger.info("[WorkDirector] Bootstrap starting...")

    # Start buffers for event-driven sources
    {:ok, inv_buffer} = Source.Investigation.start_buffer()
    {:ok, manual_buffer} = Source.Manual.start_buffer()
    Logger.debug("[WorkDirector] Buffers started")

    # Subscribe to investigation_complete events (async — don't block bootstrap)
    investigation_ref =
      try do
        handler = fn event ->
          data = Map.get(event, :data, Map.get(event, "data", %{}))
          Source.Investigation.push(inv_buffer, data)
        end

        # Use a timeout to avoid blocking if Bus is busy
        task = Task.async(fn -> Daemon.Events.Bus.register_handler(:investigation_complete, handler) end)
        case Task.yield(task, 5_000) || Task.shutdown(task) do
          {:ok, ref} -> ref
          _ ->
            Logger.warning("[WorkDirector] Bus subscription timed out — skipping")
            nil
        end
      rescue
        e ->
          Logger.warning("[WorkDirector] Failed to subscribe to events: #{Exception.message(e)}")
          nil
      catch
        :exit, reason ->
          Logger.warning("[WorkDirector] Failed to subscribe to events: #{inspect(reason)}")
          nil
      end

    Logger.debug("[WorkDirector] Event subscription done (ref=#{inspect(investigation_ref)})")

    # Load persisted backlog
    persisted =
      try do
        Backlog.load()
      rescue
        e ->
          Logger.warning("[WorkDirector] Failed to load backlog: #{Exception.message(e)}")
          %{}
      end

    Logger.debug("[WorkDirector] Backlog loaded (#{map_size(persisted)} items)")

    state = %{state |
      investigation_buffer: inv_buffer,
      manual_buffer: manual_buffer,
      investigation_ref: investigation_ref,
      backlog: persisted
    }

    # Initial backlog refresh
    state =
      try do
        refresh_backlog(state)
      rescue
        e ->
          Logger.error("[WorkDirector] Backlog refresh failed: #{Exception.message(e)}")
          state
      catch
        :exit, reason ->
          Logger.error("[WorkDirector] Backlog refresh exit: #{inspect(reason)}")
          state
      end

    # Schedule recurring timers
    schedule_refresh()
    schedule_pr_poll()

    # Start the dispatch loop
    send(self(), :try_dispatch)

    Logger.info("[WorkDirector] Bootstrap complete (backlog=#{map_size(state.backlog)} items)")
    {:noreply, state}
  end

  def handle_info(:try_dispatch, state) do
    state = maybe_reset_daily_counter(state)

    cond do
      not state.enabled ->
        {:noreply, state}

      state.current_dispatch != nil ->
        {:noreply, state}

      circuit_breaker_active?(state) ->
        Logger.debug("[WorkDirector] Circuit breaker active until #{state.circuit_breaker_until}")
        {:noreply, state}

      state.dispatches_today >= @max_dispatches_per_day ->
        Logger.debug("[WorkDirector] Daily dispatch cap reached (#{state.dispatches_today}/#{@max_dispatches_per_day})")
        {:noreply, state}

      not budget_ok?() ->
        Logger.warning("[WorkDirector] Budget exceeded, pausing dispatches")
        {:noreply, state}

      true ->
        state = try_dispatch_loop(state, MapSet.new(), 5)
        {:noreply, state}
    end
  end

  # Try to dispatch, skipping conflicted items up to max_attempts
  defp try_dispatch_loop(state, _skip_set, 0), do: state

  defp try_dispatch_loop(state, skip_set, attempts_left) do
    eligible_backlog =
      Map.reject(state.backlog, fn {hash, _} -> MapSet.member?(skip_set, hash) end)

    case Backlog.pick_next(eligible_backlog, state.arms) do
      :empty ->
        state

      {:ok, item} ->
        case dispatch_item(state, item) do
          {:conflict, updated_state} ->
            # Item conflicted — skip it and try next
            try_dispatch_loop(updated_state, MapSet.put(skip_set, item.content_hash), attempts_left - 1)

          updated_state ->
            updated_state
        end
    end
  end

  def handle_info({:dispatch_complete, ref, result}, %{current_dispatch: %{ref: dispatch_ref}} = state)
      when ref == dispatch_ref do
    dispatch = state.current_dispatch
    state = %{state | current_dispatch: nil}

    state =
      case result do
        {:ok, _output, branch} ->
          case verify_safety(branch) do
            :safe ->
              Logger.info("[WorkDirector] Dispatch completed: #{dispatch.title} (branch=#{branch})")
              DecisionJournal.record_outcome(branch, :success, %{title: dispatch.title})

              state
              |> update_backlog_completed(dispatch.content_hash, {:ok, branch})
              |> reward_arm(dispatch.source, 0.3)
              |> add_completed_pr(branch, dispatch.source, dispatch.content_hash)
              |> Map.put(:consecutive_failures, 0)
              |> Map.update!(:total_dispatches, &(&1 + 1))

            :unsafe ->
              Logger.warning("[WorkDirector] Safety violation in #{branch}, deleting branch")
              delete_branch(branch)
              DecisionJournal.record_outcome(branch, :failure, %{reason: :safety_violation})

              state
              |> update_backlog_completed(dispatch.content_hash, {:safety_violation, branch})
              |> reward_arm(dispatch.source, 0.0)
              |> Map.put(:consecutive_failures, 0)
          end

        {:error, reason} ->
          failure_class = classify_failure(reason)
          Logger.warning("[WorkDirector] Dispatch failed: #{failure_class} — #{inspect(reason)}")
          DecisionJournal.record_outcome(dispatch.branch, :failure, %{
            reason: inspect(reason),
            failure_class: failure_class
          })

          # Reward based on failure class — partial signals
          reward = failure_class_reward(failure_class)
          failures = state.consecutive_failures + 1

          state
          |> update_backlog_failed(dispatch.content_hash)
          |> reward_arm(dispatch.source, reward)
          |> Map.put(:consecutive_failures, failures)
          |> maybe_trip_circuit_breaker(failures)
      end

    # Stage 3.5: Post-dispatch — remember outcome, store knowledge, evolve skills
    post_dispatch_learn(dispatch, result)

    # Persist and continue the loop
    Backlog.persist(state.backlog)
    send(self(), :try_dispatch)

    {:noreply, state}
  end

  # Handle DOWN from spawned dispatch process
  def handle_info({:DOWN, _monitor_ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, reason}, state) when state.current_dispatch != nil do
    Logger.error("[WorkDirector] Dispatch process crashed: #{inspect(reason)}")
    dispatch = state.current_dispatch
    failures = state.consecutive_failures + 1

    state =
      state
      |> Map.put(:current_dispatch, nil)
      |> update_backlog_failed(dispatch.content_hash)
      |> Map.put(:consecutive_failures, failures)
      |> maybe_trip_circuit_breaker(failures)

    Backlog.persist(state.backlog)
    send(self(), :try_dispatch)

    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Handle PR outcome from Decision Journal (unified polling)
  def handle_info({:journal_pr_outcome, branch, reward}, state) do
    match = Enum.find(state.completed_prs, fn cp -> cp.branch == branch end)

    if match do
      Logger.info("[WorkDirector] Journal PR outcome for #{branch}: reward=#{reward}")
      state = reward_arm(state, match.source, reward)
      state = remove_completed_pr(state, branch)

      state = if reward >= 0.5 do
        Map.update!(state, :total_merged, &(&1 + 1))
      else
        Map.update!(state, :total_rejected, &(&1 + 1))
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:refresh_backlog, state) do
    state = refresh_backlog(state)
    schedule_refresh()

    # If idle, try a dispatch
    if state.current_dispatch == nil do
      send(self(), :try_dispatch)
    end

    {:noreply, state}
  end

  def handle_info(:poll_pr_outcomes, state) do
    state = poll_pr_outcomes(state)
    schedule_pr_poll()
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      status: if(state.enabled, do: :running, else: :disabled),
      backlog_size: map_size(state.backlog),
      pending_count: state.backlog |> Map.values() |> Enum.count(&(&1.status == :pending)),
      dispatches_today: state.dispatches_today,
      current_dispatch: if(state.current_dispatch, do: state.current_dispatch.title, else: nil),
      arms: Enum.map(state.arms, fn {source, %{alpha: a, beta: b}} ->
        {source, %{alpha: a, beta: b, mean: Float.round(a / (a + b), 3)}}
      end) |> Map.new(),
      circuit_breaker: circuit_breaker_active?(state),
      consecutive_failures: state.consecutive_failures,
      total_dispatches: state.total_dispatches,
      total_merged: state.total_merged,
      total_rejected: state.total_rejected,
      completed_prs: length(state.completed_prs)
    }

    {:reply, stats, state}
  end

  def handle_call(:backlog, _from, state) do
    items =
      state.backlog
      |> Map.values()
      |> Enum.sort_by(& &1.base_priority, :desc)
      |> Enum.map(fn item ->
        %{
          title: item.title,
          source: item.source,
          status: item.status,
          priority: item.base_priority,
          attempts: item.attempt_count,
          branch: item.pr_branch
        }
      end)

    {:reply, items, state}
  end

  @impl true
  def handle_cast(:enable, state) do
    Logger.info("[WorkDirector] Enabled")
    state = %{state | enabled: true}

    if state.investigation_buffer == nil do
      Process.send_after(self(), :bootstrap, 1_000)
    else
      send(self(), :try_dispatch)
    end

    {:noreply, state}
  end

  def handle_cast(:disable, state) do
    Logger.info("[WorkDirector] Disabled")
    {:noreply, %{state | enabled: false}}
  end

  def handle_cast({:submit, title, description, priority}, state) do
    if state.manual_buffer do
      Source.Manual.submit(state.manual_buffer, title, description, priority)
      Logger.info("[WorkDirector] Manual task submitted: #{title}")
    end

    {:noreply, state}
  end

  def handle_cast(:force_cycle, state) do
    Logger.info("[WorkDirector] Force cycle triggered")
    state = refresh_backlog(state)
    send(self(), :try_dispatch)
    {:noreply, state}
  end

  # -- Internal --

  defp refresh_backlog(state) do
    Logger.debug("[WorkDirector] Refreshing backlog from #{length(@source_modules)} static sources...")

    # Fetch each source independently with timeout
    static_items =
      Enum.flat_map(@source_modules, fn mod ->
        source_name = mod |> Module.split() |> List.last()
        Logger.debug("[WorkDirector] Fetching from #{source_name}...")

        try do
          task = Task.async(fn -> mod.fetch() end)
          case Task.yield(task, 15_000) || Task.shutdown(task) do
            {:ok, {:ok, items}} ->
              Logger.debug("[WorkDirector] #{source_name}: #{length(items)} items")
              items

            {:ok, {:error, reason}} ->
              Logger.warning("[WorkDirector] #{source_name} error: #{inspect(reason)}")
              []

            nil ->
              Logger.warning("[WorkDirector] #{source_name} timed out (15s)")
              []
          end
        rescue
          e ->
            Logger.warning("[WorkDirector] #{source_name} crashed: #{Exception.message(e)}")
            []
        catch
          :exit, reason ->
            Logger.warning("[WorkDirector] #{source_name} exit: #{inspect(reason)}")
            []
        end
      end)

    Logger.debug("[WorkDirector] Static sources returned #{length(static_items)} items")

    # Fetch from buffer-based sources
    inv_items =
      if state.investigation_buffer do
        case Source.Investigation.fetch(state.investigation_buffer) do
          {:ok, items} -> items
          _ -> []
        end
      else
        []
      end

    manual_items =
      if state.manual_buffer do
        case Source.Manual.fetch(state.manual_buffer) do
          {:ok, items} -> items
          _ -> []
        end
      else
        []
      end

    all_items = static_items ++ inv_items ++ manual_items
    backlog = Backlog.merge(state.backlog, all_items) |> Backlog.prune_stale()

    pending = backlog |> Map.values() |> Enum.count(&(&1.status == :pending))
    Logger.info("[WorkDirector] Backlog refreshed: #{map_size(backlog)} items (#{pending} pending, #{length(all_items)} fetched)")

    %{state | backlog: backlog}
  end

  defp dispatch_item(state, %WorkItem{} = item) do
    branch = branch_name(item)

    # Check with Decision Journal for conflicts
    case DecisionJournal.propose(:work_director, :create_pr, %{
      topic: item.title,
      branch: branch,
      source: item.source,
      priority: item.base_priority
    }) do
      {:conflict, reason} ->
        Logger.info("[WorkDirector] Journal conflict for '#{item.title}': #{reason}")
        {:conflict, state}

      :approved ->
        do_dispatch_item(state, item, branch)
    end
  end

  @orchestrator_poll_interval_ms 10_000
  @orchestrator_timeout_ms :timer.minutes(15)
  @compile_fix_max_attempts 2
  @agent_max_iterations 35

  defp do_dispatch_item(state, %WorkItem{} = item, branch) do
    session_id = "workdir-#{:erlang.unique_integer([:positive])}"

    Logger.info("[WorkDirector] Dispatching: #{item.title} (source=#{item.source}, priority=#{item.base_priority})")

    parent = self()
    ref = make_ref()
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    {_pid, _monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            staged_dispatch(item, branch, session_id, repo_path)
          rescue
            e -> {:error, {:exception, Exception.message(e)}}
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        send(parent, {:dispatch_complete, ref, result})
      end)

    backlog = Backlog.mark_dispatched(state.backlog, item.content_hash, branch)

    try do
      Daemon.Events.Bus.emit(:work_dispatched, %{
        title: item.title,
        source: item.source,
        branch: branch,
        priority: item.base_priority
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    %{state |
      backlog: backlog,
      current_dispatch: %{
        ref: ref,
        content_hash: item.content_hash,
        source: item.source,
        title: item.title,
        branch: branch,
        started_at: DateTime.utc_now()
      },
      dispatches_today: state.dispatches_today + 1
    }
  end

  # -- Staged Execution Pipeline --
  # Stage 0:    Create branch (zero LLM cost)
  # Stage 0.5:  Pre-research context enrichment (vault, knowledge, investigation, appraiser)
  # Stage 1:    Implementation via Orchestrator (specialist routing / swarm / simple)
  # Stage 1.5:  Recover branch if agent drifted
  # Stage 1.9:  Substance check — reject stubs (hard gate)
  # Stage 2:    Verify compilation (AutoFixer or simple 2-attempt)
  # Stage 2.5:  Grounded verification — check phantom references
  # Stage 2.75: Test gate (soft)
  # Stage 2.9:  Code review (debate/review pattern)
  # Stage 3:    Git add/commit/push/PR (zero LLM cost)
  # Stage 3.5:  Post-dispatch — vault remember, knowledge store, skill evolution

  defp staged_dispatch(item, branch, session_id, repo_path) do
    # Stage 0: Create the branch ourselves
    Logger.info("[WorkDirector] Stage 0: Creating branch #{branch}")
    case create_branch(branch, repo_path) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[WorkDirector] Stage 0 failed: #{inspect(reason)}")
        throw({:stage0_failed, reason})
    end

    # Stage 0.5: Pre-research context enrichment
    pre_research_context = build_pre_research_context(item, repo_path, session_id)

    # Stage 1: Implementation — agent only writes code, no git operations
    Logger.info("[WorkDirector] Stage 1: Dispatching implementation to Orchestrator")
    prompt = build_implementation_prompt(item, repo_path, pre_research_context)

    case execute_and_poll(prompt, session_id, item) do
      {:completed, synthesis} ->
        Logger.info("[WorkDirector] Stage 1 complete: agent finished implementation")

        # Stage 1.5: Recover branch if agent switched away
        recover_branch(branch, repo_path)

        # Stage 1.9: Substance check — reject stubs
        maybe_check_substance(branch, repo_path)

        # Stage 2: Verify compilation (with retry loop)
        case verify_and_fix_compilation(item, branch, session_id, repo_path, 0) do
          :ok ->
            Logger.info("[WorkDirector] Stage 2 complete: compilation verified")
            # Recover branch if compile-fix agent switched away
            recover_branch(branch, repo_path)

            # Stage 2.5: Grounded verification — check phantom references
            case verify_and_fix_references(branch, session_id, repo_path, 0) do
              :ok ->
                Logger.info("[WorkDirector] Stage 2.5 complete: references verified")
              {:warnings, warnings} ->
                Logger.info("[WorkDirector] Stage 2.5 passed with warnings: #{Enum.join(warnings, "; ")}")
              {:error, _reason} ->
                Logger.warning("[WorkDirector] Stage 2.5 failed: phantom references unfixable")
                cleanup_branch(branch, repo_path)
                throw({:stage2_5_failed, :phantom_references})
            end

            # Stage 2.75: Test gate (soft — warn only)
            maybe_run_test_gate(branch, repo_path)

            # Stage 2.9: Code review (debate/review)
            maybe_run_code_review(item, branch, session_id, repo_path)

            # Recover branch before finalize — agents may have switched during stages 2.5-2.9
            recover_branch(branch, repo_path)

            # Stage 3: Commit, push, PR
            case finalize_branch(item, branch, repo_path) do
              {:ok, _pr_info} ->
                Logger.info("[WorkDirector] Stage 3 complete: branch #{branch} committed and pushed")
                # Switch back to main for next dispatch
                System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
                {:ok, synthesis, branch}

              {:error, :no_changes} ->
                Logger.warning("[WorkDirector] Stage 3 failed: no file changes detected")
                cleanup_branch(branch, repo_path)
                {:error, {:empty_branch, synthesis}}

              {:error, reason} ->
                Logger.warning("[WorkDirector] Stage 3 failed: #{inspect(reason)}")
                cleanup_branch(branch, repo_path)
                {:error, {:commit_failed, reason}}
            end

          {:error, reason} ->
            Logger.warning("[WorkDirector] Stage 2 failed: compilation cannot be fixed")
            cleanup_branch(branch, repo_path)
            {:error, {:compilation_unfixable, reason}}
        end

      {:failed, error} ->
        Logger.warning("[WorkDirector] Stage 1 failed: #{inspect(error)}")
        cleanup_branch(branch, repo_path)
        {:error, {:orchestrator_failed, error}}

      {:timeout, last_status} ->
        Logger.warning("[WorkDirector] Stage 1 timed out")
        cleanup_branch(branch, repo_path)
        {:error, {:timeout, last_status}}
    end
  catch
    {:stage0_failed, reason} -> {:error, {:no_branch, reason}}
    {:stage1_9_failed, reason} -> {:error, {:stub_detected, reason}}
    {:stage2_5_failed, reason} -> {:error, {:phantom_references, reason}}
  end

  # -- Stage 0.5: Pre-Research Context Enrichment --

  defp build_pre_research_context(item, _repo_path, session_id) do
    sections = []

    # Vault: prior dispatch memories
    sections = sections ++ vault_context_section(item)

    # Knowledge Store: codebase patterns
    sections = sections ++ knowledge_context_section(item)

    # Appraiser: complexity estimate
    sections = sections ++ appraiser_section(item)

    # Specialist hints: what agents match this task
    sections = sections ++ specialist_hints_section(item)

    # Autonomous loop insights: CodeIntrospector + ActiveLearner findings
    sections = sections ++ introspector_section(item)

    # Investigation: deep research (expensive, only for high-priority/complex tasks)
    sections = sections ++ investigation_section(item, session_id)

    context = Enum.join(sections, "\n")

    if context != "" do
      Logger.info("[WorkDirector] Stage 0.5: Pre-research enriched prompt (#{String.length(context)} chars)")
    end

    context
  end

  defp vault_context_section(item) do
    if @enable_vault_context do
      try do
        recalls = Vault.recall(item.title, limit: 5)

        if recalls != [] do
          formatted =
            Enum.map_join(recalls, "\n", fn {cat, path, _score} ->
              case File.read(path) do
                {:ok, content} ->
                  body = content |> String.split("\n") |> Enum.take(8) |> Enum.join("\n")
                  "- [#{cat}] #{String.slice(body, 0, 300)}"

                _ ->
                  ""
              end
            end)

          Logger.info("[WorkDirector] Stage 0.5: Injecting #{length(recalls)} vault memories")
          ["\n## Prior Context (learn from previous attempts)\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp knowledge_context_section(item) do
    if @enable_knowledge_context do
      try do
        # Query knowledge graph for patterns related to the task
        store = "osa_default"
        keywords = item.title |> String.split(~r/\s+/) |> Enum.take(5)

        triples =
          Enum.flat_map(keywords, fn kw ->
            case Vaos.Knowledge.query(store, subject: kw) do
              {:ok, results} -> Enum.take(results, 3)
              _ -> []
            end
          end)
          |> Enum.uniq()
          |> Enum.take(10)

        if triples != [] do
          formatted =
            Enum.map_join(triples, "\n", fn {s, p, o} ->
              "- #{s} —[#{p}]→ #{o}"
            end)

          Logger.info("[WorkDirector] Stage 0.5: #{length(triples)} knowledge triples")
          ["\n## Codebase Knowledge\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp appraiser_section(item) do
    if @enable_appraiser do
      try do
        # Estimate complexity based on description length and keywords
        complexity =
          cond do
            String.length(item.description || "") > 500 -> 7
            String.length(item.description || "") > 200 -> 5
            true -> 3
          end

        estimate = Appraiser.estimate(complexity, :backend)

        section = """

        ## Task Estimate
        - Complexity: #{estimate.complexity}/10
        - Estimated hours: #{estimate.estimated_hours}
        - Confidence: #{Float.round(estimate.confidence * 100, 0)}%
        - Scale: #{if estimate.estimated_hours > 8, do: "LARGE — break into smaller pieces", else: "manageable"}
        """

        Logger.info("[WorkDirector] Stage 0.5: Appraiser estimates #{estimate.estimated_hours}h, confidence #{Float.round(estimate.confidence * 100, 0)}%")
        [section]
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp specialist_hints_section(item) do
    if @enable_specialist_routing do
      try do
        scored = Roster.select_for_task_scored(item.title)
        top = Enum.take(scored, 3)

        if top != [] do
          formatted =
            Enum.map_join(top, "\n", fn {name, score} ->
              "- #{name} (score: #{Float.round(score, 2)})"
            end)

          Logger.info("[WorkDirector] Stage 0.5: Top specialists: #{inspect(Enum.map(top, &elem(&1, 0)))}")
          ["\n## Recommended Specialists\n#{formatted}\n"]
        else
          []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp introspector_section(_item) do
    if @enable_introspector_feed do
      try do
        sections = []

        # CodeIntrospector recent findings
        sections =
          try do
            %{recent_findings: findings} = CodeIntrospector.stats()

            if findings != [] do
              formatted =
                findings
                |> Enum.take(3)
                |> Enum.map_join("\n", fn f ->
                  "- [#{f.anomaly_type}] #{inspect(f.result) |> String.slice(0, 200)}"
                end)

              sections ++ ["\n## Recent System Anomalies\n#{formatted}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        # ActiveLearner bottleneck
        sections =
          try do
            %{bottleneck: bottleneck} = ActiveLearner.stats()

            if bottleneck do
              sections ++ ["\n## System Bottleneck: #{bottleneck.bottleneck}\n#{bottleneck.prescription}\n"]
            else
              sections
            end
          rescue
            _ -> sections
          catch
            :exit, _ -> sections
          end

        sections
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp investigation_section(item, session_id) do
    if @enable_investigation_pre and item.base_priority >= 0.7 do
      try do
        Logger.info("[WorkDirector] Stage 0.5: Running pre-dispatch investigation for '#{item.title}'")
        investigate_tool = Daemon.Tools.Builtins.Investigate

        case investigate_tool.execute(%{
               "topic" => "How to implement: #{item.title}",
               "depth" => "standard",
               "metadata" => %{"source_module" => "WorkDirector", "session_id" => session_id}
             }) do
          {:ok, result} ->
            # Extract key findings (truncate to avoid prompt bloat)
            summary = result |> String.split("\n") |> Enum.take(30) |> Enum.join("\n")
            Logger.info("[WorkDirector] Stage 0.5: Investigation complete (#{String.length(result)} chars)")
            ["\n## Research Findings\n#{String.slice(summary, 0, 2000)}\n"]

          {:error, reason} ->
            Logger.warning("[WorkDirector] Stage 0.5: Investigation failed: #{reason}")
            []
        end
      rescue
        e ->
          Logger.warning("[WorkDirector] Stage 0.5: Investigation error: #{Exception.message(e)}")
          []
      catch
        :exit, r ->
          Logger.warning("[WorkDirector] Stage 0.5: Investigation exit: #{inspect(r)}")
          []
      end
    else
      []
    end
  end

  # -- Stage 1.9: Substance Check --

  defp maybe_check_substance(branch, repo_path) do
    if @enable_substance_check do
      try do
        case GroundedVerifier.get_diff(branch, repo_path) do
          {:ok, diff} ->
            analysis = GroundedVerifier.analyze_substance(diff)

            unless analysis.has_substance do
              Logger.warning(
                "[WorkDirector] Stage 1.9: STUB — #{analysis.meaningful_lines} lines, stubs: #{inspect(analysis.stub_patterns)}"
              )

              cleanup_branch(branch, repo_path)
              throw({:stage1_9_failed, {:stub_detected, analysis}})
            end

            if analysis.warnings != [] do
              Logger.info("[WorkDirector] Stage 1.9: OK with warnings: #{Enum.join(analysis.warnings, "; ")}")
            else
              Logger.info("[WorkDirector] Stage 1.9: Substance OK (#{analysis.meaningful_lines} lines)")
            end

          {:error, reason} ->
            Logger.warning("[WorkDirector] Stage 1.9: diff failed (non-blocking): #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.warning("[WorkDirector] Stage 1.9 error (non-blocking): #{Exception.message(e)}")
      catch
        :exit, r ->
          Logger.warning("[WorkDirector] Stage 1.9 exit (non-blocking): #{inspect(r)}")
      end
    end
  end

  # -- Stage 2.75: Test Gate --

  @test_gate_timeout_ms 120_000

  defp maybe_run_test_gate(branch, repo_path) do
    if @enable_test_gate do
      try do
        Logger.info("[WorkDirector] Stage 2.75: Running tests")
        recover_branch(branch, repo_path)

        task = Task.async(fn ->
          System.cmd("bash", ["-c", "cd #{repo_path} && mix test --max-failures 5 2>&1"],
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )
        end)

        case Task.yield(task, @test_gate_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {_output, 0}} ->
            Logger.info("[WorkDirector] Stage 2.75: Tests PASSED")

          {:ok, {output, _}} ->
            summary =
              output
              |> String.split("\n")
              |> Enum.filter(&(String.contains?(&1, "failure") or String.contains?(&1, "error")))
              |> Enum.take(3)
              |> Enum.join("; ")

            Logger.warning(
              "[WorkDirector] Stage 2.75: Tests FAILED (soft gate): #{String.slice(summary, 0, 500)}"
            )

          nil ->
            Logger.warning("[WorkDirector] Stage 2.75: Tests TIMED OUT after #{div(@test_gate_timeout_ms, 1000)}s (soft gate)")
        end
      rescue
        e -> Logger.warning("[WorkDirector] Stage 2.75 error: #{Exception.message(e)}")
      catch
        :exit, r -> Logger.warning("[WorkDirector] Stage 2.75 exit: #{inspect(r)}")
      end
    end
  end

  # -- Stage 2.9: Code Review --

  defp maybe_run_code_review(item, branch, _session_id, repo_path) do
    if @enable_code_review do
      try do
        Logger.info("[WorkDirector] Stage 2.9: Running code review via debate")

        # Get the diff for reviewers
        {diff, _} =
          System.cmd("git", ["diff", "--stat", "main...#{branch}"],
            cd: repo_path,
            stderr_to_stdout: true
          )

        review_prompt =
          "Review this code change for '#{item.title}'. " <>
            "Check for: correctness, security issues, code style, missing error handling, phantom references. " <>
            "Diff summary:\n#{String.slice(diff, 0, 2000)}"

        case Debate.run(review_prompt, providers: ["anthropic"], timeout: 30_000) do
          {:ok, %{synthesis: synthesis}} ->
            Logger.info("[WorkDirector] Stage 2.9: Review complete: #{String.slice(synthesis, 0, 200)}")

          {:error, reason} ->
            Logger.warning("[WorkDirector] Stage 2.9: Review failed (non-blocking): #{inspect(reason)}")
        end
      rescue
        e -> Logger.warning("[WorkDirector] Stage 2.9 error: #{Exception.message(e)}")
      catch
        :exit, r -> Logger.warning("[WorkDirector] Stage 2.9 exit: #{inspect(r)}")
      end
    end
  end

  defp create_branch(branch, repo_path) do
    # Remove stale lock file from crashed git processes
    lock_path = Path.join([repo_path, ".git", "index.lock"])
    if File.exists?(lock_path), do: File.rm(lock_path)

    # Nuclear cleanup: abort any in-progress merge/rebase/cherry-pick, then hard reset
    System.cmd("git", ["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["rebase", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: repo_path, stderr_to_stdout: true)

    # Delete ALL stale workdir/ branches (from previous cycles or other systems)
    {branches_raw, _} = System.cmd("git", ["branch"], cd: repo_path, stderr_to_stdout: true)
    branches_raw
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "workdir/"))
    |> Enum.each(fn b ->
      System.cmd("git", ["branch", "-D", b], cd: repo_path, stderr_to_stdout: true)
    end)

    # Delete stale remote branch if it exists (prevents push rejection)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)

    case System.cmd("git", ["checkout", "-b", branch, "main"], cd: repo_path, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git checkout -b failed: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Recover if the agent switched away from the workdir branch during Stage 1.
  # Stashes any uncommitted changes, switches to the correct branch, then unstashes.
  # If the agent committed to main, cherry-picks those commits to the branch and resets main.
  defp recover_branch(branch, repo_path) do
    {current_raw, _} = System.cmd("git", ["branch", "--show-current"], cd: repo_path, stderr_to_stdout: true)
    current = String.trim(current_raw)

    if current == branch do
      Logger.debug("[WorkDirector] Branch OK: still on #{branch}")
    else
      Logger.warning("[WorkDirector] Branch drift! Expected #{branch}, on #{current}. Recovering...")

      # Check if agent made rogue commits on the wrong branch (e.g., main)
      if current == "main" do
        {ahead_raw, _} = System.cmd("git", ["rev-list", "origin/main..main", "--count"], cd: repo_path, stderr_to_stdout: true)
        ahead = String.trim(ahead_raw) |> String.to_integer()

        if ahead > 0 do
          Logger.warning("[WorkDirector] Found #{ahead} rogue commit(s) on main — cherry-picking to #{branch}")
          # Get the rogue commit SHAs
          {shas_raw, _} = System.cmd("git", ["rev-list", "origin/main..main", "--reverse"], cd: repo_path, stderr_to_stdout: true)
          rogue_shas = String.split(shas_raw, "\n", trim: true)

          # Stash any uncommitted changes
          System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

          # Reset main to origin/main (remove rogue commits from main)
          System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)

          # Switch to the workdir branch
          System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true)

          # Cherry-pick the rogue commits onto the branch
          Enum.each(rogue_shas, fn sha ->
            case System.cmd("git", ["cherry-pick", sha], cd: repo_path, stderr_to_stdout: true) do
              {_, 0} -> Logger.info("[WorkDirector] Cherry-picked #{String.slice(sha, 0, 8)} to #{branch}")
              {err, _} ->
                Logger.warning("[WorkDirector] Cherry-pick failed for #{String.slice(sha, 0, 8)}: #{String.trim(err)}")
                System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
            end
          end)

          # Unstash working tree changes
          System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        else
          # No rogue commits, just stash + switch
          System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

          case System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true) do
            {_, 0} -> :ok
            {_, _} ->
              Logger.warning("[WorkDirector] Branch #{branch} gone from main — recreating")
              System.cmd("git", ["checkout", "-b", branch], cd: repo_path, stderr_to_stdout: true)
          end

          System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        end
      else
        # On some other branch entirely — stash + switch
        System.cmd("git", ["stash", "--include-untracked"], cd: repo_path, stderr_to_stdout: true)

        case System.cmd("git", ["checkout", branch], cd: repo_path, stderr_to_stdout: true) do
          {_, 0} ->
            System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)

          {_err, _} ->
            # Branch doesn't exist (was deleted) — recreate it from current HEAD
            Logger.warning("[WorkDirector] Branch #{branch} gone — recreating from current state")
            System.cmd("git", ["checkout", "-b", branch], cd: repo_path, stderr_to_stdout: true)
            System.cmd("git", ["stash", "pop"], cd: repo_path, stderr_to_stdout: true)
        end
      end
    end
  rescue
    e ->
      Logger.error("[WorkDirector] Branch recovery failed: #{Exception.message(e)}")
  end

  defp cleanup_branch(branch, repo_path) do
    # Nuclear cleanup: abort any in-progress operations, hard reset to origin/main
    System.cmd("git", ["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["rebase", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["cherry-pick", "--abort"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["checkout", "main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["reset", "--hard", "origin/main"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp execute_and_poll(prompt, session_id, item \\ nil) do
    # Swarm dispatch: use SwarmMode with pattern selection
    if @enable_swarm_dispatch and item != nil do
      execute_via_swarm(prompt, session_id, item)
    else
      # Specialist routing: let Orchestrator auto-decompose and route
      opts =
        if @enable_specialist_routing do
          Logger.info("[WorkDirector] Stage 1: Using specialist routing (Orchestrator auto-decomposition)")
          [max_iterations: @agent_max_iterations, tier: :elite]
        else
          [force_simple: true, max_iterations: @agent_max_iterations, tier: :elite]
        end

      case Orchestrator.execute(prompt, session_id, opts) do
        {:ok, task_id} -> await_orchestrator_completion(task_id)
        {:error, reason} -> {:failed, reason}
      end
    end
  end

  defp execute_via_swarm(prompt, session_id, item) do
    pattern = select_swarm_pattern(item)
    Logger.info("[WorkDirector] Stage 1: Using swarm pattern #{inspect(pattern)}")

    case SwarmMode.launch(prompt,
           pattern: pattern,
           session_id: session_id,
           timeout_ms: @orchestrator_timeout_ms
         ) do
      {:ok, swarm_id} ->
        await_swarm_completion(swarm_id)

      {:error, reason} ->
        Logger.warning("[WorkDirector] Swarm launch failed, falling back to simple dispatch: #{inspect(reason)}")
        opts = [force_simple: true, max_iterations: @agent_max_iterations, tier: :elite]

        case Orchestrator.execute(prompt, session_id, opts) do
          {:ok, task_id} -> await_orchestrator_completion(task_id)
          {:error, r} -> {:failed, r}
        end
    end
  end

  defp select_swarm_pattern(item) do
    title = String.downcase(item.title || "")
    desc = String.downcase(item.description || "")
    text = title <> " " <> desc

    cond do
      String.contains?(text, "security") or String.contains?(text, "audit") -> :debate
      String.contains?(text, "test") or String.contains?(text, "spec") -> :review
      String.contains?(text, "refactor") or String.contains?(text, "review") -> :review
      String.contains?(text, "debug") or String.contains?(text, "fix") -> :parallel
      String.contains?(text, "pipeline") or String.contains?(text, "migration") -> :pipeline
      true -> :review
    end
  end

  defp await_swarm_completion(swarm_id) do
    deadline = System.monotonic_time(:millisecond) + @orchestrator_timeout_ms
    poll_swarm(swarm_id, deadline)
  end

  defp poll_swarm(swarm_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, :deadline_exceeded}
    else
      case SwarmMode.status(swarm_id) do
        {:ok, %{status: :completed, result: result}} ->
          {:completed, result || ""}

        {:ok, %{status: :failed, error: error}} ->
          {:failed, error}

        {:ok, %{status: status}} when status in [:running, :planning] ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_swarm(swarm_id, deadline)

        {:error, :not_found} ->
          {:failed, :swarm_not_found}

        _ ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_swarm(swarm_id, deadline)
      end
    end
  rescue
    _ -> {:failed, :swarm_poll_error}
  catch
    :exit, _ -> {:failed, :swarm_poll_exit}
  end

  defp verify_and_fix_compilation(item, branch, session_id, repo_path, attempt) do
    if @enable_autofixer do
      verify_compilation_autofixer(session_id, repo_path)
    else
      verify_compilation_simple(item, branch, session_id, repo_path, attempt)
    end
  end

  defp verify_compilation_autofixer(session_id, repo_path) do
    case run_compile(repo_path) do
      :ok ->
        :ok

      {:error, _} ->
        Logger.info("[WorkDirector] Stage 2 (AutoFixer): delegating compilation fix")

        try do
          case AutoFixer.run(%{
                 type: :compile,
                 session_id: "#{session_id}-autofix",
                 cwd: repo_path,
                 max_iterations: 10,
                 command: "mix compile"
               }) do
            {:ok, %{success: true, iterations: n}} ->
              Logger.info("[WorkDirector] Stage 2 (AutoFixer): fixed in #{n} iterations")
              :ok

            {:ok, %{success: false, remaining_errors: errors}} ->
              {:error, {:autofixer_exhausted, Enum.join(errors, "\n")}}

            {:error, reason} ->
              {:error, {:autofixer_error, reason}}
          end
        rescue
          e ->
            Logger.warning("[WorkDirector] AutoFixer crashed, falling back: #{Exception.message(e)}")
            verify_compilation_simple(nil, nil, nil, repo_path, 0)
        catch
          :exit, reason ->
            Logger.warning("[WorkDirector] AutoFixer exit, falling back: #{inspect(reason)}")
            verify_compilation_simple(nil, nil, nil, repo_path, 0)
        end
    end
  end

  defp verify_compilation_simple(_item, _branch, _session_id, repo_path, attempt)
       when attempt >= @compile_fix_max_attempts do
    case run_compile(repo_path) do
      :ok -> :ok
      {:error, errors} -> {:error, {:max_fix_attempts, errors}}
    end
  end

  defp verify_compilation_simple(item, branch, session_id, repo_path, attempt) do
    case run_compile(repo_path) do
      :ok ->
        :ok

      {:error, errors} ->
        Logger.info("[WorkDirector] Stage 2: Compilation failed (attempt #{attempt + 1}), dispatching fix agent")

        fix_prompt = """
        Fix the following compilation errors in this Elixir/OTP codebase.

        ## Repository
        The codebase is at: `#{repo_path}`
        You are on branch `#{branch}`.

        CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
        For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

        ## Compilation Errors
        ```
        #{String.slice(errors, 0, 3000)}
        ```

        ## Instructions
        1. Read the files mentioned in the errors
        2. Fix the compilation errors
        3. Run `mix compile` to verify the fix (use cwd: "#{repo_path}")
        4. If new errors appear, fix those too

        ONLY fix compilation errors. Do NOT add features, refactor, or change behavior.
        Do NOT modify: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
        """

        fix_session = "#{session_id}-fix-#{attempt}"

        case execute_and_poll(fix_prompt, fix_session) do
          {:completed, _} ->
            verify_compilation_simple(item, branch, session_id, repo_path, attempt + 1)

          {:failed, reason} ->
            {:error, {:fix_agent_failed, reason}}

          {:timeout, _} ->
            {:error, :fix_agent_timeout}
        end
    end
  end

  defp run_compile(repo_path) do
    # Use plain `mix compile` — NOT --warnings-as-errors, because this codebase
    # has 60+ pre-existing warnings (Bcrypt, film_pipeline, etc.) that would
    # cause false failures on every agent attempt.
    case System.cmd("bash", ["-c", "cd #{repo_path} && mix compile 2>&1"],
           stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}]) do
      {_output, 0} -> :ok
      {output, _} ->
        # Filter out warnings — only report actual errors
        errors = output
          |> String.split("\n")
          |> Enum.filter(fn line ->
            String.contains?(line, "** (CompileError)") or
            String.contains?(line, "error:") or
            String.contains?(line, "== Compilation error")
          end)
          |> Enum.join("\n")

        if errors == "" do
          # Only warnings, no real errors — treat as success
          :ok
        else
          {:error, output}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Stage 2.5: Grounded Reference Verification --

  @reference_fix_max_attempts 1

  defp verify_and_fix_references(_branch, _session_id, _repo_path, attempt)
       when attempt > @reference_fix_max_attempts do
    {:error, :max_reference_fix_attempts}
  end

  defp verify_and_fix_references(branch, session_id, repo_path, attempt) do
    case GroundedVerifier.verify(branch, repo_path) do
      {:ok, []} ->
        :ok

      {:ok, warnings} ->
        {:warnings, warnings}

      {:error, violations} ->
        Logger.warning("[WorkDirector] Stage 2.5: #{length(violations)} phantom reference(s) found (attempt #{attempt + 1})")
        Enum.each(violations, fn v -> Logger.warning("[WorkDirector] Stage 2.5 violation: #{v}") end)

        fix_prompt = """
        Fix the following reference errors in this Elixir/OTP codebase.

        ## Repository
        The codebase is at: `#{repo_path}`
        You are on branch `#{branch}`.

        CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
        For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

        ## Reference Violations
        #{GroundedVerifier.fix_prompt(violations)}

        ## Instructions
        1. For each violation, either CREATE the missing module with real functionality, or CHANGE the code to use an existing module
        2. Run `mix compile` to verify (use cwd: "#{repo_path}")
        3. Do NOT create empty stubs — every module must have real working code

        Do NOT modify: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
        """

        fix_session = "#{session_id}-reffix-#{attempt}"

        case execute_and_poll(fix_prompt, fix_session) do
          {:completed, _} ->
            # Re-verify after fix (also re-check compilation since fix agent may have introduced errors)
            case run_compile(repo_path) do
              :ok -> verify_and_fix_references(branch, session_id, repo_path, attempt + 1)
              {:error, _} -> {:error, :fix_broke_compilation}
            end

          {:failed, reason} ->
            {:error, {:reference_fix_failed, reason}}

          {:timeout, _} ->
            {:error, :reference_fix_timeout}
        end
    end
  end

  defp finalize_branch(item, branch, repo_path) do
    # Last-resort recovery: ensure we're on the correct branch before committing
    recover_branch(branch, repo_path)

    {current_raw, _} = System.cmd("git", ["branch", "--show-current"], cd: repo_path, stderr_to_stdout: true)
    current = String.trim(current_raw)

    if current != branch do
      Logger.error("[WorkDirector] Stage 3 ABORT: on #{current}, expected #{branch}. Recovery failed.")
      {:error, {:wrong_branch, current, branch}}
    else
      finalize_branch_impl(item, branch, repo_path)
    end
  end

  defp finalize_branch_impl(item, branch, repo_path) do
    # Check what files changed
    case System.cmd("git", ["diff", "--name-only", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} when byte_size(output) > 2 ->
        files = output |> String.split("\n", trim: true) |> filter_safe_files()

        if files == [] do
          {:error, :no_changes}
        else
          # Git add only safe files
          System.cmd("git", ["add" | files], cd: repo_path, stderr_to_stdout: true)

          # Commit
          commit_msg = "feat: #{item.title}\n\nSource: #{item.source}\nPriority: #{item.base_priority}\n\nAutonomously generated by WorkDirector staged execution."
          case System.cmd("git", ["commit", "-m", commit_msg], cd: repo_path, stderr_to_stdout: true) do
            {_, 0} ->
              # Push
              case System.cmd("git", ["push", "origin", branch], cd: repo_path, stderr_to_stdout: true) do
                {_, 0} ->
                  # Create draft PR
                  pr_body = "Source: #{item.source}\nPriority: #{item.base_priority}\n\n#{String.slice(item.description || "", 0, 500)}\n\n---\n_Autonomously generated by WorkDirector staged execution._"
                  pr_result = System.cmd("gh", [
                    "pr", "create", "--draft",
                    "--title", item.title,
                    "--repo", @daemon_repo,
                    "--body", pr_body
                  ], cd: repo_path, stderr_to_stdout: true)

                  case pr_result do
                    {url, 0} -> {:ok, %{pr_url: String.trim(url)}}
                    {_, _} -> {:ok, %{pr_url: nil, note: "pushed but PR creation failed"}}
                  end

                {push_err, _} ->
                  {:error, {:push_failed, push_err}}
              end

            {commit_err, _} ->
              {:error, {:commit_failed, commit_err}}
          end
        end

      _ ->
        # Also check untracked files
        case System.cmd("git", ["status", "--porcelain"], cd: repo_path, stderr_to_stdout: true) do
          {output, 0} when byte_size(output) > 2 ->
            # There are changes — extract file paths
            files =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(fn line -> String.slice(line, 3..-1//1) |> String.trim() end)
              |> Enum.reject(&(&1 == ""))
              |> filter_safe_files()

            if files == [] do
              {:error, :no_changes}
            else
              System.cmd("git", ["add" | files], cd: repo_path, stderr_to_stdout: true)
              commit_msg = "feat: #{item.title}\n\nSource: #{item.source}\nPriority: #{item.base_priority}\n\nAutonomously generated by WorkDirector staged execution."
              case System.cmd("git", ["commit", "-m", commit_msg], cd: repo_path, stderr_to_stdout: true) do
                {_, 0} ->
                  case System.cmd("git", ["push", "origin", branch], cd: repo_path, stderr_to_stdout: true) do
                    {_, 0} ->
                      pr_body = "Source: #{item.source}\nPriority: #{item.base_priority}\n\n#{String.slice(item.description || "", 0, 500)}"
                      pr_result = System.cmd("gh", [
                        "pr", "create", "--draft",
                        "--title", item.title,
                        "--repo", @daemon_repo,
                        "--body", pr_body
                      ], cd: repo_path, stderr_to_stdout: true)
                      case pr_result do
                        {url, 0} -> {:ok, %{pr_url: String.trim(url)}}
                        {_, _} -> {:ok, %{pr_url: nil}}
                      end
                    {err, _} -> {:error, {:push_failed, err}}
                  end
                {err, _} -> {:error, {:commit_failed, err}}
              end
            end

          _ ->
            {:error, :no_changes}
        end
    end
  rescue
    e -> {:error, {:finalize_exception, Exception.message(e)}}
  end

  defp filter_safe_files(files) do
    regexes = Enum.map(@protected_path_patterns, &Regex.compile!/1)

    Enum.reject(files, fn file ->
      Enum.any?(regexes, fn regex -> Regex.match?(regex, file) end)
    end)
  end

  defp build_implementation_prompt(item, repo_path, pre_research_context) do
    source_context =
      case item.source do
        :vision ->
          "This task comes from VISION.md — a strategic product goal."

        :issues ->
          number = get_in(item.metadata, ["number"])
          if number, do: "This task comes from GitHub Issue ##{number}. Closes ##{number}.", else: "This task comes from a GitHub Issue."

        :investigation ->
          "This task originated from an investigation finding backed by evidence."

        :fitness ->
          "This task addresses a fitness function violation."

        :manual ->
          "This task was manually submitted by a human operator."
      end

    # Pre-compute codebase context via DispatchIntelligence (zero LLM cost)
    codebase_context =
      case DispatchIntelligence.enrich(item.title, item.description || "", repo_path) do
        {:ok, %{execution_trace: trace}} ->
          Logger.debug("[WorkDirector] DispatchIntelligence enriched prompt for '#{item.title}'")
          trace

        {:error, reason} ->
          Logger.warning("[WorkDirector] DispatchIntelligence failed: #{inspect(reason)}")
          ""
      end

    """
    #{source_context}

    ## Repository
    The codebase is located at: `#{repo_path}`

    CRITICAL: For ALL shell commands, use the `cwd` parameter set to `#{repo_path}`.
    Example: shell_execute(command: "mix compile", cwd: "#{repo_path}")
    For file operations, use ABSOLUTE paths starting with `#{repo_path}/`.

    #{codebase_context}
    #{pre_research_context}

    ## Task
    **#{item.title}**

    #{item.description}

    ## Instructions
    You are already on branch with the codebase ready. Your ONLY job is to implement the changes.
    Do NOT create branches, commit, push, or create PRs — that is handled automatically after you finish.

    1. Study the reference implementations and file territory above
    2. Implement the changes using file_write / file_edit tools with ABSOLUTE paths
    3. Use shell_execute with cwd: "#{repo_path}" to run `mix compile`
    4. If compilation fails, read the errors and fix them
    5. Run `mix test` for relevant test files (with cwd: "#{repo_path}")
    6. Verify your implementation is complete and compiles cleanly

    IMPORTANT: Do NOT modify any files matching: application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
    You MUST make at least one meaningful code change. Finish your implementation — do NOT just explore the codebase.
    """
  end

  defp branch_name(%WorkItem{title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    "workdir/#{slug}"
  end

  defp verify_safety(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))
    regexes = Enum.map(@protected_path_patterns, &Regex.compile!/1)

    case System.cmd("git", ["diff", "--name-only", "main...#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true) do
      {output, 0} ->
        files = String.split(output, "\n", trim: true)

        unsafe =
          Enum.any?(files, fn file ->
            Enum.any?(regexes, fn regex -> Regex.match?(regex, file) end)
          end)

        if unsafe, do: :unsafe, else: :safe

      _ ->
        # Can't verify — assume safe (branch might not exist yet)
        :safe
    end
  end

  defp delete_branch(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)
  end

  defp poll_pr_outcomes(state) do
    case System.cmd("gh", [
           "pr", "list",
           "--repo", @daemon_repo,
           "--head", "workdir/",
           "--json", "headRefName,state,mergedAt",
           "--limit", "50",
           "--state", "all"
         ], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} ->
            process_pr_outcomes(state, prs)

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp process_pr_outcomes(state, prs) do
    Enum.reduce(prs, state, fn pr, acc ->
      branch = pr["headRefName"]

      # Find matching completed PR
      match = Enum.find(acc.completed_prs, fn cp -> cp.branch == branch end)

      if match do
        cond do
          pr["state"] == "MERGED" ->
            Logger.info("[WorkDirector] PR MERGED: #{branch}")

            acc
            |> reward_arm(match.source, 1.0)
            |> Map.update!(:total_merged, &(&1 + 1))
            |> remove_completed_pr(branch)

          pr["state"] == "CLOSED" ->
            Logger.info("[WorkDirector] PR REJECTED: #{branch}")

            acc
            |> reward_arm(match.source, 0.2)
            |> Map.update!(:total_rejected, &(&1 + 1))
            |> remove_completed_pr(branch)

          true ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp reward_arm(state, source, reward) do
    clamped = max(0.0, min(1.0, reward))

    arms =
      Map.update(state.arms, source, %{alpha: 1.0, beta: 1.0}, fn arm ->
        %{arm | alpha: arm.alpha + clamped, beta: arm.beta + (1.0 - clamped)}
      end)

    state = %{state | arms: arms}
    persist_arms(state)
    state
  end

  defp update_backlog_completed(state, content_hash, result) do
    %{state | backlog: Backlog.mark_completed(state.backlog, content_hash, result)}
  end

  defp update_backlog_failed(state, content_hash) do
    %{state | backlog: Backlog.mark_failed(state.backlog, content_hash)}
  end

  defp add_completed_pr(state, branch, source, content_hash) do
    pr = %{branch: branch, source: source, content_hash: content_hash}
    completed = [pr | state.completed_prs] |> Enum.take(@max_completed_prs)
    %{state | completed_prs: completed}
  end

  defp remove_completed_pr(state, branch) do
    completed = Enum.reject(state.completed_prs, fn cp -> cp.branch == branch end)
    %{state | completed_prs: completed}
  end

  defp maybe_trip_circuit_breaker(state, failures) when failures >= @circuit_breaker_threshold do
    until = DateTime.add(DateTime.utc_now(), @circuit_breaker_ms, :millisecond)
    Logger.warning("[WorkDirector] Circuit breaker tripped: #{failures} consecutive failures, disabled until #{until}")
    %{state | circuit_breaker_until: until}
  end

  defp maybe_trip_circuit_breaker(state, _failures), do: state

  defp circuit_breaker_active?(%{circuit_breaker_until: nil}), do: false

  defp circuit_breaker_active?(%{circuit_breaker_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  defp budget_ok? do
    try do
      case MiosaBudget.Budget.check_budget() do
        {:ok, _} -> true
        _ -> false
      end
    rescue
      _ -> true
    catch
      :exit, _ -> true
    end
  end

  defp maybe_reset_daily_counter(state) do
    today = Date.utc_today()

    if state.last_day_reset != today do
      %{state | dispatches_today: 0, last_day_reset: today}
    else
      state
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_backlog, @backlog_refresh_ms)
  end

  defp schedule_pr_poll do
    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_ms)
  end

  # -- Stage 3.5: Post-Dispatch Learning --

  defp post_dispatch_learn(dispatch, result) do
    # Vault: remember dispatch outcome
    if @enable_vault_remember do
      try do
        {category, content} =
          case result do
            {:ok, _output, branch} ->
              {:lesson,
               "WorkDirector SUCCEEDED: \"#{dispatch.title}\" (#{dispatch.source}), branch: #{branch}"}

            {:error, reason} ->
              fc = classify_failure(reason)

              {:lesson,
               "WorkDirector FAILED: \"#{dispatch.title}\" (#{dispatch.source}), class: #{fc}, error: #{inspect(reason) |> String.slice(0, 300)}"}
          end

        Vault.remember(content, category, %{
          title: "workdir-#{String.slice(dispatch.title, 0, 40)}",
          session_id: "workdir-vault"
        })

        Logger.info("[WorkDirector] Stage 3.5: Vault remembered #{category} for '#{String.slice(dispatch.title, 0, 50)}'")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Knowledge Store: assert dispatch outcome as triple
    if @enable_knowledge_remember do
      try do
        store = "osa_default"
        slug = String.slice(dispatch.title, 0, 60) |> String.replace(~r/[^a-zA-Z0-9]/, "_")
        outcome = if match?({:ok, _, _}, result), do: "success", else: "failure"

        Vaos.Knowledge.assert(store, {"workdir:#{slug}", "osa:dispatch_outcome", outcome})
        Vaos.Knowledge.assert(store, {"workdir:#{slug}", "osa:source", to_string(dispatch.source)})
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # SkillEvolution: trigger evolution on failure
    if @enable_skill_evolution do
      case result do
        {:error, reason} ->
          try do
            fc = classify_failure(reason)

            SkillEvolution.trigger_evolution("workdir-#{dispatch.title}", %{
              reason: inspect(fc),
              title: dispatch.title,
              source: dispatch.source,
              failure_class: fc
            })

            Logger.info("[WorkDirector] Stage 3.5: Triggered skill evolution for #{fc}")
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  # -- Failure Classification --

  defp classify_failure({:empty_branch, _}), do: :empty_branch
  defp classify_failure({:no_branch, _}), do: :no_branch_created
  defp classify_failure({:orchestrator_failed, _}), do: :orchestrator_error
  defp classify_failure({:timeout, _}), do: :timeout
  defp classify_failure({:compilation_unfixable, _}), do: :compilation_error
  defp classify_failure({:phantom_references, _}), do: :phantom_references
  defp classify_failure({:stub_detected, _}), do: :stub_detected
  defp classify_failure({:autofixer_exhausted, _}), do: :compilation_error
  defp classify_failure({:autofixer_error, _}), do: :compilation_error
  defp classify_failure({:commit_failed, _}), do: :commit_error
  defp classify_failure({:exception, msg}) when is_binary(msg) do
    cond do
      String.contains?(msg, "compile") -> :compilation_error
      String.contains?(msg, "test") -> :test_failure
      true -> :exception
    end
  end
  defp classify_failure({:exit, _}), do: :process_crash
  defp classify_failure(_), do: :unknown

  # Reward based on how far the dispatch got
  # These partial signals help Thompson learn which sources produce completable tasks
  defp failure_class_reward(:empty_branch), do: 0.10       # Agent wrote no code
  defp failure_class_reward(:no_branch_created), do: 0.05  # Branch creation failed
  defp failure_class_reward(:orchestrator_error), do: 0.05  # Orchestrator itself failed
  defp failure_class_reward(:timeout), do: 0.10             # Task was too large
  defp failure_class_reward(:compilation_error), do: 0.15   # Code written but won't compile
  defp failure_class_reward(:phantom_references), do: 0.18  # Compiles but references non-existent modules
  defp failure_class_reward(:stub_detected), do: 0.05       # Agent produced stubs, not real code
  defp failure_class_reward(:commit_error), do: 0.20        # Code compiles but commit failed
  defp failure_class_reward(:test_failure), do: 0.20        # Code compiled but tests failed (close!)
  defp failure_class_reward(:process_crash), do: 0.0        # Total failure
  defp failure_class_reward(_), do: 0.05

  # -- Orchestrator Completion Polling --

  defp await_orchestrator_completion(task_id) do
    deadline = System.monotonic_time(:millisecond) + @orchestrator_timeout_ms
    poll_orchestrator(task_id, deadline)
  end

  defp poll_orchestrator(task_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, :deadline_exceeded}
    else
      case Orchestrator.progress(task_id) do
        {:ok, %{status: :completed, synthesis: synthesis}} ->
          {:completed, synthesis || ""}

        {:ok, %{status: :failed, error: error}} ->
          {:failed, error}

        {:ok, %{status: status}} when status in [:running, :planning] ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_orchestrator(task_id, deadline)

        {:error, :not_found} ->
          # Task may have been cleaned up — treat as failure
          {:failed, :task_not_found}

        _ ->
          Process.sleep(@orchestrator_poll_interval_ms)
          poll_orchestrator(task_id, deadline)
      end
    end
  rescue
    _ -> {:failed, :poll_error}
  catch
    :exit, _ -> {:failed, :poll_exit}
  end

  # -- Arm Persistence --

  @arms_dir Path.expand("~/.daemon/work_director")
  @arms_file Path.join(@arms_dir, "arms.json")

  defp persist_arms(state) do
    data = %{
      "version" => 1,
      "arms" => Map.new(state.arms, fn {source, arm} ->
        {to_string(source), %{"alpha" => arm.alpha, "beta" => arm.beta}}
      end),
      "stats" => %{
        "total_dispatches" => state.total_dispatches,
        "total_merged" => state.total_merged,
        "total_rejected" => state.total_rejected
      }
    }

    File.mkdir_p!(@arms_dir)
    File.write!(@arms_file, Jason.encode!(data, pretty: true))
  rescue
    e ->
      Logger.warning("[WorkDirector] Failed to persist arms: #{Exception.message(e)}")
  end

  defp load_persisted_arms(state) do
    case File.read(@arms_file) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"version" => 1, "arms" => raw_arms} = data} ->
            arms =
              Enum.reduce(raw_arms, state.arms, fn {source_str, arm_data}, acc ->
                source = String.to_existing_atom(source_str)
                alpha = arm_data["alpha"] || 1.0
                beta = arm_data["beta"] || 1.0

                if is_number(alpha) and is_number(beta) and alpha > 0 and beta > 0 do
                  Map.put(acc, source, %{alpha: alpha / 1.0, beta: beta / 1.0})
                else
                  acc
                end
              end)

            stats = Map.get(data, "stats", %{})

            %{state |
              arms: arms,
              total_dispatches: Map.get(stats, "total_dispatches", 0),
              total_merged: Map.get(stats, "total_merged", 0),
              total_rejected: Map.get(stats, "total_rejected", 0)
            }

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  rescue
    _ -> state
  end
end
