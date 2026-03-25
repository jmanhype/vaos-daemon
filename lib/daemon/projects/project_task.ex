defmodule Daemon.Projects.ProjectTask do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_tasks" do
    belongs_to :project, Daemon.Projects.Project
    field :task_id, :string
    belongs_to :goal, Daemon.Projects.Goal

    timestamps()
  end

  @required [:project_id, :task_id]
  @optional [:goal_id]

  def changeset(pt \\ %__MODULE__{}, attrs) do
    pt
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:goal_id)
    |> unique_constraint([:project_id, :task_id])
  end
end
