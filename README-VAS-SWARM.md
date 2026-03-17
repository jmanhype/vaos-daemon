# VAS-Swarm Integration

VAOS-Swarm (Vault Agent OS Swarm) integration for OSA — connects OSA to the Go Kernel for JWT-based authorization, ALCOA+ audit trails, and real-time telemetry coordination.

## Overview

VAS-Swarm extends OSA with enterprise-grade governance and coordination capabilities:

1. **JWT Authorization** — Every agent action requires a JWT token signed by the Kernel
2. **Intent Hashing** — SHA256 hashes of agent intents for auditability
3. **ALCOA+ Compliance** — Attributable, Legible, Contemporaneous, Original, Accurate records
4. **Real-time Telemetry** — Agent status and performance metrics via AMQP
5. **Signal Theory Routing** — Automatic capture and logging of routing decisions

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      OSA Agent                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │   Signal Theory Classifier                                │  │
│  │   → Mode, Genre, Type, Format, Weight                    │  │
│  │   → Intent Hash Generation (SHA256)                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            ↓                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │   VAS-Swarm Integration Layer                             │  │
│  │   ├── IntentHash (SHA256 hashing)                         │  │
│  │   ├── GrpcClient (JWT requests, telemetry)                │  │
│  │   ├── TelemetryPublisher (AMQP publisher)                 │  │
│  │   └── Integration (orchestration)                         │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            ↓                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │   Communication Channels                                  │  │
│  │   ├── gRPC (Go Kernel - JWT + audit)                      │  │
│  │   └── AMQP (RabbitMQ - telemetry + commands)             │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                            ↓
        ┌─────────────────────────────────────────┐
        │              Go Kernel                   │
        │   • JWT Token Issuance                   │
        │   • ALCOA+ Audit Trail                  │
        │   • Agent Coordination                   │
        │   • Signal Theory Routing Logs           │
        └─────────────────────────────────────────┘
```

## Components

### 1. IntentHash

SHA256-based intent hashing for audit trails:

```elixir
# Compute hash for an intent
{:ok, hash} = IntentHash.compute("Build a REST API")

# Compute with full metadata for audit trail
{:ok, intent_hash} = IntentHash.compute_with_metadata(
  "Build a REST API",
  "agent-123",
  "session-456"
)

# Verify hash against original intent
{:ok, true} = IntentHash.verify(hash, "Build a REST API")
```

### 2. GrpcClient

Fault-tolerant gRPC client for Kernel communication:

```elixir
# Request JWT token for an action
{:ok, token_response} = GrpcClient.request_token(
  "agent-123",
  "a1b2c3d4...",
  "build",
  %{"priority" => "high"}
)

# Submit telemetry data
{:ok, :submitted} = GrpcClient.submit_telemetry(%{
  agent_id: "agent-123",
  status: "busy",
  cpu_usage: 45.5,
  memory_usage: 60.2
})

# Submit routing logs
{:ok, %{correlation_id: "..."}} = GrpcClient.submit_routing_log(%{
  session_id: "session-123",
  mode: "BUILD",
  genre: "DIRECT",
  weight: 0.85,
  tier: "elite",
  intent_hash: "a1b2c3d4..."
})

# Confirm ALCOA+ audit
{:ok, %{audit_id: "..."}} = GrpcClient.confirm_audit(%{
  agent_id: "agent-123",
  action_id: "action-456",
  intent_hash: "a1b2c3d4...",
  jwt_token: "eyJhbGciOi...",
  attributable: true,
  legible: true,
  contemporaneous: true,
  original: true,
  accurate: true
})
```

### 3. TelemetryPublisher

Non-blocking AMQP telemetry publisher:

```elixir
# Publish agent status (non-blocking)
TelemetryPublisher.publish_agent_status(
  "agent-123",
  "busy",
  %{cpu_usage: 45.5, memory_usage: 60.2}
)

# Publish routing telemetry
TelemetryPublisher.publish_routing(%{
  session_id: "session-123",
  mode: "BUILD",
  weight: 0.85,
  tier: "elite"
})

# Publish performance metrics
TelemetryPublisher.publish_performance_metrics("agent-123", %{
  tasks_completed: 10,
  tasks_failed: 1,
  avg_task_duration: 2.5
})

# Subscribe to Kernel commands
{:ok, ref} = TelemetryPublisher.subscribe_to_commands(fn command ->
  IO.puts("Received command: #{inspect(command)}")
end)
```

### 4. Integration

Orchestration layer that ties everything together:

```elixir
# Initialize VAS-Swarm (called automatically on boot)
Integration.init()

# Request action token (non-blocking)
{:ok, ref} = Integration.request_action_token(
  "agent-123",
  "session-456",
  "build",
  "Create user authentication module",
  %{"priority" => "high"}
)

# Publish agent status
Integration.publish_agent_status("agent-123", "busy", %{cpu_usage: 45.5})

# Publish performance metrics
Integration.publish_performance_metrics("agent-123", %{
  tasks_completed: 10,
  avg_task_duration: 2.5
})
```

## Configuration

### Enable VAS-Swarm

Add to your `config/config.exs`:

```elixir
config :optimal_system_agent,
  vas_swarm_enabled: true
