defmodule OptimalSystemAgent.Platform.AMQP do
  use GenServer
  require Logger

  @events_exchange "miosa.events"
  @tasks_exchange "miosa.tasks"
  @buffer_table :osa_amqp_buffer
  @max_buffer_size 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def publish_event(event_type, data) do
    GenServer.cast(__MODULE__, {:publish_event, event_type, data})
  end

  def publish_task(routing_key, data) do
    GenServer.cast(__MODULE__, {:publish_task, routing_key, data})
  end

  @impl true
  def init(_opts) do
    amqp_url = Application.get_env(:optimal_system_agent, :amqp_url)
    :ets.new(@buffer_table, [:named_table, :ordered_set, :public])
    send(self(), :connect)
    {:ok, %{url: amqp_url, conn: nil, channel: nil, bus_handlers: []}, {:continue, :register_bus_handlers}}
  end

  @impl true
  def handle_continue(:register_bus_handlers, state) do
    # Register a catch-all handler on the Events.Bus that forwards every event
    # to AMQP. One handler per event type — unregistered on terminate.
    bus = OptimalSystemAgent.Events.Bus
    event_types = bus.event_types()

    refs =
      Enum.map(event_types, fn event_type ->
        ref =
          bus.register_handler(event_type, fn payload ->
            publish_event(to_string(event_type), payload)
          end)

        {event_type, ref}
      end)

    Logger.info("[Platform.AMQP] Registered Bus handlers for #{length(refs)} event types")
    {:noreply, %{state | bus_handlers: refs}}
  end

  @impl true
  def handle_info(:connect, %{url: url} = state) do
    case AMQP.Connection.open(url) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        {:ok, channel} = AMQP.Channel.open(conn)
        # Declare exchanges
        :ok = AMQP.Exchange.declare(channel, @events_exchange, :fanout, durable: true)
        :ok = AMQP.Exchange.declare(channel, @tasks_exchange, :topic, durable: true)
        Logger.info("[Platform.AMQP] Connected to RabbitMQ")
        flush_buffer(channel)
        {:noreply, %{state | conn: conn, channel: channel}}

      {:error, reason} ->
        Logger.warning("[Platform.AMQP] Connection failed: #{inspect(reason)}, retrying in 5s")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.warning("[Platform.AMQP] Connection lost: #{inspect(reason)}, reconnecting...")
    Process.send_after(self(), :connect, 1_000)
    {:noreply, %{state | conn: nil, channel: nil}}
  end

  @impl true
  def terminate(_reason, %{bus_handlers: refs}) do
    bus = OptimalSystemAgent.Events.Bus

    Enum.each(refs, fn {event_type, ref} ->
      bus.unregister_handler(event_type, ref)
    end)
  end

  @impl true
  def handle_cast({:publish_event, event_type, data}, %{channel: nil} = state) do
    Logger.warning("[Platform.AMQP] Not connected, buffering event: #{event_type}")
    buffer_message({:event, event_type, data})
    {:noreply, state}
  end

  def handle_cast({:publish_event, event_type, data}, %{channel: channel} = state) do
    payload = Jason.encode!(%{type: event_type, data: data, timestamp: DateTime.utc_now()})

    AMQP.Basic.publish(channel, @events_exchange, "", payload,
      content_type: "application/json",
      headers: [{"event_type", :longstr, event_type}]
    )

    {:noreply, state}
  end

  def handle_cast({:publish_task, routing_key, data}, %{channel: nil} = state) do
    Logger.warning("[Platform.AMQP] Not connected, buffering task: #{routing_key}")
    buffer_message({:task, routing_key, data})
    {:noreply, state}
  end

  def handle_cast({:publish_task, routing_key, data}, %{channel: channel} = state) do
    payload = Jason.encode!(data)

    AMQP.Basic.publish(channel, @tasks_exchange, routing_key, payload,
      content_type: "application/json"
    )

    {:noreply, state}
  end

  # ── Buffer helpers ──

  defp buffer_message(message) do
    size = :ets.info(@buffer_table, :size) || 0

    if size >= @max_buffer_size do
      # Drop oldest entry (smallest key in ordered_set)
      case :ets.first(@buffer_table) do
        :"$end_of_table" -> :ok
        key -> :ets.delete(@buffer_table, key)
      end

      Logger.warning("[Platform.AMQP] Buffer full (#{@max_buffer_size}), dropping oldest message")
    end

    :ets.insert(@buffer_table, {System.monotonic_time(), message})
  end

  defp flush_buffer(channel) do
    entries = :ets.tab2list(@buffer_table)

    if entries != [] do
      Logger.info("[Platform.AMQP] Flushing #{length(entries)} buffered messages")

      Enum.each(entries, fn {_ts, msg} ->
        try do
          replay_message(channel, msg)
        rescue
          e -> Logger.warning("[Platform.AMQP] Failed to flush message: #{Exception.message(e)}")
        end
      end)

      :ets.delete_all_objects(@buffer_table)
    end
  end

  defp replay_message(channel, {:event, event_type, data}) do
    payload = Jason.encode!(%{type: event_type, data: data, timestamp: DateTime.utc_now()})

    AMQP.Basic.publish(channel, @events_exchange, "", payload,
      content_type: "application/json",
      headers: [{"event_type", :longstr, event_type}]
    )
  end

  defp replay_message(channel, {:task, routing_key, data}) do
    payload = Jason.encode!(data)

    AMQP.Basic.publish(channel, @tasks_exchange, routing_key, payload,
      content_type: "application/json"
    )
  end
end
