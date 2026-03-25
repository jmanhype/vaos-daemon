defmodule Daemon.Channels.HTTP.API.SessionRoutes do
  @moduledoc """
  Session management routes.

    GET    /sessions
    POST   /sessions
    GET    /sessions/:id
    GET    /sessions/:id/messages
    GET    /sessions/:id/stream   — SSE event stream for the session
    POST   /sessions/:id/message
    POST   /sessions/:id/cancel
    POST   /sessions/:id/survey/answer
    POST   /sessions/:id/survey/skip
    DELETE /sessions/:id
  """
  use Plug.Router
  import Plug.Conn
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Agent.Memory
  alias Daemon.Agent.Loop

  plug :match
  plug :dispatch

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    {page, per_page} = pagination_params(conn)

    # Merge persisted sessions (from Memory/SQLite) with live Registry sessions.
    persisted = Memory.list_sessions()

    live_ids =
      Registry.select(Daemon.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

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

    case Daemon.SDK.Session.create(user_id: user_id, channel: :http) do
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
      case Registry.lookup(Daemon.SessionRegistry, session_id) do
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

  # ── GET /sessions/:id/stream — SSE event stream ────────────────────
  #
  # Convenience alias for GET /stream/:id handled by AgentRoutes.
  # Subscribes to the session-scoped PubSub topic "osa:session:{id}" and
  # streams {:daemon_event, event} messages as SSE frames until the client
  # disconnects. A `: keepalive` comment is sent every 30 s to prevent
  # proxy timeouts.
  #
  # Event frame format:
  #   event: <event_type>\n
  #   data: <json>\n\n
  #
  # system_event sub-events are unwrapped so that the TUI SSE parser
  # receives the sub-event name as the SSE event type, matching the
  # behaviour in AgentRoutes.sse_loop/2.

  get "/:id/stream" do
    session_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"

    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:session:#{session_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

    Logger.debug("[SSE] /sessions/#{session_id}/stream opened by #{user_id}")

    session_sse_loop(conn, session_id)
  end

  # ── DELETE /sessions/:id ───────────────────────────────────────────

  delete "/:id" do
    session_id = conn.params["id"]

    # Cancel active loop if running (ignore if already stopped)
    Loop.cancel(session_id)

    # Remove the session JSONL file from disk
    sessions_dir =
      Application.get_env(:daemon, :sessions_dir, "~/.daemon/sessions")
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
    :ets.insert(:daemon_survey_answers, {key, answers})

    Daemon.Events.Bus.emit(:system_event, %{
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
    :ets.insert(:daemon_survey_answers, {key, :skipped})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "skipped"}))
  end

  # ── POST /sessions/:id/proactive ───────────────────────────────

  post "/:id/proactive" do
    body = conn.body_params

    case body["enabled"] do
      true ->
        Daemon.Agent.ProactiveMode.enable()
        resp = Jason.encode!(%{status: "ok", enabled: true})
        conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

      false ->
        Daemon.Agent.ProactiveMode.disable()
        resp = Jason.encode!(%{status: "ok", enabled: false})
        conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

      _ ->
        json_error(conn, 400, "invalid_request", "Provide {\"enabled\": true|false}")
    end
  end

  # ── GET /sessions/:id/activity ─────────────────────────────────

  get "/:id/activity" do
    log = Daemon.Agent.ProactiveMode.activity_log()
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
    case Registry.lookup(Daemon.SessionRegistry, session_id) do
      [{_pid, _}] ->
        # Pre-filter noise before dispatching to the agent loop.
        # Mirrors the same check done in orchestration_routes.ex.
        case Daemon.Channels.NoiseFilter.check(message, nil) do
          {:filtered, _ack} ->
            resp = Jason.encode!(%{status: "filtered", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          {:clarify, prompt} ->
            resp = Jason.encode!(%{status: "clarify", prompt: prompt, session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          :pass ->
            # Fire-and-forget — the loop processes in background.
            # Client polls GET /sessions/:id/messages for results.
            # Uses Task.Supervisor to ensure the task survives long LLM calls
            # (Task.start would create an unsupervised process that may be reaped).
            Task.Supervisor.start_child(
              Daemon.TaskSupervisor,
              fn -> Loop.process_message(session_id, message) end,
              restart: :temporary
            )

            resp = Jason.encode!(%{status: "processing", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(202, resp)
        end

      [] ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── POST /sessions/:id/replay ──────────────────────────────────────

  post "/:id/replay" do
    source_session_id = conn.params["id"]
    body = conn.body_params

    opts =
      []
      |> then(fn o -> if b = body["session_id"], do: Keyword.put(o, :session_id, b), else: o end)
      |> then(fn o -> if b = body["provider"], do: Keyword.put(o, :provider, b), else: o end)
      |> then(fn o -> if b = body["model"], do: Keyword.put(o, :model, b), else: o end)

    case Daemon.Agent.Replay.replay(source_session_id, opts) do
      {:ok, replay_id} ->
        resp =
          Jason.encode!(%{
            status: "replaying",
            source_session_id: source_session_id,
            replay_session_id: replay_id
          })

        conn |> put_resp_content_type("application/json") |> send_resp(202, resp)

      {:error, :not_found} ->
        json_error(conn, 404, "no_history", "No stored conversation for session #{source_session_id}")

      {:error, reason} ->
        json_error(conn, 500, "replay_failed", inspect(reason))
    end
  end

  # ── POST /sessions/:id/provider ── hot-swap LLM provider ──────────

  post "/:id/provider" do
    session_id = conn.params["id"]
    body = conn.body_params

    provider = body["provider"]
    model = body["model"]

    if not (is_binary(provider) and provider != "") do
      conn
      |> send_resp(400, Jason.encode!(%{error: "provider is required"}))
      |> halt()
    else
      case Registry.lookup(Daemon.SessionRegistry, session_id) do
        [{pid, _}] ->
          case GenServer.call(pid, {:swap_provider, provider, model}) do
            :ok ->
              resp =
                Jason.encode!(%{
                  status: "ok",
                  session_id: session_id,
                  provider: provider,
                  model: model
                })

              conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

            {:error, reason} ->
              json_error(conn, 500, "swap_failed", inspect(reason))
          end

        [] ->
          json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
      end
    end
  end

  # ── GET /:id/pending_questions ─────────────────────────────────────────

  get "/:id/pending_questions" do
    session_id = conn.params["id"]

    questions =
      try do
        :ets.tab2list(:daemon_pending_questions)
        |> Enum.filter(fn {_ref, meta} -> meta.session_id == session_id end)
        |> Enum.map(fn {ref, meta} ->
          %{
            ref: ref,
            question: meta.question,
            options: meta.options,
            asked_at: meta.asked_at
          }
        end)
      rescue
        _ -> []
      end

    body = Jason.encode!(%{pending_questions: questions, count: length(questions)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Session endpoint not found")
  end

  # ── SSE loop for session stream ──────────────────────────────────────
  #
  # Mirrors the loop in AgentRoutes so both entry points behave identically.
  # Receives {:daemon_event, event} messages from Phoenix.PubSub and writes
  # each as an SSE frame. Sends a keepalive comment after 30 s of silence.
  # Exits when the client disconnects (chunk/2 returns {:error, _}).

  defp session_sse_loop(conn, session_id) do
    receive do
      {:daemon_event, event} ->
        event_type =
          case event do
            %{type: :system_event, event: sub} -> to_string(sub)
            %{type: t} -> to_string(t)
            _ -> "unknown"
          end

        case Jason.encode(event) do
          {:ok, data} ->
            Logger.debug("[SSE] session=#{session_id} sending #{event_type}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                session_sse_loop(conn, session_id)

              {:error, _reason} ->
                Logger.debug("[SSE] client disconnected: session=#{session_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] session=#{session_id} encode failed for #{event_type}: #{inspect(reason)}")
            session_sse_loop(conn, session_id)
        end

    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> session_sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end
end
