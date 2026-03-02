defmodule OptimalSystemAgent.Commands.SchedulerCmd do
  @moduledoc """
  Scheduler commands: /schedule, /cron, /triggers, /heartbeat.

  Named SchedulerCmd to avoid collision with OptimalSystemAgent.Agent.Scheduler.
  """

  @doc "Handle the `/schedule` command — show scheduler overview."
  def cmd_schedule(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler

    case Scheduler.status() do
      %{} = s ->
        next_str = Calendar.strftime(s.next_heartbeat, "%Y-%m-%dT%H:%M:%SZ")
        diff_sec = DateTime.diff(s.next_heartbeat, DateTime.utc_now())
        in_str = format_duration(diff_sec)

        output =
          """
          Scheduler:
            Cron jobs:    #{s.cron_active} active (#{s.cron_total} total)
            Triggers:     #{s.trigger_active} active (#{s.trigger_total} total)
            Heartbeat:    #{s.heartbeat_pending} pending tasks
            Next beat:    #{next_str} (#{in_str})
          """
          |> String.trim()

        {:command, output}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  @doc "Handle the `/cron` command with subcommand routing."
  def cmd_cron(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        jobs = Scheduler.list_jobs()

        if jobs == [] do
          {:command, "No cron jobs configured.\n\nUse /cron add to create one."}
        else
          lines =
            Enum.map_join(jobs, "\n", fn job ->
              status =
                cond do
                  job["circuit_open"] -> "circuit-open"
                  job["enabled"] -> "enabled"
                  true -> "disabled"
                end

              "  #{String.pad_trailing(job["id"] || "?", 12)} " <>
                "#{String.pad_trailing(job["name"] || "", 24)} " <>
                "#{String.pad_trailing(job["schedule"] || "", 16)} [#{status}]"
            end)

          header = "Cron jobs (#{length(jobs)}):\n"
          footer = "\n\nCommands: /cron add | run | enable | disable | remove <id>"
          {:command, header <> lines <> footer}
        end

      trimmed == "add" ->
        {:prompt,
         "Create a new cron job. Provide: name, schedule (cron expression), type (agent/command/webhook), and the task/command/url."}

      String.starts_with?(trimmed, "remove ") ->
        id = String.trim(String.trim_leading(trimmed, "remove"))

        case Scheduler.remove_job(id) do
          :ok -> {:command, "Removed cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "enable ") ->
        id = String.trim(String.trim_leading(trimmed, "enable"))

        case Scheduler.toggle_job(id, true) do
          :ok -> {:command, "Enabled cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "disable ") ->
        id = String.trim(String.trim_leading(trimmed, "disable"))

        case Scheduler.toggle_job(id, false) do
          :ok -> {:command, "Disabled cron job: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      String.starts_with?(trimmed, "run ") ->
        id = String.trim(String.trim_leading(trimmed, "run"))

        case Scheduler.run_job(id) do
          {:ok, _result} -> {:command, "Cron job '#{id}' executed successfully."}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      true ->
        {:command,
         "Unknown cron subcommand: #{trimmed}\n\nUsage: /cron [add | run | enable | disable | remove] <id>"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  @doc "Handle the `/triggers` command with subcommand routing."
  def cmd_triggers(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        triggers = Scheduler.list_triggers()

        if triggers == [] do
          {:command, "No triggers configured.\n\nUse /triggers add to create one."}
        else
          lines =
            Enum.map_join(triggers, "\n", fn t ->
              status =
                cond do
                  t["circuit_open"] -> "circuit-open"
                  t["enabled"] -> "enabled"
                  true -> "disabled"
                end

              "  #{String.pad_trailing(t["id"] || "?", 12)} " <>
                "#{String.pad_trailing(t["name"] || "", 24)} " <>
                "#{String.pad_trailing(t["event"] || "", 16)} [#{status}]"
            end)

          header = "Triggers (#{length(triggers)}):\n"
          footer = "\n\nCommands: /triggers add | remove <id>"
          {:command, header <> lines <> footer}
        end

      trimmed == "add" ->
        {:prompt,
         "Create a new event trigger. Provide: name, event to watch for, type (agent/command), and the action (job description or command)."}

      String.starts_with?(trimmed, "remove ") ->
        id = String.trim(String.trim_leading(trimmed, "remove"))

        case Scheduler.remove_trigger(id) do
          :ok -> {:command, "Removed trigger: #{id}"}
          {:error, reason} -> {:command, "Failed: #{reason}"}
        end

      true ->
        {:command,
         "Unknown triggers subcommand: #{trimmed}\n\nUsage: /triggers [add | remove <id>]"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  @doc "Handle the `/heartbeat` command."
  def cmd_heartbeat(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Scheduler
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        path = Scheduler.heartbeat_path()

        content =
          case File.read(path) do
            {:ok, c} -> c
            _ -> "(file not found)"
          end

        next = Scheduler.next_heartbeat_at()
        next_str = Calendar.strftime(next, "%Y-%m-%dT%H:%M:%SZ")
        diff_sec = DateTime.diff(next, DateTime.utc_now())
        in_str = format_duration(diff_sec)

        output =
          """
          #{String.trim(content)}

          Next heartbeat: #{next_str} (#{in_str})
          """
          |> String.trim()

        {:command, output}

      String.starts_with?(trimmed, "add ") ->
        text = String.trim(String.trim_leading(trimmed, "add"))

        if text == "" do
          {:command, "Usage: /heartbeat add <task description>"}
        else
          case Scheduler.add_heartbeat_task(text) do
            :ok -> {:command, "Added heartbeat task: #{text}"}
            {:error, reason} -> {:command, "Failed: #{reason}"}
          end
        end

      true ->
        {:command, "Unknown heartbeat subcommand: #{trimmed}\n\nUsage: /heartbeat [add <task>]"}
    end
  rescue
    _ -> {:command, "Scheduler not available."}
  end

  # ── Formatting helpers ──────────────────────────────────────────

  @doc "Format a seconds integer into a human-readable duration string."
  def format_duration(seconds) when seconds < 0, do: "now"
  def format_duration(seconds) when seconds < 60, do: "in #{seconds}s"
  def format_duration(seconds) when seconds < 3600, do: "in #{div(seconds, 60)} min"

  def format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "in #{hours}h #{mins}m"
  end
end
