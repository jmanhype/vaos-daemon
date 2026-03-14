defmodule OptimalSystemAgent.Channels.HTTP.API.DashboardRoutes do
  @moduledoc """
  Dashboard API routes.

  Forwarded prefix: /dashboard

  Routes:
    GET / → combined dashboard KPI payload
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Dashboard.Service

  plug :match
  plug :dispatch

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
      %{kpis: %{}, active_agents: [], recent_activity: [], system_health: %{backend: "error"}}
  catch
    :exit, reason ->
      Logger.error("[Dashboard] summary exit: #{inspect(reason)}")
      %{kpis: %{}, active_agents: [], recent_activity: [], system_health: %{backend: "error"}}
  end
end
