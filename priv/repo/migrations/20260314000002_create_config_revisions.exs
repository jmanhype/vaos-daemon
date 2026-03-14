defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateConfigRevisions do
  use Ecto.Migration

  def change do
    create table(:config_revisions) do
      add :entity_type, :string, null: false
      add :entity_id, :string, null: false
      add :revision_number, :integer, null: false
      add :previous_config, :map
      add :new_config, :map
      add :changed_fields, {:array, :string}
      add :changed_by, :string
      add :change_reason, :text
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:config_revisions, [:entity_type, :entity_id])
    create unique_index(:config_revisions, [:entity_type, :entity_id, :revision_number])
  end
end
