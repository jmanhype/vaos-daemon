defmodule OptimalSystemAgent.Platform.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :email, :display_name, :avatar_url, :role, :email_verified_at, :last_login_at, :inserted_at, :updated_at]}

  schema "platform_users" do
    field :email, :string
    field :password_hash, :string
    field :display_name, :string
    field :avatar_url, :string
    field :role, :string, default: "user"
    field :email_verified_at, :utc_datetime
    field :last_login_at, :utc_datetime

    # Virtual field for password input
    field :password, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :display_name, :avatar_url, :role, :last_login_at])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> require_password_on_create(user)
    |> validate_length(:password, min: 8)
    |> unique_constraint(:email)
    |> maybe_hash_password()
  end

  defp require_password_on_create(changeset, %{id: nil}), do: validate_required(changeset, [:password])
  defp require_password_on_create(changeset, %{id: _}), do: changeset
  defp require_password_on_create(changeset, _), do: validate_required(changeset, [:password])

  defp maybe_hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
