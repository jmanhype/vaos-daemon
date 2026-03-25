defmodule Daemon.Projects.Goal do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(active in_progress completed blocked)
  @valid_priorities ~w(low medium high)

  schema "goals" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"
    field :priority, :string, default: "medium"
    field :metadata, :map, default: %{}

    belongs_to :project, Daemon.Projects.Project
    belongs_to :parent, Daemon.Projects.Goal

    timestamps()
  end

  @required [:title, :project_id]
  @optional [:description, :status, :priority, :parent_id, :metadata]

  def changeset(goal \\ %__MODULE__{}, attrs) do
    goal
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:priority, @valid_priorities)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_id)
  end
end
