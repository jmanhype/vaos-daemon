defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateProjectsAndGoals do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :string, null: false
      add :description, :text
      add :goal, :text
      add :workspace_path, :string
      add :status, :string, default: "active"
      add :slug, :string
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:projects, [:status])
    create unique_index(:projects, [:slug])

    create table(:goals) do
      add :title, :string, null: false
      add :description, :text
      add :parent_id, references(:goals, on_delete: :nilify_all)
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :status, :string, default: "active"
      add :priority, :string, default: "medium"
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:goals, [:project_id])
    create index(:goals, [:parent_id])
    create index(:goals, [:status])

    create table(:project_tasks) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :task_id, :string, null: false
      add :goal_id, references(:goals, on_delete: :nilify_all)

      timestamps()
    end

    create index(:project_tasks, [:project_id])
    create index(:project_tasks, [:task_id])
    create unique_index(:project_tasks, [:project_id, :task_id])
  end
end
