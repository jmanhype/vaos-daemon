defmodule OptimalSystemAgent.Governance.ConfigRevisions do
  import Ecto.Query
  alias OptimalSystemAgent.Governance.ConfigRevision
  alias OptimalSystemAgent.Store.Repo

  def track_change(entity_type, entity_id, old_config, new_config, changed_by, reason \\ nil) do
    changed_fields = diff_keys(old_config || %{}, new_config)

    %ConfigRevision{}
    |> ConfigRevision.changeset(%{
      entity_type: entity_type, entity_id: entity_id,
      revision_number: next_revision(entity_type, entity_id),
      previous_config: old_config, new_config: new_config,
      changed_fields: changed_fields, changed_by: changed_by,
      change_reason: reason, metadata: %{}
    })
    |> Repo.insert()
  end

  def list_revisions(entity_type, entity_id, opts \\ []) do
    ConfigRevision
    |> where([r], r.entity_type == ^entity_type and r.entity_id == ^entity_id)
    |> order_by([r], desc: r.revision_number)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  def get_revision(entity_type, entity_id, revision_number) do
    case Repo.get_by(ConfigRevision,
           entity_type: entity_type, entity_id: entity_id,
           revision_number: revision_number) do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end

  def rollback(entity_type, entity_id, target_number) do
    with {:ok, target} <- get_revision(entity_type, entity_id, target_number) do
      current = current_config(entity_type, entity_id)
      track_change(entity_type, entity_id, current, target.new_config,
        "system", "Rollback to revision #{target_number}")
    end
  end

  def diff(%ConfigRevision{new_config: a}, %ConfigRevision{new_config: b}) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, acc ->
      va = Map.get(a, key)
      vb = Map.get(b, key)
      if va == vb, do: acc, else: Map.put(acc, key, %{from: va, to: vb})
    end)
  end

  defp next_revision(entity_type, entity_id) do
    (ConfigRevision
    |> where([r], r.entity_type == ^entity_type and r.entity_id == ^entity_id)
    |> select([r], max(r.revision_number))
    |> Repo.one() || 0) + 1
  end

  defp diff_keys(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
  end

  defp current_config(entity_type, entity_id) do
    case list_revisions(entity_type, entity_id, limit: 1) do
      [latest | _] -> latest.new_config
      [] -> %{}
    end
  end
end
