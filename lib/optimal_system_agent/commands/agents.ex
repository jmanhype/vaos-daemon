defmodule OptimalSystemAgent.Commands.Agents do
  @moduledoc """
  Agent ecosystem commands: /agents, /tiers, /tier, /swarms, /hooks, /learning,
  /budget, /thinking, /machines.
  """

  @doc "Handle the `/agents` command."
  def cmd_agents(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Roster

    if arg != "" and String.trim(arg) != "" do
      case Roster.get(String.trim(arg)) do
        nil ->
          {:command, "Unknown agent: #{arg}\nUse /agents to list all."}

        agent ->
          output = """
          #{agent.name} (#{agent.tier})
            Role: #{agent.role}
            #{agent.description}

            Skills: #{Enum.join(agent.skills, ", ")}
            Triggers: #{Enum.join(agent.triggers, ", ")}
            Territory: #{Enum.join(agent.territory, ", ")}
            Escalates to: #{agent.escalate_to || "none"}
          """

          {:command, String.trim(output)}
      end
    else
      agents = Roster.all()

      elite =
        agents |> Map.values() |> Enum.filter(&(&1.tier == :elite)) |> Enum.sort_by(& &1.name)

      specialist =
        agents
        |> Map.values()
        |> Enum.filter(&(&1.tier == :specialist))
        |> Enum.sort_by(& &1.name)

      utility =
        agents |> Map.values() |> Enum.filter(&(&1.tier == :utility)) |> Enum.sort_by(& &1.name)

      format_tier = fn tier_agents ->
        Enum.map_join(tier_agents, "\n", fn a ->
          "  #{String.pad_trailing(a.name, 22)} #{a.description}"
        end)
      end

      output = """
      Agent Roster (#{map_size(agents)} agents)

      ELITE (opus):
      #{format_tier.(elite)}

      SPECIALIST (sonnet):
      #{format_tier.(specialist)}

      UTILITY (haiku):
      #{format_tier.(utility)}

      Use /agents <name> for details.
      """

      {:command, String.trim(output)}
    end
  end

  @doc "Handle the `/tiers` command."
  def cmd_tiers(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Tier

    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    output = """
    Model Tiers (provider: #{provider})

    Elite (opus-class):
      Model: #{Tier.model_for(:elite, provider)}
      Budget: #{Tier.total_budget(:elite)} tokens
      Max agents: #{Tier.max_agents(:elite)}
      Max iterations: #{Tier.max_iterations(:elite)}

    Specialist (sonnet-class):
      Model: #{Tier.model_for(:specialist, provider)}
      Budget: #{Tier.total_budget(:specialist)} tokens
      Max agents: #{Tier.max_agents(:specialist)}
      Max iterations: #{Tier.max_iterations(:specialist)}

    Utility (haiku-class):
      Model: #{Tier.model_for(:utility, provider)}
      Budget: #{Tier.total_budget(:utility)} tokens
      Max agents: #{Tier.max_agents(:utility)}
      Max iterations: #{Tier.max_iterations(:utility)}
    """

    {:command, String.trim(output)}
  end

  @doc "Handle the `/tier` command for setting tier model overrides."
  def cmd_tier_set(arg, _session_id) do
    alias OptimalSystemAgent.Agent.Tier

    parts = arg |> String.trim() |> String.split(~r/\s+/, parts: 2)

    case parts do
      [tier_str, model] when tier_str in ["elite", "specialist", "utility"] ->
        tier = String.to_existing_atom(tier_str)
        Tier.set_tier_override(tier, model)

        result = OptimalSystemAgent.Commands.Model.format_tier_refresh()
        {:command, "Set #{tier_str} → #{model}\n#{result}"}

      ["clear", tier_str] when tier_str in ["elite", "specialist", "utility"] ->
        tier = String.to_existing_atom(tier_str)
        Tier.clear_tier_override(tier)

        result = OptimalSystemAgent.Commands.Model.format_tier_refresh()
        {:command, "Cleared #{tier_str} override.\n#{result}"}

      ["clear"] ->
        for tier <- [:elite, :specialist, :utility], do: Tier.clear_tier_override(tier)

        result = OptimalSystemAgent.Commands.Model.format_tier_refresh()
        {:command, "All tier overrides cleared.\n#{result}"}

      _ ->
        overrides = Tier.get_tier_overrides()

        override_lines =
          if map_size(overrides) > 0 do
            lines = Enum.map_join(overrides, "\n", fn {t, m} -> "  #{t}: #{m}" end)
            "\nActive overrides:\n#{lines}"
          else
            "\nNo overrides — using auto-detection (size-based)."
          end

        {:command,
         """
         Usage:
           /tier elite <model>       Set elite tier model
           /tier specialist <model>  Set specialist tier model
           /tier utility <model>     Set utility tier model
           /tier clear [tier]        Remove override(s)
         #{override_lines}
         """
         |> String.trim()}
    end
  end

  @doc "Handle the `/swarms` command."
  def cmd_swarms(_arg, _session_id) do
    alias OptimalSystemAgent.Agent.Roster

    presets = Roster.swarm_presets()

    lines =
      Enum.map_join(presets, "\n", fn {name, preset} ->
        agents_str = Enum.join(preset.agents, ", ")
        "  #{String.pad_trailing(name, 20)} #{preset.pattern} — #{agents_str}"
      end)

    output = """
    Swarm Presets (#{map_size(presets)})

    #{lines}

    Use: /swarm <preset> to launch a swarm (coming soon)
    """

    {:command, String.trim(output)}
  end

  @doc "Handle the `/hooks` command."
  def cmd_hooks(_arg, _session_id) do
    try do
      hooks = OptimalSystemAgent.Agent.Hooks.list_hooks()
      metrics = OptimalSystemAgent.Agent.Hooks.metrics()

      hook_lines =
        Enum.map_join(hooks, "\n", fn {event, entries} ->
          entry_strs = Enum.map_join(entries, ", ", fn e -> "#{e.name}(p#{e.priority})" end)
          "  #{String.pad_trailing(to_string(event), 18)} #{entry_strs}"
        end)

      metrics_lines =
        Enum.map_join(metrics, "\n", fn {event, m} ->
          "  #{String.pad_trailing(to_string(event), 18)} #{m.calls} calls, avg #{m[:avg_us] || 0}μs, #{m.blocks} blocks"
        end)

      output = """
      Hook Pipeline

      Registered:
      #{hook_lines}

      Metrics:
      #{if metrics_lines == "", do: "  (no data yet)", else: metrics_lines}
      """

      {:command, String.trim(output)}
    rescue
      _ -> {:command, "Hook pipeline not initialized yet."}
    end
  end

  @doc "Handle the `/learning` command."
  def cmd_learning(_arg, _session_id) do
    try do
      metrics = OptimalSystemAgent.Agent.Learning.metrics()
      patterns = OptimalSystemAgent.Agent.Learning.patterns()

      top_patterns =
        patterns
        |> Enum.sort_by(fn {_k, v} -> v.count end, :desc)
        |> Enum.take(10)
        |> Enum.map_join("\n", fn {key, info} ->
          "  #{String.pad_trailing(key, 30)} #{info.count}x"
        end)

      output = """
      Learning Engine (SICA)

      Metrics:
        Total interactions: #{metrics.total_interactions}
        Patterns captured:  #{metrics.patterns_captured}
        Skills generated:   #{metrics.skills_generated}
        Errors recovered:   #{metrics.errors_recovered}
        Consolidations:     #{metrics.consolidations}

      Top Patterns:
      #{if top_patterns == "", do: "  (none yet — interact more)", else: top_patterns}
      """

      {:command, String.trim(output)}
    rescue
      _ -> {:command, "Learning engine not initialized yet."}
    end
  end

  @doc "Handle the `/budget` command."
  def cmd_budget(_arg, _session_id) do
    try do
      {:ok, status} = OptimalSystemAgent.Agent.Budget.get_status()

      daily_pct =
        if status.daily_limit > 0,
          do: Float.round(status.daily_spent / status.daily_limit * 100, 1),
          else: 0.0

      monthly_pct =
        if status.monthly_limit > 0,
          do: Float.round(status.monthly_spent / status.monthly_limit * 100, 1),
          else: 0.0

      output =
        """
        Budget Status

        Daily:
          Spent:     $#{Float.round(status.daily_spent, 4)}
          Limit:     $#{Float.round(status.daily_limit, 2)}
          Remaining: $#{Float.round(status.daily_remaining, 4)} (#{daily_pct}% used)

        Monthly:
          Spent:     $#{Float.round(status.monthly_spent, 4)}
          Limit:     $#{Float.round(status.monthly_limit, 2)}
          Remaining: $#{Float.round(status.monthly_remaining, 4)} (#{monthly_pct}% used)

        Per-call limit: $#{Float.round(status.per_call_limit, 2)}
        Ledger entries: #{status.ledger_entries}
        """
        |> String.trim()

      {:command, output}
    rescue
      _ -> {:command, "Budget tracker not available."}
    end
  end

  @doc "Handle the `/thinking` command."
  def cmd_thinking(arg, _session_id) do
    trimmed = String.trim(arg)

    cond do
      trimmed == "" ->
        enabled = Application.get_env(:optimal_system_agent, :thinking_enabled, false)
        budget = Application.get_env(:optimal_system_agent, :thinking_budget_tokens, 5_000)
        provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

        status_str = if enabled, do: "enabled", else: "disabled"

        provider_note =
          if enabled and provider not in [:anthropic],
            do:
              "\n  Note: Extended thinking only works with Anthropic provider (current: #{provider})",
            else: ""

        output =
          """
          Extended Thinking: #{status_str}
            Budget tokens: #{format_number(budget)}
            Provider:      #{provider}#{provider_note}

          Usage:
            /thinking on         Enable extended thinking
            /thinking off        Disable extended thinking
            /thinking budget N   Set thinking budget tokens
          """
          |> String.trim()

        {:command, output}

      trimmed == "on" ->
        Application.put_env(:optimal_system_agent, :thinking_enabled, true)
        {:command, "Extended thinking enabled."}

      trimmed == "off" ->
        Application.put_env(:optimal_system_agent, :thinking_enabled, false)
        {:command, "Extended thinking disabled."}

      String.starts_with?(trimmed, "budget ") ->
        budget_str = String.trim(String.trim_leading(trimmed, "budget"))

        case Integer.parse(budget_str) do
          {n, _} when n > 0 ->
            Application.put_env(:optimal_system_agent, :thinking_budget_tokens, n)
            {:command, "Thinking budget set to #{format_number(n)} tokens."}

          _ ->
            {:command, "Invalid budget. Usage: /thinking budget 10000"}
        end

      true ->
        {:command, "Unknown option: #{trimmed}\n\nUsage: /thinking [on|off|budget N]"}
    end
  end

  @doc "Handle the `/machines` command."
  def cmd_machines(_arg, _session_id) do
    try do
      machines = OptimalSystemAgent.Machines.active()

      active_list =
        if machines == [] do
          "  (none active)"
        else
          Enum.map_join(machines, "\n", fn m ->
            "  #{String.pad_trailing(to_string(m), 20)} active"
          end)
        end

      fleet_output =
        try do
          agents = OptimalSystemAgent.Fleet.Registry.list_agents()
          stats = OptimalSystemAgent.Fleet.Registry.get_stats()

          if agents == [] do
            "\nFleet: no remote agents registered"
          else
            agent_lines =
              Enum.map_join(agents, "\n", fn a ->
                status = a[:status] || "unknown"
                id = a[:agent_id] || a[:id] || "?"
                "  #{String.pad_trailing(to_string(id), 24)} #{status}"
              end)

            "\nFleet (#{stats.total} total, #{stats.online} online):\n#{agent_lines}"
          end
        rescue
          _ -> "\nFleet: registry not available"
        end

      output = "Machines (skill groups):\n#{active_list}#{fleet_output}"
      {:command, output}
    rescue
      _ -> {:command, "Machines module not available."}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: "#{n}"
end
