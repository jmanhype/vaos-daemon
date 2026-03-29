defmodule Daemon.Channels.HTTP.API.SignalRoutes do
  @moduledoc """
  Signal persistence, analytics, and live streaming routes.

  Signals are the core abstraction for agent interactions — every tool call,
  memory access, and channel message generates a signal with metadata, weight,
  and timing information.

  Endpoints:
    GET  /              — List signals with filtering (mode, genre, type, channel, tier, weight range, date range)
    GET  /stats         — Aggregated signal statistics (count by type, avg weight, etc.)
    GET  /patterns      — Signal patterns over N days (trend analysis, anomaly detection)
    GET  /live          — SSE live stream of new signals and stats updates

  Query parameters (for GET /):
    mode, genre, type, channel, tier  — Filter by signal attributes
    weight_min, weight_max            — Filter by weight range (float)
    from, to                          — ISO8601 date range filter
    limit                             — Max results (default: 50)
    offset                            — Pagination offset (default: 0)

  SSE events (GET /live):
    - signal:new        — Emitted on each new signal
    - signal:stats_update — Emitted when stats change
    - keepalive         — Sent every 30s

  Example queries:
    GET /api/v1/signals?type=tool_call&limit=10           — Recent tool calls
    GET /api/v1/signals?weight_min=0.7&genre=intent       — High-weight intent signals
    GET /api/v1/signals?from=2024-01-01T00:00:00&to=2024-01-31T23:59:59 — Date range
    GET /api/v1/signals/patterns?days=30                  — 30-day pattern analysis

  Signals are persisted to disk and indexed for fast queries. The live stream
  uses Phoenix.PubSub for real-time broadcast to all connected clients.
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared

  alias Daemon.Signal.Persistence

  plug :match
  plug :fetch_query_params
  plug :dispatch

  get "/" do
    opts = build_filter_opts(conn)
    signals = Persistence.list_signals(opts)
    body = Jason.encode!(signals)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/stats" do
    stats = Persistence.signal_stats()
    body = Jason.encode!(stats)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/patterns" do
    days = parse_positive_int(conn.query_params["days"], 7)
    patterns = Persistence.signal_patterns(days: days)
    body = Jason.encode!(patterns)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/live" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:signals")
    chunk(conn, "event: connected\ndata: {\"status\":\"ok\"}\n\n")
    signal_sse_loop(conn)
  end

  match _ do
    json_error(conn, 404, "not_found", "Signal endpoint not found")
  end

  defp signal_sse_loop(conn) do
    receive do
      {:signal_new, payload} ->
        frame = "event: signal:new\ndata: #{Jason.encode!(payload)}\n\n"

        case chunk(conn, frame) do
          {:ok, conn} -> signal_sse_loop(conn)
          {:error, _} -> conn
        end

      {:signal_stats_update, stats} ->
        frame = "event: signal:stats_update\ndata: #{Jason.encode!(stats)}\n\n"

        case chunk(conn, frame) do
          {:ok, conn} -> signal_sse_loop(conn)
          {:error, _} -> conn
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> signal_sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp build_filter_opts(conn) do
    params = conn.query_params

    []
    |> maybe_filter(:mode, params["mode"])
    |> maybe_filter(:genre, params["genre"])
    |> maybe_filter(:type, params["type"])
    |> maybe_filter(:channel, params["channel"])
    |> maybe_filter(:tier, params["tier"])
    |> maybe_filter_float(:weight_min, params["weight_min"])
    |> maybe_filter_float(:weight_max, params["weight_max"])
    |> maybe_filter_datetime(:from, params["from"])
    |> maybe_filter_datetime(:to, params["to"])
    |> Keyword.put(:limit, parse_positive_int(params["limit"], 50))
    |> Keyword.put(:offset, parse_positive_int(params["offset"], 0))
  end

  defp maybe_filter(opts, _key, nil), do: opts
  defp maybe_filter(opts, _key, ""), do: opts
  defp maybe_filter(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_filter_float(opts, _key, nil), do: opts

  defp maybe_filter_float(opts, key, val) do
    case Float.parse(val) do
      {f, _} -> Keyword.put(opts, key, f)
      :error -> opts
    end
  end

  defp maybe_filter_datetime(opts, _key, nil), do: opts

  defp maybe_filter_datetime(opts, key, val) do
    case NaiveDateTime.from_iso8601(val) do
      {:ok, dt} -> Keyword.put(opts, key, dt)
      {:error, _} -> opts
    end
  end
end
