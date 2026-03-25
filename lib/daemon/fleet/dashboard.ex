defmodule Daemon.Fleet.Dashboard do
  @moduledoc """
  Fleet-level aggregation across all OS instances.

  Pulls from Fleet.Registry (remote agents/sentinels), Sandbox.Registry
  (OS→sprite mappings), and CommandCenter (per-instance agent ecosystem)
  to provide a unified fleet-wide view.
  """

  alias Daemon.Fleet.Registry, as: FleetRegistry
  alias Daemon.Sandbox.Registry, as: SandboxRegistry
  alias Daemon.CommandCenter

  @doc "Full fleet overview: instance count, health, global metrics."
  @spec overview() :: map()
  def overview do
    stats = FleetRegistry.get_stats()
    sprites = SandboxRegistry.all_sprites()

    %{
      fleet: %{
        total_instances: length(sprites),
        total_agents: stats.total,
        agents_online: stats.online,
        agents_unreachable: stats.unreachable
      },
      local: CommandCenter.dashboard_summary(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc "List all OS instances with their agent metrics."
  @spec instances() :: [map()]
  def instances do
    sprites = SandboxRegistry.all_sprites()
    agents = FleetRegistry.list_agents()

    Enum.map(sprites, fn {os_id, sprite_id} ->
      instance_agents =
        Enum.filter(agents, fn a ->
          String.starts_with?(a.agent_id, os_id)
        end)

      %{
        os_id: os_id,
        sprite_id: sprite_id,
        agent_count: length(instance_agents),
        agents_online: Enum.count(instance_agents, &(&1.status == :online)),
        agents_unreachable: Enum.count(instance_agents, &(&1.status == :unreachable))
      }
    end)
  end

  @doc "Detail for a single OS instance."
  @spec instance_detail(String.t()) :: {:ok, map()} | {:error, :not_found}
  def instance_detail(os_id) do
    case SandboxRegistry.sprite_lookup(os_id) do
      nil ->
        {:error, :not_found}

      sprite_id ->
        agents = FleetRegistry.list_agents()

        instance_agents =
          Enum.filter(agents, fn a ->
            String.starts_with?(a.agent_id, os_id)
          end)

        {:ok,
         %{
           os_id: os_id,
           sprite_id: sprite_id,
           agents: instance_agents,
           agent_count: length(instance_agents),
           agents_online: Enum.count(instance_agents, &(&1.status == :online)),
           agents_unreachable: Enum.count(instance_agents, &(&1.status == :unreachable))
         }}
    end
  end

  @doc "Aggregate metrics across the entire fleet."
  @spec global_metrics() :: map()
  def global_metrics do
    stats = FleetRegistry.get_stats()
    local_metrics = CommandCenter.metrics_summary()
    sprites = SandboxRegistry.all_sprites()

    %{
      fleet: %{
        total_instances: length(sprites),
        total_agents: stats.total,
        agents_online: stats.online,
        agents_unreachable: stats.unreachable
      },
      local: local_metrics,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Agent type counts across the fleet."
  @spec agent_census() :: map()
  def agent_census do
    agents = FleetRegistry.list_agents()

    by_status =
      agents
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {status, list} -> {status, length(list)} end)

    by_capability =
      agents
      |> Enum.flat_map(fn a -> Enum.map(a.capabilities, &{&1, a.agent_id}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {cap, ids} -> {cap, length(ids)} end)

    %{
      total: length(agents),
      by_status: by_status,
      by_capability: by_capability,
      timestamp: DateTime.utc_now()
    }
  end
end
