defmodule OptimalSystemAgent.Channels.HTTP.API.ConfigRoutes do
  use Plug.Router
  import Plug.Conn
  import OptimalSystemAgent.Channels.HTTP.API.Shared, except: [parse_int: 1]

  alias OptimalSystemAgent.Governance.ConfigRevisions

  plug :match
  plug :dispatch

  get "/revisions/:entity_type/:entity_id" do
    revisions = ConfigRevisions.list_revisions(entity_type, entity_id)
    body = Jason.encode!(%{revisions: revisions, count: length(revisions)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  get "/revisions/:entity_type/:entity_id/:number" do
    case Integer.parse(number) do
      {n, ""} ->
        case ConfigRevisions.get_revision(entity_type, entity_id, n) do
          {:ok, rev} ->
            conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(rev))
          {:error, :not_found} ->
            json_error(conn, 404, "revision_not_found", "Revision #{n} not found")
        end
      _ ->
        json_error(conn, 400, "invalid_revision_number", "Revision number must be an integer")
    end
  end

  post "/revisions/:entity_type/:entity_id/rollback" do
    case conn.body_params["revision_number"] do
      nil ->
        json_error(conn, 400, "missing_param", "revision_number is required")
      rev_num ->
        case ConfigRevisions.rollback(entity_type, entity_id, rev_num) do
          {:ok, rev} ->
            conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(rev))
          {:error, :not_found} ->
            json_error(conn, 404, "revision_not_found", "Revision not found")
          {:error, _} ->
            json_error(conn, 400, "rollback_failed", "Rollback could not be completed")
        end
    end
  end

  get "/revisions/:entity_type/:entity_id/diff" do
    conn = fetch_query_params(conn)
    with {from_n, ""} <- parse_int(conn.query_params["from"]),
         {to_n, ""} <- parse_int(conn.query_params["to"]),
         {:ok, rev_a} <- ConfigRevisions.get_revision(entity_type, entity_id, from_n),
         {:ok, rev_b} <- ConfigRevisions.get_revision(entity_type, entity_id, to_n) do
      diff = ConfigRevisions.diff(rev_a, rev_b)
      body = Jason.encode!(%{diff: diff, from: from_n, to: to_n})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    else
      :missing -> json_error(conn, 400, "missing_param", "Query params 'from' and 'to' are required")
      :invalid -> json_error(conn, 400, "invalid_revision_number", "Revision numbers must be integers")
      {:error, :not_found} -> json_error(conn, 404, "revision_not_found", "Revision not found")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Config route not found")
  end

  defp parse_int(nil), do: :missing
  defp parse_int(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {_, ""} = ok -> ok
      _ -> :invalid
    end
  end
end
