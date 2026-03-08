defmodule OptimalSystemAgent.PlatformRepo.Migrations.CreatePlatformTables do
  use Ecto.Migration

  def change do
    # 1. platform_users
    create table(:platform_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string
      add :display_name, :string
      add :avatar_url, :string
      add :role, :string, default: "user"
      add :email_verified_at, :utc_datetime
      add :last_login_at, :utc_datetime

      timestamps()
    end

    create unique_index(:platform_users, [:email])

    # 2. tenants
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :owner_id, references(:platform_users, type: :binary_id, on_delete: :restrict)
      add :plan, :string, default: "free"
      add :settings, :map, default: %{}

      timestamps()
    end

    create unique_index(:tenants, [:slug])

    # 3. tenant_members
    create table(:tenant_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:platform_users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :joined_at, :utc_datetime
    end

    create unique_index(:tenant_members, [:tenant_id, :user_id])

    # 4. tenant_invites
    create table(:tenant_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :role, :string, default: "member"
      add :token, :string, null: false
      add :expires_at, :utc_datetime
      add :accepted_at, :utc_datetime

      timestamps()
    end

    create unique_index(:tenant_invites, [:token])

    # 5. os_instances
    create table(:os_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :owner_id, references(:platform_users, type: :binary_id, on_delete: :restrict)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, default: "provisioning"
      add :template_type, :string
      add :config, :map, default: %{}
      add :sandbox_id, :string

      timestamps()
    end

    create unique_index(:os_instances, [:tenant_id, :slug])

    # 6. os_instance_members
    create table(:os_instance_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :os_instance_id, references(:os_instances, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:platform_users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, default: "member"
      add :permissions, :map, default: %{}

      timestamps()
    end

    create unique_index(:os_instance_members, [:os_instance_id, :user_id])

    # 7. cross_os_grants
    create table(:cross_os_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_os_id, references(:os_instances, type: :binary_id, on_delete: :restrict), null: false
      add :target_os_id, references(:os_instances, type: :binary_id, on_delete: :restrict), null: false
      add :granted_by, references(:platform_users, type: :binary_id, on_delete: :restrict)
      add :grant_type, :string, null: false
      add :resource_pattern, :string
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end
  end
end
