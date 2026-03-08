defmodule OptimalSystemAgent.Channels.HTTP.API.CommandCenterRoutes do
  @moduledoc """
  Command Center API routes.

  Forwarded prefix: /command-center

  Routes:
    GET  /                  → dashboard summary
    GET  /agents            → all agents
    GET  /agents/:name      → agent detail
    GET  /tiers             → tier breakdown
    GET  /patterns          → swarm patterns
    GET  /metrics           → metrics summary
    GET  /sandboxes         → list sandboxes
    POST /sandboxes         → provision sandbox
    DELETE /sandboxes/:id   → deprovision sandbox
    GET  /events            → SSE event stream
    GET  /events/history    → recent event history
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.CommandCenter
  alias OptimalSystemAgent.Sandbox.Provisioner

  plug :match
  plug :dispatch

  # ── GET / — dashboard summary ──────────────────────────────────────

  get "/" do
    body = Jason.encode!(CommandCenter.dashboard_summary())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /agents — all agents ───────────────────────────────────────

  get "/agents" do
    agents =
      OptimalSystemAgent.Agent.Roster.all()
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    body = Jason.encode!(%{agents: agents, count: length(agents)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /agents/:name — agent detail ───────────────────────────────

  get "/agents/:name" do
    case CommandCenter.agent_detail(name) do
      {:ok, detail} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(detail))

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Agent '#{name}' not found")
    end
  end

  # ── GET /tiers — tier breakdown ────────────────────────────────────

  get "/tiers" do
    body = Jason.encode!(CommandCenter.tier_breakdown())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /patterns — swarm patterns ─────────────────────────────────

  get "/patterns" do
    patterns =
      OptimalSystemAgent.Agent.Orchestrator.Patterns.list_patterns()
      |> Enum.map(fn {name, desc} -> %{name: name, description: desc} end)

    body = Jason.encode!(%{patterns: patterns, count: length(patterns)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /metrics — metrics summary ─────────────────────────────────

  get "/metrics" do
    body = Jason.encode!(CommandCenter.metrics_summary())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /sandboxes — list sandboxes ────────────────────────────────

  get "/sandboxes" do
    body = Jason.encode!(%{sandboxes: [], count: 0})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sandboxes — provision sandbox ────────────────────────────

  post "/sandboxes" do
    with %{"os_id" => os_id} <- conn.body_params do
      template =
        case conn.body_params["template"] do
          t when t in ~w(node python elixir go rust) -> String.to_existing_atom(t)
          _ -> :default
        end

      case Provisioner.provision(os_id, template) do
        {:ok, sprite_id} ->
          body = Jason.encode!(%{status: "provisioned", os_id: os_id, sprite_id: sprite_id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, reason} ->
          json_error(conn, 500, "provision_failed", inspect(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: os_id")
    end
  end

  # ── DELETE /sandboxes/:id — deprovision sandbox ────────────────────

  delete "/sandboxes/:id" do
    case Provisioner.deprovision(id) do
      :ok ->
        body = Jason.encode!(%{status: "deprovisioned", os_id: id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Sandbox '#{id}' not found")

      {:error, reason} ->
        json_error(conn, 500, "deprovision_failed", inspect(reason))
    end
  end

  # ── GET /events — SSE event stream ─────────────────────────────────
  # TODO: re-implement via Events.Bus PubSub once Command Center SSE is scoped

  get "/events" do
    json_error(conn, 501, "not_implemented", "SSE event stream not yet available")
  end

  # ── GET /events/history — recent event history ─────────────────────
  # TODO: re-implement via Events.Bus once history storage is scoped

  get "/events/history" do
    json_error(conn, 501, "not_implemented", "Event history not yet available")
  end

  match _ do
    json_error(conn, 404, "not_found", "Command Center endpoint not found")
  end
end
