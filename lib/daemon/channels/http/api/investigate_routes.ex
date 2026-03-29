defmodule Daemon.Channels.HTTP.API.InvestigateRoutes do
  @moduledoc """
  Investigation routes — epistemic investigation with streaming results.

    POST /                    — Start a new investigation (fire-and-forget)
    GET  /stream/:investigation_id — SSE stream of investigation progress

  This module is forwarded to from the parent router at /investigate, so routes
  are relative to that prefix.
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Tools.Builtins.Investigate

  plug :match
  plug :dispatch

  # ── POST / — start investigation ─────────────────────────────────────

  post "/" do
    with %{"topic" => topic} when is_binary(topic) and topic != "" <- conn.body_params do
      depth = conn.body_params["depth"] || "standard"
      steering = conn.body_params["steering"] || ""
      metadata = conn.body_params["metadata"] || %{}

      # Generate investigation ID
      investigation_id = generate_investigation_id(topic)

      # Start investigation in background
      Task.start(fn ->
        Logger.info("[Investigate] Starting investigation #{investigation_id}: #{topic}")

        args = %{
          "topic" => topic,
          "depth" => depth,
          "steering" => steering,
          "metadata" => Map.merge(metadata, %{"investigation_id" => investigation_id})
        }

        result = case Investigate.execute(args) do
          {:ok, result_text} ->
            # Emit completion event with full results
            Phoenix.PubSub.broadcast(
              Daemon.PubSub,
              "investigation:#{investigation_id}",
              {:investigation_complete, %{
                investigation_id: investigation_id,
                status: "complete",
                result: result_text
              }}
            )
            Logger.info("[Investigate] Completed investigation #{investigation_id}")

          {:error, reason} ->
            # Emit error event
            Phoenix.PubSub.broadcast(
              Daemon.PubSub,
              "investigation:#{investigation_id}",
              {:investigation_error, %{
                investigation_id: investigation_id,
                status: "error",
                error: reason
              }}
            )
            Logger.error("[Investigate] Failed investigation #{investigation_id}: #{inspect(reason)}")
        end

        result
      end)

      # Return immediately with investigation_id
      body = Jason.encode!(%{
        investigation_id: investigation_id,
        status: "started",
        topic: topic,
        depth: depth
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, body)

    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: topic")
    end
  end

  # ── GET /stream/:investigation_id — SSE stream ───────────────────────

  get "/stream/:investigation_id" do
    investigation_id = conn.params["investigation_id"]

    # Subscribe to investigation-specific channel
    Phoenix.PubSub.subscribe(Daemon.PubSub, "investigation:#{investigation_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"investigation_id\": \"#{investigation_id}\"}\n\n")

    investigate_sse_loop(conn, investigation_id)
  end

  # ── Catch-all ─────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Investigation endpoint not found")
  end

  # ── SSE Loop ──────────────────────────────────────────────────────────

  defp investigate_sse_loop(conn, investigation_id) do
    receive do
      {:investigation_complete, %{status: "complete", result: result_text}} ->
        # Send completion event with full result
        event_data = %{
          investigation_id: investigation_id,
          status: "complete",
          result: result_text
        }

        case Jason.encode(event_data) do
          {:ok, data} ->
            case chunk(conn, "event: complete\ndata: #{data}\n\n") do
              {:ok, conn} ->
                # Send final done event
                chunk(conn, "event: done\ndata: {}\n\n")

              {:error, _reason} ->
                Logger.debug("SSE client disconnected for investigation #{investigation_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] Failed to encode completion event: #{inspect(reason)}")
            conn
        end

      {:investigation_error, %{status: "error", error: error}} ->
        # Send error event
        event_data = %{
          investigation_id: investigation_id,
          status: "error",
          error: inspect(error)
        }

        case Jason.encode(event_data) do
          {:ok, data} ->
            case chunk(conn, "event: error\ndata: #{data}\n\n") do
              {:ok, conn} ->
                # Send final done event
                chunk(conn, "event: done\ndata: {}\n\n")

              {:error, _reason} ->
                Logger.debug("SSE client disconnected for investigation #{investigation_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning("[SSE] Failed to encode error event: #{inspect(reason)}")
            conn
        end

    after
      60_000 ->
        # Keepalive timeout (60 seconds)
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> investigate_sse_loop(conn, investigation_id)
          {:error, _} -> conn
        end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp generate_investigation_id(topic) do
    hash = :crypto.hash(:sha256, topic <> Integer.to_string(System.unique_integer([:positive])))
    "inv_" <> Base.encode16(hash, case: :lower) |> binary_part(0, 16)
  end
end
