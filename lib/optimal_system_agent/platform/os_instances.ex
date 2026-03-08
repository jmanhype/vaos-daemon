defmodule OptimalSystemAgent.Platform.OsInstances do
  import Ecto.Query

  alias OptimalSystemAgent.Platform.Repo
  alias OptimalSystemAgent.Platform.Schemas.{OsInstance, OsInstanceMember}
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @doc "Insert an OsInstance with status 'provisioning'."
  def create(tenant_id, owner_id, attrs) do
    attrs =
      attrs
      |> Map.put("tenant_id", tenant_id)
      |> Map.put("owner_id", owner_id)
      |> Map.put_new("status", "provisioning")

    %OsInstance{}
    |> OsInstance.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch an OsInstance by id."
  def get(os_id), do: Repo.get(OsInstance, os_id)

  @doc "List all OsInstances for a tenant, newest first."
  def list(tenant_id) do
    OsInstance
    |> where([o], o.tenant_id == ^tenant_id)
    |> order_by([o], desc: o.inserted_at)
    |> Repo.all()
  end

  @doc "Update an OsInstance by id via changeset."
  def update(os_id, attrs) do
    case Repo.get(OsInstance, os_id) do
      nil -> {:error, :not_found}
      instance -> instance |> OsInstance.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Soft-delete an OsInstance by setting status to 'deleting'."
  def delete(os_id) do
    case Repo.get(OsInstance, os_id) do
      nil -> {:error, :not_found}
      instance -> instance |> OsInstance.changeset(%{"status" => "deleting"}) |> Repo.update()
    end
  end

  @doc "Verify membership and return a scoped JWT with os_id in claims."
  def enter(os_id, user_id) do
    member =
      OsInstanceMember
      |> where([m], m.os_instance_id == ^os_id and m.user_id == ^user_id)
      |> Repo.one()

    case member do
      nil ->
        {:error, :not_member}

      %{user_id: ^user_id} ->
        token = Auth.generate_token(%{"user_id" => user_id, "os_id" => os_id})
        {:ok, token}

      _mismatch ->
        {:error, :not_member}
    end
  end

  @doc "Add a member to an OsInstance."
  def add_member(os_id, user_id, role) do
    %OsInstanceMember{}
    |> OsInstanceMember.changeset(%{
      "os_instance_id" => os_id,
      "user_id" => user_id,
      "role" => role
    })
    |> Repo.insert()
  end

  @doc "Remove a member from an OsInstance."
  def remove_member(os_id, user_id) do
    OsInstanceMember
    |> where([m], m.os_instance_id == ^os_id and m.user_id == ^user_id)
    |> Repo.delete_all()
    |> case do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc "List all members of an OsInstance."
  def list_members(os_id) do
    OsInstanceMember
    |> where([m], m.os_instance_id == ^os_id)
    |> Repo.all()
  end
end
