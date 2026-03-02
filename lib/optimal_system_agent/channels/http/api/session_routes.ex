defmodule OptimalSystemAgent.Channels.HTTP.API.SessionRoutes do
  @moduledoc """
  Session management routes.

    GET  /sessions
    POST /sessions
    GET  /sessions/:id
    GET  /sessions/:id/messages
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.Memory

  plug :match
  plug :dispatch

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    # Merge persisted sessions (from Memory/SQLite) with live Registry sessions.
    persisted = Memory.list_sessions()

    live_ids =
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    persisted_map = Map.new(persisted, fn s -> {s.session_id, s} end)
    all_ids = Enum.uniq(Map.keys(persisted_map) ++ live_ids)

    sessions =
      Enum.map(all_ids, fn sid ->
        meta = Map.get(persisted_map, sid, %{})
        alive = sid in live_ids

        %{
          id: sid,
          title: Map.get(meta, :topic_hint),
          message_count: Map.get(meta, :message_count, 0),
          created_at: Map.get(meta, :first_active),
          last_active: Map.get(meta, :last_active),
          alive: alive
        }
      end)
      |> Enum.sort_by(fn s -> s.last_active || "" end, :desc)

    body = Jason.encode!(%{sessions: sessions, count: length(sessions)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sessions ─────────────────────────────────────────────────

  post "/" do
    user_id = conn.assigns[:user_id] || "anonymous"

    case OptimalSystemAgent.SDK.Session.create(user_id: user_id, channel: :http) do
      {:ok, session_id} ->
        body = Jason.encode!(%{id: session_id, status: "created"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, body)

      {:error, reason} ->
        json_error(conn, 500, "session_create_failed", inspect(reason))
    end
  end

  # ── GET /sessions/:id ──────────────────────────────────────────────

  get "/:id" do
    session_id = conn.params["id"]
    persisted = Memory.list_sessions()
    meta = Enum.find(persisted, fn s -> s.session_id == session_id end)

    alive =
      case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
        [{_pid, _}] -> true
        [] -> false
      end

    if meta || alive do
      messages = Memory.load_session(session_id) || []

      formatted_messages =
        Enum.map(messages, fn m ->
          %{
            role: m["role"],
            content: m["content"],
            timestamp: m["timestamp"]
          }
        end)

      body =
        Jason.encode!(%{
          id: session_id,
          title: if(meta, do: meta.topic_hint),
          message_count: if(meta, do: meta.message_count, else: length(messages)),
          created_at: if(meta, do: meta.first_active),
          last_active: if(meta, do: meta.last_active),
          alive: alive,
          messages: formatted_messages
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── GET /sessions/:id/messages ─────────────────────────────────────

  get "/:id/messages" do
    session_id = conn.params["id"]
    messages = Memory.load_session(session_id) || []

    formatted =
      Enum.map(messages, fn m ->
        %{
          role: m["role"],
          content: m["content"],
          timestamp: m["timestamp"]
        }
      end)

    body = Jason.encode!(%{messages: formatted, count: length(formatted)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Session endpoint not found")
  end
end
