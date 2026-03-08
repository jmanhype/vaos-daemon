defmodule OptimalSystemAgent.Platform.Tenants do
  import Ecto.Query
  alias OptimalSystemAgent.Platform.Repo
  alias OptimalSystemAgent.Platform.Schemas.{Tenant, TenantMember, TenantInvite}

  def create(owner_id, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:tenant, Tenant.changeset(%Tenant{}, Map.put(attrs, "owner_id", owner_id)))
    |> Ecto.Multi.insert(:member, fn %{tenant: tenant} ->
      TenantMember.changeset(%TenantMember{}, %{
        tenant_id: tenant.id,
        user_id: owner_id,
        role: "owner",
        joined_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tenant: tenant}} -> {:ok, tenant}
      {:error, :tenant, changeset, _} -> {:error, changeset}
      {:error, :member, changeset, _} -> {:error, changeset}
    end
  end

  def get(tenant_id), do: Repo.get(Tenant, tenant_id)

  def list_for_user(user_id) do
    from(t in Tenant,
      join: m in TenantMember,
      on: m.tenant_id == t.id,
      where: m.user_id == ^user_id
    )
    |> Repo.all()
  end

  def update(tenant_id, attrs) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :not_found}
      tenant -> tenant |> Tenant.changeset(attrs) |> Repo.update()
    end
  end

  def delete(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :not_found}
      tenant -> Repo.delete(tenant)
    end
  end

  def list_members(tenant_id) do
    from(m in TenantMember, where: m.tenant_id == ^tenant_id, preload: [])
    |> Repo.all()
  end

  def invite_member(tenant_id, email, role \\ "member") do
    %TenantInvite{}
    |> TenantInvite.changeset(%{
      tenant_id: tenant_id,
      email: email,
      role: role,
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
    })
    |> Repo.insert()
  end

  def accept_invite(token) do
    case Repo.get_by(TenantInvite, token: token) do
      nil -> {:error, :not_found}
      %{accepted_at: %DateTime{}} -> {:error, :already_accepted}
      invite ->
        if DateTime.compare(DateTime.utc_now(), invite.expires_at) == :gt do
          {:error, :expired}
        else
          accept_invite_transaction(invite)
        end
    end
  end

  def remove_member(tenant_id, user_id) do
    from(m in TenantMember, where: m.tenant_id == ^tenant_id and m.user_id == ^user_id)
    |> Repo.delete_all()
    |> case do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @valid_roles ~w(owner admin member)

  def update_member_role(tenant_id, user_id, role) do
    if role not in @valid_roles do
      {:error, :invalid_role}
    else
      case Repo.get_by(TenantMember, tenant_id: tenant_id, user_id: user_id) do
        nil -> {:error, :not_found}
        member -> member |> TenantMember.changeset(%{role: role}) |> Repo.update()
      end
    end
  end

  defp accept_invite_transaction(invite) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:invite, Ecto.Changeset.change(invite, %{accepted_at: DateTime.utc_now()}))
    |> Ecto.Multi.run(:user, fn repo, _changes ->
      case repo.get_by(OptimalSystemAgent.Platform.Schemas.User, email: invite.email) do
        nil -> {:error, :user_not_found}
        user -> {:ok, user}
      end
    end)
    |> Ecto.Multi.insert(:member, fn %{user: user} ->
      TenantMember.changeset(%TenantMember{}, %{
        tenant_id: invite.tenant_id,
        user_id: user.id,
        role: invite.role,
        joined_at: DateTime.utc_now()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invite: invite}} -> {:ok, invite}
      {:error, :user, :user_not_found, _} -> {:error, :user_not_found}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end
end
