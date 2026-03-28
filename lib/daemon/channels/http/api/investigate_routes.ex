defmodule Daemon.Channels.HTTP.API.InvestigateRoutes do
  @moduledoc """
  Investigation routes with Server-Sent Events streaming.

    POST /api/v1/investigate — runs investigation and streams results via SSE

  The investigate tool performs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv)
  followed by dual adversarial LLM analysis with citation verification.

  Request body:
    {
      "topic": "claim or topic to investigate",
      "depth": "standard" | "deep",  // optional, default "standard"
      "steering": "optional steering context",  // optional
      "metadata": {}  // optional metadata merged into event payload
    }

  Response: Server-Sent Events stream with the following event types:
    - connected: initial connection confirmation
    - status: progress updates (e.g., "Searching papers...", "Running FOR advocate...")
    - papers: paper search results
    - evidence_for: verified evidence supporting the claim
    - evidence_against: verified evidence opposing the claim
    - result: final investigation result
    - error: error occurred
    - done: stream complete
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  alias Daemon.Tools.Builtins.Investigate

  plug :match
  plug :dispatch

  # ── POST / ───────────────────────────────────────────────────────────

  post "/" do
    case conn.body_params do
      %{"topic" => topic} when is_binary(topic) and topic != "" ->
        depth = Map.get(conn.body_params, "depth", "standard")
        steering = Map.get(conn.body_params, "steering", "")
        metadata = Map.get(conn.body_params, "metadata", %{})

        # Validate depth parameter
        if depth not in ["standard", "deep"] do
          json_error(conn, 400, "invalid_request", "depth must be 'standard' or 'deep'")
        else
          run_investigation_stream(conn, topic, depth, steering, metadata)
        end

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: topic")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Investigate endpoint not found")
  end

  # ── Investigation Streaming ───────────────────────────────────────────

  defp run_investigation_stream(conn, topic, depth, steering, metadata) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Send connected event
    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"topic\": \"#{escape_json(topic)}\"}\n\n")

    # Run investigation with streaming callback
    args = %{
      "topic" => topic,
      "depth" => depth,
      "steering" => steering,
      "metadata" => metadata
    }

    case Investigate.execute_with_stream(args, fn event ->
      send_sse_event(conn, event)
    end) do
      :ok ->
        # Stream completed successfully
        conn

      {:error, reason} ->
        # Investigation failed
        error_data = Jason.encode!(%{error: inspect(reason)})
        chunk(conn, "event: error\ndata: #{error_data}\n\n")
        chunk(conn, "event: done\ndata: {}\n\n")
    end
  rescue
    e ->
      Logger.error("[InvestigateRoutes] Investigation failed: #{Exception.message(e)}")
      error_data = Jason.encode!(%{error: Exception.message(e)})
      chunk(conn, "event: error\ndata: #{error_data}\n\n")
      conn
  end

  # ── SSE Event Sending ─────────────────────────────────────────────────

  defp send_sse_event(conn, event) do
    {event_type, data} =
      case event do
        {:status, message} ->
          {"status", %{message: message}}

        {:papers_found, papers, source_counts} ->
          {"papers", %{
            count: length(papers),
            sources: source_counts,
            papers: Enum.map(papers, fn p ->
              %{
                title: p["title"],
                year: p["year"],
                citations: p["citation_count"] || p["citationCount"] || 0,
                source: p["source"] || "unknown"
              }
            end)
          }}

        {:evidence_for, evidence} ->
          {"evidence_for", %{
            count: length(evidence),
            items: Enum.map(evidence, fn ev ->
              %{
                summary: ev.summary,
                verified: ev.verified,
                verification: ev.verification,
                paper_type: Atom.to_string(ev.paper_type),
                score: ev.score,
                citation_count: ev.citation_count
              }
            end)
          }}

        {:evidence_against, evidence} ->
          {"evidence_against", %{
            count: length(evidence),
            items: Enum.map(evidence, fn ev ->
              %{
                summary: ev.summary,
                verified: ev.verified,
                verification: ev.verification,
                paper_type: Atom.to_string(ev.paper_type),
                score: ev.score,
                citation_count: ev.citation_count
              }
            end)
          }}

        {:result, result} ->
          # Full investigation result (markdown text)
          {"result", %{result: result}}

        {:done, _result} ->
          {"done", %{}}

        other ->
          Logger.warning("[InvestigateRoutes] Unknown event type: #{inspect(other)}")
          {"status", %{message: "Processing..."}}
      end

    case Jason.encode(data) do
      {:ok, json} ->
        chunk(conn, "event: #{event_type}\ndata: #{json}\n\n")

      {:error, reason} ->
        Logger.error("[InvestigateRoutes] Failed to encode event: #{inspect(reason)}")
        conn
    end
  end

  # ── JSON String Escaping ─────────────────────────────────────────────

  defp escape_json(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
