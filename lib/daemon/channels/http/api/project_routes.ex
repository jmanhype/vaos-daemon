defmodule Daemon.Channels.HTTP.API.ProjectRoutes do
  @moduledoc """
  Project and goal routes.

  Forwarded from /projects in the parent API router.

  Effective endpoints:
    GET    /projects              — list projects (optional ?status=)
    POST   /projects              — create project
    GET    /projects/:id          — project detail with goals + task_count
    PUT    /projects/:id          — update project
    DELETE /projects/:id          — archive project (soft delete)
    GET    /projects/:id/tasks    — list tasks linked to project
    POST   /projects/:id/tasks/:task_id — link task to project + goal
    GET    /projects/:id/goals    — goal tree for project
    POST   /projects/:id/goals    — create goal for project
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Projects

  plug :match
  plug :dispatch

  # ── GET / — list projects ──────────────────────────────────────────────

  get "/" do
    conn = fetch_query_params(conn)
    status = conn.query_params["status"]

    projects = Projects.list_projects(status: status)
    json(conn, 200, %{projects: Enum.map(projects, &serialize_project/1)})
  end

  # ── POST / — create project ────────────────────────────────────────────

  post "/" do
    with %{"name" => name} when is_binary(name) and name != "" <- conn.body_params do
      params = %{
        name: name,
        description: conn.body_params["description"],
        goal: conn.body_params["goal"],
        workspace_path: conn.body_params["workspace_path"]
      }

      case Projects.create_project(params) do
        {:ok, project} ->
          json(conn, 201, %{project: serialize_project(project)})

        {:error, %Ecto.Changeset{} = _cs} ->
          json_error(conn, 422, "validation_error", "Validation failed")

        {:error, reason} ->
          Logger.error("[ProjectRoutes] create_project failed: #{safe_inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to create project")
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: name")
    end
  end

  # ── GET /:id — project detail ──────────────────────────────────────────

  get "/:id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, project} <- Projects.get_project_with_stats(id) do
      goals = Projects.list_goals(project.id)
      json(conn, 200, %{project: serialize_project_detail(project, goals)})
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] get_project_with_stats failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch project")
    end
  end

  # ── PUT /:id — update project ──────────────────────────────────────────

  put "/:id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, project} <- Projects.get_project(id) do
      case Projects.update_project(project, conn.body_params) do
        {:ok, updated} ->
          json(conn, 200, %{project: serialize_project(updated)})

        {:error, %Ecto.Changeset{} = _cs} ->
          json_error(conn, 422, "validation_error", "Validation failed")

        {:error, reason} ->
          Logger.error("[ProjectRoutes] update_project failed: #{safe_inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to update project")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] get_project failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch project")
    end
  end

  # ── DELETE /:id — archive project ─────────────────────────────────────

  delete "/:id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, project} <- Projects.get_project(id) do
      case Projects.archive_project(project) do
        {:ok, archived} ->
          json(conn, 200, %{project: serialize_project(archived), archived: true})

        {:error, reason} ->
          Logger.error("[ProjectRoutes] archive_project failed: #{safe_inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to archive project")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] get_project failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch project")
    end
  end

  # ── GET /:id/tasks — list tasks linked to project ─────────────────────

  get "/:id/tasks" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, _project} <- Projects.get_project(id) do
      tasks = Projects.list_project_tasks(id)
      json(conn, 200, %{tasks: tasks, count: length(tasks)})
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] list_project_tasks failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch tasks")
    end
  end

  # ── POST /:id/tasks/:task_id — link task to project ───────────────────

  post "/:id/tasks/:task_id" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, _project} <- Projects.get_project(id) do
      task_id = conn.params["task_id"]
      goal_id = conn.body_params["goal_id"]

      case Projects.link_task(id, task_id, goal_id: goal_id) do
        {:ok, link} ->
          json(conn, 201, %{link: link, project_id: id, task_id: task_id})

        {:error, :not_found} ->
          json_error(conn, 404, "not_found", "Task not found")

        {:error, reason} ->
          Logger.error("[ProjectRoutes] link_task failed: #{safe_inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to link task")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] get_project failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch project")
    end
  end

  # ── GET /:id/goals — goal tree for project ────────────────────────────

  get "/:id/goals" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, _project} <- Projects.get_project(id) do
      tree = Projects.goal_tree(id)
      json(conn, 200, %{goals: tree})
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] goal_tree failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch goal tree")
    end
  end

  # ── POST /:id/goals — create goal for project ─────────────────────────

  post "/:id/goals" do
    with {:ok, id} <- parse_id(conn.params["id"]),
         {:ok, _project} <- Projects.get_project(id),
         %{"title" => title} when is_binary(title) and title != "" <- conn.body_params do
      params = %{
        project_id: id,
        title: title,
        description: conn.body_params["description"],
        parent_id: conn.body_params["parent_id"],
        priority: conn.body_params["priority"]
      }

      case Projects.create_goal(params) do
        {:ok, goal} ->
          json(conn, 201, %{goal: serialize_goal(goal)})

        {:error, %Ecto.Changeset{} = _cs} ->
          json_error(conn, 422, "validation_error", "Validation failed")

        {:error, reason} ->
          Logger.error("[ProjectRoutes] create_goal failed: #{safe_inspect(reason)}")
          json_error(conn, 500, "internal_error", "Failed to create goal")
      end
    else
      :invalid_id ->
        json_error(conn, 400, "invalid_id", "Project ID must be an integer")

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Project not found")

      %{} ->
        json_error(conn, 400, "invalid_request", "Missing required field: title")

      {:error, reason} ->
        Logger.error("[ProjectRoutes] get_project failed: #{safe_inspect(reason)}")
        json_error(conn, 500, "internal_error", "Failed to fetch project")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Project endpoint not found")
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp parse_id(raw) do
    {:ok, String.to_integer(raw)}
  rescue
    ArgumentError -> :invalid_id
  end

  defp serialize_project(project) do
    %{
      id: project.id,
      name: project.name,
      description: project.description,
      goal: project.goal,
      status: project.status,
      slug: project.slug,
      workspace_path: project.workspace_path,
      metadata: project.metadata,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp serialize_project_detail(project, goals) do
    project
    |> serialize_project()
    |> Map.merge(%{
      goals: Enum.map(goals, &serialize_goal/1),
      task_count: Map.get(project, :task_count, 0)
    })
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
