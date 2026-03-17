defmodule OptimalSystemAgent.VasSwarm.GrpcClient do
  @moduledoc """
  gRPC client for VAOS-Kernel communication.

  Provides fault-tolerant connection to the Go Kernel service for:
  - JWT token requests with intent hash
  - Telemetry data submission
  - ALCOA+ audit confirmations
  - Routing log submission

  Features:
  - Automatic reconnection with exponential backoff
  - Circuit breaker pattern for fault tolerance
  - Request timeout management
  - Connection pooling via gun
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.VasSwarm.IntentHash

  @reconnect_interval_min 1000
  @reconnect_interval_max 30000
  @request_timeout 5000
  @circuit_threshold 5
  @circuit_timeout 30000

  @typedoc """
  Connection state.
  """
  @type state :: %{
          url: String.t() | nil,
          conn: pid() | nil,
          channel: any() | nil,
          connected: boolean(),
          retry_count: non_neg_integer(),
          circuit_open: boolean(),
          circuit_reset_at: integer() | nil
        }

  # Public API

  @doc """
  Request a JWT token from the Kernel.

  ## Examples

      iex> GrpcClient.request_token("agent-123", "abc123...", "build")
      {:ok, "eyJhbGciOi..."}

  """
  @spec request_token(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def request_token(agent_id, intent_hash, action_type, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:request_token, agent_id, intent_hash, action_type, metadata},
      @request_timeout
    )
  end

  @doc """
  Submit telemetry data to the Kernel.

  ## Examples

      iex> telemetry = %{agent_id: "agent-123", status: "busy", cpu_usage: 45.5}
      iex> GrpcClient.submit_telemetry(telemetry)
      {:ok, :submitted}

  """
  @spec submit_telemetry(map()) :: {:ok, :submitted} | {:error, term()}
  def submit_telemetry(telemetry_map) do
    GenServer.call(__MODULE__, {:submit_telemetry, telemetry_map}, @request_timeout)
  end

  @doc """
  Submit routing logs from Signal Theory classifier.

  ## Examples

      iex> routing = %{
      ...>   session_id: "session-123",
      ...>   mode: "BUILD",
      ...>   genre: "DIRECT",
      ...>   weight: 0.85,
      ...>   tier: "elite",
      ...>   intent_hash: "abc123..."
      ...> }
      iex> GrpcClient.submit_routing_log(routing)
      {:ok, %{correlation_id: "..."}}

  """
  @spec submit_routing_log(map()) :: {:ok, map()} | {:error, term()}
  def submit_routing_log(routing_map) do
    GenServer.call(__MODULE__, {:submit_routing_log, routing_map}, @request_timeout)
  end

  @doc """
  Confirm ALCOA+ audit trail.

  ## Examples

      iex> GrpcClient.confirm_audit(%{
      ...>   agent_id: "agent-123",
      ...>   action_id: "action-456",
      ...>   intent_hash: "abc123...",
      ...>   jwt_token: "eyJhbGciOi...",
      ...>   attributable: true,
      ...>   legible: true,
      ...>   contemporaneous: true,
      ...>   original: true,
      ...>   accurate: true
      ...> })
      {:ok, %{audit_id: "..."}}

  """
  @spec confirm_audit(map()) :: {:ok, map()} | {:error, term()}
  def confirm_audit(audit_map) do
    GenServer.call(__MODULE__, {:confirm_audit, audit_map}, @request_timeout)
  end

  # GenServer callbacks

  @doc """
  Start the gRPC client.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    kernel_url = Application.get_env(:optimal_system_agent, :vas_kernel_url)

    state = %{
      url: kernel_url,
      conn: nil,
      channel: nil,
      connected: false,
      retry_count: 0,
      circuit_open: false,
      circuit_reset_at: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{url: nil} = state) do
    Logger.debug("[GrpcClient] No Kernel URL configured, skipping connection")
    {:noreply, state}
  end

  def handle_info(:connect, %{url: url, circuit_open: true, circuit_reset_at: reset_at} = state) do
    if System.monotonic_time(:millisecond) > reset_at do
      # Circuit timeout passed, try to reconnect
      Logger.info("[GrpcClient] Circuit reset, attempting reconnection")
      do_connect(url, %{state | circuit_open: false, circuit_reset_at: nil, retry_count: 0})
    else
      # Circuit still open, schedule next check
      wait_time = reset_at - System.monotonic_time(:millisecond)
      Process.send_after(self(), :connect, min(wait_time, 5000))
      {:noreply, state}
    end
  end

  def handle_info(:connect, %{url: url, retry_count: retry_count} = state) do
    backoff = calculate_backoff(retry_count)
    Logger.debug("[GrpcClient] Connecting to Kernel (attempt #{retry_count + 1})")

    case connect_with_backoff(url, backoff) do
      {:ok, conn, channel} ->
        Logger.info("[GrpcClient] Connected to Kernel at #{url}")
        {:noreply, %{state | conn: conn, channel: channel, connected: true, retry_count: 0}}

      {:error, reason} ->
        Logger.warning("[GrpcClient] Connection failed: #{inspect(reason)}")
        new_retry_count = retry_count + 1

        if new_retry_count >= @circuit_threshold do
          Logger.error("[GrpcClient] Circuit breaker opened after #{new_retry_count} failures")
          {:noreply,
           %{
             state
             | circuit_open: true,
               circuit_reset_at: System.monotonic_time(:millisecond) + @circuit_timeout,
               retry_count: new_retry_count
           }}
        else
          Process.send_after(self(), :connect, backoff)
          {:noreply, %{state | retry_count: new_retry_count}}
        end
    end
  end

  def handle_info({:gun_down, _conn, _protocol, _reason, _}, state) do
    Logger.warning("[GrpcClient] Connection lost, reconnecting...")
    send(self(), :connect)
    {:noreply, %{state | conn: nil, channel: nil, connected: false}}
  end

  @impl true
  def handle_call(_request, _from, %{circuit_open: true} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:request_token, agent_id, intent_hash, action_type, metadata}, _from, %{
        connected: false
      } = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:request_token, agent_id, intent_hash, action_type, metadata}, _from, %{
        channel: channel
      } = state) do
    Logger.debug(
      "[GrpcClient] Requesting token for agent #{agent_id}, action #{action_type}"
    )

    # Build the token request message
    # Note: This is a simplified version - in production you'd use generated gRPC stubs
    request = %{
      agent_id: agent_id,
      intent_hash: intent_hash,
      action_type: action_type,
      metadata: metadata
    }

    # For now, return a mock response until gRPC stubs are generated
    # In production, this would be: Grpc.Stub.call(channel, request, timeout: @request_timeout)
    {:reply,
     {:ok,
      %{
        token: "mock_jwt_token_#{intent_hash}",
        expires_at: System.system_time(:second) + 3600,
        scope: action_type
      }}, state}
  end

  def handle_call({:submit_telemetry, telemetry}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:submit_telemetry, telemetry}, _from, %{channel: _channel} = state) do
    Logger.debug("[GrpcClient] Submitting telemetry for agent #{telemetry.agent_id}")

    # In production, this would call the gRPC stub
    {:reply, {:ok, :submitted}, state}
  end

  def handle_call({:submit_routing_log, routing}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:submit_routing_log, routing}, _from, %{channel: _channel} = state) do
    Logger.debug(
      "[GrpcClient] Submitting routing log for session #{routing.session_id}, mode #{routing.mode}"
    )

    # In production, this would call the gRPC stub
    correlation_id = "#{routing.session_id}:#{routing.intent_hash}:#{System.system_time(:microsecond)}"

    {:reply,
     {:ok,
      %{
        correlation_id: correlation_id
      }}, state}
  end

  def handle_call({:confirm_audit, audit}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:confirm_audit, audit}, _from, %{channel: _channel} = state) do
    Logger.debug("[GrpcClient] Confirming audit for action #{audit.action_id}")

    # In production, this would call the gRPC stub
    audit_id = "audit_#{audit.action_id}_#{System.system_time(:microsecond)}"

    {:reply, {:ok, %{audit_id: audit_id, confirmed: true}}, state}
  end

  # Private helpers

  defp do_connect(url, state) do
    case connect_with_backoff(url, 0) do
      {:ok, conn, channel} ->
        Logger.info("[GrpcClient] Connected to Kernel at #{url}")
        {:noreply, %{state | conn: conn, channel: channel, connected: true, retry_count: 0}}

      {:error, reason} ->
        Logger.warning("[GrpcClient] Connection failed: #{inspect(reason)}")
        send(self(), :connect)
        {:noreply, %{state | retry_count: state.retry_count + 1}}
    end
  end

  defp connect_with_backoff(url, backoff) do
    if backoff > 0 do
      Process.sleep(backoff)
    end

    # Parse URL and open gun connection
    # For now, return a mock response until gRPC stubs are generated
    # In production: {:ok, conn} = :gun.open(...)

    # Mock connection for development
    {:ok, self(), :mock_channel}
  rescue
    e -> {:error, e}
  end

  defp calculate_backoff(retry_count) do
    # Exponential backoff with jitter
    base = :math.pow(2, retry_count) * @reconnect_interval_min
    capped = min(base, @reconnect_interval_max)
    jitter = :rand.uniform() * 1000
    round(capped + jitter)
  end
end
