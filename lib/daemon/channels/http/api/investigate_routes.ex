defmodule Daemon.Channels.HTTP.API.InvestigateRoutes do
  @moduledoc """
  HTTP routes for the epistemic investigation feature with streaming support.

  POST /investigate
    Body: {
      "topic":   string (required),
      "depth":   string (optional, "standard" or "deep", default: "standard"),
      "steering": string (optional, context for advocate system prompts)
    }

    Returns Server-Sent Events (SSE) stream:
      - event: status          - Investigation status updates
      - event: progress        - Progress through pipeline stages
      - event: papers          - Paper search results
      - event: result          - Final investigation result
      - event: error           - Error occurred

    Example SSE events:
      event: status
      data: {"stage": "starting", "message": "Initializing investigation..."}

      event: papers
      data: {"count": 15, "sources": {"semantic_scholar": 8, "openalex": 7}}

      event: result
      data: {"investigation": "## Investigation: ...", "metadata": {...}}

  Errors:
    400 — topic field missing or empty
    500 — investigation failed
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Tools.Builtins.Investigate

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  post "/" do
    with %{"topic" => topic} when is_binary(topic) and topic != "" <- conn.body_params do
      depth = conn.body_params["depth"] || "standard"
      steering = conn.body_params["steering"] || ""
      user_id = conn.assigns[:user_id] || "anonymous"

      # Validate depth parameter
      unless depth in ["standard", "deep"] do
        json_error(conn, 400, "invalid_request", "depth must be 'standard' or 'deep'")
      end

      # Set up SSE stream
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      # Send initial connection event
      {:ok, conn} = chunk(conn, ~s(event: connected\ndata: {"status":"connected"}\n\n))

      # Spawn investigation in a separate task and stream results
      parent_pid = self()

      task = Task.async(fn ->
        run_investigation_with_streaming(topic, depth, steering, parent_pid, user_id)
      end)

      # Stream loop
      investigate_stream_loop(conn, task, topic)
    else
      %{"topic" => _} ->
        json_error(conn, 400, "invalid_request", "topic must be a non-empty string")

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: topic")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end

  # ── Investigation with Streaming ─────────────────────────────────────

  defp run_investigation_with_streaming(topic, depth, steering, parent_pid, user_id) do
    # Send status update
    send_sse(parent_pid, "status", %{
      stage: "starting",
      message: "Initializing investigation for: #{topic}"
    })

    # The investigate tool returns {:ok, result} or {:error, reason}
    # We'll need to wrap it to emit progress events during execution
    # For now, we'll emit the final result

    args = %{
      "topic" => topic,
      "depth" => depth,
      "steering" => steering,
      "metadata" => %{"user_id" => user_id, "source" => "api"}
    }

    send_sse(parent_pid, "status", %{
      stage: "searching",
      message: "Searching literature across multiple sources..."
    })

    result = Investigate.execute(args)

    case result do
      {:ok, investigation_text} ->
        # Extract JSON metadata from the special comment
        json_metadata = extract_json_metadata(investigation_text)

        send_sse(parent_pid, "result", %{
          investigation: investigation_text,
          metadata: json_metadata
        })

        send_sse(parent_pid, "status", %{
          stage: "complete",
          message: "Investigation completed successfully"
        })

      {:error, reason} ->
        send_sse(parent_pid, "error", %{
          error: "investigation_failed",
          reason: inspect(reason)
        })
    end
  rescue
    e ->
      Logger.error("[investigate_routes] Investigation crashed: #{Exception.message(e)}")

      send_sse(parent_pid, "error", %{
        error: "investigation_failed",
        reason: Exception.message(e)
      })
  end

  # ── SSE Streaming Loop ────────────────────────────────────────────────

  defp investigate_stream_loop(conn, task, topic) do
    receive do
      {:sse_event, event_type, data} ->
        json = Jason.encode!(data)
        event_data = "event: #{event_type}\ndata: #{json}\n\n"

        case chunk(conn, event_data) do
          {:ok, conn} ->
            investigate_stream_loop(conn, task, topic)

          {:error, :closed} ->
            Logger.debug("[investigate_routes] Client disconnected from investigation stream")
            conn
        end

      {:DOWN, _ref, :process, ^task, _result} ->
        # Task finished normally
        conn

      {:EXIT, ^task, reason} ->
        # Task crashed
        Logger.error("[investigate_routes] Task exited: #{inspect(reason)}")

        case chunk(conn, ~s(event: error\ndata: {"error":"task_failed"}\n\n)) do
          {:ok, conn} -> conn
          _ -> conn
        end
    after
      60_000 ->
        # 60 second timeout
        Logger.warning("[investigate_routes] Investigation timeout for: #{topic}")

        case chunk(conn, ~s(event: error\ndata: {"error":"timeout"}\n\n)) do
          {:ok, conn} -> conn
          _ -> conn
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp send_sse(pid, event_type, data) do
    send(pid, {:sse_event, event_type, data})
  end

  @doc """
  Extract JSON metadata from investigation result text.
  Looks for <!-- VAOS_JSON:{...} --> comment.
  """
  def extract_json_metadata(text) do
    case Regex.run(~r/<!-- VAOS_JSON:(.+) -->/s, text) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, metadata} -> metadata
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
