defmodule OptimalSystemAgent.Store.Repo.Migrations.AddKanbanFields do
  use Ecto.Migration

  def change do
    alter table(:task_queue) do
      add :priority, :string, default: "medium"
      add :assignee_agent, :string
      add :checkout_lock, :utc_datetime_usec
    end

    create_if_not_exists index(:task_queue, [:assignee_agent])
    create_if_not_exists index(:task_queue, [:priority])
  end
end
