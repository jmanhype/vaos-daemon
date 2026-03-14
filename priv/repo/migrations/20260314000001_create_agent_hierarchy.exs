defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateAgentHierarchy do
  use Ecto.Migration

  def change do
    create table(:agent_hierarchy) do
      add :agent_name, :string, null: false
      add :reports_to, :string
      add :org_role, :string, null: false, default: "engineer"
      add :title, :string
      add :org_order, :integer, null: false, default: 0
      add :can_delegate_to, :text
      add :metadata, :map, default: %{}
      timestamps()
    end

    create unique_index(:agent_hierarchy, [:agent_name])
    create index(:agent_hierarchy, [:reports_to])
  end
end
