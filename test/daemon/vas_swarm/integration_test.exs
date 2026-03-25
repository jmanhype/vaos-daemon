defmodule Daemon.VasSwarm.IntegrationTest do
  use ExUnit.Case, async: true

  alias Daemon.VasSwarm.IntentHash
  alias Daemon.VasSwarm.GrpcClient
  alias Daemon.VasSwarm.TelemetryPublisher
  alias Daemon.VasSwarm.Integration

  describe "IntentHash" do
    test "compute/1 generates consistent hash for same intent" do
      intent = "Build a REST API with authentication"

      {:ok, hash1} = IntentHash.compute(intent)
      {:ok, hash2} = IntentHash.compute(intent)

      assert hash1 == hash2
      assert String.length(hash1) == 64  # SHA256 hex length
    end

    test "compute/1 generates different hashes for different intents" do
      intent1 = "Build a REST API"
      intent2 = "Deploy to production"

      {:ok, hash1} = IntentHash.compute(intent1)
      {:ok, hash2} = IntentHash.compute(intent2)

      assert hash1 != hash2
    end

    test "compute/1 returns error for non-string input" do
      assert IntentHash.compute(123) == {:error, :invalid_intent}
      assert IntentHash.compute(nil) == {:error, :invalid_intent}
    end

    test "compute_with_metadata/3 creates intent hash with full metadata" do
      intent = "Analyze sales data"
      agent_id = "agent-123"
      session_id = "session-456"

      {:ok, intent_hash} = IntentHash.compute_with_metadata(intent, agent_id, session_id)

      assert intent_hash.raw_intent == intent
      assert intent_hash.agent_id == agent_id
      assert intent_hash.session_id == session_id
      assert is_binary(intent_hash.hash)
      assert %DateTime{} = intent_hash.timestamp
    end

    test "verify/2 validates hash against intent" do
      intent = "Execute database migration"

      {:ok, hash} = IntentHash.compute(intent)
      {:ok, true} = IntentHash.verify(hash, intent)
      {:ok, false} = IntentHash.verify(hash, "Different intent")
    end

    test "correlation_id/1 generates unique IDs" do
      intent = "Test intent"
      {:ok, hash} = IntentHash.compute(intent)

      intent_hash = %IntentHash{
        hash: hash,
        raw_intent: intent,
        agent_id: "agent-123",
        session_id: "session-456",
        timestamp: DateTime.utc_now()
      }

      corr_id = IntentHash.correlation_id(intent_hash)

      assert is_binary(corr_id)
      assert String.contains?(corr_id, "agent-123")
      assert String.contains?(corr_id, hash)
    end
  end

  describe "GrpcClient" do
    setup do
      # Start the gRPC client for testing
      start_supervised!({GrpcClient, []})
      :ok
    end

    test "request_token/4 returns mock token when not connected to Kernel", %{conn: nil} do
      # When no Kernel URL is configured, client should handle gracefully
      result = GrpcClient.request_token("agent-123", "abc123", "build")

      assert {:error, :not_connected} = result
    end

    test "submit_telemetry/1 returns error when not connected", %{conn: nil} do
      telemetry = %{agent_id: "agent-123", status: "busy"}
      result = GrpcClient.submit_telemetry(telemetry)

      assert {:error, :not_connected} = result
    end

    test "submit_routing_log/1 returns error when not connected", %{conn: nil} do
      routing = %{
        session_id: "session-123",
        mode: "BUILD",
        weight: 0.85
      }
      result = GrpcClient.submit_routing_log(routing)

      assert {:error, :not_connected} = result
    end

    test "confirm_audit/1 returns error when not connected", %{conn: nil} do
      audit = %{
        agent_id: "agent-123",
        action_id: "action-456",
        intent_hash: "abc123",
        jwt_token: "token123",
        attributable: true
      }
      result = GrpcClient.confirm_audit(audit)

      assert {:error, :not_connected} = result
    end
  end

  describe "TelemetryPublisher" do
    setup do
      # Start the telemetry publisher for testing
      start_supervised!({TelemetryPublisher, []})
      :ok
    end

    test "publish_agent_status/3 buffers status telemetry", %{buffer_table: buffer} do
      TelemetryPublisher.publish_agent_status("agent-123", "busy", %{cpu_usage: 45.5})

      # Give some time for buffering
      Process.sleep(10)

      # Check if message was buffered
      buffered = :ets.tab2list(buffer)
      assert length(buffered) > 0
    end

    test "publish_routing/1 buffers routing telemetry", %{buffer_table: buffer} do
      routing = %{
        session_id: "session-123",
        mode: "BUILD",
        weight: 0.85
      }

      TelemetryPublisher.publish_routing(routing)

      # Give some time for buffering
      Process.sleep(10)

      # Check if message was buffered
      buffered = :ets.tab2list(buffer)
      assert length(buffered) > 0
    end

    test "publish_performance_metrics/2 buffers performance telemetry", %{buffer_table: buffer} do
      metrics = %{
        tasks_completed: 10,
        tasks_failed: 1,
        avg_task_duration: 2.5
      }

      TelemetryPublisher.publish_performance_metrics("agent-123", metrics)

      # Give some time for buffering
      Process.sleep(10)

      # Check if message was buffered
      buffered = :ets.tab2list(buffer)
      assert length(buffered) > 0
    end
  end

  describe "Integration" do
    setup do
      # Enable VAS-Swarm for testing
      Application.put_env(:daemon, :vas_swarm_enabled, true)
      :ok
    end

    test "enabled?/0 returns true when enabled" do
      assert Integration.enabled?()
    end

    test "process_signal_classification/1 handles signal classification" do
      # Create a mock signal
      signal = %MiosaSignal.MessageClassifier{
        mode: :build,
        genre: :direct,
        type: "request",
        format: :message,
        weight: 0.85,
        raw: "Build a REST API",
        channel: :cli,
        timestamp: DateTime.utc_now(),
        confidence: :high
      }

      # Process the signal (non-blocking)
      assert :ok = Integration.process_signal_classification(signal)
    end

    test "request_action_token/5 creates intent hash and requests token" do
      agent_id = "agent-123"
      session_id = "session-456"
      action_type = "build"
      intent = "Create a user authentication module"
      metadata = %{"priority" => "high"}

      # This should return immediately with a reference
      result = Integration.request_action_token(agent_id, session_id, action_type, intent, metadata)

      assert {:ok, ref} = result
      assert is_reference(ref)
    end

    test "publish_agent_status/3 publishes agent status" do
      assert :ok = Integration.publish_agent_status("agent-123", "busy", %{cpu_usage: 45.5})
    end

    test "publish_performance_metrics/2 publishes performance metrics" do
      metrics = %{
        tasks_completed: 10,
        tasks_failed: 1,
        avg_task_duration: 2.5
      }

      assert :ok = Integration.publish_performance_metrics("agent-123", metrics)
    end

    test "get_tier_from_weight/1 maps weights to tiers" do
      assert Integration.get_tier_from_weight(0.8) == "elite"
      assert Integration.get_tier_from_weight(0.5) == "specialist"
      assert Integration.get_tier_from_weight(0.2) == "utility"
    end
  end
end
