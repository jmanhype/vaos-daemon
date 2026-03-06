defmodule OptimalSystemAgent.Channels.HTTP.API.FleetDashboardRoutes do
  @moduledoc """
  Fleet Dashboard API routes.

  Forwarded prefix: /fleet-dashboard

  Routes:
    GET  /                  → fleet overview
    GET  /instances         → list all OS instances
    GET  /instances/:os_id  → single instance detail
    GET  /metrics           → global fleet metrics
    GET  /census            → agent census across fleet
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Fleet.Dashboard

  plug :match
  plug :dispatch

  # ── GET / — fleet overview ───────────────────────────────────────

  get "/" do
    body = Jason.encode!(Dashboard.overview())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /instances — list all OS instances ───────────────────────

  get "/instances" do
    instances = Dashboard.instances()
    body = Jason.encode!(%{instances: instances, count: length(instances)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /instances/:os_id — single instance detail ───────────────

  get "/instances/:os_id" do
    case Dashboard.instance_detail(os_id) do
      {:ok, detail} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(detail))

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Instance '#{os_id}' not found")
    end
  end

  # ── GET /metrics — global fleet metrics ──────────────────────────

  get "/metrics" do
    body = Jason.encode!(Dashboard.global_metrics())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /census — agent census across fleet ──────────────────────

  get "/census" do
    body = Jason.encode!(Dashboard.agent_census())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Fleet Dashboard endpoint not found")
  end
end
