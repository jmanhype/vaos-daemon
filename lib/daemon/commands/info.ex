defmodule Daemon.Commands.Info do
  @moduledoc """
  Informational commands: /help, /status, /skills, /memory, /soul, /cortex.

  All functions follow the `(arg, session_id) -> command_result` convention.
  Formatting helpers used only by these commands are also defined here.
  """

  alias Daemon.Intelligence.AdaptationTrials
  alias Daemon.Intelligence.DecisionJournal

  @doc "Handle the `/help` and `/commands` command."
  def cmd_help(_arg, _session_id) do
    custom_cmds =
      try do
        :ets.tab2list(:daemon_commands)
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
        /status adaptation  Adaptation journal + meta-state
        /status adaptation review  Longitudinal adaptation review
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
  def cmd_status(arg, _session_id) do
    case String.trim(arg) do
      "adaptation review" ->
        {:command, format_adaptation_review(DecisionJournal.adaptation_review())}

      "adaptation" ->
        stats = DecisionJournal.stats()
        meta_state = Map.get(stats, :meta_state, DecisionJournal.meta_state())
        recent_events = DecisionJournal.adaptation_events(5)
        trial_snapshot = AdaptationTrials.snapshot()
        active_trial = Map.get(trial_snapshot, :current_trial)

        {:command,
         format_adaptation_status(meta_state, recent_events, stats, active_trial, trial_snapshot)}

      _ ->
        {:command, format_system_status()}
    end
  end

  @doc false
  def format_adaptation_review(review) do
    trials = Map.get(review, :trials, %{})
    promotions = Map.get(review, :promotions, %{})
    suppressions = Map.get(review, :suppressions, %{})

    [
      "Adaptation Review:",
      "  window:              #{format_review_window(review)}",
      "  trial hit rate:      #{format_rate_with_counts(Map.get(trials, :helpful_rate), Map.get(trials, :helpful, 0), Map.get(trials, :completed, 0), "helpful")}",
      "  blocked rate:        #{format_rate_with_ratio(Map.get(trials, :blocked_rate), Map.get(trials, :blocked, 0), Map.get(trials, :started, 0))}",
      "  expiry rate:         #{format_rate_with_ratio(Map.get(trials, :expiry_rate), Map.get(trials, :expired, 0), Map.get(trials, :started, 0))}",
      "  promotion keep rate: #{format_promotion_keep_rate(promotions)}",
      "  suppression hit rate: #{format_rate_with_ratio(Map.get(suppressions, :hit_rate), Map.get(suppressions, :hits, 0), Map.get(suppressions, :started, 0))}",
      "  domain skew:         #{format_domain_skew(Map.get(review, :domain_skew, []))}",
      "",
      "Positive signatures:",
      format_signature_section(Map.get(review, :positive_signatures, []), :positive),
      "",
      "Noisy signatures:",
      format_signature_section(Map.get(review, :noisy_signatures, []), :noisy)
    ]
    |> Enum.join("\n")
  end

  @doc false
  def format_adaptation_status(
        meta_state,
        recent_events,
        stats \\ %{},
        active_trial \\ nil,
        trial_snapshot \\ %{}
      ) do
    journal_status =
      case Map.get(stats, :status) do
        :running -> "running"
        _ -> "inactive"
      end

    last_experiment =
      case Map.get(meta_state, :last_experiment) do
        %{domain: domain, event_type: event_type, timestamp: timestamp} ->
          "#{domain} / #{event_type} @ #{format_timestamp(timestamp)}"

        _ ->
          "-"
      end

    recent_failed =
      meta_state
      |> Map.get(:recent_failed_adaptations, [])
      |> length()

    signals_stored =
      case Map.get(stats, :adaptation_event_count) do
        count when is_integer(count) -> count
        _ -> length(recent_events)
      end

    in_flight =
      case Map.get(stats, :in_flight_count) do
        count when is_integer(count) -> count
        _ -> 0
      end

    recent_signals =
      case recent_events do
        [] -> "  - none"
        events -> Enum.map_join(events, "\n", &format_adaptation_event/1)
      end

    lines =
      [
        "Adaptation Status:",
        "  journal:             #{journal_status}",
        "  authority:           #{format_presence(meta_state[:authority_domain])}",
        "  bottleneck:          #{format_presence(meta_state[:active_bottleneck])}",
        "  pivot reason:        #{format_presence(meta_state[:pivot_reason])}",
        "  steering hypothesis: #{format_presence(meta_state[:active_steering_hypothesis])}"
      ] ++
        maybe_trial_line(active_trial) ++
        maybe_promotion_line(trial_snapshot) ++
        maybe_suppression_line(trial_snapshot) ++
        [
          "  last updated:        #{format_presence(format_optional_timestamp(meta_state[:last_updated_at]))}",
          "  last experiment:     #{last_experiment}",
          "  failed adaptations:  #{recent_failed}",
          "  signals stored:      #{signals_stored}",
          "  decisions in flight: #{in_flight}",
          "",
          "Recent signals:",
          recent_signals
        ]

    Enum.join(lines, "\n")
  end

  defp format_adaptation_trial(trial) do
    trial_type = Map.get(trial, :trial_type) || Map.get(trial, "trial_type") || "trial"
    trigger_event = Map.get(trial, :trigger_event) || Map.get(trial, "trigger_event") || "-"
    status = Map.get(trial, :status) || Map.get(trial, "status") || :pending
    remaining_uses = Map.get(trial, :remaining_uses) || Map.get(trial, "remaining_uses") || 0
    use_label = if remaining_uses == 1, do: "use", else: "uses"
    "#{trial_type} via #{trigger_event} (#{status}, #{remaining_uses} #{use_label} left)"
  end

  defp maybe_trial_line(nil), do: []
  defp maybe_trial_line(trial), do: ["  active trial:        #{format_adaptation_trial(trial)}"]

  defp maybe_promotion_line(%{active_promotions: [promotion | _]}) do
    ["  promoted steering:   #{format_trial_promotion(promotion)}"]
  end

  defp maybe_promotion_line(_), do: []

  defp maybe_suppression_line(%{active_suppressions: [suppression | _]}) do
    ["  trial suppression:   #{format_trial_suppression(suppression)}"]
  end

  defp maybe_suppression_line(_), do: []

  defp format_trial_promotion(promotion) do
    trigger_event =
      Map.get(promotion, :trigger_event) || Map.get(promotion, "trigger_event") || "-"

    bottleneck = Map.get(promotion, :bottleneck) || Map.get(promotion, "bottleneck") || "-"

    helpful_streak =
      Map.get(promotion, :helpful_streak) || Map.get(promotion, "helpful_streak") || 0

    expires_at = Map.get(promotion, :expires_at) || Map.get(promotion, "expires_at")

    "#{trigger_event} / #{bottleneck} (#{helpful_streak} helpful) until #{format_presence(format_optional_timestamp(expires_at))}"
  end

  defp format_trial_suppression(suppression) do
    trigger_event =
      Map.get(suppression, :trigger_event) || Map.get(suppression, "trigger_event") || "-"

    bottleneck = Map.get(suppression, :bottleneck) || Map.get(suppression, "bottleneck") || "-"

    negative_streak =
      Map.get(suppression, :negative_streak) || Map.get(suppression, "negative_streak") || 0

    expires_at = Map.get(suppression, :expires_at) || Map.get(suppression, "expires_at")

    "#{trigger_event} / #{bottleneck} (#{negative_streak} negatives) until #{format_presence(format_optional_timestamp(expires_at))}"
  end

  defp format_system_status do
    providers = MiosaProviders.Registry.list_providers()
    skills = Daemon.Tools.Registry.list_tools_direct()
    memory_stats = Daemon.Agent.Memory.memory_stats()
    soul_loaded = if Daemon.Soul.identity(), do: "yes", else: "defaults"

    """
    System Status:
      providers:  #{length(providers)} loaded
      tools:      #{length(skills)} available
      sessions:   #{memory_stats[:session_count] || 0} stored
      memory:     #{memory_stats[:long_term_size] || 0} bytes
      soul:       #{soul_loaded}
      http:       port #{Application.get_env(:daemon, :http_port, 8089)}
    """
    |> String.trim()
  end

  @doc "Handle the `/skills` command."
  def cmd_skills(arg, _session_id) do
    trimmed = String.trim(arg)

    case trimmed do
      "" ->
        skills = Daemon.Tools.Registry.list_tools_direct()

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
        case Daemon.Tools.Builtins.SkillManager.execute(%{"action" => "list"}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "reload" ->
        case Daemon.Tools.Builtins.SkillManager.execute(%{"action" => "reload"}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "search " <> query ->
        case Daemon.Tools.Builtins.SkillManager.execute(%{"action" => "search", "query" => query}) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "enable " <> name ->
        case Daemon.Tools.Builtins.SkillManager.execute(%{
               "action" => "enable",
               "name" => String.trim(name)
             }) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "disable " <> name ->
        case Daemon.Tools.Builtins.SkillManager.execute(%{
               "action" => "disable",
               "name" => String.trim(name)
             }) do
          {:ok, result} -> {:command, result}
          {:error, reason} -> {:command, "Error: #{reason}"}
        end

      "delete " <> name ->
        case Daemon.Tools.Builtins.SkillManager.execute(%{
               "action" => "delete",
               "name" => String.trim(name)
             }) do
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
    stats = Daemon.Agent.Memory.memory_stats()

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
    identity = Daemon.Soul.identity()
    soul = Daemon.Soul.soul()
    user = Daemon.Soul.user()

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
    bulletin = Daemon.Agent.Cortex.bulletin()
    topics = Daemon.Agent.Cortex.active_topics()
    stats = Daemon.Agent.Cortex.synthesis_stats()

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

  @doc "Handle the `/desktop` and `/gui` command."
  def cmd_desktop(_arg, _session_id) do
    osa_root = Application.get_env(:daemon, :root_path, File.cwd!())
    desktop_dir = Path.join(osa_root, "desktop")

    # Look for the built Tauri binary first, then fall back to dev mode
    binary_paths = [
      Path.join([desktop_dir, "src-tauri", "target", "release", "osa-desktop"]),
      Path.join([desktop_dir, "src-tauri", "target", "debug", "osa-desktop"])
    ]

    case Enum.find(binary_paths, &File.exists?/1) do
      nil ->
        # No built binary — try launching dev mode in background
        launch_desktop_dev(desktop_dir)

      binary ->
        # Launch the built Tauri app
        port = Port.open({:spawn_executable, binary}, [:binary, :nouse_stdio, {:cd, desktop_dir}])
        Port.close(port)
        {:command, "Launching OSA Desktop (#{Path.basename(binary)})"}
    end
  end

  defp launch_desktop_dev(desktop_dir) do
    npm = if match?({:win32, _}, :os.type()), do: "npm.cmd", else: "npm"

    if File.exists?(Path.join(desktop_dir, "package.json")) do
      # Install deps if needed
      unless File.dir?(Path.join(desktop_dir, "node_modules")) do
        System.cmd(npm, ["install"], cd: desktop_dir, stderr_to_stdout: true)
      end

      # Start tauri dev in background
      Port.open(
        {:spawn_executable, System.find_executable(npm)},
        [:binary, :nouse_stdio, {:cd, desktop_dir}, {:args, ["run", "tauri:dev"]}]
      )

      {:command, "Starting OSA Desktop in dev mode...\nThe Tauri window will open shortly."}
    else
      {:command, "Desktop app not found at #{desktop_dir}\nRun from the OSA project root."}
    end
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

  defp format_adaptation_event(event) do
    summary =
      event
      |> Map.get(:context, %{})
      |> summarize_event_context()

    prefix =
      "  - #{format_timestamp(Map.get(event, :timestamp))} #{Map.get(event, :domain, "-")} / #{Map.get(event, :event_type, "-")}"

    case summary do
      "" -> prefix
      _ -> "#{prefix} — #{summary}"
    end
  end

  defp summarize_event_context(context) when is_map(context) do
    ~w(reason bottleneck authority_domain steering_hypothesis pattern_key session_rate historical_rate outcome)
    |> Enum.reduce([], fn key, acc ->
      case Map.get(context, key) do
        value when value in [nil, "", "nil"] -> acc
        value -> ["#{key}=#{format_context_value(value)}" | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(3)
    |> Enum.join(", ")
  end

  defp summarize_event_context(_), do: ""

  defp format_context_value(value) when is_binary(value), do: value
  defp format_context_value(value), do: inspect(value)

  defp format_review_window(review) do
    count = Map.get(review, :window_event_count, 0)
    started_at = Map.get(review, :window_started_at)
    ended_at = Map.get(review, :window_ended_at)

    case {started_at, ended_at} do
      {nil, _} ->
        "#{count} signals"

      {from, to} ->
        "#{count} signals from #{format_timestamp(from)} to #{format_timestamp(to)}"
    end
  end

  defp format_rate_with_counts(nil, numerator, denominator, label),
    do: "- (#{numerator}/#{denominator} #{label})"

  defp format_rate_with_counts(rate, numerator, denominator, label),
    do: "#{format_percentage(rate)} (#{numerator}/#{denominator} #{label})"

  defp format_rate_with_ratio(nil, numerator, denominator), do: "- (#{numerator}/#{denominator})"

  defp format_rate_with_ratio(rate, numerator, denominator),
    do: "#{format_percentage(rate)} (#{numerator}/#{denominator})"

  defp format_promotion_keep_rate(promotions) do
    started = Map.get(promotions, :started, 0)
    cleared = Map.get(promotions, :cleared, 0)
    keep_rate = Map.get(promotions, :keep_rate)

    case keep_rate do
      nil -> "- (#{started} started, #{cleared} cleared)"
      _ -> "#{format_percentage(keep_rate)} (#{started} started, #{cleared} cleared)"
    end
  end

  defp format_domain_skew([]), do: "-"

  defp format_domain_skew(domain_skew) do
    domain_skew
    |> Enum.take(3)
    |> Enum.map_join(", ", fn %{domain: domain, share: share} ->
      "#{domain} #{format_percentage(share)}"
    end)
  end

  defp format_signature_section([], _kind), do: "  - none"

  defp format_signature_section(signatures, :positive) do
    Enum.map_join(signatures, "\n", fn signature ->
      "  - #{format_signature_label(signature)} net #{format_signed_integer(Map.get(signature, :net_score, 0))} (#{Map.get(signature, :helpful, 0)} helpful, #{Map.get(signature, :promotions, 0)} promotions)"
    end)
  end

  defp format_signature_section(signatures, :noisy) do
    Enum.map_join(signatures, "\n", fn signature ->
      "  - #{format_signature_label(signature)} net #{format_signed_integer(Map.get(signature, :net_score, 0))} (#{Map.get(signature, :not_helpful, 0)} not_helpful, #{Map.get(signature, :suppression_hits, 0)} suppression hits)"
    end)
  end

  defp format_signature_label(signature) do
    trigger_event =
      Map.get(signature, :trigger_event) || Map.get(signature, "trigger_event") || "-"

    bottleneck = Map.get(signature, :bottleneck) || Map.get(signature, "bottleneck") || "-"
    "#{trigger_event} / #{bottleneck}"
  end

  defp format_percentage(nil), do: "-"

  defp format_percentage(value) when is_number(value) do
    :erlang.float_to_binary(value * 100, decimals: 1) <> "%"
  end

  defp format_signed_integer(value) when is_integer(value) and value > 0, do: "+#{value}"
  defp format_signed_integer(value), do: to_string(value)

  defp format_presence(nil), do: "-"
  defp format_presence(""), do: "-"
  defp format_presence(value), do: to_string(value)

  defp format_optional_timestamp(nil), do: nil
  defp format_optional_timestamp(value), do: format_timestamp(value)
end
