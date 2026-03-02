defmodule OptimalSystemAgent.Commands.Info do
  @moduledoc """
  Informational commands: /help, /status, /skills, /memory, /soul, /cortex.

  All functions follow the `(arg, session_id) -> command_result` convention.
  Formatting helpers used only by these commands are also defined here.
  """

  @doc "Handle the `/help` and `/commands` command."
  def cmd_help(_arg, _session_id) do
    custom_cmds =
      try do
        :ets.tab2list(:osa_commands)
        |> Enum.map(fn {name, _template, desc} -> {name, desc} end)
      rescue
        ArgumentError -> []
      end

    custom_section =
      if custom_cmds != [] do
        lines =
          Enum.map_join(custom_cmds, "\n", fn {n, d} ->
            "  /#{String.pad_trailing(n, 18)} #{d}"
          end)

        "\nCustom:\n#{lines}\n"
      else
        ""
      end

    output =
      """
      Info:
        /status             System status
        /skills             List available skills
        /memory             Memory statistics
        /soul               Show personality config
        /doctor             System diagnostics

      Model & Provider:
        /model              Show active provider + model
        /model list         List all providers with status
        /model <provider>   Switch provider (e.g. /model anthropic)
        /model <p> <model>  Switch provider + model
        /models             List installed Ollama models
        /model ollama-url   Set Ollama URL (cloud support)

      Session:
        /new                Start a fresh session
        /sessions           List stored sessions
        /resume <id>        Resume a previous session
        /history            Browse conversation history
        /history <id>       View messages in a session
        /history search <q> Search all messages

      Channels:
        /channels                  List all channel adapters
        /channels connect <name>   Start a channel adapter
        /channels disconnect <n>   Stop a channel adapter
        /channels status <name>    Detailed channel status
        /channels test <name>      Verify channel responding
        /whatsapp                  WhatsApp Web status
        /whatsapp connect          Connect via QR code
        /whatsapp disconnect       Logout + stop
        /whatsapp test             Verify connection

      Context:
        /compact            Context compaction stats
        /usage              Token usage breakdown
        /cortex             Cortex bulletin & topics

      Configuration:
        /verbose            Toggle verbose output
        /think <level>      Set reasoning depth (fast/normal/deep)
        /plan               Toggle autonomous plan mode
        /config             Show runtime configuration
        /setup              Run channel setup wizard
        /reload             Reload soul + prompt files from disk

      Agents:
        /agents             List all agents in the roster
        /agents <name>      Show agent details
        /tiers              Show model tier configuration
        /swarms             List swarm presets
        /hooks              Hook pipeline status
        /learning           Learning engine metrics

      Budget & Providers:
        /budget             Token and cost budget status
        /providers          List all LLM providers with status
        /thinking           Toggle extended thinking mode
        /export [file]      Export session to file
        /machines           List connected machines and fleet

      Scheduler:
        /schedule           Scheduler overview (crons, triggers, heartbeat)
        /cron               List cron jobs
        /cron add           Create a new cron job
        /cron run <id>      Execute a cron job immediately
        /cron enable <id>   Enable a cron job
        /cron disable <id>  Disable a cron job
        /cron remove <id>   Remove a cron job
        /triggers           List event triggers
        /triggers add       Create a new trigger
        /triggers remove <id>  Remove a trigger
        /heartbeat          Show heartbeat tasks + next run
        /heartbeat add <t>  Add a heartbeat task

      Commands:
        /create-command     Create a custom slash command
      #{custom_section}
      Examples:
        /agents backend-go              Show the Go backend agent details
        /models                         List Ollama models on your machine
        /model ollama qwen3:32b         Switch to a specific local model
        /model anthropic                Switch to Anthropic Claude
        /create-command standup | Daily standup | Summarize my recent activity
      """
      |> String.trim_trailing()

    {:command, output}
  end

  @doc "Handle the `/status` command."
  def cmd_status(_arg, _session_id) do
    providers = OptimalSystemAgent.Providers.Registry.list_providers()
    skills = OptimalSystemAgent.Tools.Registry.list_tools_direct()
    memory_stats = OptimalSystemAgent.Agent.Memory.memory_stats()
    soul_loaded = if OptimalSystemAgent.Soul.identity(), do: "yes", else: "defaults"

    output =
      """
      System Status:
        providers:  #{length(providers)} loaded
        tools:      #{length(skills)} available
        sessions:   #{memory_stats[:session_count] || 0} stored
        memory:     #{memory_stats[:long_term_size] || 0} bytes
        soul:       #{soul_loaded}
        http:       port #{Application.get_env(:optimal_system_agent, :http_port, 8089)}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/skills` command."
  def cmd_skills(arg, _session_id) do
    trimmed = String.trim(arg)

    case trimmed do
      "" ->
        skills = OptimalSystemAgent.Tools.Registry.list_tools_direct()

        output =
          if skills == [] do
            "No tools loaded."
          else
            header = "Available tools (#{length(skills)}):\n"

            body =
              Enum.map_join(skills, "\n", fn skill ->
                "  #{String.pad_trailing(skill.name, 18)} #{String.slice(skill.description, 0, 60)}"
              end)

            header <> body
          end

        {:command, output}

      "list" ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "list"}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "reload" ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "reload"}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "search " <> query ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "search", "query" => query}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "enable " <> name ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "enable", "name" => String.trim(name)}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "disable " <> name ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "disable", "name" => String.trim(name)}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "delete " <> name ->
        case OptimalSystemAgent.Tools.Builtins.SkillManager.execute(%{"action" => "delete", "name" => String.trim(name)}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      _ ->
        {:command,
         "Unknown /skills subcommand: #{trimmed}\n\nUsage:\n  /skills              List all tools\n  /skills list         List custom skills with status\n  /skills search <q>   Search past sessions\n  /skills enable <n>   Enable a skill\n  /skills disable <n>  Disable a skill\n  /skills delete <n>   Delete a skill\n  /skills reload       Reload skills from disk"}
    end
  end

  @doc "Handle the `/memory` command."
  def cmd_memory(_arg, _session_id) do
    stats = OptimalSystemAgent.Agent.Memory.memory_stats()

    output =
      """
      Memory:
        sessions:    #{stats[:session_count] || 0}
        long-term:   #{stats[:long_term_size] || 0} bytes
        categories:  #{format_categories(stats[:categories])}
        index keys:  #{stats[:index_keywords] || 0}
      """
      |> String.trim()

    {:command, output}
  end

  @doc "Handle the `/soul` command."
  def cmd_soul(_arg, _session_id) do
    identity = OptimalSystemAgent.Soul.identity()
    soul = OptimalSystemAgent.Soul.soul()
    user = OptimalSystemAgent.Soul.user()

    parts = []

    parts =
      if identity do
        ["IDENTITY.md: loaded (#{String.length(identity)} chars)" | parts]
      else
        ["IDENTITY.md: using defaults" | parts]
      end

    parts =
      if soul do
        ["SOUL.md: loaded (#{String.length(soul)} chars)" | parts]
      else
        ["SOUL.md: using defaults" | parts]
      end

    parts =
      if user do
        ["USER.md: loaded (#{String.length(user)} chars)" | parts]
      else
        ["USER.md: not found" | parts]
      end

    {:command, "Soul configuration:\n  " <> Enum.join(Enum.reverse(parts), "\n  ")}
  end

  @doc "Handle the `/cortex` command."
  def cmd_cortex(_arg, _session_id) do
    bulletin = OptimalSystemAgent.Agent.Cortex.bulletin()
    topics = OptimalSystemAgent.Agent.Cortex.active_topics()
    stats = OptimalSystemAgent.Agent.Cortex.synthesis_stats()

    parts = []

    parts =
      if bulletin do
        ["Bulletin:\n#{indent(bulletin, 4)}" | parts]
      else
        ["Bulletin: (not yet generated — waiting for first synthesis cycle)" | parts]
      end

    parts =
      if topics != [] do
        topic_list =
          topics
          |> Enum.take(10)
          |> Enum.map_join("\n", fn t ->
            "    #{t[:topic] || t.topic}  (#{t[:frequency] || t.frequency}x)"
          end)

        ["Active topics:\n#{topic_list}" | parts]
      else
        parts
      end

    parts = [
      "Stats: last refresh #{format_timestamp(stats[:last_refresh])}, #{stats[:bulletin_bytes] || 0} bytes, #{stats[:active_topic_count] || 0} topics"
      | parts
    ]

    {:command, Enum.reverse(parts) |> Enum.join("\n\n")}
  end

  # ── Formatting Helpers ─────────────────────────────────────────

  @doc "Format a DateTime or nil for display."
  def format_timestamp(nil), do: "never"
  def format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  def format_timestamp(str) when is_binary(str), do: str
  def format_timestamp(_), do: "unknown"

  @doc "Format memory category map for display."
  def format_categories(nil), do: "none"

  def format_categories(cats) when is_map(cats) do
    cats
    |> Enum.map_join(", ", fn {k, v} -> "#{k}:#{v}" end)
  end

  def format_categories(_), do: "none"

  @doc "Format compactor pipeline steps map for display."
  def format_pipeline_steps(nil), do: "none"
  def format_pipeline_steps(steps) when is_map(steps) and map_size(steps) == 0, do: "none"

  def format_pipeline_steps(steps) when is_map(steps) do
    steps
    |> Enum.map_join(", ", fn {k, v} -> "#{k}:#{v}" end)
  end

  def format_pipeline_steps(_), do: "none"

  @doc "Indent all lines of `text` by `spaces` spaces."
  def indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> pad <> line end)
  end
end
