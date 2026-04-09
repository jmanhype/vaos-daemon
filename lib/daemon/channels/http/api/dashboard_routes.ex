defmodule Daemon.Channels.HTTP.API.DashboardRoutes do
  @moduledoc """
  Dashboard API routes.

  Forwarded prefix: /dashboard

  Routes:
    GET / → combined dashboard KPI payload
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Dashboard.Service

  plug(:match)
  plug(:dispatch)

  get "/" do
    data = safe_summary()
    json(conn, 200, data)
  end

  match _ do
    json_error(conn, 404, "not_found", "Dashboard endpoint not found")
  end

  defp safe_summary do
    Service.summary()
  rescue
    e ->
      Logger.error("[Dashboard] summary failed: #{Exception.message(e)}")

      %{
        kpis: %{},
        active_agents: [],
        recent_activity: [],
        system_health: %{backend: "error"},
        adaptation: %{
          journal: %{status: "inactive", signal_count: 0, in_flight_count: 0},
          meta_state: %{
            authority_domain: nil,
            active_bottleneck: nil,
            pivot_reason: nil,
            active_steering_hypothesis: nil,
            last_updated_at: nil,
            last_experiment: nil,
            recent_failed_count: 0,
            recent_failed_adaptations: []
          },
          current_trial: nil,
          active_promotions: [],
          active_suppressions: [],
          recent_signals: []
        }
      }
  catch
    :exit, reason ->
      Logger.error("[Dashboard] summary exit: #{inspect(reason)}")

      %{
        kpis: %{},
        active_agents: [],
        recent_activity: [],
        system_health: %{backend: "error"},
        adaptation: %{
          journal: %{status: "inactive", signal_count: 0, in_flight_count: 0},
          meta_state: %{
            authority_domain: nil,
            active_bottleneck: nil,
            pivot_reason: nil,
            active_steering_hypothesis: nil,
            last_updated_at: nil,
            last_experiment: nil,
            recent_failed_count: 0,
            recent_failed_adaptations: []
          },
          current_trial: nil,
          active_promotions: [],
          active_suppressions: [],
          recent_signals: []
        }
      }
  end
end
