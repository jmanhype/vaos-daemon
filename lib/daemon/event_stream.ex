defmodule Daemon.EventStream do
  @moduledoc """
  SSE event streaming for the Command Center.

  Uses Phoenix.PubSub for pub/sub and an ETS ring buffer for event history.
  Clients subscribe to the "command_center:events" topic and receive
  events as SSE chunks.
  """

  use GenServer
  require Logger

  @topic "command_center:events"
  @table :command_center_events
  @max_history 100

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the calling process to command center events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Daemon.PubSub, @topic)
  end

  @doc "Subscribe to a filtered sub-topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(filter) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, "#{@topic}:#{filter}")
  end

  @doc "Broadcast an event to all command center subscribers."
  @spec broadcast(String.t(), map()) :: :ok | {:error, term()}
  def broadcast(event_type, payload) do
    event = %{
      type: event_type,
      payload: payload,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    GenServer.cast(__MODULE__, {:record, event})
    Phoenix.PubSub.broadcast(Daemon.PubSub, @topic, {:command_center_event, event})
  end

  @doc """
  Plug-compatible SSE stream. Sends chunked response and loops on PubSub messages.
  """
  @spec stream(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def stream(conn, _opts \\ []) do
    subscribe()

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "event: connected\ndata: {}\n\n")
    sse_loop(conn)
  end

  @doc "Get recent event history. Optionally filter by event type."
  @spec event_history(String.t() | nil) :: [map()]
  def event_history(event_type \\ nil) do
    events =
      try do
        # ordered_set is already sorted by seq key
        :ets.tab2list(@table)
        |> Enum.map(fn {_seq, event} -> event end)
      rescue
        ArgumentError -> []
      end

    case event_type do
      nil -> events
      type -> Enum.filter(events, &(&1.type == type))
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    Logger.info("[EventStream] Initialized — topic=#{@topic}")
    {:ok, %{table: table, seq: 0}}
  end

  @impl true
  def handle_cast({:record, event}, %{seq: seq} = state) do
    next_seq = seq + 1
    :ets.insert(@table, {next_seq, event})

    # Prune oldest entries beyond max_history (ordered_set is sorted by key)
    prune_count = :ets.info(@table, :size) - @max_history

    if prune_count > 0 do
      Enum.each(1..prune_count, fn _ ->
        key = :ets.first(@table)
        if key != :"$end_of_table", do: :ets.delete(@table, key)
      end)
    end

    {:noreply, %{state | seq: next_seq}}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp sse_loop(conn) do
    receive do
      {:command_center_event, event} ->
        data = Jason.encode!(event)

        case Plug.Conn.chunk(conn, "event: #{event.type}\ndata: #{data}\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      30_000 ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end
end
