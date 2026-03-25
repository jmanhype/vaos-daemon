defmodule Daemon.Channels.HTTP.API.HierarchyRoutes do
  @moduledoc """
  Agent hierarchy routes forwarded from /api/v1/agents/hierarchy.

  Effective routes:
    GET  /                    Return full org tree
    PUT  /:agent_name         Update position (reports_to, org_role, title)
    POST /seed                Seed default hierarchy
    POST /:agent_name/delegate Delegate a task from one agent to another
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Agents.Hierarchy

  plug :match
  plug :dispatch

  # ── GET / — full org tree ───────────────────────────────────────────

  get "/" do
    json(conn, 200, Hierarchy.get_tree())
  end

  # ── POST /seed — seed default hierarchy ────────────────────────────
  # Must be defined before /:agent_name to avoid routing ambiguity.

  post "/seed" do
    case Hierarchy.seed_defaults() do
      {:ok, count} ->
        json(conn, 200, %{status: "seeded", count: count})
    end
  end

  # ── POST /:agent_name/delegate — delegate a task ───────────────────

  post "/:agent_name/delegate" do
    agent_name = conn.params["agent_name"]

    with %{"to" => to_agent, "task" => task}
         when is_binary(to_agent) and to_agent != "" and
                is_binary(task) and task != "" <- conn.body_params do
      case Hierarchy.delegate(agent_name, to_agent, task) do
        {:ok, result} ->
          json(conn, 200, result)

        {:error, reason} ->
          json_error(conn, 422, "delegation_failed", to_string(reason))
      end
    else
      _ ->
        json_error(conn, 400, "invalid_request", "Required fields: to, task (non-empty strings)")
    end
  end

  # ── PUT /:agent_name — update agent position ───────────────────────

  put "/:agent_name" do
    agent_name = conn.params["agent_name"]
    reports_to = conn.body_params["reports_to"]
    org_role = conn.body_params["org_role"]
    title = conn.body_params["title"]

    with :ok <- apply_move(agent_name, reports_to),
         :ok <- apply_role(agent_name, org_role) do
      json(conn, 200, %{
        status: "updated",
        agent: agent_name,
        reports_to: reports_to,
        org_role: org_role,
        title: title
      })
    else
      {:halt, :cycle} ->
        json_error(conn, 409, "cycle_detected", "Moving #{agent_name} would create a reporting cycle")

      {:halt, :not_found} ->
        json_error(conn, 404, "not_found", "Agent #{agent_name} not found")

      {:halt, :invalid_role} ->
        json_error(conn, 422, "invalid_role", "Role #{org_role} is not valid")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Hierarchy endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp apply_move(_agent_name, nil), do: :ok

  defp apply_move(agent_name, reports_to) do
    case Hierarchy.move_agent(agent_name, reports_to) do
      {:ok, _} -> :ok
      {:error, :cycle_detected} -> {:halt, :cycle}
      {:error, :not_found} -> {:halt, :not_found}
    end
  end

  defp apply_role(_agent_name, nil), do: :ok

  defp apply_role(agent_name, role) do
    case Hierarchy.set_role(agent_name, role) do
      {:ok, _} -> :ok
      {:error, :invalid_role} -> {:halt, :invalid_role}
    end
  end
end
