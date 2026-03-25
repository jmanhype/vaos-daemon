defmodule Daemon.Commands.Proactive do
  @moduledoc """
  `/proactive` and `/activity` slash commands.
  """

  alias Daemon.Agent.ProactiveMode

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @green IO.ANSI.green()
  @yellow IO.ANSI.yellow()

  def cmd_proactive(arg, _session_id) do
    arg = String.trim(arg)

    case arg do
      "on" ->
        ProactiveMode.enable()
        {:command, "#{@green}  proactive mode: enabled#{@reset}\n#{@dim}  OSA will greet you, work autonomously, and notify you of results.#{@reset}"}

      "off" ->
        ProactiveMode.disable()
        {:command, "#{@yellow}  proactive mode: disabled#{@reset}"}

      "" ->
        render_status()

      _ ->
        {:command, "#{@yellow}  Usage: /proactive [on|off]#{@reset}"}
    end
  end

  def cmd_activity(arg, _session_id) do
    arg = String.trim(arg)

    case arg do
      "clear" ->
        ProactiveMode.clear_activity_log()
        {:command, "#{@dim}  Activity log cleared#{@reset}"}

      "" ->
        render_activity()

      _ ->
        {:command, "#{@yellow}  Usage: /activity [clear]#{@reset}"}
    end
  end

  defp render_status do
    status = ProactiveMode.status()

    enabled_str = if status.enabled, do: "#{@green}enabled#{@reset}", else: "#{@dim}disabled#{@reset}"

    lines = [
      "#{@bold}#{@cyan}  Proactive Mode#{@reset}",
      "  Status: #{enabled_str}",
      "  Greeting: #{if status.greeting_enabled, do: "on", else: "off"}",
      "  Autonomous work: #{if status.autonomous_work, do: "on", else: "off"}",
      "  Permission tier: #{status.permission_tier}",
      "  Messages this hour: #{status.messages_this_hour}/#{status.max_messages_per_hour}",
      "  Activity log: #{status.activity_log_count} entries",
      "  Pending notifications: #{status.pending_notifications}"
    ]

    # Scheduler info
    lines =
      case status[:scheduler] do
        %{} = s ->
          lines ++
            [
              "",
              "#{@bold}  Scheduler#{@reset}",
              "  Cron jobs: #{Map.get(s, :cron_active, 0)}/#{Map.get(s, :cron_total, 0)} active",
              "  Triggers: #{Map.get(s, :trigger_active, 0)}/#{Map.get(s, :trigger_total, 0)} active",
              "  Heartbeat pending: #{Map.get(s, :heartbeat_pending, 0)}"
            ]

        _ ->
          lines
      end

    {:command, Enum.join(lines, "\n")}
  end

  defp render_activity do
    log = ProactiveMode.activity_log()

    if log == [] do
      {:command, "#{@dim}  No activity logged yet.#{@reset}"}
    else
      header = "#{@bold}#{@cyan}  Activity Log#{@reset} (#{length(log)} entries)\n"

      entries =
        log
        |> Enum.take(20)
        |> Enum.map(fn entry ->
          ts = entry["ts"] || ""
          # Show just time portion
          time =
            case String.split(ts, "T") do
              [_, time_part] -> String.slice(time_part, 0, 8)
              _ -> ts
            end

          type = entry["type"] || "?"
          msg = entry["message"] || ""

          type_color =
            cond do
              String.contains?(type, "complete") -> @green
              String.contains?(type, "fail") -> @yellow
              String.contains?(type, "alert") -> @yellow
              true -> @dim
            end

          "  #{@dim}#{time}#{@reset} #{type_color}[#{type}]#{@reset} #{msg}"
        end)
        |> Enum.join("\n")

      more =
        if length(log) > 20,
          do: "\n#{@dim}  ... and #{length(log) - 20} more#{@reset}",
          else: ""

      {:command, header <> entries <> more}
    end
  end
end
