defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateCostEvents do
  use Ecto.Migration

  def change do
    create table(:cost_events) do
      add :agent_name, :string, null: false
      add :session_id, :string
      add :task_id, :string
      add :provider, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cache_read_tokens, :integer, null: false, default: 0
      add :cache_write_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      timestamps()
    end

    create index(:cost_events, [:agent_name])
    create index(:cost_events, [:session_id])
    create index(:cost_events, [:inserted_at])
    create index(:cost_events, [:agent_name, :inserted_at])
  end
end
