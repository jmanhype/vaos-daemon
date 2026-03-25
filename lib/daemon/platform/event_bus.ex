defmodule Daemon.Platform.EventBus do
  @moduledoc """
  Cross-OS platform event bus for fleet-wide event visibility.

  Same pattern as EventStream but scoped to cross-OS events:
  - Events tagged with os_id for filtering
  - ETS ring buffer (last 500 events)
  - PubSub fan-out on "platform:events" topic
  - SSE streaming for real-time subscribers

  NOTE: Not yet wired into the supervision tree or API router.
  This module and its companion PlatformEventsRoutes are scaffolded for
  future fleet/multi-OS support. To activate:
  1. Add `Daemon.Platform.EventBus` to Infrastructure supervisor
  2. Add `forward "/platform-events", to: API.PlatformEventsRoutes` in api.ex
  """

  use GenServer
  require Logger

  @topic "platform:events"
  @table :platform_events
  @max_history 500

  # -- Public API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the calling process to platform events."
  @spec subscribe(keyword()) :: :ok | {:error, term()}
  def subscribe(opts \\ []) do
    case Keyword.get(opts, :os_id) do
      nil -> Phoenix.PubSub.subscribe(Daemon.PubSub, @topic)
      os_id -> Phoenix.PubSub.subscribe(Daemon.PubSub, "#{@topic}:#{os_id}")
    end
  end

  @doc "Broadcast an event from a specific OS instance to the global bus."
  @spec broadcast(String.t(), map()) :: :ok | {:error, term()}
  def broadcast(os_id, event) when is_binary(os_id) and is_map(event) do
    tagged = Map.merge(event, %{
      os_id: os_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    GenServer.cast(__MODULE__, {:record, tagged})

    pubsub = Daemon.PubSub
    Phoenix.PubSub.broadcast(pubsub, @topic, {:platform_event, tagged})
    Phoenix.PubSub.broadcast(pubsub, "#{@topic}:#{os_id}", {:platform_event, tagged})
  end

  @doc "Plug-compatible SSE stream of platform events."
  @spec stream(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def stream(conn, opts \\ []) do
    subscribe(opts)

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, "event: connected\ndata: {}\n\n")

    type_filter = Keyword.get(opts, :type)
    sse_loop(conn, type_filter)
  end

  @doc "Get recent event history from the ETS ring buffer."
  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    os_id = Keyword.get(opts, :os_id)
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, @max_history)

    events =
      try do
        :ets.tab2list(@table)
        |> Enum.map(fn {_seq, event} -> event end)
      rescue
        ArgumentError -> []
      end

    events
    |> maybe_filter(:os_id, os_id)
    |> maybe_filter(:type, type)
    |> Enum.take(-limit)
  end

  @doc "Event counts by type and by os_id."
  @spec stats() :: map()
  def stats do
    events =
      try do
        :ets.tab2list(@table)
        |> Enum.map(fn {_seq, event} -> event end)
      rescue
        ArgumentError -> []
      end

    by_type =
      events
      |> Enum.group_by(&Map.get(&1, :type, "unknown"))
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    by_os_id =
      events
      |> Enum.group_by(&Map.get(&1, :os_id, "unknown"))
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    %{
      total: length(events),
      by_type: by_type,
      by_os_id: by_os_id
    }
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    Logger.info("[PlatformEventBus] Initialized — topic=#{@topic}, max_history=#{@max_history}")
    {:ok, %{table: table, seq: 0}}
  end

  @impl true
  def handle_cast({:record, event}, %{seq: seq} = state) do
    next_seq = seq + 1
    :ets.insert(@table, {next_seq, event})

    prune_count = :ets.info(@table, :size) - @max_history

    if prune_count > 0 do
      Enum.each(1..prune_count, fn _ ->
        key = :ets.first(@table)
        if key != :"$end_of_table", do: :ets.delete(@table, key)
      end)
    end

    {:noreply, %{state | seq: next_seq}}
  end

  # -- Private ---------------------------------------------------------------

  defp sse_loop(conn, type_filter) do
    receive do
      {:platform_event, event} ->
        if type_filter == nil or Map.get(event, :type) == type_filter do
          data = Jason.encode!(event)
          event_type = Map.get(event, :type, "platform_event")

          case Plug.Conn.chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
            {:ok, conn} -> sse_loop(conn, type_filter)
            {:error, _} -> conn
          end
        else
          sse_loop(conn, type_filter)
        end
    after
      30_000 ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, type_filter)
          {:error, _} -> conn
        end
    end
  end

  defp maybe_filter(events, _key, nil), do: events
  defp maybe_filter(events, key, value), do: Enum.filter(events, &(Map.get(&1, key) == value))
end
