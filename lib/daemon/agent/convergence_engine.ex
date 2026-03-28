defmodule Daemon.Agent.ConvergenceEngine do
  @moduledoc """
  Desired-state convergence engine — proactive architectural fitness enforcement.

  Periodically runs deterministic fitness functions against the codebase and
  dispatches repair tasks to the Orchestrator for any NEW violations. Uses
  FreezingArchRule to snapshot existing violations on first run and only act
  on regressions.

  Key differences from CodeIntrospector:
  - Fitness functions are deterministic (no LLM decides "is this actionable?")
  - If a guard says "not kept", we repair. Period.
  - Runs less frequently (30min vs 10min) because checks are heavier
  - Conservative: max 1 repair per cycle, max 3 per day
  """

  use GenServer
  require Logger

  alias Daemon.Agent.Orchestrator
  alias Daemon.Fitness
  alias Daemon.Intelligence.DecisionJournal

  # ── Configuration ────────────────────────────────────────────

  @poll_interval_ms :timer.minutes(30)
  @initial_delay_ms :timer.seconds(180)
  @max_repairs_per_day 3
  @cooldown_hours 24
  @max_consecutive_failures 5
  @circuit_breaker_hours 24
  @daemon_repo "jmanhype/vaos-daemon"

  # Protected path patterns (as strings — compiled to Regex at runtime)
  @protected_path_sources [
    "^lib/daemon/application\\.ex$",
    "^lib/daemon/supervisors/",
    "^lib/daemon/security/",
    "^lib/daemon/agent/loop\\.ex$",
    "^lib/daemon/agent/convergence_engine\\.ex$",
    "^lib/daemon/fitness\\.ex$",
    "^lib/daemon/fitness/",
    "^config/runtime\\.exs$",
    "^mix\\.exs$",
    "^mix\\.lock$"
  ]

  defp protected_paths do
    Enum.map(@protected_path_sources, &Regex.compile!/1)
  end

  # ── Public API ───────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{status: :not_running}
    catch
      :exit, _ -> %{status: :not_running}
    end
  end

  def force_cycle do
    try do
      GenServer.cast(__MODULE__, :force_cycle)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  def enable, do: set_enabled(true)
  def disable, do: set_enabled(false)

  defp set_enabled(value) do
    try do
      GenServer.call(__MODULE__, {:set_enabled, value})
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      enabled: enabled,
      repair_history: %{},
      repairs_today: 0,
      last_day_reset: Date.utc_today(),
      pending_repair: nil,
      frozen_initialized: false,
      consecutive_failures: 0,
      circuit_breaker_until: nil,
      total_cycles: 0,
      total_repairs: 0,
      last_cycle_at: nil,
      last_results: []
    }

    if enabled do
      Logger.info("[ConvergenceEngine] Started (enabled=true)")
      Logger.info("[ConvergenceEngine] First cycle in #{div(@initial_delay_ms, 1000)}s")
      Process.send_after(self(), :first_cycle, @initial_delay_ms)
    else
      Logger.info("[ConvergenceEngine] Started (enabled=false)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      status: if(state.enabled, do: :running, else: :disabled),
      enabled: state.enabled,
      frozen_initialized: state.frozen_initialized,
      repairs_today: state.repairs_today,
      total_cycles: state.total_cycles,
      total_repairs: state.total_repairs,
      consecutive_failures: state.consecutive_failures,
      pending_repair: state.pending_repair != nil,
      last_cycle_at: state.last_cycle_at,
      last_results: state.last_results
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_enabled, value}, _from, state) do
    Logger.info("[ConvergenceEngine] #{if value, do: "Enabled", else: "Disabled"}")

    if value and not state.enabled do
      Process.send_after(self(), :cycle, @poll_interval_ms)
    end

    {:reply, :ok, %{state | enabled: value}}
  end

  @impl true
  def handle_cast(:force_cycle, state) do
    if state.enabled do
      Logger.info("[ConvergenceEngine] Forced cycle triggered")
      send(self(), :cycle)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:first_cycle, state) do
    state = run_cycle(state)
    schedule_next_cycle()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cycle, state) do
    state =
      if state.enabled do
        run_cycle(state)
      else
        state
      end

    schedule_next_cycle()
    {:noreply, state}
  end

  @impl true
  def handle_info({:repair_complete, ref, result}, state) do
    state = handle_repair_result(ref, result, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, _pid, reason}, state) do
    case state.pending_repair do
      {_ref, fitness_name, _started_at} ->
        Logger.warning("[ConvergenceEngine] Repair process for '#{fitness_name}' died: #{inspect(reason)}")
        state = %{state | pending_repair: nil, consecutive_failures: state.consecutive_failures + 1}
        state = maybe_trip_circuit_breaker(state)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  # Handle PR outcome from Decision Journal (unified polling)
  def handle_info({:journal_pr_outcome, branch, reward}, state) do
    Logger.info("[ConvergenceEngine] Journal PR outcome for #{branch}: reward=#{reward}")
    # ConvergenceEngine doesn't use Thompson yet, but log for observability
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("[ConvergenceEngine] Shutting down")
    :ok
  end

  # ── Core Loop ────────────────────────────────────────────────

  defp run_cycle(state) do
    state = maybe_reset_daily_counter(state)

    if circuit_breaker_active?(state) do
      Logger.info("[ConvergenceEngine] Circuit breaker active — skipping cycle")
      %{state | total_cycles: state.total_cycles + 1, last_cycle_at: DateTime.utc_now()}
    else
      do_run_cycle(state)
    end
  end

  defp do_run_cycle(state) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    # Step 1: Initialize frozen store on first run
    state =
      if not state.frozen_initialized do
        Logger.info("[ConvergenceEngine] Initializing frozen store — snapshotting existing violations")

        try do
          Fitness.freeze_current!(repo_path)
          %{state | frozen_initialized: true}
        rescue
          e ->
            Logger.warning("[ConvergenceEngine] Failed to initialize frozen store: #{Exception.message(e)}")
            state
        catch
          kind, reason ->
            Logger.warning("[ConvergenceEngine] Failed to initialize frozen store: #{kind} #{inspect(reason)}")
            state
        end
      else
        state
      end

    # Step 2: Run all fitness functions
    raw_results = Fitness.evaluate_all(repo_path)

    # Step 3: Apply frozen filter
    filtered_results =
      Enum.map(raw_results, fn {name, result} ->
        {name, Fitness.apply_frozen_filter(name, result)}
      end)

    # Log results
    summary =
      Enum.map_join(filtered_results, ", ", fn {name, {status, _score, _detail}} ->
        "#{name}=#{status}"
      end)

    Logger.info("[ConvergenceEngine] Fitness results: #{summary}")

    state = %{
      state
      | total_cycles: state.total_cycles + 1,
        last_cycle_at: DateTime.utc_now(),
        last_results: filtered_results
    }

    # Step 4: Find violations eligible for repair
    violations =
      filtered_results
      |> Enum.filter(fn {_name, {status, _score, _detail}} -> status == :not_kept end)
      |> Enum.reject(fn {name, _result} -> on_cooldown?(name, state) end)

    # Step 5: Check caps and dispatch
    cond do
      state.pending_repair != nil ->
        Logger.debug("[ConvergenceEngine] Repair already in flight — skipping dispatch")
        state

      state.repairs_today >= @max_repairs_per_day ->
        Logger.info("[ConvergenceEngine] Daily repair cap reached (#{state.repairs_today}/#{@max_repairs_per_day})")
        state

      violations == [] ->
        Logger.info("[ConvergenceEngine] No new violations to repair")
        state

      true ->
        # Take first violation (max 1 per cycle)
        {name, {_status, score, detail}} = hd(violations)
        dispatch_repair(name, score, detail, repo_path, state)
    end
  end

  # ── Repair Dispatch ──────────────────────────────────────────

  defp dispatch_repair(fitness_name, score, detail, repo_path, state) do
    branch_name = "convergence/#{fitness_name}"

    # Check with Decision Journal for cross-module conflicts
    case DecisionJournal.propose(:convergence_engine, :repair, %{
      topic: "Fitness violation: #{fitness_name}",
      branch: branch_name,
      fitness_name: fitness_name,
      score: score
    }) do
      {:conflict, reason} ->
        Logger.info("[ConvergenceEngine] Journal conflict for '#{fitness_name}': #{reason}")
        state

      :approved ->
        do_dispatch_repair(fitness_name, score, detail, repo_path, branch_name, state)
    end
  end

  defp do_dispatch_repair(fitness_name, score, detail, repo_path, branch_name, state) do
    # Find the module for description
    mod = Enum.find(Fitness.all(), fn m -> m.name() == fitness_name end)
    description = if mod, do: mod.description(), else: fitness_name

    session_id = "convergence-#{System.unique_integer([:positive])}"

    prompt = build_repair_prompt(fitness_name, description, score, detail, repo_path, branch_name)

    Logger.info("[ConvergenceEngine] Dispatching repair for '#{fitness_name}' (score=#{Float.round(score, 2)})")

    parent = self()
    ref = make_ref()

    {_pid, _monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            case Orchestrator.execute(prompt, session_id, strategy: "pact") do
              {:ok, output} -> {:ok, output, branch_name}
              {:error, reason} -> {:error, reason}
            end
          rescue
            e -> {:error, {:exception, Exception.message(e)}}
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        send(parent, {:repair_complete, ref, result})
      end)

    %{
      state
      | pending_repair: {ref, fitness_name, System.monotonic_time(:millisecond)},
        repair_history: Map.put(state.repair_history, fitness_name, DateTime.utc_now())
    }
  end

  defp build_repair_prompt(fitness_name, description, score, detail, repo_path, branch_name) do
    protected_list =
      @protected_path_sources
      |> Enum.map_join("\n      ", &"- #{&1}")

    """
    ## Task: Fix Fitness Function Violation

    ### Violation
    - Fitness Function: #{fitness_name}
    - Description: #{description}
    - Score: #{Float.round(score, 3)}

    ### Evidence (deterministic — these are facts, not opinions)
    #{detail}

    ### Implementation Instructions
    1. Working directory: #{repo_path}
    2. Create branch: `git checkout -b #{branch_name}`
    3. Fix the violations listed above
    4. Run `mix compile --warnings-as-errors` — must pass
    5. Run `mix test` — must pass
    6. Stage ONLY the files you changed (NO `git add .` or `git add -A`)
    7. Commit with message: "fix(convergence): #{fitness_name} — #{String.slice(detail, 0, 50)}"
    8. Push the branch: `git push origin #{branch_name}`
    9. Create a **draft** PR on #{@daemon_repo} with:
       - Title: "[ConvergenceEngine] Fix #{fitness_name}"
       - Body must include:
         ```
         ## Provenance
         - Fitness function: #{fitness_name}
         - Description: #{description}
         - Score: #{Float.round(score, 3)}
         - Source: ConvergenceEngine (deterministic fitness check)

         ## Evidence
         #{detail}

         ---
         *Auto-generated by ConvergenceEngine from fitness function violation.*
         ```

    ### SAFETY CONSTRAINTS (CRITICAL — NEVER VIOLATE)
    - NEVER push to main
    - NEVER modify these paths:
      #{protected_list}
    - If `mix test` fails after your changes, revert ALL changes and report failure
    - If you cannot implement the change safely, report why and stop
    """
  end

  # ── Repair Result Handling ───────────────────────────────────

  defp handle_repair_result(ref, result, state) do
    case state.pending_repair do
      {^ref, fitness_name, started_at} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        case result do
          {:ok, _output, branch_name} ->
            case verify_repair_safety(branch_name) do
              :safe ->
                Logger.info(
                  "[ConvergenceEngine] Repair PR created: #{branch_name} (#{duration_ms}ms)"
                )

                DecisionJournal.record_outcome(branch_name, :success, %{fitness_name: fitness_name})

                %{
                  state
                  | pending_repair: nil,
                    repairs_today: state.repairs_today + 1,
                    total_repairs: state.total_repairs + 1,
                    consecutive_failures: 0
                }

              {:unsafe, violations} ->
                Logger.warning(
                  "[ConvergenceEngine] SAFETY VIOLATION on #{branch_name}: #{inspect(violations)} — deleting branch"
                )

                delete_branch(branch_name)
                DecisionJournal.record_outcome(branch_name, :failure, %{reason: :safety_violation})
                state = %{state | pending_repair: nil, consecutive_failures: state.consecutive_failures + 1}
                maybe_trip_circuit_breaker(state)
            end

          {:error, reason} ->
            Logger.warning(
              "[ConvergenceEngine] Repair failed for '#{fitness_name}': #{inspect(reason)} (#{duration_ms}ms)"
            )

            branch_name = case state.pending_repair do
              {_, name, _} -> "convergence/#{name}"
              _ -> "convergence/unknown"
            end
            DecisionJournal.record_outcome(branch_name, :failure, %{reason: inspect(reason)})

            state = %{state | pending_repair: nil, consecutive_failures: state.consecutive_failures + 1}
            maybe_trip_circuit_breaker(state)
        end

      _ ->
        # Unknown ref — ignore
        state
    end
  rescue
    e ->
      Logger.warning("[ConvergenceEngine] Error handling repair result: #{Exception.message(e)}")
      %{state | pending_repair: nil}
  end

  # ── Safety Gate ──────────────────────────────────────────────

  defp verify_repair_safety(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    case System.cmd("git", ["diff", "--name-only", "main...#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {diff, 0} ->
        changed_files = String.split(diff, "\n", trim: true)

        violations =
          Enum.filter(changed_files, fn f ->
            Enum.any?(protected_paths(), &Regex.match?(&1, f))
          end)

        if violations == [], do: :safe, else: {:unsafe, violations}

      {error, _code} ->
        Logger.warning(
          "[ConvergenceEngine] Safety check git diff failed: #{String.slice(error, 0, 200)}"
        )

        {:unsafe, ["(unable to verify — git diff failed)"]}
    end
  rescue
    _ -> {:unsafe, ["(unable to verify — exception)"]}
  end

  defp delete_branch(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))
    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  # ── Cooldown & Circuit Breaker ───────────────────────────────

  defp on_cooldown?(fitness_name, state) do
    case Map.get(state.repair_history, fitness_name) do
      nil ->
        false

      last_attempt ->
        hours_since = DateTime.diff(DateTime.utc_now(), last_attempt, :hour)
        hours_since < @cooldown_hours
    end
  end

  defp circuit_breaker_active?(state) do
    case state.circuit_breaker_until do
      nil -> false
      until -> DateTime.compare(DateTime.utc_now(), until) == :lt
    end
  end

  defp maybe_trip_circuit_breaker(state) do
    if state.consecutive_failures >= @max_consecutive_failures do
      until = DateTime.add(DateTime.utc_now(), @circuit_breaker_hours * 3600, :second)

      Logger.warning(
        "[ConvergenceEngine] Circuit breaker tripped after #{state.consecutive_failures} consecutive failures — disabled until #{until}"
      )

      %{state | circuit_breaker_until: until}
    else
      state
    end
  end

  # ── Daily Reset ──────────────────────────────────────────────

  defp maybe_reset_daily_counter(state) do
    today = Date.utc_today()

    if Date.compare(today, state.last_day_reset) != :eq do
      %{state | repairs_today: 0, last_day_reset: today}
    else
      state
    end
  end

  # ── Scheduling ───────────────────────────────────────────────

  defp schedule_next_cycle do
    Process.send_after(self(), :cycle, @poll_interval_ms)
  end
end
