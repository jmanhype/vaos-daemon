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
  alias Daemon.Agent.WorkDirector.Source
  alias Daemon.Agent.Orchestrator
  @backlog_refresh_ms :timer.minutes(10)
  @pr_poll_ms :timer.hours(1)
  @initial_delay_ms :timer.seconds(60)
  @max_dispatches_per_day 5
  @max_completed_prs 50
  @circuit_breaker_threshold 5
  @circuit_breaker_ms :timer.hours(24)
  @pact_poll_interval_ms :timer.seconds(30)
  @pact_max_wait_ms :timer.minutes(10)
  @daemon_repo "jmanhype/vaos-daemon"

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
      arms: %{
        vision: %{a: 1.0, b: 1.0},
        issues: %{a: 1.0, b: 1.0},
        investigation: %{a: 1.0, b: 1.0},
        fitness: %{a: 1.0, b: 1.0},
        manual: %{a: 2.0, b: 1.0}
      },
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

    if enabled do
      Logger.info("[WorkDirector] Started (enabled=true)")
      Process.send_after(self(), :bootstrap, @initial_delay_ms)
    else
      Logger.info("[WorkDirector] Started (enabled=false)")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    # Start buffers for event-driven sources
    {:ok, inv_buffer} = Source.Investigation.start_buffer()
    {:ok, manual_buffer} = Source.Manual.start_buffer()

    # Subscribe to investigation_complete events
    investigation_ref =
      try do
        handler = fn event ->
          # Extract finding data from event
          data = Map.get(event, :data, Map.get(event, "data", %{}))
          Source.Investigation.push(inv_buffer, data)
        end

        Daemon.Events.Bus.register_handler(:investigation_complete, handler)
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    # Load persisted backlog
    persisted = Backlog.load()

    state = %{state |
      investigation_buffer: inv_buffer,
      manual_buffer: manual_buffer,
      investigation_ref: investigation_ref,
      backlog: persisted
    }

    # Initial backlog refresh
    state = refresh_backlog(state)

    # Schedule recurring timers
    schedule_refresh()
    schedule_pr_poll()

    # Start the dispatch loop
    send(self(), :try_dispatch)

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
        case Backlog.pick_next(state.backlog, state.arms) do
          :empty ->
            {:noreply, state}

          {:ok, item} ->
            state = dispatch_item(state, item)
            {:noreply, state}
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

              state
              |> update_backlog_completed(dispatch.content_hash, {:ok, branch})
              |> reward_arm(dispatch.source, 0.3)
              |> add_completed_pr(branch, dispatch.source, dispatch.content_hash)
              |> Map.put(:consecutive_failures, 0)
              |> Map.update!(:total_dispatches, &(&1 + 1))

            :unsafe ->
              Logger.warning("[WorkDirector] Safety violation in #{branch}, deleting branch")
              delete_branch(branch)

              state
              |> update_backlog_completed(dispatch.content_hash, {:safety_violation, branch})
              |> reward_arm(dispatch.source, 0.0)
              |> Map.put(:consecutive_failures, 0)
          end

        {:error, reason} ->
          Logger.warning("[WorkDirector] Dispatch failed: #{inspect(reason)}")
          failures = state.consecutive_failures + 1

          state
          |> update_backlog_failed(dispatch.content_hash)
          |> Map.put(:consecutive_failures, failures)
          |> maybe_trip_circuit_breaker(failures)
      end

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
      arms: Enum.map(state.arms, fn {source, %{a: a, b: b}} ->
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
    # Fetch from static sources
    static_items = Source.fetch_all(@source_modules)

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
    session_id = "workdir-#{:erlang.unique_integer([:positive])}"
    prompt = build_prompt(item, branch)

    Logger.info("[WorkDirector] Dispatching: #{item.title} (source=#{item.source}, priority=#{item.base_priority})")

    parent = self()
    ref = make_ref()

    {_pid, _monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            case Orchestrator.execute(prompt, session_id, strategy: "pact") do
              {:ok, task_id} ->
                # PACT is fire-and-forget — poll progress until done
                case await_pact_completion(task_id) do
                  {:ok, output} -> {:ok, output, branch}
                  {:error, reason} -> {:error, reason}
                end

              {:error, reason} ->
                {:error, reason}
            end
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

  defp await_pact_completion(task_id) do
    deadline = System.monotonic_time(:millisecond) + @pact_max_wait_ms
    do_await_pact(task_id, deadline)
  end

  defp do_await_pact(task_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("[WorkDirector] PACT task #{task_id} timed out after #{div(@pact_max_wait_ms, 1000)}s")
      {:error, :pact_timeout}
    else
      Process.sleep(@pact_poll_interval_ms)

      try do
        case Orchestrator.progress(task_id) do
          {:ok, %{status: :completed} = progress} ->
            output = Map.get(progress, :result, "completed")
            {:ok, output}

          {:ok, %{status: :failed} = progress} ->
            error = Map.get(progress, :error, "unknown failure")
            {:error, {:pact_failed, error}}

          {:ok, _in_progress} ->
            do_await_pact(task_id, deadline)

          {:error, :not_found} ->
            # Task may have been cleaned up — check one more time after delay
            Process.sleep(5_000)

            case Orchestrator.progress(task_id) do
              {:error, :not_found} -> {:error, :task_not_found}
              other -> handle_progress_result(other, task_id, deadline)
            end
        end
      rescue
        _ -> do_await_pact(task_id, deadline)
      catch
        :exit, _ -> do_await_pact(task_id, deadline)
      end
    end
  end

  defp handle_progress_result({:ok, %{status: :completed} = progress}, _task_id, _deadline) do
    {:ok, Map.get(progress, :result, "completed")}
  end

  defp handle_progress_result({:ok, %{status: :failed} = progress}, _task_id, _deadline) do
    {:error, {:pact_failed, Map.get(progress, :error, "unknown")}}
  end

  defp handle_progress_result(_, task_id, deadline) do
    do_await_pact(task_id, deadline)
  end

  defp build_prompt(item, branch) do
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

    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    """
    #{source_context}

    ## Repository
    The codebase is located at: `#{repo_path}`
    All shell commands MUST use `cwd: "#{repo_path}"` or `cd #{repo_path} &&` prefix.
    This is an Elixir/OTP project using Mix.

    ## Task
    **#{item.title}**

    #{item.description}

    ## Instructions
    1. `cd #{repo_path}` then create branch `#{branch}` from main: `git checkout -b #{branch} main`
    2. Implement the changes described above
    3. Run `mix compile --warnings-as-errors` to verify compilation
    4. Run `mix test` for relevant test files
    5. Stage only the specific files you changed (no mix.lock, no config/)
    6. Commit with a descriptive message
    7. Push the branch: `git push origin #{branch}`
    8. Create a draft PR:
       ```
       gh pr create --draft --title "#{escape_shell(item.title)}" \\
         --repo #{@daemon_repo} \\
         --body "Source: #{item.source}\\nPriority: #{item.base_priority}\\n\\n#{escape_shell(String.slice(item.description, 0, 500))}"
       ```

    IMPORTANT: Do NOT modify any files in application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, or mix.lock.
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

  defp escape_shell(str) do
    String.replace(str, ~S("), ~S(\"))
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
    arms =
      Map.update(state.arms, source, %{a: 1.0, b: 1.0}, fn arm ->
        if reward > 0.5 do
          %{arm | a: arm.a + reward}
        else
          %{arm | b: arm.b + (1.0 - reward)}
        end
      end)

    %{state | arms: arms}
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
end
