defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateAgentBudgets do
  use Ecto.Migration

  def change do
    create table(:agent_budgets) do
      add :agent_name, :string, null: false
      add :budget_daily_cents, :integer, null: false, default: 25000
      add :budget_monthly_cents, :integer, null: false, default: 250000
      add :spent_daily_cents, :integer, null: false, default: 0
      add :spent_monthly_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :last_reset_daily, :date
      add :last_reset_monthly, :date
      timestamps()
    end

    create unique_index(:agent_budgets, [:agent_name])
  end
end
