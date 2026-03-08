defmodule OptimalSystemAgent.PlatformRepo.Migrations.CreateSurveyResponses do
  use Ecto.Migration

  def change do
    create table(:survey_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string
      add :tools, {:array, :string}, default: []
      add :source, :string
      add :used_openclass, :boolean
      add :email, :string
      add :user_id, :binary_id
      add :session_token, :string

      timestamps(type: :utc_datetime)
    end

    create index(:survey_responses, [:email])
    create index(:survey_responses, [:user_id])
    create index(:survey_responses, [:inserted_at])
  end
end
