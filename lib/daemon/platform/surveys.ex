defmodule Daemon.Platform.Surveys do
  import Ecto.Query
  alias Daemon.Platform.Repo
  alias Daemon.Platform.Schemas.SurveyResponse

  def create(attrs) do
    %SurveyResponse{}
    |> SurveyResponse.changeset(attrs)
    |> Repo.insert()
  end

  def get(id), do: Repo.get(SurveyResponse, id)

  def list_recent(limit \\ 50) do
    from(s in SurveyResponse, order_by: [desc: s.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  def link_to_user(email, user_id) do
    from(s in SurveyResponse, where: s.email == ^email and is_nil(s.user_id))
    |> Repo.update_all(set: [user_id: user_id])
  end

  def stats do
    roles =
      from(s in SurveyResponse, group_by: s.role, select: {s.role, count(s.id)})
      |> Repo.all()
      |> Map.new()

    sources =
      from(s in SurveyResponse, group_by: s.source, select: {s.source, count(s.id)})
      |> Repo.all()
      |> Map.new()

    total = Repo.aggregate(SurveyResponse, :count)

    %{total: total, roles: roles, sources: sources}
  end
end
