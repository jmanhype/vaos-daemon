defmodule OptimalSystemAgent.VasSwarm.TelemetryPublisher do
  @moduledoc """
  Telemetry publisher for VAS-Swarm integration.

  Publishes agent telemetry data to AMQP for the Go Kernel to consume.
  Designed to be non-blocking - all operations are fire-and-forget.

  Features:
  - Asynchronous telemetry submission (non-blocking)
  - Buffered telemetry for offline scenarios
  - Batch publishing for efficiency
  - Automatic reconnection to AMQP
  """

  use GenServer
  require Logger

  @telemetry_exchange "vas_swarm.telemetry"
  @command_queue "vas_swarm.commands"
  @status_queue "vas_swarm.status"

  @flush_interval 1000
  @max_batch_size 100

  # Public API

  @doc """
  Start the telemetry publisher.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish agent status telemetry.

  Non-blocking - returns immediately after buffering.
  """
  @spec publish_agent_status(String.t(), String.t(), map()) :: :ok
  def publish_agent_status(agent_id, status, metrics \\ %{}) do
    GenServer.cast(__MODULE__, {:publish_status, agent_id, status, metrics})
  end

  @doc """
  Publish routing telemetry from Signal Theory classifier.

  Non-blocking - returns immediately after buffering.
  """
  @spec publish_routing(map()) :: :ok
  def publish_routing(routing_data) do
    GenServer.cast(__MODULE__, {:publish_routing, routing_data})
  end

  @doc """
  Publish performance metrics.

  Non-blocking - returns immediately after buffering.
  """
  @spec publish_performance_metrics(String.t(), map()) :: :ok
  def publish_performance_metrics(agent_id, metrics) do
    GenServer.cast(__MODULE__, {:publish_performance, agent_id, metrics})
  end

  @doc """
  Subscribe to Kernel command queue.

  Returns a subscription reference for unsubscribing later.
  """
  @spec subscribe_to_commands((map() -> :ok)) :: {:ok, reference()} | {:error, term()}
  def subscribe_to_commands(handler_fn) when is_function(handler_fn, 1) do
    GenServer.call(__MODULE__, {:subscribe_commands, handler_fn})
  end

  @doc """
  Unsubscribe from Kernel command queue.
  """
  @spec unsubscribe_from_commands(reference()) :: :ok
  def unsubscribe_from_commands(ref) do
    GenServer.cast(__MODULE__, {:unsubscribe, ref})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    amqp_url = Application.get_env(:optimal_system_agent, :amqp_url)
    buffer_table = :ets.new(:vas_telemetry_buffer, [:bag, :private])

    state = %{
      url: amqp_url,
      conn: nil,
      channel: nil,
      buffer_table: buffer_table,
      subscribed: false,
      command_subscribers: %{},
      flush_timer: nil
    }

    # Start buffer flush timer
    timer = Process.send_after(self(), :flush_buffer, @flush_interval)

    # Attempt connection
    send(self(), :connect)

    {:ok, %{state | flush_timer: timer}}
  end

  @impl true
  def handle_info(:connect, %{url: nil} = state) do
    Logger.debug("[TelemetryPublisher] No AMQP URL configured, skipping connection")
    {:noreply, state}
  end

  def handle_info(:connect, %{url: url} = state) do
    case connect_to_amqp(url) do
      {:ok, conn, channel} ->
        Logger.info("[TelemetryPublisher] Connected to AMQP")
        {:noreply, %{state | conn: conn, channel: channel}}

      {:error, reason} ->
        Logger.warning("[TelemetryPublisher] Connection failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :connect, 5000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.warning("[TelemetryPublisher] Connection lost: #{inspect(reason)}, reconnecting...")
    send(self(), :connect)
    {:noreply, %{state | conn: nil, channel: nil, subscribed: false}}
  end

  def handle_info(:flush_buffer, %{channel: nil, buffer_table: buffer_table} = state) do
    # No connection, just schedule next flush
    timer = Process.send_after(self(), :flush_buffer, @flush_interval)
    {:noreply, %{state | flush_timer: timer}}
  end

  def handle_info(:flush_buffer, %{channel: channel, buffer_table: buffer_table} = state) do
    flush_telemetry_buffer(channel, buffer_table)

    timer = Process.send_after(self(), :flush_buffer, @flush_interval)
    {:noreply, %{state | flush_timer: timer}}
  end

  def handle_info({:amqp_message, payload, meta}, %{command_subscribers: subscribers} = state) do
    # Deliver message to all subscribers
    Enum.each(subscribers, fn {_ref, handler_fn} ->
      try do
        handler_fn.(payload)
      rescue
        e ->
          Logger.error("[TelemetryPublisher] Handler error: #{Exception.message(e)}")
      end
    end)

    # Acknowledge message
    if channel = state[:channel] do
      AMQP.Basic.ack(channel, meta.delivery_tag)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:publish_status, agent_id, status, metrics}, %{buffer_table: buffer} = state) do
    telemetry = %{
      type: "agent_status",
      agent_id: agent_id,
      status: status,
      timestamp: DateTime.utc_now(),
      metrics: metrics
    }

    :ets.insert(buffer, {:status, telemetry})
    {:noreply, state}
  end

  def handle_cast({:publish_routing, routing_data}, %{buffer_table: buffer} = state) do
    telemetry = %{
      type: "routing",
      timestamp: DateTime.utc_now(),
      data: routing_data
    }

    :ets.insert(buffer, {:routing, telemetry})
    {:noreply, state}
  end

  def handle_cast({:publish_performance, agent_id, metrics}, %{buffer_table: buffer} = state) do
    telemetry = %{
      type: "performance",
      agent_id: agent_id,
      timestamp: DateTime.utc_now(),
      metrics: metrics
    }

    :ets.insert(buffer, {:performance, telemetry})
    {:noreply, state}
  end

  def handle_cast({:unsubscribe, ref}, %{command_subscribers: subscribers} = state) do
    {:noreply, %{state | command_subscribers: Map.delete(subscribers, ref)}}
  end

  @impl true
  def handle_call({:subscribe_commands, handler_fn}, _from, %{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:subscribe_commands, handler_fn},
        _from,
        %{channel: channel, command_subscribers: subscribers} = state
      ) do
    # Subscribe to command queue if not already subscribed
    unless state.subscribed do
      {:ok, _tag} = AMQP.Queue.declare(channel, @command_queue, durable: true)
      {:ok, _tag} = AMQP.Basic.consume(channel, @command_queue)
      Logger.info("[TelemetryPublisher] Subscribed to Kernel command queue")
    end

    ref = make_ref()
    {:reply, {:ok, ref}, %{state | subscribed: true, command_subscribers: Map.put(subscribers, ref, handler_fn)}}
  end

  # Private helpers

  defp connect_to_amqp(url) do
    case AMQP.Connection.open(url) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        {:ok, channel} = AMQP.Channel.open(conn)

        # Declare exchanges and queues
        :ok = AMQP.Exchange.declare(channel, @telemetry_exchange, :topic, durable: true)
        {:ok, _} = AMQP.Queue.declare(channel, @status_queue, durable: true)
        :ok = AMQP.Queue.bind(channel, @status_queue, @telemetry_exchange, routing_key: "status.#")
        :ok = AMQP.Queue.bind(channel, @command_queue, @telemetry_exchange, routing_key: "commands.#")

        {:ok, conn, channel}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flush_telemetry_buffer(channel, buffer_table) do
    # Get all buffered messages
    entries = :ets.tab2list(buffer_table)

    if entries == [] do
      :ok
    else
      Logger.debug("[TelemetryPublisher] Flushing #{length(entries)} telemetry messages")

      # Group by type for batch publishing
      entries
      |> Enum.group_by(fn {type, _} -> type end)
      |> Enum.each(fn {type, messages} ->
        publish_batch(channel, type, messages)
      end)

      # Clear buffer
      :ets.delete_all_objects(buffer_table)
    end
  end

  defp publish_batch(channel, :status, messages) do
    Enum.take(messages, @max_batch_size)
    |> Enum.each(fn {_type, telemetry} ->
      payload = Jason.encode!(telemetry)
      routing_key = "status.#{telemetry.agent_id}"

      AMQP.Basic.publish(channel, @telemetry_exchange, routing_key, payload,
        content_type: "application/json"
      )
    end)
  end

  defp publish_batch(channel, :routing, messages) do
    Enum.take(messages, @max_batch_size)
    |> Enum.each(fn {_type, telemetry} ->
      payload = Jason.encode!(telemetry)
      routing_key = "routing.#{telemetry.data.session_id}"

      AMQP.Basic.publish(channel, @telemetry_exchange, routing_key, payload,
        content_type: "application/json"
      )
    end)
  end

  defp publish_batch(channel, :performance, messages) do
    Enum.take(messages, @max_batch_size)
    |> Enum.each(fn {_type, telemetry} ->
      payload = Jason.encode!(telemetry)
      routing_key = "performance.#{telemetry.agent_id}"

      AMQP.Basic.publish(channel, @telemetry_exchange, routing_key, payload,
        content_type: "application/json"
      )
    end)
  end
end
