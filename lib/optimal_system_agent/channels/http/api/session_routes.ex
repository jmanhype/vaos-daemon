defmodule OptimalSystemAgent.Channels.HTTP.API.SessionRoutes do
  @moduledoc """
  Session management routes.

    GET    /sessions
    POST   /sessions
    GET    /sessions/:id
    GET    /sessions/:id/messages
    POST   /sessions/:id/message
    POST   /sessions/:id/cancel
    POST   /sessions/:id/survey/answer
    POST   /sessions/:id/survey/skip
    DELETE /sessions/:id
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Agent.Loop

  plug :match
  plug :dispatch

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    {page, per_page} = pagination_params(conn)

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
      |> Enum.sort_by(fn s -> s.last_active || "9999-99-99T99:99:99" end, :desc)

    total = length(sessions)

    paginated =
      sessions
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    body = Jason.encode!(%{sessions: paginated, count: total, page: page, per_page: per_page})

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

      {:error, _reason} ->
        json_error(conn, 500, "session_create_failed", "An internal error occurred while creating the session")
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
        messages
        |> Enum.reject(fn m -> m["role"] == "system" end)
        |> Enum.map(fn m ->
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
      messages
      |> Enum.reject(fn m -> m["role"] == "system" end)
      |> Enum.map(fn m ->
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

  # ── DELETE /sessions/:id ───────────────────────────────────────────

  delete "/:id" do
    session_id = conn.params["id"]

    # Cancel active loop if running (ignore if already stopped)
    Loop.cancel(session_id)

    # Remove the session JSONL file from disk
    sessions_dir =
      Application.get_env(:optimal_system_agent, :sessions_dir, "~/.osa/sessions")
      |> Path.expand()

    session_file = Path.join(sessions_dir, "#{session_id}.jsonl")

    case File.rm(session_file) do
      :ok ->
        body = Jason.encode!(%{status: "deleted", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :enoent} ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      {:error, _reason} ->
        json_error(conn, 500, "delete_failed", "An internal error occurred while deleting the session")
    end
  end

  # ── POST /sessions/:id/cancel ──────────────────────────────────────

  post "/:id/cancel" do
    session_id = conn.params["id"]

    case Loop.cancel(session_id) do
      :ok ->
        body = Jason.encode!(%{status: "cancel_requested", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_running} ->
        json_error(conn, 404, "not_running", "No active agent loop for session #{session_id}")
    end
  end

  # ── POST /sessions/:id/survey/answer ──────────────────────────────

  post "/:id/survey/answer" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]
    answers = body["answers"]

    unless survey_id && answers do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing survey_id or answers"}))
      |> halt()
    end

    key = {session_id, survey_id}
    :ets.insert(:osa_survey_answers, {key, answers})

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :survey_answered,
      session_id: session_id,
      data: %{
        survey_id: survey_id,
        summary:
          Enum.map(answers, fn a ->
            answer_text =
              case a do
                %{"free_text" => ft} when is_binary(ft) and ft != "" -> ft
                %{"selected" => selected} -> Enum.join(selected, ", ")
                _ -> ""
              end

            {a["question_text"] || "", answer_text}
          end)
      }
    })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # ── POST /sessions/:id/survey/skip ───────────────────────────────

  post "/:id/survey/skip" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]

    unless survey_id do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing survey_id"}))
      |> halt()
    end

    key = {session_id, survey_id}
    :ets.insert(:osa_survey_answers, {key, :skipped})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "skipped"}))
  end

  # ── POST /sessions/:id/proactive ───────────────────────────────

  post "/:id/proactive" do
    body = conn.body_params

    case body["enabled"] do
      true ->
        OptimalSystemAgent.Agent.ProactiveMode.enable()
        resp = Jason.encode!(%{status: "ok", enabled: true})
        conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

      false ->
        OptimalSystemAgent.Agent.ProactiveMode.disable()
        resp = Jason.encode!(%{status: "ok", enabled: false})
        conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

      _ ->
        json_error(conn, 400, "invalid_request", "Provide {\"enabled\": true|false}")
    end
  end

  # ── GET /sessions/:id/activity ─────────────────────────────────

  get "/:id/activity" do
    log = OptimalSystemAgent.Agent.ProactiveMode.activity_log()
    body = Jason.encode!(%{activity: log, count: length(log)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # ── POST /sessions/:id/message ─────────────────────────────────

  post "/:id/message" do
    session_id = conn.params["id"]
    body = conn.body_params

    message = body["message"]

    unless is_binary(message) && message != "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing or empty message"}))
      |> halt()
    end

    # Check session exists before dispatching async
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        # Fire-and-forget — the loop processes in background.
        # Client polls GET /sessions/:id/messages for results.
        # Uses Task.Supervisor to ensure the task survives long LLM calls
        # (Task.start would create an unsupervised process that may be reaped).
        Task.Supervisor.start_child(
          OptimalSystemAgent.TaskSupervisor,
          fn -> Loop.process_message(session_id, message) end,
          restart: :temporary
        )

        resp = Jason.encode!(%{status: "processing", session_id: session_id})
        conn |> put_resp_content_type("application/json") |> send_resp(202, resp)

      [] ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Session endpoint not found")
  end

end
