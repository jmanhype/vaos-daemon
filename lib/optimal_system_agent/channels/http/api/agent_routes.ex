defmodule OptimalSystemAgent.Channels.HTTP.API.AgentRoutes do
  @moduledoc """
  Agent SSE stream route.

    GET /:session_id  — SSE event stream for a session

  This module is forwarded to from the parent router at /stream, so routes
  are relative to that prefix.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug :match
  plug :dispatch

  # ── GET /:session_id ───────────────────────────────────────────────

  get "/:session_id" do
    session_id = conn.params["session_id"]
    user_id = conn.assigns[:user_id]

    case validate_session_owner(session_id, user_id) do
      :ok ->
        Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        {:ok, conn} =
          chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

        sse_loop(conn, session_id)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Session not found")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Agent endpoint not found")
  end

  # ── Session Ownership Validation ────────────────────────────────────

  defp validate_session_owner(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] ->
        cond do
          user_id == "anonymous" -> :ok
          owner == user_id -> :ok
          true ->
            Logger.warning(
              "[API] Session ownership mismatch: session=#{session_id} owner=#{inspect(owner)} requester=#{inspect(user_id)}"
            )

            {:error, :not_found}
        end

      _ ->
        if user_id == "anonymous" do
          :ok
        else
          {:error, :not_found}
        end
    end
  end

  # ── SSE Loop ────────────────────────────────────────────────────────

  defp sse_loop(conn, session_id) do
    receive do
      {:osa_event, event} ->
        event_type = Map.get(event, :type, "unknown") |> to_string()

        case Jason.encode(event) do
          {:ok, data} ->
            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                sse_loop(conn, session_id)

              {:error, _reason} ->
                Logger.debug("SSE client disconnected for session #{session_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] Failed to encode #{event_type} event: #{inspect(reason)}")
            sse_loop(conn, session_id)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end
end
