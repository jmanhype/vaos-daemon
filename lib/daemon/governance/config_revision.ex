defmodule Daemon.Governance.ConfigRevision do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :entity_type, :entity_id, :revision_number,
    :previous_config, :new_config, :changed_fields, :changed_by, :change_reason,
    :metadata, :inserted_at]}

  schema "config_revisions" do
    field :entity_type, :string
    field :entity_id, :string
    field :revision_number, :integer
    field :previous_config, :map
    field :new_config, :map
    field :changed_fields, {:array, :string}
    field :changed_by, :string
    field :change_reason, :string
    field :metadata, :map
    timestamps()
  end

  @required ~w(entity_type entity_id revision_number new_config changed_by)a
  @optional ~w(previous_config changed_fields change_reason metadata)a

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:revision_number, greater_than: 0)
  end
end
