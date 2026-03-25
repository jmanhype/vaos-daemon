defmodule Daemon.Commands.Config do
  @moduledoc """
  Configuration-related commands: verbose, plan, think, config, compact, usage.
  """

  require Logger

  @doc "Handle the `/verbose` command."
  def cmd_verbose(_arg, session_id) do
    current = Daemon.Commands.get_setting(session_id, :verbose, false)
    new_value = !current
    Daemon.Commands.put_setting(session_id, :verbose, new_value)
    {:command, "Verbose mode: #{if new_value, do: "on", else: "off"}"}
  end

  @doc "Handle the `/plan` command."
  def cmd_plan(_arg, session_id) do
    case GenServer.call(
           {:via, Registry, {Daemon.SessionRegistry, session_id}},
           :toggle_plan_mode
         ) do
      {:ok, true} ->
        {:command, "Plan mode enabled — complex tasks will show plans for approval"}

      {:ok, false} ->
        {:command, "Plan mode disabled — all tasks execute immediately"}
    end
  rescue
    _ -> {:command, "Plan mode toggle failed — no active session"}
  end

  @doc "Handle the `/think` command."
  def cmd_think(arg, session_id) do
    level = String.trim(arg) |> String.downcase()

    case level do
      "" ->
        current = Daemon.Commands.get_setting(session_id, :think_level, "normal")
        {:command, "Current reasoning depth: #{current}\n\nUsage: /think fast|normal|deep"}

      l when l in ["fast", "normal", "deep"] ->
        Daemon.Commands.put_setting(session_id, :think_level, l)

        desc =
          case l do
            "fast" -> "quick responses, minimal deliberation"
            "normal" -> "balanced reasoning and speed"
            "deep" -> "thorough analysis, extended thinking"
          end

        {:command, "Reasoning depth: #{l} (#{desc})"}

      _ ->
        {:command, "Unknown level: #{level}\n\nUsage: /think fast|normal|deep"}
    end
  end

  @doc "Handle the `/config` command."
  def cmd_config(_arg, session_id) do
    verbose = Daemon.Commands.get_setting(session_id, :verbose, false)
    think = Daemon.Commands.get_setting(session_id, :think_level, "normal")
    provider = Application.get_env(:daemon, :default_provider, "unknown")
    max_tokens = Application.get_env(:daemon, :max_context_tokens, 128_000)
    max_iter = Application.get_env(:daemon, :max_iterations, 30)
    http_port = Application.get_env(:daemon, :http_port, 8089)
    sandbox = Application.get_env(:daemon, :sandbox_enabled, false)

    output =
      """
      Runtime Configuration:
        session:       #{session_id}
        verbose:       #{verbose}
        think level:   #{think}
        provider:      #{provider}
        max tokens:    #{format_number(max_tokens)}
        max iterations: #{max_iter}
        http port:     #{http_port}
        sandbox:       #{sandbox}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/compact` command."
  def cmd_compact(_arg, _session_id) do
    stats = Daemon.Agent.Compactor.stats()

    output =
      """
      Context Compactor:
        compactions:     #{stats[:compaction_count] || 0}
        tokens saved:    #{stats[:tokens_saved] || 0}
        last compacted:  #{Daemon.Commands.Info.format_timestamp(stats[:last_compacted_at])}
        pipeline steps:  #{Daemon.Commands.Info.format_pipeline_steps(stats[:pipeline_steps_used])}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/usage` command."
  def cmd_usage(_arg, session_id) do
    compactor_stats = Daemon.Agent.Compactor.stats()
    memory_stats = Daemon.Agent.Memory.memory_stats()
    max_tokens = Application.get_env(:daemon, :max_context_tokens, 128_000)

    context_line =
      try do
        case Registry.lookup(Daemon.SessionRegistry, session_id) do
          [{pid, _}] ->
            state = :sys.get_state(pid)
            estimated = Daemon.Agent.Compactor.estimate_tokens(state.messages)
            util = if max_tokens > 0, do: Float.round(estimated / max_tokens * 100, 1), else: 0.0
            bar = context_utilization_bar(util)
            "  context now:   #{bar} #{format_number(estimated)}/#{format_number(max_tokens)} (#{util}%)"

          _ ->
            nil
        end
      rescue
        _ -> nil
      end

    lines = [
      "Token Usage:",
      "  max context:     #{format_number(max_tokens)} tokens",
      "  tokens saved:    #{format_number(compactor_stats[:tokens_saved] || 0)} (via compaction)",
      "  compactions:     #{compactor_stats[:compaction_count] || 0}",
      "  sessions stored: #{memory_stats[:session_count] || 0}",
      "  memory on disk:  #{format_bytes(memory_stats[:long_term_size] || 0)}"
    ]

    lines =
      if context_line,
        do: [Enum.at(lines, 0)] ++ [context_line] ++ Enum.drop(lines, 1),
        else: lines

    {:command, Enum.join(lines, "\n")}
  end

  # ── Formatting Helpers ──────────────────────────────────────────

  @doc false
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(n), do: "#{n}"

  @doc false
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} bytes"
  def format_bytes(_), do: "0 bytes"

  @doc false
  def context_utilization_bar(util) do
    filled = round(util / 5) |> min(20) |> max(0)
    empty = 20 - filled

    cond do
      util >= 90.0 ->
        "#{IO.ANSI.red()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      util >= 70.0 ->
        "#{IO.ANSI.yellow()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"

      true ->
        "#{IO.ANSI.green()}[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}]#{IO.ANSI.reset()}"
    end
  end

  @doc """
  Handle the `/tier` command.

  Sets the permission tier for the current session, controlling which tools
  the agent is allowed to execute.

      /tier             — show current tier
      /tier full        — all tools enabled (default)
      /tier workspace   — read + local file writes, no network/shell
      /tier read_only   — read-only tools only, no writes

  """
  def cmd_tier(arg, session_id) do
    raw = arg |> String.trim() |> String.downcase()

    if raw == "" do
      # Show current tier
      case GenServer.call(
             {:via, Registry, {Daemon.SessionRegistry, session_id}},
             {:get_permission_tier},
             5_000
           ) do
        {:ok, tier} ->
          desc = tier_description(tier)
          {:command, "Current permission tier: #{tier}\n#{desc}\n\nUsage: /tier full|workspace|read_only"}

        _ ->
          {:command, "Permission tier: full (default)\n\nUsage: /tier full|workspace|read_only"}
      end
    else
      tier =
        case raw do
          "full" -> :full
          "workspace" -> :workspace
          "read_only" -> :read_only
          "readonly" -> :read_only
          _ -> :unknown
        end

      if tier == :unknown do
        {:command, "Unknown tier: #{raw}\n\nUsage: /tier full|workspace|read_only"}
      else
        case GenServer.call(
               {:via, Registry, {Daemon.SessionRegistry, session_id}},
               {:set_permission_tier, tier},
               5_000
             ) do
          {:ok, ^tier} ->
            {:command, "Permission tier set to: #{tier}\n#{tier_description(tier)}"}

          _ ->
            {:command, "Failed to set permission tier — is there an active session?"}
        end
      end
    end
  rescue
    _ -> {:command, "Permission tier change failed — no active session"}
  end

  defp tier_description(:full),
    do: "  All tools enabled — no restrictions."

  defp tier_description(:workspace),
    do: "  Read + local file/git writes allowed. Network and shell tools are blocked."

  defp tier_description(:read_only),
    do: "  Read-only tools only. No writes, no network, no shell execution."

  defp tier_description(_), do: ""
end
