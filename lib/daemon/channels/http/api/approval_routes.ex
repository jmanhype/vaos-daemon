defmodule Daemon.Channels.HTTP.API.ApprovalRoutes do
  @moduledoc """
  Approval lifecycle routes.
  Forwarded from /approvals in the main API router.
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Governance.Approvals

  plug :match
  plug :dispatch

  # ── GET / — list all approvals ────────────────────────────────────────

  get "/" do
    conn = Plug.Conn.fetch_query_params(conn)
    {page, per_page} = pagination_params(conn)

    filters =
      %{}
      |> maybe_put_map("status", conn.query_params["status"])
      |> maybe_put_map("type", conn.query_params["type"])
      |> Map.merge(%{page: page, per_page: per_page})

    result = Approvals.list_all(filters)
    json(conn, 200, result)
  end

  # ── GET /pending — pending approvals with count ───────────────────────

  get "/pending" do
    json(conn, 200, %{
      count: Approvals.pending_count(),
      approvals: Approvals.list_pending()
    })
  end

  # ── POST / — create approval ──────────────────────────────────────────

  post "/" do
    required = ~w(type title description requested_by)

    with params when is_map(params) <- conn.body_params,
         true <- Enum.all?(required, &(Map.has_key?(params, &1) and params[&1] != "")) do
      attrs = %{
        type: params["type"],
        title: params["title"],
        description: params["description"],
        requested_by: params["requested_by"],
        context: params["context"]
      }

      case Approvals.create(attrs) do
        {:ok, approval} -> json(conn, 201, approval)
        {:error, changeset} -> json_error(conn, 422, "validation_error", format_changeset_errors(changeset))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required fields: type, title, description, requested_by")
    end
  end

  # ── POST /:id/approve ─────────────────────────────────────────────────

  post "/:id/approve" do
    resolve_approval(conn, id, "approved")
  end

  # ── POST /:id/reject ──────────────────────────────────────────────────

  post "/:id/reject" do
    resolve_approval(conn, id, "rejected")
  end

  # ── POST /:id/request-revision ────────────────────────────────────────

  post "/:id/request-revision" do
    resolve_approval(conn, id, "revision_requested")
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp resolve_approval(conn, id, decision) do
    notes = conn.body_params["notes"]
    resolved_by = conn.body_params["resolved_by"]

    case Approvals.resolve(id, decision, notes, resolved_by) do
      {:ok, approval} -> json(conn, 200, approval)
      {:error, :not_found} -> json_error(conn, 404, "not_found", "Approval not found")
      {:error, :already_resolved} -> json_error(conn, 409, "already_resolved", "Approval has already been resolved")
    end
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, ""), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp format_changeset_errors(%Ecto.Changeset{} = cs), do: changeset_errors(cs)
  defp format_changeset_errors(reason), do: to_string(reason)
end
