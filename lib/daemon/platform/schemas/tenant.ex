defmodule Daemon.Platform.Schemas.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :name, :slug, :owner_id, :plan, :settings, :inserted_at, :updated_at]}

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :owner_id, :binary_id
    field :plan, :string, default: "free"
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :owner_id, :plan, :settings])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, max: 100)
    |> validate_format(:slug, ~r/^[a-z0-9\-]+$/, message: "must be lowercase alphanumeric with hyphens")
    |> validate_inclusion(:plan, ~w(free starter pro enterprise))
    |> unique_constraint(:slug)
  end
end

defmodule Daemon.Platform.Schemas.TenantMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :tenant_id, :user_id, :role, :joined_at]}

  @valid_roles ~w(owner admin member)

  schema "tenant_members" do
    field :tenant_id, :binary_id
    field :user_id, :binary_id
    field :role, :string
    field :joined_at, :utc_datetime
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:tenant_id, :user_id, :role, :joined_at])
    |> validate_required([:tenant_id, :user_id, :role])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:tenant_id, :user_id])
  end
end

defmodule Daemon.Platform.Schemas.TenantInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :tenant_id, :email, :role, :token, :expires_at, :accepted_at]}

  schema "tenant_invites" do
    field :tenant_id, :binary_id
    field :email, :string
    field :role, :string
    field :token, :string
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:tenant_id, :email, :role, :token, :expires_at, :accepted_at])
    |> validate_required([:tenant_id, :email, :role])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> maybe_generate_token()
    |> unique_constraint(:token)
    |> unique_constraint([:tenant_id, :email])
  end

  defp maybe_generate_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
      _existing -> changeset
    end
  end
end
