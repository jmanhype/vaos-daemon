defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateSignals do
  use Ecto.Migration

  def change do
    create table(:signals) do
      add :session_id, :string
      add :channel, :string, null: false
      add :mode, :string, null: false
      add :genre, :string, null: false
      add :type, :string, null: false, default: "general"
      add :format, :string, null: false
      add :weight, :float, null: false, default: 0.5
      add :tier, :string
      add :input_preview, :text
      add :agent_name, :string
      add :confidence, :string, default: "high"
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:signals, [:mode])
    create index(:signals, [:weight])
    create index(:signals, [:channel])
    create index(:signals, [:inserted_at])
    create index(:signals, [:tier])
  end
end
