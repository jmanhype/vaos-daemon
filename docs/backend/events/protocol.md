# Events: Protocol

OSA uses two protocol layers for structured event communication: CloudEvents 1.0 as the envelope standard, and OSCP (Optimal Signal Communication Protocol) as the typed agent-to-agent message format built on top of CloudEvents.

---

## CloudEvents 1.0 (`Protocol.CloudEvent`)

`OptimalSystemAgent.Protocol.CloudEvent` is a backward-compatibility shim over `MiosaSignal.CloudEvent`. The canonical implementation lives in the `miosa_signal` package.

### Struct fields

| Field | CloudEvents attribute | Description |
|-------|----------------------|-------------|
| `specversion` | Required | Always `"1.0"` |
| `type` | Required | Event type string (e.g. `"oscp.heartbeat"`) |
| `source` | Required | URI identifying the origin system/agent |
| `subject` | Optional | Subject of the event (e.g. task ID) |
| `id` | Required | UUID v4, auto-generated |
| `time` | Optional | ISO 8601 UTC timestamp, auto-set |
| `datacontenttype` | Optional | `"application/json"` |
| `data` | Optional | Payload map |

### Functions

| Function | Description |
|----------|-------------|
| `CloudEvent.new/1` | Build a CloudEvent from an attrs map |
| `CloudEvent.encode/1` | Serialize to JSON string |
| `CloudEvent.decode/1` | Deserialize from JSON string |
| `CloudEvent.from_bus_event/1` | Convert internal Bus event map to CloudEvent |
| `CloudEvent.to_bus_event/1` | Convert CloudEvent back to Bus event map |

### Example

```elixir
event = CloudEvent.new(%{
  type: "oscp.heartbeat",
  source: "urn:osa:agent:agent-42",
  subject: "agent-42",
  data: %{cpu: 0.12, memory: 0.34, status: :idle}
})

{:ok, json} = CloudEvent.encode(event)
{:ok, decoded} = CloudEvent.decode(json)
```

---

## OSCP (`Protocol.OSCP`)

OSCP is a thin typed wrapper over `Protocol.CloudEvent` for agent-to-agent and agent-to-orchestrator communication. It defines four event types with typed constructors.

### Event types

| Type | Direction | Purpose |
|------|-----------|---------|
| `oscp.heartbeat` | Agent -> Orchestrator | Health metrics: cpu, memory, status |
| `oscp.instruction` | Orchestrator -> Agent | Task assignment with priority and lease |
| `oscp.result` | Agent -> Orchestrator | Task outcome (success or failure) |
| `oscp.signal` | Any -> Any | Generic signal with `subtype` field |

### Source URN convention

Agent sources use the prefix `urn:osa:agent:<agent_id>`. The orchestrator uses `urn:osa:orchestrator`.

### Typed constructors

#### `OSCP.heartbeat/2`

```elixir
OSCP.heartbeat("agent-42", %{cpu: 0.12, memory_mb: 256, status: :working})
```

Produces `oscp.heartbeat` CloudEvent with `subject: agent_id`.

#### `OSCP.instruction/4`

```elixir
OSCP.instruction("agent-42", "task-xyz", %{prompt: "Analyze logs"}, priority: 1, lease_ms: 120_000)
```

Produces `oscp.instruction` CloudEvent. Default priority: 0. Default lease: 300 000 ms (5 min).

#### `OSCP.result/3`

```elixir
OSCP.result("agent-42", "task-xyz", %{status: :completed, output: "Analysis done"})
```

Produces `oscp.result` CloudEvent. Outcome map is merged with `agent_id` and `task_id`.

#### `OSCP.signal/3`

```elixir
OSCP.signal("urn:osa:agent:agent-42", "context_pressure", %{utilization: 0.87})
```

Produces `oscp.signal` CloudEvent with `subject: subtype`.

### Validation

```elixir
:ok = OSCP.validate(event)           # checks type is a valid OSCP type
true = OSCP.valid_type?("oscp.heartbeat")
```

### Encode / Decode

```elixir
{:ok, json} = OSCP.encode(event)
{:ok, event} = OSCP.decode(json)    # decodes + validates OSCP type
```

### Bus integration

OSCP events can be converted to/from internal Bus event maps:

```elixir
# Bus map -> OSCP CloudEvent
cloud_event = OSCP.from_bus_event(%{event: :fleet_agent_heartbeat, agent_id: "42", ...})

# OSCP CloudEvent -> Bus map
bus_map = OSCP.to_bus_event(cloud_event)
```

**Bus event mapping:**

| Bus event atom | OSCP type |
|----------------|-----------|
| `:fleet_agent_heartbeat` | `oscp.heartbeat` |
| `:fleet_agent_registered` | `oscp.signal` |
| `:fleet_agent_unreachable` | `oscp.signal` |
| `:task_enqueued` | `oscp.instruction` |
| `:task_leased` | `oscp.instruction` |
| `:task_completed` | `oscp.result` |
| `:task_failed` | `oscp.result` |
| All others | `oscp.signal` |

And in reverse:

| OSCP type | Bus atom |
|-----------|----------|
| `oscp.heartbeat` | `:fleet_agent_heartbeat` |
| `oscp.instruction` | `:task_enqueued` |
| `oscp.result` | `:task_completed` |
| `oscp.signal` | `:system_event` |

---

## HTTP Endpoints

OSCP events are received and emitted via the HTTP channel:

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/oscp` | Receive an inbound OSCP CloudEvent |
| `POST` | `/api/v1/events` | Post a generic event to the Bus |
| `GET` | `/api/v1/events/stream` | SSE stream of Bus events |

---

## Agent-to-Agent Messaging

In a multi-agent deployment (fleet mode), agents communicate via OSCP over AMQP or direct HTTP:

```
Agent A                        Agent B
  OSCP.instruction()
    -> encode to JSON
    -> POST /api/v1/oscp (Agent B's endpoint)
                              <- OSCP.decode(json)
                              <- OSCP.validate()
                              -> Bus.emit(:task_enqueued, ...)
                              -> Agent.Loop.process_message()
  <- OSCP.result()
```

The `oscp.heartbeat` type is used by fleet agents to report health to the orchestrator on a regular interval.

---

## See Also

- [bus.md](bus.md) — Event bus internals and event types
- [telemetry.md](telemetry.md) — Telemetry metrics
- [../platform/amqp.md](../platform/amqp.md) — RabbitMQ cross-instance propagation
