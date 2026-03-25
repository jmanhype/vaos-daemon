defmodule Daemon.Dashboard.Service do
  @moduledoc """
  Aggregates KPI data from sessions, agents, tasks, signals, and metrics
  into a single dashboard payload.
  """

  require Logger

  alias Daemon.Agent.Roster
  alias Daemon.Agent.Tasks
  alias Daemon.Agent.HealthTracker
  alias Daemon.CommandCenter
  alias Daemon.CommandCenter.EventHistory

  @spec summary() :: map()
  def summary do
    %{
      kpis: build_kpis(),
      active_agents: build_active_agents(),
      recent_activity: build_recent_activity(),
      system_health: build_system_health()
    }
  end

  # ── KPIs ──────────────────────────────────────────────────────────────

  defp build_kpis do
    metrics = CommandCenter.metrics_summary()
    dashboard = CommandCenter.dashboard_summary()

    %{
      active_sessions: metrics[:active_sessions] || 0,
      agents_online: dashboard[:running] || 0,
      agents_total: dashboard[:total_agents] || 0,
      signals_today: metrics[:total_messages] || 0,
      tasks_completed: metrics[:total_tasks_completed] || 0,
      tasks_pending: count_pending_tasks(),
      tokens_used_today: metrics[:total_tokens_used] || 0,
      uptime_seconds: metrics[:uptime_seconds] || 0
    }
  end

  defp count_pending_tasks do
    Tasks.list_tasks([])
    |> Enum.count(fn task -> Map.get(task, :status) in [:pending, :queued] end)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ── Active Agents ─────────────────────────────────────────────────────

  defp build_active_agents do
    running = CommandCenter.running_agents()

    running
    |> Enum.take(20)
    |> Enum.map(fn task ->
      health = agent_health(task[:agent] || task[:agent_name])

      %{
        name: task[:agent] || task[:agent_name] || "unknown",
        status: normalize_status(task[:status]),
        current_task: task[:task] || task[:description],
        last_active: health[:last_active]
      }
    end)
  end

  defp agent_health(nil), do: %{}

  defp agent_health(name) do
    case HealthTracker.get(to_string(name)) do
      {:ok, h} -> h
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp normalize_status(:leased), do: "running"
  defp normalize_status(s) when is_atom(s), do: Atom.to_string(s)
  defp normalize_status(s) when is_binary(s), do: s
  defp normalize_status(_), do: "idle"

  # ── Recent Activity ───────────────────────────────────────────────────

  defp build_recent_activity do
    EventHistory.recent(20)
    |> Enum.map(fn event ->
      %{
        type: Map.get(event, :type, "event") |> to_string(),
        message: Map.get(event, :message, Map.get(event, :description, "")),
        timestamp: Map.get(event, :timestamp, Map.get(event, :inserted_at)),
        agent: Map.get(event, :agent) |> to_string_or_nil(),
        level: Map.get(event, :level, "info") |> to_string()
      }
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v), do: to_string(v)

  # ── System Health ─────────────────────────────────────────────────────

  defp build_system_health do
    provider = Application.get_env(:daemon, :default_provider, :ollama)

    memory_mb =
      :erlang.memory(:total)
      |> Kernel.div(1_048_576)

    %{
      backend: "ok",
      provider: to_string(provider),
      provider_status: check_provider_status(),
      memory_mb: memory_mb
    }
  end

  defp check_provider_status do
    agents = Roster.all()
    if map_size(agents) > 0, do: "connected", else: "connected"
  rescue
    _ -> "disconnected"
  catch
    :exit, _ -> "disconnected"
  end
end
