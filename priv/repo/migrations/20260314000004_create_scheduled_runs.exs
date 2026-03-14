defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateScheduledRuns do
  use Ecto.Migration

  def change do
    create table(:scheduled_runs) do
      add :scheduled_task_id, :string, null: false
      add :agent_name, :string
      add :status, :string, null: false, default: "pending"
      add :trigger_type, :string
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :exit_code, :integer
      add :stdout, :text
      add :stderr, :text
      add :token_usage, :map, default: %{}
      add :session_state, :map, default: %{}
      add :error_message, :text
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:scheduled_runs, [:scheduled_task_id])
    create index(:scheduled_runs, [:status])
    create index(:scheduled_runs, [:inserted_at])
  end
end
