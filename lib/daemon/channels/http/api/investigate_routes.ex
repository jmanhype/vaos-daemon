defmodule Daemon.Channels.HTTP.API.InvestigateRoutes do
  @moduledoc """
  Investigation routes — claim investigation with streaming results.

  Effective endpoints:
    POST /              — Launch investigation with optional streaming
    GET /:task_id       — Get investigation results
    GET /:task_id/stream — SSE stream of investigation progress

  Investigation uses the Daemon.Tools.Builtins.Investigate tool which:
  - Runs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv)
  - Executes dual adversarial LLM analysis (FOR/AGAINST)
  - Verifies citations against paper abstracts
  - Scores evidence by hierarchy (review > trial > study)
  - Returns structured findings with evidence quality metrics
  """

  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Tools.Builtins.Investigate

  plug :match
  plug :dispatch

  # ── POST / — launch investigation ────────────────────────────────────

  post "/" do
    # Ensure ETS table exists
    ensure_table()

    with %{"topic" => topic} when is_binary(topic) and topic != "" <- conn.body_params do
      depth = conn.body_params["depth"] || "standard"
      steering = conn.body_params["steering"] || ""
      metadata = conn.body_params["metadata"] || %{}
      stream = conn.body_params["stream"] == true

      # Validate depth parameter
      unless depth in ["standard", "deep"] do
        json_error(conn, 400, "invalid_request", "depth must be 'standard' or 'deep'")
      else
        # Generate task ID for tracking
        task_id = generate_task_id()

        # Subscribe to investigation progress if streaming requested
        if stream do
          Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:investigate:#{task_id}")

          # Launch investigation asynchronously
          Task.start(fn ->
            run_and_publish_investigation(task_id, topic, depth, steering, metadata)
          end)

          # Return task ID immediately for streaming
          body = Jason.encode!(%{
            task_id: task_id,
            status: "running",
            stream_topic: "osa:investigate:#{task_id}"
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)
        else
          # Run synchronously (blocking mode)
          Task.start(fn ->
            run_and_publish_investigation(task_id, topic, depth, steering, metadata)
          end)

          body = Jason.encode!(%{
            task_id: task_id,
            status: "running"
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, body)
        end
      end
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: topic")
    end
  end

  # ── GET /:task_id — get investigation results ────────────────────────

  get "/:task_id" do
    # Ensure ETS table exists
    ensure_table()

    task_id = conn.params["task_id"]

    case get_investigation_result(task_id) do
      {:ok, result} ->
        body = Jason.encode!(result)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "Investigation #{task_id} not found")

      {:error, :running} ->
        body = Jason.encode!(%{
          task_id: task_id,
          status: "running"
        })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, body)
    end
  end

  # ── GET /:task_id/stream — SSE stream of investigation progress ─────

  get "/:task_id/stream" do
    # Ensure ETS table exists
    ensure_table()

    task_id = conn.params["task_id"]

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_chunked(200)

    # Subscribe to investigation progress
    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:investigate:#{task_id}")

    # Send initial connection event
    {:ok, conn} = chunk(conn, "event: connected\ndata: {\"task_id\": \"#{task_id}\"}\n\n")

    # Check if investigation already completed
    case get_investigation_result(task_id) do
      {:ok, result} ->
        # Investigation already complete - send final result
        send_final_result(conn, result)

      {:error, :running} ->
        # Still running - stream updates
        stream_investigation_progress(conn, task_id)

      {:error, :not_found} ->
        # Task doesn't exist yet - wait for it
        stream_investigation_progress(conn, task_id)
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Investigation endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp run_and_publish_investigation(task_id, topic, depth, steering, metadata) do
    # Publish start event
    publish_progress(task_id, %{status: "started", topic: topic})

    # Execute investigation
    args = %{
      "topic" => topic,
      "depth" => depth,
      "steering" => steering,
      "metadata" => Map.put(metadata, :task_id, task_id)
    }

    result = case Investigate.execute(args) do
      {:ok, investigation_result} ->
        # Parse JSON metadata from the result (embedded in VAOS_JSON comment)
        json_metadata = extract_json_metadata(investigation_result)

        %{
          status: "completed",
          result: investigation_result,
          metadata: json_metadata
        }

      {:error, reason} ->
        %{
          status: "failed",
          error: to_string(reason)
        }
    end

    # Store result for later retrieval
    store_investigation_result(task_id, result)

    # Publish completion event
    publish_progress(task_id, result)
  end

  defp stream_investigation_progress(conn, task_id) do
    receive do
      {:investigate_progress, ^task_id, data} ->
        event_type = Map.get(data, "status", "progress")
        payload = Jason.encode!(data)

        case chunk(conn, "event: #{event_type}\ndata: #{payload}\n\n") do
          {:ok, conn} ->
            if Map.get(data, "status") in ["completed", "failed"] do
              conn
            else
              stream_investigation_progress(conn, task_id)
            end

          {:error, _reason} ->
            Logger.debug("[Investigate] SSE client disconnected for task #{task_id}")
            conn
        end

    after
      # Send keepalive every 30s
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_investigation_progress(conn, task_id)
          {:error, _} -> conn
        end
    end
  end

  defp send_final_result(conn, result) do
    payload = Jason.encode!(result)

    case chunk(conn, "event: completed\ndata: #{payload}\n\n") do
      {:ok, _conn} -> :ok
      {:error, _} -> :error
    end
  end

  defp publish_progress(task_id, data) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "osa:investigate:#{task_id}", {:investigate_progress, task_id, data})
  end

  defp store_investigation_result(task_id, result) do
    :ets.insert(:investigation_results, {task_id, result, System.monotonic_time(:millisecond)})
  end

  defp get_investigation_result(task_id) do
    case :ets.lookup(:investigation_results, task_id) do
      [{^task_id, result, _timestamp}] ->
        case result do
          %{status: "completed"} -> {:ok, result}
          %{status: "failed"} -> {:ok, result}
          %{status: "running"} -> {:error, :running}
        end

      [] ->
        # Check if investigation is in progress by checking PubSub subscribers
        case Phoenix.PubSub.subscribers(Daemon.PubSub, "osa:investigate:#{task_id}") do
          [] -> {:error, :not_found}
          _ -> {:error, :running}
        end
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist yet
      {:error, :not_found}
  end

  defp generate_task_id do
    "inv_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp extract_json_metadata(text) when is_binary(text) do
    case Regex.run(~r/<!-- VAOS_JSON:(.+) -->/s, text) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, data} -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp extract_json_metadata(_), do: %{}

  # Ensure ETS table exists on module load
  @doc false
  def ensure_table do
    try do
      :ets.new(:investigation_results, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok  # Table already exists
    end
  end
end
