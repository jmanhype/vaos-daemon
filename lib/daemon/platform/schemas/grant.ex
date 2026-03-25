defmodule Daemon.Platform.Schemas.Grant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :source_os_id, :target_os_id, :granted_by, :grant_type, :resource_pattern, :expires_at, :revoked_at, :inserted_at, :updated_at]}

  schema "cross_os_grants" do
    field :source_os_id, :binary_id
    field :target_os_id, :binary_id
    field :granted_by, :binary_id
    field :grant_type, :string  # read, write, execute, admin
    field :resource_pattern, :string  # e.g. "agents/*", "data/shared/*"
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:source_os_id, :target_os_id, :granted_by, :grant_type, :resource_pattern, :expires_at])
    |> validate_required([:source_os_id, :target_os_id, :granted_by, :grant_type])
    |> validate_inclusion(:grant_type, ~w(read write execute admin))
    |> validate_not_self_grant()
  end

  defp validate_not_self_grant(changeset) do
    source = get_field(changeset, :source_os_id)
    target = get_field(changeset, :target_os_id)

    if source && target && source == target do
      add_error(changeset, :target_os_id, "cannot grant to the same OS instance")
    else
      changeset
    end
  end
end
