defmodule OptimalSystemAgent.Channels.HTTP.API.OrchestrationRoutes do
  @moduledoc """
  Orchestration routes — simple agent, complex multi-agent, and swarm.

  This module handles two forwarded prefixes from the parent router:
    forward "/orchestrate" → routes here use /[...] relative paths
    forward "/swarm"       → routes here use /[...] relative paths

  Effective endpoints:
    POST   /orchestrate                   — Simple fire-and-forget via agent loop
    POST   /orchestrate/complex           — Launch multi-agent orchestrated task
    GET    /orchestrate/tasks             — List all orchestrated tasks
    GET    /orchestrate/:task_id/progress — Real-time progress for a task
    POST   /swarm/launch                  — Launch a new swarm
    GET    /swarm                         — List all swarms
    GET    /swarm/:id                     — Get swarm status
    DELETE /swarm/:id                     — Cancel a swarm
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Swarm.Orchestrator, as: Swarm
  alias OptimalSystemAgent.Agent.Orchestrator, as: TaskOrchestrator
  alias OptimalSystemAgent.Agent.Progress

  plug :match
  plug :dispatch

  # ── POST / — simple orchestrate ────────────────────────────────────
  # Receives prefix-stripped path after forward "/orchestrate".

  post "/" do
    with %{"input" => input} <- conn.body_params do
      user_id = conn.body_params["user_id"] || conn.assigns[:user_id]
      session_id = conn.body_params["session_id"] || generate_session_id()

      case Session.ensure_loop(session_id, user_id, :http) do
        {:error, reason} ->
          json_error(conn, 503, "session_unavailable", "Could not start session: #{inspect(reason)}")

        _ ->
          skip_plan = conn.body_params["skip_plan"] == true
          Task.start(fn -> Loop.process_message(session_id, input, skip_plan: skip_plan) end)

          body = Jason.encode!(%{session_id: session_id, status: "processing"})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)
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

  # ── POST /complex ───────────────────────────────────────────────────

  post "/complex" do
    with %{"task" => task} when is_binary(task) and task != "" <- conn.body_params do
      strategy = conn.body_params["strategy"] || "auto"
      session_id = conn.body_params["session_id"] || generate_session_id()
      blocking = conn.body_params["blocking"] == true

      case TaskOrchestrator.execute(task, session_id, strategy: strategy) do
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
        json_error(conn, 404, "not_found", "Task #{task_id} not found")
    end
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

  @valid_swarm_patterns ~w(parallel pipeline debate review)

  defp parse_swarm_pattern_opts(nil), do: {:ok, []}

  defp parse_swarm_pattern_opts(p) when is_binary(p) do
    if p in @valid_swarm_patterns do
      {:ok, [pattern: String.to_existing_atom(p)]}
    else
      {:error, :invalid_pattern,
       "Invalid swarm pattern '#{p}'. Valid patterns: #{Enum.join(@valid_swarm_patterns, ", ")}"}
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
