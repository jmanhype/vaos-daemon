defmodule OptimalSystemAgent.Agent.Scheduler.Heartbeat do
  @moduledoc """
  Heartbeat execution and HEARTBEAT.md management.

  Reads `~/.osa/HEARTBEAT.md` every tick, runs pending checklist tasks through
  the agent loop, and marks completed items in the file. Quiet-hours suppression
  is checked before each run via HeartbeatState.
  """
  require Logger

  alias OptimalSystemAgent.Agent.HeartbeatState
  alias OptimalSystemAgent.Agent.Scheduler.JobExecutor
  alias OptimalSystemAgent.Events.Bus

  @circuit_breaker_limit 3

  defp heartbeat_interval,
    do: Application.get_env(:optimal_system_agent, :heartbeat_interval, 1_800_000)

  defp config_dir,
    do: Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()

  # ── Public API ────────────────────────────────────────────────────────

  @doc "Get the path to the HEARTBEAT.md file."
  def path do
    Path.expand(Path.join(config_dir(), "HEARTBEAT.md"))
  end

  @doc """
  Run a heartbeat cycle against the given scheduler state. Checks quiet hours,
  reads pending tasks, executes them, and marks completions. Returns updated state.
  """
  def run(state) do
    quiet =
      try do
        HeartbeatState.in_quiet_hours?()
      catch
        :exit, _ -> false
      end

    if quiet do
      Logger.debug("[Scheduler] Heartbeat suppressed — quiet hours active")
      return = %{state | last_run: DateTime.utc_now()}

      try do
        HeartbeatState.record_check(:heartbeat, :suppressed_quiet_hours)
      catch
        :exit, _ -> :ok
      end

      return
    else
      run_heartbeat_tasks(state)
    end
  end

  @doc "Ensure the HEARTBEAT.md file exists, creating it with a template if not."
  def ensure_heartbeat_file do
    heartbeat_path = path()
    dir = Path.dirname(heartbeat_path)
    File.mkdir_p!(dir)

    unless File.exists?(heartbeat_path) do
      File.write!(heartbeat_path, """
      # Heartbeat Tasks

      Add tasks here as a markdown checklist. OSA checks this file every #{div(heartbeat_interval(), 60_000)} minutes
      and executes any unchecked items through the agent loop.

      ## Periodic Tasks

      <!-- Example tasks (uncomment to activate):
      - [ ] Check for new emails and summarize urgent ones
      - [ ] Review today's calendar and prepare a briefing
      -->
      """)
    end
  end

  # ── Private Helpers ───────────────────────────────────────────────────

  defp run_heartbeat_tasks(state) do
    heartbeat_path = path()

    if File.exists?(heartbeat_path) do
      content = File.read!(heartbeat_path)
      tasks = parse_pending_tasks(content)

      if tasks == [] do
        Logger.debug("Heartbeat: no pending tasks")
        %{state | last_run: DateTime.utc_now()}
      else
        Logger.info("Heartbeat: #{length(tasks)} pending task(s)")

        Bus.emit(:system_event, %{
          event: :heartbeat_started,
          task_count: length(tasks)
        })

        {completed, state} =
          Enum.reduce(tasks, {[], state}, fn task, {done, acc} ->
            failures = Map.get(acc.failures, task, 0)

            if failures >= @circuit_breaker_limit do
              Logger.warning(
                "Heartbeat: skipping '#{task}' — circuit breaker open (#{failures} failures)"
              )

              {done, acc}
            else
              case JobExecutor.execute_task(task, "heartbeat_#{System.system_time(:second)}") do
                {:ok, _result} ->
                  Logger.info("Heartbeat: completed '#{task}'")
                  {[task | done], %{acc | failures: Map.delete(acc.failures, task)}}

                {:error, reason} ->
                  Logger.warning("Heartbeat: failed '#{task}' — #{reason}")
                  {done, %{acc | failures: Map.put(acc.failures, task, failures + 1)}}
              end
            end
          end)

        if completed != [] do
          updated = mark_completed(content, completed)
          File.write!(heartbeat_path, updated)
        end

        Bus.emit(:system_event, %{
          event: :heartbeat_completed,
          completed: length(completed),
          total: length(tasks)
        })

        result = %{completed: length(completed), total: length(tasks)}

        try do
          HeartbeatState.record_check(:heartbeat, result)
        catch
          :exit, _ -> :ok
        end

        %{state | last_run: DateTime.utc_now()}
      end
    else
      %{state | last_run: DateTime.utc_now()}
    end
  end

  @doc "Parse HEARTBEAT.md content and return the list of pending (unchecked) task strings."
  def parse_pending_tasks(content) do
    content
    |> String.replace(~r/<!--[\s\S]*?-->/, "")
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^\s*-\s*\[\s*\]\s*.+/))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*-\s*\[\s*\]\s*/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp mark_completed(content, completed_tasks) do
    Enum.reduce(completed_tasks, content, fn task, acc ->
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      pattern = ~r/(-\s*)\[\s*\](\s*#{Regex.escape(task)})/
      replacement = "\\1[x]\\2 (completed #{timestamp})"
      String.replace(acc, pattern, replacement, global: false)
    end)
  end
end
