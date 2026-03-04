defmodule OptimalSystemAgent.Channels.HTTP.API do
  @moduledoc """
  Authenticated API router — all endpoints under /api/v1.

  Auth plug runs globally. Channel webhook routes bypass JWT because they
  are forwarded before the auth result halts the conn — platform-specific
  HMAC/challenge verification happens inside ChannelRoutes.

  Sub-router forwarding map:

    /auth        → AuthRoutes        POST /login|logout|refresh
    /channels    → ChannelRoutes     GET /, POST /*/webhook (10 platforms)
    /sessions    → SessionRoutes     GET|POST /, GET /:id, GET /:id/messages
    /fleet       → FleetRoutes       POST /register|heartbeat|dispatch, GET /agents|/:id
    /orchestrate → OrchestrationRoutes  POST /|/complex, GET /tasks, GET /:id/progress
    /swarm       → OrchestrationRoutes  POST /launch, GET /|/:id, DELETE /:id
    /stream      → AgentRoutes       GET /:session_id  (SSE)
    /tools       → ToolRoutes        GET /, POST /:name/execute
    /skills      → ToolRoutes        GET /, POST /create
    /commands    → ToolRoutes        GET /, POST /execute
    /memory      → DataRoutes        POST /, GET /recall
    /models      → DataRoutes        GET /, POST /switch
    /analytics   → DataRoutes        GET /
    /scheduler   → DataRoutes        GET /jobs, POST /reload
    /webhooks    → DataRoutes        POST /:trigger_id
    /machines    → DataRoutes        GET /
    /events      → ProtocolRoutes    POST /, GET /stream
    /oscp        → ProtocolRoutes    POST /
    /tasks       → ProtocolRoutes    GET /history
  """
  use Plug.Router
  require Logger

  alias OptimalSystemAgent.Channels.HTTP.Auth
  alias OptimalSystemAgent.Channels.HTTP.API

  # ── Global error handler ────────────────────────────────────────────

  @impl Plug
  def call(conn, opts) do
    super(conn, opts)
  rescue
    e ->
      Logger.error("[API] Unhandled exception: #{Exception.message(e)}",
        exception: Exception.format(:error, e, __STACKTRACE__)
      )

      body = Jason.encode!(%{error: "internal_error", details: Exception.message(e)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, body)
  end

  plug OptimalSystemAgent.Channels.HTTP.RateLimiter
  plug :authenticate
  plug OptimalSystemAgent.Channels.HTTP.Integrity
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000

  plug :dispatch

  # ── Auth (no JWT required — forwarded before authenticate would halt) ─
  forward "/auth", to: API.AuthRoutes

  # ── Channel webhooks (platform-specific auth, not JWT) ───────────────
  forward "/channels", to: API.ChannelRoutes

  # ── Sessions ─────────────────────────────────────────────────────────
  forward "/sessions", to: API.SessionRoutes

  # ── Fleet ────────────────────────────────────────────────────────────
  forward "/fleet", to: API.FleetRoutes

  # ── Orchestration (simple POST + complex + swarm) ────────────────────
  forward "/orchestrate", to: API.OrchestrationRoutes
  forward "/swarm", to: API.OrchestrationRoutes

  # ── Agent SSE stream ─────────────────────────────────────────────────
  forward "/stream", to: API.AgentRoutes

  # ── Tools, skills, commands ──────────────────────────────────────────
  forward "/tools", to: API.ToolRoutes
  forward "/skills", to: API.ToolRoutes
  forward "/commands", to: API.ToolRoutes

  # ── Data ─────────────────────────────────────────────────────────────
  forward "/memory", to: API.DataRoutes
  forward "/models", to: API.DataRoutes
  forward "/analytics", to: API.DataRoutes
  forward "/scheduler", to: API.DataRoutes
  forward "/webhooks", to: API.DataRoutes
  forward "/machines", to: API.DataRoutes

  # ── Protocol ─────────────────────────────────────────────────────────
  forward "/events", to: API.ProtocolRoutes
  forward "/oscp", to: API.ProtocolRoutes
  forward "/tasks", to: API.ProtocolRoutes

  # ── Catch-all ────────────────────────────────────────────────────────
  match _ do
    body = Jason.encode!(%{error: "not_found", details: "Endpoint not found"})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, body)
  end

  # ── JWT Authentication Plug ─────────────────────────────────────────
  # Auth routes and channel webhook routes bypass JWT.

  defp authenticate(%{request_path: "/api/v1/auth/" <> _} = conn, _opts), do: conn
  defp authenticate(%{request_path: "/api/v1/channels/" <> _} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Auth.verify_token(token) do
          {:ok, claims} ->
            conn
            |> assign(:user_id, claims["user_id"])
            |> assign(:workspace_id, claims["workspace_id"])
            |> assign(:claims, claims)

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "INVALID_TOKEN"}))
            |> halt()
        end

      _ ->
        if Application.get_env(:optimal_system_agent, :require_auth, false) do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "unauthorized", code: "MISSING_TOKEN"}))
          |> halt()
        else
          Logger.debug("HTTP request without auth — dev mode, allowing")

          conn
          |> assign(:user_id, "anonymous")
          |> assign(:workspace_id, nil)
          |> assign(:claims, %{})
        end
    end
  end
end
