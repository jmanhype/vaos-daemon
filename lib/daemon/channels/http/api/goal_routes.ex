defmodule Daemon.Channels.HTTP.API.GoalRoutes do
  @moduledoc """
  Goal management routes.

  Forwarded from /goals in the parent API router.

  Effective endpoints:
    PUT    /goals/:id           — update goal
    DELETE /goals/:id           — delete goal
    GET    /goals/:id/ancestry  — ancestry chain for goal
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Projects

  plug :match
  plug :dispatch

  # ── PUT /:id — update goal ─────────────────────────────────────────────

  put "/:id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, goal} <- Projects.get_goal(id) do
      case Projects.update_goal(goal, conn.body_params) do
        {:ok, updated} ->
          json(conn, 200, %{goal: serialize_goal(updated)})

        {:error, %Ecto.Changeset{} = cs} ->
          json_error(conn, 422, "validation_error", inspect(changeset_errors(cs)))

        {:error, reason} ->
          Logger.error("[GoalRoutes] update_goal failed: #{inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to update goal")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Goal ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Goal not found")

      {:error, reason} ->
        Logger.error("[GoalRoutes] get_goal failed: #{inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch goal")
    end
  end

  # ── DELETE /:id — delete goal ──────────────────────────────────────────

  delete "/:id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, goal} <- Projects.get_goal(id) do
      case Projects.delete_goal(goal) do
        {:ok, _deleted} ->
          json(conn, 200, %{deleted: true, id: id})

        {:error, reason} ->
          Logger.error("[GoalRoutes] delete_goal failed: #{inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to delete goal")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Goal ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Goal not found")

      {:error, reason} ->
        Logger.error("[GoalRoutes] get_goal failed: #{inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch goal")
    end
  end

  # ── GET /:id/ancestry — ancestry chain ────────────────────────────────

  get "/:id/ancestry" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, _goal} <- Projects.get_goal(id) do
      ancestry = Projects.goal_ancestry(id)
      json(conn, 200, %{ancestry: Enum.map(ancestry, &serialize_goal/1), goal_id: id})
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Goal ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Goal not found")

      {:error, reason} ->
        Logger.error("[GoalRoutes] goal_ancestry failed: #{inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch ancestry")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Goal endpoint not found")
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp parse_id(raw) do
    {:ok, String.to_integer(raw)}
  rescue
    ArgumentError -> :invalid_id
  end

  defp serialize_goal(goal) do
    %{
      id: goal.id,
      project_id: goal.project_id,
      parent_id: goal.parent_id,
      title: goal.title,
      description: goal.description,
      priority: goal.priority,
      status: goal.status,
      inserted_at: goal.inserted_at,
      updated_at: goal.updated_at
    }
  end
end
