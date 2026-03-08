defmodule OptimalSystemAgent.Platform.Grants do
  import Ecto.Query
  alias OptimalSystemAgent.Platform.Repo
  alias OptimalSystemAgent.Platform.Schemas.Grant

  def list(os_id) do
    from(g in Grant,
      where: (g.source_os_id == ^os_id or g.target_os_id == ^os_id) and is_nil(g.revoked_at),
      order_by: [desc: g.inserted_at]
    )
    |> Repo.all()
  end

  def create(attrs) do
    changeset = Grant.changeset(%Grant{}, attrs)

    with :ok <- validate_not_self_grant(changeset),
         :ok <- validate_expires_in_future(changeset) do
      Repo.insert(changeset)
    end
  end

  defp validate_not_self_grant(changeset) do
    source = Ecto.Changeset.get_field(changeset, :source_os_id)
    target = Ecto.Changeset.get_field(changeset, :target_os_id)

    if source && target && source == target do
      {:error, Ecto.Changeset.add_error(changeset, :target_os_id, "cannot grant to the same OS instance")}
    else
      :ok
    end
  end

  defp validate_expires_in_future(changeset) do
    case Ecto.Changeset.get_field(changeset, :expires_at) do
      nil -> :ok
      expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          :ok
        else
          {:error, Ecto.Changeset.add_error(changeset, :expires_at, "must be in the future")}
        end
    end
  end

  def revoke(grant_id) do
    case Repo.get(Grant, grant_id) do
      nil -> {:error, :not_found}
      grant -> grant |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()}) |> Repo.update()
    end
  end

  def check(source_os_id, target_os_id, grant_type) do
    now = DateTime.utc_now()
    query = from(g in Grant,
      where: g.source_os_id == ^source_os_id and g.target_os_id == ^target_os_id
        and g.grant_type == ^grant_type and is_nil(g.revoked_at)
        and (is_nil(g.expires_at) or g.expires_at > ^now)
    )
    Repo.exists?(query)
  end
end
