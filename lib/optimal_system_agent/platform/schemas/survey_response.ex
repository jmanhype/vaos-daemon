defmodule OptimalSystemAgent.Platform.Schemas.SurveyResponse do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :role, :tools, :source, :used_openclass, :email, :user_id, :inserted_at]}

  schema "survey_responses" do
    field :role, :string
    field :tools, {:array, :string}, default: []
    field :source, :string
    field :used_openclass, :boolean
    field :email, :string
    field :user_id, :binary_id
    field :session_token, :string

    timestamps(type: :utc_datetime)
  end

  @valid_roles ~w(founder builder vibe-coder agency creator other)
  @valid_sources ~w(social search friend community article other)

  def changeset(survey, attrs) do
    survey
    |> cast(attrs, [:role, :tools, :source, :used_openclass, :email, :user_id, :session_token])
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:source, @valid_sources)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
  end
end
