defmodule OptimalSystemAgent.Projects do
  import Ecto.Query

  alias OptimalSystemAgent.Store.Repo
  alias OptimalSystemAgent.Projects.{Goal, Project, ProjectTask}

  # ── Projects ─────────────────────────────────────────────────────

  def list_projects(opts \\ []) do
    status = Keyword.get(opts, :status)

    Project
    |> maybe_filter_status(status)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def create_project(attrs) do
    Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def archive_project(%Project{} = project) do
    update_project(project, %{status: "archived"})
  end

  def get_project_with_stats(id) do
    case get_project(id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, project} ->
        task_count = Repo.aggregate(from(pt in ProjectTask, where: pt.project_id == ^id), :count)
        {:ok, Map.put(project, :task_count, task_count)}
    end
  end

  # ── Task Linking ──────────────────────────────────────────────────

  def link_task(project_id, task_id, opts \\ []) do
    goal_id = Keyword.get(opts, :goal_id)

    ProjectTask.changeset(%{project_id: project_id, task_id: task_id, goal_id: goal_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  def unlink_task(project_id, task_id) do
    from(pt in ProjectTask,
      where: pt.project_id == ^project_id and pt.task_id == ^task_id
    )
    |> Repo.delete_all()
  end

  def list_project_tasks(project_id) do
    from(pt in ProjectTask,
      where: pt.project_id == ^project_id,
      order_by: [desc: :inserted_at],
      preload: [:goal]
    )
    |> Repo.all()
  end

  # ── Goals ─────────────────────────────────────────────────────────

  def list_goals(project_id) do
    from(g in Goal, where: g.project_id == ^project_id, order_by: :inserted_at)
    |> Repo.all()
  end

  def get_goal(id) do
    case Repo.get(Goal, id) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  def create_goal(attrs) do
    Goal.changeset(attrs)
    |> Repo.insert()
  end

  def update_goal(%Goal{} = goal, attrs) do
    goal
    |> Goal.changeset(attrs)
    |> Repo.update()
  end

  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  def goal_ancestry(goal_id) do
    case Repo.get(Goal, goal_id) do
      nil -> []
      goal -> build_ancestry(goal, [goal])
    end
  end

  def goal_tree(project_id) do
    goals = list_goals(project_id)
    build_tree(goals, nil)
  end

  # ── Private ───────────────────────────────────────────────────────

  defp build_ancestry(%Goal{parent_id: nil}, acc), do: Enum.reverse(acc)

  defp build_ancestry(%Goal{parent_id: pid}, acc) do
    case Repo.get(Goal, pid) do
      nil -> Enum.reverse(acc)
      parent -> build_ancestry(parent, [parent | acc])
    end
  end

  defp build_tree(goals, parent_id) do
    goals
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.map(fn goal ->
      %{goal: goal, children: build_tree(goals, goal.id)}
    end)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [p], p.status == ^status)
end