```

### Kernel Connection (gRPC)

```elixir
config :optimal_system_agent,
  vas_kernel_url: "grpc://localhost:50051"
```

### AMQP Connection

```elixir
config :optimal_system_agent,
  amqp_url: "amqp://guest:guest@localhost:5672"
```

## Protobuf Definitions

The gRPC protocol is defined in `protos/kernel.proto`:

- `KernelService` — Main service interface
- `TokenRequest/Response` — JWT token requests
- `TelemetryRequest/Response` — Agent telemetry
- `RoutingLogRequest/Response` — Signal Theory routing logs
- `AuditConfirmation/Response` — ALCOA+ audit confirmations

To regenerate Elixir stubs from protobuf:

```bash
# Install protoc-gen-grpc-elixir
go install github.com/elixir-grpc/protoc-gen-grpc-elixir@latest

# Generate Elixir code
protoc --elixir_out=./lib --grpc_out=./lib protos/kernel.proto
```

## ALCOA+ Compliance

VAS-Swarm maintains ALCOA+ audit trails for all agent actions:

| Attribute | Description |
|-----------|-------------|
| **Attributable** | Every action is linked to an agent ID and session |
| **Legible** | Audit records are stored in human-readable Markdown |
| **Contemporaneous** | Timestamps are captured at time of action |
| **Original** | Intent hashes prevent tampering |
| **Accurate** | Full context and metadata are preserved |

Audit records are stored in `~/.osa/vault/facts/intent_hash_*.md`.

## Signal Theory Integration

VAS-Swarm automatically hooks into OSA's Signal Theory classifier:

1. Every classified signal generates an intent hash
2. Routing decisions are logged to the Kernel via gRPC
3. Telemetry is published to AMQP for real-time monitoring

Example routing data:

```elixir
%{
  session_id: "session-123",
  mode: "BUILD",           # Signal Theory mode
  genre: "DIRECT",          # Signal Theory genre
  type: "request",          # Signal Theory type
  format: "message",        # Signal Theory format
  weight: 0.85,             # Signal Theory weight (0.0-1.0)
  confidence: "high",       # Classification confidence
  tier: "elite",            # Selected compute tier
  model: "claude-opus-4-6", # Selected model
  provider: "anthropic",    # Selected provider
  intent_hash: "a1b2c3..."  # SHA256 hash of intent
}
```

## Testing

Run integration tests:

```bash
mix test test/optimal_system_agent/vas_swarm/
```

Tests cover:
- Intent hash generation and verification
- gRPC client behavior (connected/disconnected)
- AMQP telemetry buffering and publishing
- Integration orchestration

## Non-Blocking Design

All VAS-Swarm operations are designed to be non-blocking:

- **Intent hashing** — Fast crypto operations, <1ms
- **gRPC requests** — Background tasks with fire-and-forget
- **AMQP publishing** — Buffered with async flush
- **Audit storage** — Background Task.Supervisor jobs

This ensures VAS-Swarm never interferes with agent execution.

## Fault Tolerance

VAS-Swarm includes multiple layers of fault tolerance:

1. **Circuit Breaker** — gRPC client opens circuit after 5 failures
2. **Exponential Backoff** — Automatic reconnection with backoff
3. **Request Timeouts** — 5-second timeout on all gRPC calls
4. **Buffered Telemetry** — AMQP data buffered when disconnected
5. **Graceful Degradation** — Functions return errors when services unavailable

## Performance Impact

Minimal impact on OSA performance:

- **Intent hashing** — <1ms per classification
- **Telemetry buffering** — ETS write, negligible
- **AMQP flush** — Batched every 1s, non-blocking
- **gRPC calls** — Background tasks, no blocking

## Security

- JWT tokens signed by Kernel, validated by Kernel
- Intent hashes prevent tampering with audit trails
- AMQP connection over TLS in production
- gRPC connection over TLS in production

## Troubleshooting

### VAS-Swarm not starting

Check configuration:

```elixir
Application.get_env(:optimal_system_agent, :vas_swarm_enabled)
Application.get_env(:optimal_system_agent, :vas_kernel_url)
Application.get_env(:optimal_system_agent, :amqp_url)
```

### gRPC connection failing

Check Kernel is running and accessible:

```bash
# Check if Kernel is running
curl http://localhost:50051/health

# Check VAS-Swarm logs
grep "GrpcClient" ~/.osa/logs/osa.log
```

### AMQP telemetry not publishing

Check RabbitMQ is running:

```bash
# Check RabbitMQ status
rabbitmqctl status

# Check queues
rabbitmqctl list_queues
```

## Future Enhancements

- [ ] Generate actual gRPC stubs from protobuf definitions
- [ ] Add JWT validation middleware
- [ ] Implement Kernel command handlers (pause/resume/shutdown)
- [ ] Add metrics dashboard for VAS-Swarm telemetry
- [ ] Implement batch audit record upload
- [ ] Add encryption for sensitive audit data

## References

- **Signal Theory**: [Luna, R. (2026)](https://zenodo.org/records/18774174)
- **ALCOA+**: FDA guidance on data integrity
- **gRPC Protocol**: `protos/kernel.proto`

---

**Built as part of V.A.O.S. (Vault Agent Operating System)**
