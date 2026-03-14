defmodule OptimalSystemAgent.Channels.HTTP.API.TaskKanbanRoutes do
  @moduledoc """
  Kanban-specific task operations against the task_queue table.
  Forwarded from /tasks/kanban in the main API router.
  """
  use Plug.Router
  import Ecto.Query
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Store.Repo

  plug :match
  plug :dispatch

  @valid_statuses ~w(pending leased running completed failed cancelled)

  # ── POST /:id/checkout — atomic checkout ─────────────────────────────

  post "/:id/checkout" do
    with %{"agent_name" => agent_name} when is_binary(agent_name) and agent_name != "" <-
           conn.body_params do
      {count, _} =
        Repo.update_all(
          from(t in "task_queue",
            where: t.id == ^id and t.status == "pending" and is_nil(t.checkout_lock)
          ),
          set: [
            assignee_agent: agent_name,
            status: "leased",
            checkout_lock: DateTime.utc_now()
          ]
        )

      case count do
        0 -> json_error(conn, 409, "already_assigned", "Task is not available for checkout")
        1 -> json(conn, 200, %{checked_out: true})
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_name")
    end
  end

  # ── POST /:id/release — release checkout lock ─────────────────────────

  post "/:id/release" do
    {count, _} =
      Repo.update_all(
        from(t in "task_queue", where: t.id == ^id),
        set: [checkout_lock: nil, status: "pending", assignee_agent: nil]
      )

    case count do
      0 -> json_error(conn, 404, "not_found", "Task not found")
      _ -> json(conn, 200, %{released: true})
    end
  end

  # ── PUT /:id/status — update task status ─────────────────────────────

  put "/:id/status" do
    with %{"status" => status} when is_binary(status) <- conn.body_params,
         true <- status in @valid_statuses do
      {count, _} =
        Repo.update_all(
          from(t in "task_queue", where: t.id == ^id),
          set: [status: status]
        )

      case count do
        0 -> json_error(conn, 404, "not_found", "Task not found")
        _ -> json(conn, 200, %{status: status})
      end
    else
      false -> json_error(conn, 400, "invalid_status", "Status must be one of: #{Enum.join(@valid_statuses, ", ")}")
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: status")
    end
  end

  # ── PUT /:id/priority — update task priority ─────────────────────────

  put "/:id/priority" do
    valid = ~w(low medium high critical)

    with %{"priority" => priority} when is_binary(priority) <- conn.body_params,
         true <- priority in valid do
      {count, _} =
        Repo.update_all(
          from(t in "task_queue", where: t.id == ^id),
          set: [priority: priority]
        )

      case count do
        0 -> json_error(conn, 404, "not_found", "Task not found")
        _ -> json(conn, 200, %{priority: priority})
      end
    else
      false -> json_error(conn, 400, "invalid_priority", "Priority must be one of: low, medium, high, critical")
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: priority")
    end
  end

  # ── PUT /:id/assign — assign task to agent ───────────────────────────

  put "/:id/assign" do
    with %{"agent_name" => agent_name} when is_binary(agent_name) and agent_name != "" <-
           conn.body_params do
      {count, _} =
        Repo.update_all(
          from(t in "task_queue", where: t.id == ^id),
          set: [assignee_agent: agent_name]
        )

      case count do
        0 -> json_error(conn, 404, "not_found", "Task not found")
        _ -> json(conn, 200, %{assigned_to: agent_name})
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: agent_name")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
