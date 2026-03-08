defmodule OptimalSystemAgent.Platform.Schemas.OsInstance do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(provisioning active suspended stopped deleting)
  @valid_templates ~w(business_os content_os agency_os dev_os data_os blank)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :tenant_id, :owner_id, :name, :slug, :status, :template_type, :config, :sandbox_id, :sandbox_url, :inserted_at, :updated_at]}

  schema "os_instances" do
    field :tenant_id, :binary_id
    field :owner_id, :binary_id
    field :name, :string
    field :slug, :string
    field :status, :string, default: "provisioning"
    field :template_type, :string
    field :config, :map, default: %{}
    field :sandbox_id, :string
    field :sandbox_url, :string

    timestamps()
  end

  def changeset(os_instance, attrs) do
    os_instance
    |> cast(attrs, [:tenant_id, :owner_id, :name, :slug, :status, :template_type, :config, :sandbox_id, :sandbox_url])
    |> validate_required([:tenant_id, :owner_id, :name, :slug])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:template_type, @valid_templates)
    |> unique_constraint([:tenant_id, :slug])
  end
end

defmodule OptimalSystemAgent.Platform.Schemas.OsInstanceMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: [:id, :os_instance_id, :user_id, :role, :permissions, :inserted_at, :updated_at]}

  schema "os_instance_members" do
    field :os_instance_id, :binary_id
    field :user_id, :binary_id
    field :role, :string
    field :permissions, :map, default: %{}

    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:os_instance_id, :user_id, :role, :permissions])
    |> validate_required([:os_instance_id, :user_id, :role])
  end
end
