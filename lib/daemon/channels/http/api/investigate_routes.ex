defmodule Daemon.Channels.HTTP.API.InvestigateRoutes do
  @moduledoc """
  HTTP routes for epistemic investigation with streaming support.

  POST /investigate
    Body: {
      "topic":   string (required),
      "depth":   string (optional, "standard" or "deep", default: "standard"),
      "metadata": object (optional, merged into investigation_complete event)
    }

    Initiates an investigation and returns immediately with an investigation_id.

  GET /investigate/:id/stream
    SSE stream for investigation progress and results.

    Events:
      - investigation_started: {id, topic, timestamp}
      - papers_found: {count, sources}
      - analysis_progress: {stage, message}
      - evidence_verified: {for_count, against_count, fraudulent}
      - investigation_complete: {full_result, json_metadata}
      - error: {reason}

  GET /investigate/:id
    Fetch final investigation result (non-streaming).

  Error responses:
    400 — invalid_request
    404 — not_found
    500 — internal_error
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

  # ── POST / — start investigation ─────────────────────────────────────

  post "/" do
    with %{"topic" => topic} when is_binary(topic) and topic != "" <- conn.body_params do
      depth = conn.body_params["depth"] || "standard"
      metadata = conn.body_params["metadata"] || %{}
      user_id = conn.assigns[:user_id] || "anonymous"

      # Validate depth
      unless depth in ["standard", "deep"] do
        json_error(conn, 400, "invalid_request", "depth must be 'standard' or 'deep'")
      end

      # Generate unique investigation ID
      investigation_id = generate_investigation_id()

      # Subscribe to investigation PubSub channel
      Phoenix.PubSub.subscribe(Daemon.PubSub, "investigate:#{investigation_id}")

      # Start investigation in background
      task_opts = %{
        "topic" => topic,
        "depth" => depth,
        "metadata" => Map.put(metadata, "user_id", user_id),
        "investigation_id" => investigation_id
      }

      Task.start(fn ->
        run_investigation_with_streaming(investigation_id, task_opts)
      end)

      # Return immediately with investigation_id
      body =
        Jason.encode!(%{
          "investigation_id" => investigation_id,
          "status" => "started",
          "topic" => topic,
          "stream_url" => "/api/v1/investigate/#{investigation_id}/stream"
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, body)

    else
      %{"topic" => _} ->
        json_error(conn, 400, "invalid_request", "topic must be a non-empty string")

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: topic")
    end
  end

  # ── GET /:id/stream — SSE stream ───────────────────────────────────────

  get "/:id/stream" do
    investigation_id = conn.params["id"]
    user_id = conn.assigns[:user_id]

    # Subscribe to investigation channel
    Phoenix.PubSub.subscribe(Daemon.PubSub, "investigate:#{investigation_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"investigation_id\": \"#{investigation_id}\"}\n\n")

    Logger.debug("[investigate_routes] Stream opened for #{investigation_id} by #{user_id}")

    investigate_sse_loop(conn, investigation_id)
  end

  # ── GET /:id — fetch result ────────────────────────────────────────────

  get "/:id" do
    investigation_id = conn.params["id"]

    # Check if investigation is complete in cache
    case get_cached_result(investigation_id) do
      {:ok, result} ->
        body = Jason.encode!(%{"investigation_id" => investigation_id, "result" => result})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      :error ->
        json_error(conn, 404, "not_found", "Investigation not found or not complete")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Investigation endpoint not found")
  end

  # ── SSE Loop ───────────────────────────────────────────────────────────

  defp investigate_sse_loop(conn, investigation_id) do
    receive do
      {:investigation_event, event} ->
        event_type = Map.get(event, "type", "unknown")
        event_data = Map.delete(event, "type")

        case Jason.encode(event_data) do
          {:ok, data} ->
            Logger.debug("[investigate_routes] SSE: #{event_type} to #{investigation_id}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                # Continue loop unless complete
                if event_type == "investigation_complete" or event_type == "error" do
                  conn
                else
                  investigate_sse_loop(conn, investigation_id)
                end

              {:error, _reason} ->
                Logger.debug("[investigate_routes] SSE client disconnected for #{investigation_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[investigate_routes] Failed to encode SSE event: #{inspect(reason)}")
            investigate_sse_loop(conn, investigation_id)
        end

    after
      30_000 ->
        # Keepalive
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> investigate_sse_loop(conn, investigation_id)
          {:error, _} -> conn
        end
    end
  end

  # ── Investigation Runner with Streaming Events ────────────────────────

  defp run_investigation_with_streaming(investigation_id, opts) do
    topic = opts["topic"]
    depth = opts["depth"]
    metadata = opts["metadata"]
    steering = Map.get(metadata, "steering", "")

    # Emit start event
    broadcast_event(investigation_id, %{
      "type" => "investigation_started",
      "id" => investigation_id,
      "topic" => topic,
      "depth" => depth,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    try do
      # Run the investigation with a custom callback for streaming progress
      # We'll wrap the Investigate.execute/1 to emit events at key stages
      args = %{
        "topic" => topic,
        "depth" => depth,
        "steering" => steering,
        "metadata" => Map.put(metadata, "investigation_id", investigation_id)
      }

      # Note: The Investigate tool doesn't support streaming callbacks yet,
      # so we'll emit events based on what we can observe
      result = Investigate.execute(args)

      case result do
        {:ok, investigation_text} ->
          # Extract JSON metadata from the special comment
          json_metadata = extract_investigation_json(investigation_text)

          # Emit completion event
          broadcast_event(investigation_id, %{
            "type" => "investigation_complete",
            "id" => investigation_id,
            "result" => investigation_text,
            "metadata" => json_metadata,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

          # Cache the result
          cache_result(investigation_id, investigation_text, json_metadata)

        {:error, reason} ->
          broadcast_event(investigation_id, %{
            "type" => "error",
            "id" => investigation_id,
            "reason" => inspect(reason),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          })
      end
    rescue
      e ->
        Logger.error("[investigate_routes] Investigation crashed: #{Exception.message(e)}")

        broadcast_event(investigation_id, %{
          "type" => "error",
          "id" => investigation_id,
          "reason" => Exception.message(e),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp broadcast_event(investigation_id, event) do
    Phoenix.PubSub.broadcast(Daemon.PubSub, "investigate:#{investigation_id}", {:investigation_event, event})
  end

  def generate_investigation_id do
    "inv_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  def extract_investigation_json(text) do
    case Regex.run(~r/<!-- VAOS_JSON:(.+) -->/s, text) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, data} -> data
          {:error, _} -> %{}
        end

      _ ->
        %{}
    end
  end

  # Simple in-memory cache for investigation results (ETS)
  # In production, this should be replaced with a proper cache/store
  defp cache_result(investigation_id, result, metadata) do
    ensure_cache_table()
    :ets.insert(:investigate_cache, {investigation_id, %{result: result, metadata: metadata}})
  end

  defp get_cached_result(investigation_id) do
    ensure_cache_table()

    case :ets.lookup(:investigate_cache, investigation_id) do
      [{^investigation_id, data}] -> {:ok, data}
      [] -> :error
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(:investigate_cache) do
      :undefined ->
        :ets.new(:investigate_cache, [:named_table, :public, :set])

      _pid ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
