defmodule OptimalSystemAgent.CommandCenter do
  @moduledoc """
  Facade that aggregates agent ecosystem state for the Command Center UI.

  Pulls from Roster, Tier, and Swarm.Patterns to provide a unified view
  of the agent ecosystem: who exists, what tier they're on, what swarm
  patterns are available, and (eventually) what's running right now.
  """

  alias OptimalSystemAgent.Agent.Roster
  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Agent.Orchestrator.Patterns

  @doc "Full dashboard summary: agents, tiers, patterns, running count."
  @spec dashboard_summary() :: map()
  def dashboard_summary do
    agents = Roster.all()

    agents_by_tier =
      agents
      |> Map.values()
      |> Enum.group_by(& &1.tier)
      |> Map.new(fn {tier, list} -> {tier, length(list)} end)

    %{
      total_agents: map_size(agents),
      agents_by_tier: agents_by_tier,
      tiers: Tier.all_tiers(),
      patterns: Patterns.list_patterns(),
      running: length(running_agents())
    }
  end

  @doc "Detailed info for a single agent by name."
  @spec agent_detail(String.t()) :: {:ok, map()} | {:error, :not_found}
  def agent_detail(name) do
    case Roster.get(name) do
      nil ->
        {:error, :not_found}

      agent ->
        provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
        model = Tier.model_for(agent.tier, provider)

        {:ok,
         Map.merge(agent, %{
           resolved_model: model,
           tier_config: Tier.tier_info(agent.tier),
           provider: provider
         })}
    end
  end

  @doc "List currently running agents. Placeholder — returns [] until wired to orchestrator."
  @spec running_agents() :: [map()]
  def running_agents, do: []

  @doc "Breakdown of agents per tier with tier config."
  @spec tier_breakdown() :: map()
  def tier_breakdown do
    agents = Roster.all() |> Map.values()

    [:elite, :specialist, :utility]
    |> Map.new(fn tier ->
      tier_agents = Enum.filter(agents, &(&1.tier == tier))

      {tier,
       %{
         config: Tier.tier_info(tier),
         agents: Enum.map(tier_agents, & &1.name),
         count: length(tier_agents)
       }}
    end)
  end

  @doc "Metrics summary. Placeholder with zeros until wired to telemetry."
  @spec metrics_summary() :: map()
  def metrics_summary do
    %{
      total_tasks_completed: 0,
      total_tokens_used: 0,
      active_sessions: 0,
      uptime_seconds: 0
    }
  end
end
