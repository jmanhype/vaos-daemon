defmodule OptimalSystemAgent.PlatformRepo.Migrations.AddIndexesAndConstraints do
  use Ecto.Migration

  def change do
    # Performance indexes for frequent lookups
    create_if_not_exists index(:tenants, [:owner_id])
    create_if_not_exists index(:tenant_members, [:user_id])
    create_if_not_exists index(:tenant_members, [:tenant_id, :user_id], unique: true)
    create_if_not_exists index(:os_instances, [:owner_id])
    create_if_not_exists index(:os_instance_members, [:user_id])
    create_if_not_exists index(:os_instance_members, [:os_instance_id, :user_id], unique: true)
    create_if_not_exists index(:cross_os_grants, [:granted_by])
    create_if_not_exists index(:cross_os_grants, [:expires_at])
    create_if_not_exists index(:cross_os_grants, [:source_os_id, :target_os_id])
    create_if_not_exists index(:tenant_invites, [:tenant_id, :email], unique: true)
    create_if_not_exists index(:tenant_invites, [:token], unique: true)
  end
end
