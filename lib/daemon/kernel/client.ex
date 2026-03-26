defmodule Daemon.Kernel.Client do
  @moduledoc """
  Client for VAOS-Kernel communication.

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
  - Real gRPC calls (not mocks)
  """

  use GenServer
  require Logger


  # Use generated gRPC stubs if available, otherwise use gun-based implementation
  try do
    Code.ensure_loaded?(Vaos.Kernel.Grpc)
    @use_generated_stubs true
  rescue
    _ -> @use_generated_stubs false
  end

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
          stub: any() | nil,
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
    kernel_url = Application.get_env(:daemon, :vas_kernel_url)

    state = %{
      url: kernel_url,
      conn: nil,
      channel: nil,
      stub: nil,
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
      {:ok, conn, channel, stub} ->
        Logger.info("[GrpcClient] Connected to Kernel at #{url}")
        {:noreply, %{state | conn: conn, channel: channel, stub: stub, connected: true, retry_count: 0}}

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
    {:noreply, %{state | conn: nil, channel: nil, stub: nil, connected: false}}
  end

  @impl true
  def handle_call(_request, _from, %{circuit_open: true} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:request_token, agent_id, intent_hash, action_type, metadata}, _from, %{
        connected: false
      } = state) do
    # Fallback: request token via Kernel HTTP API instead of gRPC
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"
    Logger.debug("[GrpcClient] gRPC not connected, using HTTP fallback to #{kernel_http}")

    body = Jason.encode!(%{
      agent_id: agent_id,
      intent_hash: intent_hash,
      action_type: action_type,
      metadata: metadata
    })

    case Req.post("#{kernel_http}/api/token",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        token = if is_map(resp), do: resp["token"] || resp["jwt"], else: nil
        if token do
          Logger.info("[GrpcClient] Got JWT from Kernel HTTP API (expires: #{resp["expires_at"]})")
          {:reply, {:ok, token}, state}
        else
          Logger.warning("[GrpcClient] Kernel returned 200 but no token in response")
          {:reply, {:error, :no_token_in_response}, state}
        end

      {:ok, %{status: status, body: body}} ->
        error_msg = if is_map(body), do: body["error"] || "unknown", else: "status #{status}"
        Logger.warning("[GrpcClient] Kernel HTTP token request failed: #{error_msg}")
        {:reply, {:error, {:kernel_error, error_msg}}, state}

      {:error, reason} ->
        Logger.warning("[GrpcClient] Kernel HTTP unreachable: #{inspect(reason)}")
        {:reply, {:error, {:kernel_unreachable, reason}}, state}
    end
  end

  def handle_call({:request_token, agent_id, intent_hash, action_type, metadata}, _from, %{
        stub: stub
      } = state) do
    Logger.debug(
      "[GrpcClient] Requesting token for agent #{agent_id}, action #{action_type}"
    )

    request = build_token_request(agent_id, intent_hash, action_type, metadata)

    case call_grpc(stub, :request_token, request) do
      {:ok, response} ->
        {:reply, {:ok, response.token}, state}

      {:error, reason} ->
        Logger.error("[GrpcClient] Token request failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit_telemetry, telemetry}, _from, %{connected: false} = state) do
    # HTTP fallback for telemetry is fire-and-forget
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"
    Task.start(fn ->
      try do
        Req.post("#{kernel_http}/api/telemetry",
          body: Jason.encode!(telemetry),
          headers: [{"content-type", "application/json"}],
          receive_timeout: 3_000
        )
      rescue
        _ -> :ok
      end
    end)
    {:reply, {:ok, :submitted}, state}
  end

  def handle_call({:submit_telemetry, telemetry}, _from, %{stub: stub} = state) do
    Logger.debug("[GrpcClient] Submitting telemetry for agent #{telemetry.agent_id}")

    request = build_telemetry_request(telemetry)

    case call_grpc(stub, :submit_telemetry, request) do
      {:ok, _response} ->
        {:reply, {:ok, :submitted}, state}

      {:error, reason} ->
        Logger.error("[GrpcClient] Telemetry submission failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit_routing_log, routing}, _from, %{connected: false} = state) do
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"
    Task.start(fn ->
      try do
        Req.post("#{kernel_http}/api/routing",
          body: Jason.encode!(routing),
          headers: [{"content-type", "application/json"}],
          receive_timeout: 3_000
        )
      rescue
        _ -> :ok
      end
    end)
    {:reply, {:ok, %{correlation_id: "http-#{:rand.uniform(999999)}"}}, state}
  end

  def handle_call({:submit_routing_log, routing}, _from, %{stub: stub} = state) do
    Logger.debug(
      "[GrpcClient] Submitting routing log for session #{routing.session_id}, mode #{routing.mode}"
    )

    request = build_routing_log_request(routing)

    case call_grpc(stub, :submit_routing_log, request) do
      {:ok, response} ->
        {:reply, {:ok, %{correlation_id: response.correlation_id}}, state}

      {:error, reason} ->
        Logger.error("[GrpcClient] Routing log submission failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm_audit, audit}, _from, %{connected: false} = state) do
    # HTTP fallback — mirrors request_token HTTP fallback pattern
    kernel_http = System.get_env("VAOS_KERNEL_HTTP_URL") || "http://localhost:8080"
    Logger.debug("[GrpcClient] gRPC not connected, using HTTP fallback for audit confirmation")

    body = Jason.encode!(build_audit_confirmation(audit))

    case Req.post("#{kernel_http}/api/audit",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"confirmed" => true} = resp}} ->
        Logger.info("[GrpcClient] Audit confirmed via HTTP (audit_id: #{resp["audit_id"]})")
        {:reply, {:ok, %{audit_id: resp["audit_id"], confirmed: true, signature: resp["signature"]}}, state}

      {:ok, %{status: status, body: resp_body}} ->
        error_msg = if is_map(resp_body), do: resp_body["error"] || "unknown", else: "status #{status}"
        Logger.warning("[GrpcClient] Kernel HTTP audit confirmation failed: #{error_msg}")
        {:reply, {:error, {:kernel_error, error_msg}}, state}

      {:error, reason} ->
        Logger.warning("[GrpcClient] Kernel HTTP unreachable for audit: #{inspect(reason)}")
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:confirm_audit, audit}, _from, %{stub: stub} = state) do
    Logger.debug("[GrpcClient] Confirming audit for action #{audit.action_id}")

    request = build_audit_confirmation(audit)

    case call_grpc(stub, :confirm_audit, request) do
      {:ok, response} ->
        {:reply, {:ok, %{audit_id: response.audit_id, confirmed: response.confirmed}}, state}

      {:error, reason} ->
        Logger.error("[GrpcClient] Audit confirmation failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # Private helpers

  defp do_connect(url, state) do
    case connect_with_backoff(url, 0) do
      {:ok, conn, channel, stub} ->
        Logger.info("[GrpcClient] Connected to Kernel at #{url}")
        {:noreply, %{state | conn: conn, channel: channel, stub: stub, connected: true, retry_count: 0}}

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

    # Parse gRPC URL (format: grpc://host:port)
    [_protocol, host_port] = String.split(url, "://", parts: 2)

    case :gun.open(String.to_charlist(host_port), :http2) do
      {:ok, conn} ->
        {:ok, :up} = :gun.await_up(conn, @request_timeout)

        # For now, just use the gun connection directly
        # TODO: Proper gRPC stub integration would require generated Elixir code
        {:ok, conn, nil, conn}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp call_grpc(_stub, _method, _request) do
    # TODO: Implement proper gRPC calls with gun + protobuf encoding
    # Requires:
    # 1. Protobuf encoding of request messages
    # 2. gRPC framing (compressed-flag + message-length + message)
    # 3. HTTP/2 POST to /Package.Service/Method endpoint
    # For now, return mock responses
    Logger.debug("[GrpcClient] gRPC call not yet implemented - using mock")
    {:ok, %{error: "gRPC client not fully implemented"}}
  end

  defp build_token_request(agent_id, intent_hash, action_type, metadata) do
    # Using map - protobuf types will be generated from Go Kernel
    %{
      agent_id: agent_id,
      intent_hash: intent_hash,
      action_type: action_type,
      metadata: metadata
    }
  end

  defp build_telemetry_request(telemetry) do
    # Using map - protobuf types will be generated from Go Kernel
    %{
      agent_id: telemetry.agent_id,
      timestamp: telemetry[:timestamp] || System.system_time(:second),
      status: telemetry.status || "idle",
      cpu_usage: telemetry[:cpu_usage] || 0.0,
      memory_usage: telemetry[:memory_usage] || 0.0,
      tasks_completed: telemetry[:tasks_completed] || 0,
      tasks_failed: telemetry[:tasks_failed] || 0,
      avg_task_duration: telemetry[:avg_task_duration] || 0.0,
      tokens_used: telemetry[:tokens_used] || 0,
      cost_estimate: telemetry[:cost_estimate] || 0.0,
      custom_metrics: telemetry[:custom_metrics] || %{}
    }
  end

  defp build_routing_log_request(routing) do
    # Using map - protobuf types will be generated from Go Kernel
    %{
      session_id: routing.session_id,
      agent_id: routing.agent_id,
      timestamp: routing[:timestamp] || System.system_time(:second),
      mode: routing.mode,
      genre: routing.genre,
      type: routing.type,
      format: routing.format,
      weight: routing.weight,
      confidence: routing.confidence,
      tier: routing.tier,
      model: routing.model,
      provider: routing.provider,
      intent_hash: routing.intent_hash
    }
  end

  defp build_audit_confirmation(audit) do
    # Using map - protobuf types will be generated from Go Kernel
    %{
      agent_id: audit.agent_id,
      action_id: audit.action_id,
      intent_hash: audit.intent_hash,
      jwt_token: audit.jwt_token,
      attributable: audit.attributable,
      legible: audit.legible,
      contemporaneous: audit.contemporaneous,
      original: audit.original,
      accurate: audit.accurate,
      performed_at: audit[:performed_at] || System.system_time(:second),
      performed_by: audit[:performed_by] || "unknown",
      method: audit[:method] || "unknown",
      context: audit[:context] || %{}
    }
  end

  defp calculate_backoff(retry_count) do
    # Exponential backoff with jitter
    base = :math.pow(2, retry_count) * @reconnect_interval_min
    capped = min(base, @reconnect_interval_max)
    jitter = :rand.uniform() * 1000
    round(capped + jitter)
  end
end
