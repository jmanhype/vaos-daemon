defmodule Daemon.Channels.HTTP.API.OrchestrationRoutes do
  @moduledoc """
  Orchestration routes — simple agent, complex multi-agent, and swarm.

  This module handles three forwarded prefixes from the parent router:
    forward "/orchestrate"  → routes here use /[...] relative paths
    forward "/orchestrator" → alias for /orchestrate (backward compat)
    forward "/swarm"        → routes here use /[...] relative paths

  Effective endpoints:
    POST   /orchestrate                   — Simple fire-and-forget via agent loop
    POST   /orchestrate/complex           — Launch multi-agent orchestrated task
    POST   /orchestrator/complex          — Alias (same handler, backward compat)
    GET    /orchestrate/tasks             — List all orchestrated tasks
    GET    /orchestrate/:task_id/progress — Real-time progress for a task
    POST   /swarm/launch                  — Launch a new swarm
    GET    /swarm                         — List all swarms
    GET    /swarm/status/:id              — Get swarm status (canonical path)
    GET    /swarm/:id                     — Get swarm status (short alias)
    DELETE /swarm/:id                     — Cancel a swarm
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Agent.Loop
  alias Daemon.Channels.Session
  alias Daemon.Channels.NoiseFilter
  alias Daemon.Agent.Orchestrator.SwarmMode, as: Swarm
  alias Daemon.Agent.Orchestrator.Patterns, as: SwarmPatterns
  alias Daemon.Agent.Orchestrator, as: TaskOrchestrator
  alias Daemon.Agent.Orchestrator.Complexity
  alias Daemon.Agent.Progress

  plug :match
  plug :dispatch

  # ── POST / — simple orchestrate ────────────────────────────────────
  # Receives prefix-stripped path after forward "/orchestrate".

  post "/" do
    with %{"input" => input} <- conn.body_params do
      user_id = conn.body_params["user_id"] || conn.assigns[:user_id]
      session_id = conn.body_params["session_id"] || generate_session_id()

      signal_weight =
        case get_req_header(conn, "x-signal-weight") do
          [v | _] ->
            case Float.parse(v) do
              {f, _} -> f
              :error -> nil
            end
          [] -> nil
        end

      case Session.ensure_loop(session_id, user_id, :http) do
        {:error, reason} ->
          json_error(conn, 503, "session_unavailable", "Could not start session: #{inspect(reason)}")

        _ ->
          case NoiseFilter.check(input, signal_weight) do
            {:filtered, _ack} ->
              body = Jason.encode!(%{session_id: session_id, status: "filtered"})

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, body)

            {:clarify, prompt} ->
              body = Jason.encode!(%{session_id: session_id, status: "clarify", prompt: prompt})

              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, body)

            _ ->
              skip_plan = conn.body_params["skip_plan"] == true
              working_dir = conn.body_params["working_dir"]
              auto_dispatch = conn.body_params["auto_dispatch"] != false

              # Auto-dispatch: detect complexity and route to multi-agent orchestrator when needed.
              # Uses a cheap heuristic first; only calls the LLM analyser when the heuristic
              # flags the input as possibly complex.
              route =
                if auto_dispatch do
                  case Complexity.quick_check(input) do
                    :possibly_complex ->
                      case Complexity.analyze(input) do
                        {:complex, _score, _sub_tasks} -> :multi_agent
                        {:simple, _score} -> :single_agent
                      end

                    :likely_simple ->
                      :single_agent
                  end
                else
                  :single_agent
                end

              case route do
                :multi_agent ->
                  execute_opts = [strategy: "auto"]
                  execute_opts = maybe_put(execute_opts, :max_agents, conn.body_params["max_agents"])

                  case TaskOrchestrator.execute(input, session_id, execute_opts) do
                    {:ok, task_id} ->
                      body = Jason.encode!(%{
                        session_id: session_id,
                        task_id: task_id,
                        status: "processing",
                        mode: "multi_agent"
                      })

                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(202, body)

                    {:error, _reason} ->
                      # Fallback to single agent on orchestrator failure
                      opts = [skip_plan: skip_plan]
                      opts = if is_binary(working_dir) and working_dir != "", do: Keyword.put(opts, :working_dir, working_dir), else: opts
                      Task.start(fn -> Loop.process_message(session_id, input, opts) end)

                      body = Jason.encode!(%{session_id: session_id, status: "processing", mode: "single_agent"})

                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(202, body)
                  end

                :single_agent ->
                  opts = [skip_plan: skip_plan]
                  opts = if is_binary(working_dir) and working_dir != "", do: Keyword.put(opts, :working_dir, working_dir), else: opts
                  Task.start(fn -> Loop.process_message(session_id, input, opts) end)

                  body = Jason.encode!(%{session_id: session_id, status: "processing"})

                  conn
                  |> put_resp_content_type("application/json")
                  |> send_resp(202, body)
              end
          end
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: input")
    end
  end

  # ── GET /tasks — list tasks ─────────────────────────────────────────
  # Must be defined before /:task_id/progress to win the pattern match.

  get "/tasks" do
    tasks = TaskOrchestrator.list_tasks()
    active_count = Enum.count(tasks, &(&1.status == :running))

    body =
      Jason.encode!(%{
        tasks: tasks,
        count: length(tasks),
        active_count: active_count
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /autoresearch ──────────────────────────────────────────────
  # Launches a bilevel autoresearch loop: investigate → paper → code → eval → fix

  post "/autoresearch" do
    with %{"topic" => topic} when is_binary(topic) and topic != "" <- conn.body_params do
      depth = conn.body_params["depth"] || "deep"
      session_id = conn.body_params["session_id"] || generate_session_id()

      # Create a session and send the autoresearch task as a message
      {:ok, _session} = Session.create(session_id, conn.body_params["user_id"])

      task_message = """
      Run the autoresearch_loop tool with topic="#{topic}" depth="#{depth}".
      Then execute each step of the returned workflow sequentially.
      """

      Task.start(fn ->
        Loop.handle_message(session_id, task_message)
      end)

      json(conn, 200, %{
        session_id: session_id,
        topic: topic,
        depth: depth,
        status: "started",
        monitor: "/api/v1/sessions/#{session_id}"
      })
    else
      _ -> json(conn, 400, %{error: "Missing required field: topic"})
    end
  end

  # ── POST /complex ───────────────────────────────────────────────────

  post "/complex" do
    with %{"task" => task} when is_binary(task) and task != "" <- conn.body_params do
      strategy = conn.body_params["strategy"] || "auto"
      session_id = conn.body_params["session_id"] || generate_session_id()
      blocking = conn.body_params["blocking"] == true

      execute_opts = [strategy: strategy]
      execute_opts = maybe_put(execute_opts, :max_agents, conn.body_params["max_agents"])

      case TaskOrchestrator.execute(task, session_id, execute_opts) do
        {:ok, task_id} ->
          if blocking do
            case await_orchestration_http(task_id, 300_000) do
              {:ok, synthesis} ->
                body =
                  Jason.encode!(%{
                    task_id: task_id,
                    status: "completed",
                    synthesis: synthesis,
                    session_id: session_id
                  })

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, body)

              {:error, reason} ->
                json_error(conn, 504, "orchestration_timeout", to_string(reason))
            end
          else
            body =
              Jason.encode!(%{
                task_id: task_id,
                status: "running",
                session_id: session_id
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(202, body)
          end

        {:error, reason} ->
          json_error(conn, 422, "orchestration_error", inspect(reason))
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: task")
    end
  end

  # ── GET /:task_id/progress ─────────────────────────────────────────

  get "/:task_id/progress" do
    task_id = conn.params["task_id"]

    case TaskOrchestrator.progress(task_id) do
      {:ok, progress_data} ->
        formatted =
          case Progress.format(task_id) do
            {:ok, text} -> text
            _ -> nil
          end

        body = Jason.encode!(Map.put(progress_data, :formatted, formatted))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        # Orchestrator may have cleaned the task, but Progress GenServer retains it
        case Progress.get(task_id) do
          {:ok, progress_data} ->
            formatted =
              case Progress.format(task_id) do
                {:ok, text} -> text
                _ -> nil
              end

            body = Jason.encode!(Map.put(progress_data, :formatted, formatted))

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {:error, :not_found} ->
            json_error(conn, 404, "not_found", "Task #{task_id} not found")
        end
    end
  end

  # ── GET /:task_id/progress/stream ──────────────────────────────────
  # Real-time SSE stream of orchestrator agent progress, Claude Code style.

  get "/:task_id/progress/stream" do
    task_id = conn.params["task_id"]

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_chunked(200)

    # Subscribe to orchestrator progress updates via PubSub
    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:orchestrator:#{task_id}")

    # Send initial state if available
    case Progress.format(task_id) do
      {:ok, formatted} ->
        sse_event(conn, "progress", %{task_id: task_id, formatted: formatted})
      _ -> :ok
    end

    # Block and stream events until task completes or client disconnects
    stream_progress_loop(conn, task_id)
  end

  defp stream_progress_loop(conn, task_id) do
    receive do
      {:progress_update, ^task_id, formatted} ->
        case sse_event(conn, "progress", %{task_id: task_id, formatted: formatted}) do
          {:ok, conn} -> stream_progress_loop(conn, task_id)
          {:error, _} -> conn  # Client disconnected
        end
    after
      # Send keepalive every 30s, timeout after 10min of no updates
      30_000 ->
        case Progress.get(task_id) do
          {:ok, %{status: status}} when status in [:completed, :failed] ->
            sse_event(conn, "done", %{task_id: task_id, status: status})
            conn
          _ ->
            case chunk(conn, ": keepalive\n\n") do
              {:ok, conn} -> stream_progress_loop(conn, task_id)
              {:error, _} -> conn
            end
        end
    end
  end

  defp sse_event(conn, event, data) do
    payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    chunk(conn, payload)
  end

  # ── POST /launch ────────────────────────────────────────────────────
  # Receives prefix-stripped path after forward "/swarm".

  post "/launch" do
    with %{"task" => task} when is_binary(task) and task != "" <- conn.body_params,
         {:ok, pattern_opts} <- parse_swarm_pattern_opts(conn.body_params["pattern"]) do
      opts =
        pattern_opts
        |> maybe_put(:max_agents, conn.body_params["max_agents"])
        |> maybe_put(:timeout_ms, conn.body_params["timeout_ms"])
        |> maybe_put(:session_id, conn.body_params["session_id"])

      case Swarm.launch(task, opts) do
        {:ok, swarm_id} ->
          {:ok, swarm} = Swarm.status(swarm_id)

          body =
            Jason.encode!(%{
              swarm_id: swarm_id,
              status: swarm.status,
              pattern: swarm.pattern,
              agent_count: swarm.agent_count,
              agents: swarm.agents || [],
              started_at: swarm.started_at
            })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)

        {:error, reason} ->
          json_error(conn, 422, "swarm_error", to_string(reason))
      end
    else
      {:error, :invalid_pattern, msg} ->
        json_error(conn, 400, "invalid_pattern", msg)

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: task")
    end
  end

  # ── GET / — list swarms ─────────────────────────────────────────────

  get "/" do
    case Swarm.list_swarms() do
      {:ok, swarms} ->
        active_count = Enum.count(swarms, &(&1.status == :running))

        body =
          Jason.encode!(%{
            swarms: Enum.map(swarms, &swarm_to_map/1),
            count: length(swarms),
            active_count: active_count
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 500, "swarm_error", to_string(reason))
    end
  end

  # ── GET /status/:swarm_id ──────────────────────────────────────────
  # Public-facing effective path: GET /swarm/status/:id
  # Clients that hit /api/v1/swarm/status/<id> land here after the /swarm
  # prefix is stripped by the parent router, leaving /status/<id>.

  get "/status/:swarm_id" do
    swarm_id = conn.params["swarm_id"]

    case Swarm.status(swarm_id) do
      {:ok, swarm} ->
        body = Jason.encode!(swarm_to_map(swarm))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Swarm #{swarm_id} not found")

      {:error, reason} ->
        json_error(conn, 500, "swarm_error", to_string(reason))
    end
  end

  # ── GET /:swarm_id ─────────────────────────────────────────────────

  get "/:swarm_id" do
    swarm_id = conn.params["swarm_id"]

    case Swarm.status(swarm_id) do
      {:ok, swarm} ->
        body = Jason.encode!(swarm_to_map(swarm))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Swarm #{swarm_id} not found")

      {:error, reason} ->
        json_error(conn, 500, "swarm_error", to_string(reason))
    end
  end

  # ── DELETE /:swarm_id ──────────────────────────────────────────────

  delete "/:swarm_id" do
    swarm_id = conn.params["swarm_id"]

    case Swarm.cancel(swarm_id) do
      :ok ->
        body = Jason.encode!(%{status: "cancelled", swarm_id: swarm_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Swarm #{swarm_id} not found")

      {:error, reason} ->
        json_error(conn, 422, "swarm_error", to_string(reason))
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Orchestration endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp swarm_to_map(swarm) do
    %{
      id: swarm.id,
      status: swarm.status,
      task: swarm.task,
      pattern: swarm.pattern,
      agent_count: swarm.agent_count,
      agents: swarm.agents || [],
      result: swarm.result,
      error: swarm.error,
      started_at: swarm.started_at,
      completed_at: swarm.completed_at
    }
  end

  # Execution patterns — how agents coordinate.
  @execution_patterns ~w(parallel pipeline debate review)

  defp parse_swarm_pattern_opts(nil), do: {:ok, []}

  defp parse_swarm_pattern_opts(p) when is_binary(p) do
    cond do
      # Direct execution pattern override
      p in @execution_patterns ->
        {:ok, [pattern: String.to_existing_atom(p)]}

      # Named preset from priv/swarms/patterns.json — look up its execution mode
      true ->
        case SwarmPatterns.get_pattern(p) do
          {:ok, config} ->
            pattern_atom =
              case config["mode"] do
                "parallel" -> :parallel
                "pipeline" -> :pipeline
                "sequential" -> :pipeline
                "debate" -> :debate
                "review" -> :review
                _ -> nil
              end

            opts = if pattern_atom, do: [pattern: pattern_atom], else: []
            {:ok, opts}

          {:error, :not_found} ->
            presets = SwarmPatterns.list_patterns() |> Enum.map_join(", ", &elem(&1, 0))
            valid = Enum.join(@execution_patterns, ", ")

            {:error, :invalid_pattern,
             "Unknown pattern '#{p}'. Execution patterns: #{valid}. Named presets: #{presets}"}
        end
    end
  end

  defp parse_swarm_pattern_opts(_), do: {:error, :invalid_pattern, "Pattern must be a string"}

  defp await_orchestration_http(task_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_orchestration_http(task_id, deadline)
  end

  defp do_await_orchestration_http(task_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, "Orchestration timed out"}
    else
      case TaskOrchestrator.progress(task_id) do
        {:ok, %{status: :completed, synthesis: synthesis}} when is_binary(synthesis) ->
          {:ok, synthesis}

        {:ok, %{status: :completed}} ->
          {:ok, "Orchestration completed."}

        {:ok, %{status: _}} ->
          Process.sleep(500)
          do_await_orchestration_http(task_id, deadline)

        {:error, :not_found} ->
          {:error, "Task not found"}
      end
    end
  end
end
