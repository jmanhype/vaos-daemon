defmodule OptimalSystemAgent.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(active completed archived)

  schema "projects" do
    field :name, :string
    field :description, :string
    field :goal, :string
    field :workspace_path, :string
    field :status, :string, default: "active"
    field :slug, :string
    field :metadata, :map, default: %{}

    has_many :goals, OptimalSystemAgent.Projects.Goal
    has_many :project_tasks, OptimalSystemAgent.Projects.ProjectTask

    timestamps()
  end

  @required [:name]
  @optional [:description, :goal, :workspace_path, :status, :metadata]

  def changeset(project \\ %__MODULE__{}, attrs) do
    project
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> generate_slug()
    |> unique_constraint(:slug)
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
