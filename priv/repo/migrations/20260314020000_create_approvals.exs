defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def change do
    create table(:approvals) do
      add :type, :string, null: false
      add :status, :string, default: "pending"
      add :title, :string, null: false
      add :description, :text
      add :requested_by, :string
      add :resolved_by, :string
      add :resolved_at, :utc_datetime
      add :decision_notes, :text
      add :context, :map, default: %{}
      add :related_entity_type, :string
      add :related_entity_id, :string
      timestamps()
    end

    create index(:approvals, [:status])
    create index(:approvals, [:type])
    create index(:approvals, [:requested_by])
  end
end
