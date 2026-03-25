defmodule Daemon.VasSwarm.Integration do
  @moduledoc """
  VAS-Swarm integration module.

  Orchestrates the interaction between OSA and the Go Kernel:
  - Hooks into Signal Theory classifier to capture routing decisions
  - Requests JWT tokens before agent actions
  - Submits telemetry to AMQP
  - Maintains ALCOA+ audit trail

  All operations are non-blocking to prevent interference with agent execution.
  """

  require Logger

  alias Daemon.VasSwarm.IntentHash
  alias Daemon.VasSwarm.GrpcClient
  alias Daemon.VasSwarm.TelemetryPublisher

  @doc """
  Initialize VAS-Swarm integration.

  This should be called during application startup.
  """
  def init do
    Logger.info("[VAS-Swarm] Initializing VAS-Swarm integration")

    # Start VAS-Swarm components if enabled
    if enabled?() do
      start_components()
      register_signal_classifier_hooks()
      subscribe_to_kernel_commands()
    else
      Logger.info("[VAS-Swarm] VAS-Swarm integration disabled via config")
    end

    :ok
  end

  @doc """
  Process a classified signal and send routing data to Kernel.

  Called automatically by the Signal Theory classifier hook.
  Non-blocking - telemetry is buffered and sent asynchronously.
  """
  def process_signal_classification(signal) do
    if enabled?() do
      Task.Supervisor.start_child(Daemon.TaskSupervisor, fn ->
        do_process_classification(signal)
      end)
    end

    :ok
  end

  @doc """
  Request JWT token for an agent action.

  Computes intent hash, requests token from Kernel, and stores audit record.
  Returns immediately with a promise (future) for the token.
  """
  @spec request_action_token(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, reference()} | {:error, term()}
  def request_action_token(agent_id, session_id, action_type, intent, metadata \\ %{}) do
    if not enabled?() do
      {:error, :disabled}
    else
      # Compute intent hash
      case IntentHash.compute_with_metadata(intent, agent_id, session_id) do
        {:ok, intent_hash} ->
          # Store audit record asynchronously
          Task.Supervisor.start_child(Daemon.TaskSupervisor, fn ->
            IntentHash.store_audit_record(intent_hash)
          end)

          # Request token from Kernel
          ref = make_ref()
          caller = self()

          Task.Supervisor.start_child(Daemon.TaskSupervisor, fn ->
            token_response = GrpcClient.request_token(agent_id, intent_hash.hash, action_type, metadata)

            send(caller, {ref, token_response})
          end)

          {:ok, ref}

        {:error, reason} ->
          Logger.error("[VAS-Swarm] Failed to compute intent hash: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Publish agent status telemetry.

  Non-blocking - buffers data for async AMQP publication.
  """
  @spec publish_agent_status(String.t(), String.t(), map()) :: :ok
  def publish_agent_status(agent_id, status, metrics \\ %{}) do
    if enabled?() do
      TelemetryPublisher.publish_agent_status(agent_id, status, metrics)
    end

    :ok
  end

  @doc """
  Publish agent performance metrics.

  Non-blocking - buffers data for async AMQP publication.
  """
  @spec publish_performance_metrics(String.t(), map()) :: :ok
  def publish_performance_metrics(agent_id, metrics) do
    if enabled?() do
      TelemetryPublisher.publish_performance_metrics(agent_id, metrics)
    end

    :ok
  end

  # Private helpers

  defp enabled? do
    Application.get_env(:daemon, :vas_swarm_enabled, false)
  end

  defp start_components do
    children = [
      # gRPC client for Kernel communication (optional - requires VAS_KERNEL_URL)
      {Daemon.VasSwarm.GrpcClient, []},

      # Telemetry publisher for AMQP (optional - requires amqp_url)
      {Daemon.VasSwarm.TelemetryPublisher, []}
    ]

    # Start components via DynamicSupervisor
    sup = Daemon.Supervisors.Extensions

    Enum.each(children, fn child ->
      case DynamicSupervisor.start_child(sup, child) do
        {:ok, pid} ->
          Logger.debug("[VAS-Swarm] Started component: #{inspect(child)} (pid: #{inspect(pid)})")

        {:error, {:already_started, pid}} ->
          Logger.debug("[VAS-Swarm] Component already started: #{inspect(child)} (pid: #{inspect(pid)})")

        {:error, reason} ->
          Logger.error("[VAS-Swarm] Failed to start component: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp register_signal_classifier_hooks do
    # Register a handler on the Events.Bus for :signal_classified events
    bus = Daemon.Events.Bus

    ref = bus.register_handler(:signal_classified, fn payload ->
      process_signal_classification(payload.signal)
    end)
    Logger.info("[VAS-Swarm] Registered signal classifier hook (ref: #{inspect(ref)})")

    :ok
  end

  defp subscribe_to_kernel_commands do
    # Subscribe to Kernel command queue for real-time coordination
    handler = fn command ->
      handle_kernel_command(command)
    end

    case TelemetryPublisher.subscribe_to_commands(handler) do
      {:ok, ref} ->
        Logger.info("[VAS-Swarm] Subscribed to Kernel commands (ref: #{inspect(ref)})")
      ref when is_reference(ref) ->
        Logger.info("[VAS-Swarm] Subscribed to Kernel commands (ref: #{inspect(ref)})")
      {:error, reason} ->
        Logger.warning("[VAS-Swarm] Failed to subscribe to Kernel commands: #{inspect(reason)}")
    end

    :ok
  end

  defp do_process_classification(signal) do
    # Build routing map
    routing_map = %{
      session_id: signal.session_id || "unknown",
      agent_id: signal.agent_id || "unknown",
      timestamp: DateTime.to_unix(signal.timestamp),

      # Signal Theory 5-tuple
      mode: Atom.to_string(signal.mode),
      genre: Atom.to_string(signal.genre),
      type: signal.type,
      format: Atom.to_string(signal.format),
      weight: signal.weight,
      confidence: Atom.to_string(signal.confidence),

      # Routing decision
      tier: get_tier_from_weight(signal.weight),
      model: signal.model || "unknown",
      provider: signal.provider || "unknown",

      # Compute intent hash
      intent_hash: IntentHash.compute!(signal.raw || "")
    }

    # Submit to Kernel via gRPC
    case GrpcClient.submit_routing_log(routing_map) do
      {:ok, %{correlation_id: corr_id}} ->
        Logger.debug("[VAS-Swarm] Routing log submitted: #{corr_id}")

      {:error, reason} ->
        Logger.warning("[VAS-Swarm] Failed to submit routing log: #{inspect(reason)}")
    end

    # Publish to AMQP for telemetry
    TelemetryPublisher.publish_routing(routing_map)

    :ok
  end

  defp handle_kernel_command(command) do
    Logger.debug("[VAS-Swarm] Received Kernel command: #{inspect(command)}")

    # Handle different command types
    case command["type"] do
      "shutdown" ->
        handle_shutdown_command(command)

      "pause" ->
        handle_pause_command(command)

      "resume" ->
        handle_resume_command(command)

      "configure" ->
        handle_configure_command(command)

      _ ->
        Logger.warning("[VAS-Swarm] Unknown command type: #{command["type"]}")
    end
  end

  defp handle_shutdown_command(%{"agent_id" => agent_id}) do
    Logger.info("[VAS-Swarm] Shutdown command for agent: #{agent_id}")
    # Implement agent shutdown logic
  end

  defp handle_pause_command(%{"agent_id" => agent_id}) do
    Logger.info("[VAS-Swarm] Pause command for agent: #{agent_id}")
    # Implement agent pause logic
  end

  defp handle_resume_command(%{"agent_id" => agent_id}) do
    Logger.info("[VAS-Swarm] Resume command for agent: #{agent_id}")
    # Implement agent resume logic
  end

  defp handle_configure_command(command) do
    Logger.info("[VAS-Swarm] Configure command: #{inspect(command)}")
    # Implement agent configuration logic
  end

  defp get_tier_from_weight(weight) do
    cond do
      weight >= 0.65 -> "elite"
      weight >= 0.35 -> "specialist"
      true -> "utility"
    end
  end
end
