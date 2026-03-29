defmodule Daemon.Channels.HTTP.API.ConfigRoutes do
  @moduledoc """
  Configuration revision history and rollback routes.

  Provides audit trail and time-travel for configuration entities (agents, skills, tools).
  All revisions are immutable and tracked with timestamps and metadata.

  Endpoints:
    GET  /revisions/:entity_type/:entity_id              — List all revisions for an entity
    GET  /revisions/:entity_type/:entity_id/:number      — Fetch a specific revision
    POST /revisions/:entity_type/:entity_id/rollback     — Rollback to a specific revision
    GET  /revisions/:entity_type/:entity_id/diff         — Compare two revisions (from, to query params)

  Examples:
    GET  /api/v1/config/revisions/agent/orchestrator          — List orchestrator agent revisions
    GET  /api/v1/config/revisions/agent/orchestrator/3        — Get revision 3
    POST /api/v1/config/revisions/agent/orchestrator/rollback — Rollback (requires revision_number in body)
    GET  /api/v1/config/revisions/agent/orchestrator/diff?from=2&to=5 — Compare revisions

  The revision system enables safe experimentation with configuration changes
  and quick recovery from problematic deployments.
  """
  use Plug.Router
  import Plug.Conn
  import Daemon.Channels.HTTP.API.Shared, except: [parse_int: 1]

  alias Daemon.Governance.ConfigRevisions

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
        json_error(conn, 400, "invalid_revision_number", "Must be an integer")
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
    with {from_n, ""} <- parse_revision_number(conn.query_params["from"]),
         {to_n, ""} <- parse_revision_number(conn.query_params["to"]),
         {:ok, rev_a} <- ConfigRevisions.get_revision(entity_type, entity_id, from_n),
         {:ok, rev_b} <- ConfigRevisions.get_revision(entity_type, entity_id, to_n) do
      diff = ConfigRevisions.diff(rev_a, rev_b)
      body = Jason.encode!(%{diff: diff, from: from_n, to: to_n})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    else
      :missing -> json_error(conn, 400, "missing_param", "'from' and 'to' required")
      :invalid -> json_error(conn, 400, "invalid_revision_number", "Must be integers")
      {:error, :not_found} -> json_error(conn, 404, "revision_not_found", "Not found")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Config route not found")
  end

  defp parse_revision_number(nil), do: :missing
  defp parse_revision_number(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {_, ""} = ok -> ok
      _ -> :invalid
    end
  end
end
