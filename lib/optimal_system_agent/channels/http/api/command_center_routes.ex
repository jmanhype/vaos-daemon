defmodule OptimalSystemAgent.Channels.HTTP.API.CommandCenterRoutes do
  @moduledoc """
  Command Center API routes.

  Forwarded prefix: /command-center

  Routes:
    GET  /                          → dashboard summary
    GET  /agents                    → all agents
    GET  /agents/:name              → agent detail
    GET  /tiers                     → tier breakdown
    GET  /patterns                  → swarm patterns
    GET  /metrics                   → metrics summary
    GET  /sandboxes                 → list sandboxes
    POST /sandboxes                 → provision sandbox
    DELETE /sandboxes/:id           → deprovision sandbox
    GET  /events                    → SSE event stream
    GET  /events/history            → recent event history
    GET  /scheduler                 → scheduler status
    GET  /scheduler/jobs            → list jobs
    POST /scheduler/jobs            → add job
    DELETE /scheduler/jobs/:id      → remove job
    POST /scheduler/jobs/:id/toggle → toggle job enabled
    POST /scheduler/jobs/:id/run    → run job immediately
    GET  /scheduler/triggers        → list triggers
    POST /scheduler/triggers        → add trigger
    DELETE /scheduler/triggers/:id  → remove trigger
    POST /scheduler/triggers/:id/toggle → toggle trigger enabled
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.CommandCenter
  alias OptimalSystemAgent.Sandbox.Provisioner
  alias OptimalSystemAgent.Agent.Scheduler

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
      |> Enum.map(&redact_agent_prompt/1)

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
        |> send_resp(200, Jason.encode!(redact_agent_prompt(detail)))

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

  # ── GET /scheduler — overall scheduler status ──────────────────────

  get "/scheduler" do
    try do
      body = Jason.encode!(Scheduler.status())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── GET /scheduler/jobs — list all cron jobs ───────────────────────

  get "/scheduler/jobs" do
    try do
      jobs = Scheduler.list_jobs()
      body = Jason.encode!(%{jobs: jobs, count: length(jobs)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs — create a new cron job ───────────────────

  post "/scheduler/jobs" do
    try do
      case Scheduler.add_job(conn.body_params) do
        {:ok, job} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(job))

        {:error, reason} ->
          json_error(conn, 422, "add_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── DELETE /scheduler/jobs/:id — remove a cron job ─────────────────

  delete "/scheduler/jobs/:id" do
    try do
      case Scheduler.remove_job(id) do
        :ok ->
          body = Jason.encode!(%{status: "removed", id: id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "remove_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs/:id/toggle — enable or disable a job ──────

  post "/scheduler/jobs/:id/toggle" do
    try do
      enabled = conn.body_params["enabled"]

      case Scheduler.toggle_job(id, enabled) do
        {:ok, job} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(job))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "toggle_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/jobs/:id/run — execute a job immediately ───────

  post "/scheduler/jobs/:id/run" do
    try do
      case Scheduler.run_job(id) do
        {:ok, result} ->
          body = Jason.encode!(%{status: "executed", id: id, result: result})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Job '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "run_job_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── GET /scheduler/triggers — list all triggers ─────────────────────

  get "/scheduler/triggers" do
    try do
      triggers = Scheduler.list_triggers()
      body = Jason.encode!(%{triggers: triggers, count: length(triggers)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/triggers — create a new trigger ─────────────────

  post "/scheduler/triggers" do
    try do
      case Scheduler.add_trigger(conn.body_params) do
        {:ok, trigger} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(trigger))

        {:error, reason} ->
          json_error(conn, 422, "add_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── DELETE /scheduler/triggers/:id — remove a trigger ───────────────

  delete "/scheduler/triggers/:id" do
    try do
      case Scheduler.remove_trigger(id) do
        :ok ->
          body = Jason.encode!(%{status: "removed", id: id})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Trigger '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "remove_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  # ── POST /scheduler/triggers/:id/toggle — enable or disable a trigger

  post "/scheduler/triggers/:id/toggle" do
    try do
      enabled = conn.body_params["enabled"]

      case Scheduler.toggle_trigger(id, enabled) do
        {:ok, trigger} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(trigger))

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Trigger '#{id}' not found")

        {:error, reason} ->
          json_error(conn, 500, "toggle_trigger_failed", inspect(reason))
      end
    rescue
      e -> json_error(conn, 500, "scheduler_error", Exception.message(e))
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Command Center endpoint not found")
  end

  # ── Private ──────────────────────────────────────────────────────────

  # SECURITY: strip system prompt from agent representations before
  # returning them over the API. Prompt leakage is FINDING-01 (Critical).
  defp redact_agent_prompt(agent) when is_map(agent) do
    agent
    |> Map.drop([:prompt, "prompt"])
    |> Map.put(:prompt, "[REDACTED]")
  end
end
