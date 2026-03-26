# Platform: AMQP

`Platform.AMQP` provides RabbitMQ integration for cross-instance event propagation. It enables multiple Daemon instances to coordinate via a shared message broker.

---

## Architecture

```
Daemon Instance A                RabbitMQ
  Platform.AMQP
    publish_event/2  ------->  miosa.events (fanout)  -----> All subscribers
    publish_task/2   ------->  miosa.tasks (topic)    -----> Routed subscribers
```

The AMQP module is a GenServer that maintains a single connection and channel. On disconnect, it automatically reconnects with a 1-second delay. During downtime, outbound messages are buffered in an ETS ordered set (`:daemon_amqp_buffer`) and flushed on reconnection.

---

## Configuration

```elixir
config :daemon,
  amqp_url: System.get_env("AMQP_URL")
  # e.g. "amqp://user:password@rabbitmq-host:5672/vhost"
```

The module starts (or silently skips) based on whether `:amqp_url` is configured.

---

## Exchanges

Two durable exchanges are declared at connection time:

| Exchange | Type | Purpose |
|----------|------|---------|
| `miosa.events` | `fanout` | Broadcast events to all consumers |
| `miosa.tasks` | `topic` | Route tasks by binding key |

Both are declared as `durable: true` — they survive RabbitMQ restarts.

---

## Publishing Events

```elixir
Platform.AMQP.publish_event(:llm_response, %{
  session_id: "sess-abc",
  tokens: 1200,
  duration_ms: 450
})
```

Publishes to the `miosa.events` fanout exchange with routing key `""` (fanout ignores routing keys). The payload is JSON-encoded as:

```json
{
  "type": "llm_response",
  "data": { "session_id": "sess-abc", ... },
  "timestamp": "2026-03-08T10:00:00Z"
}
```

The `event_type` is also set as a header `event_type: :longstr` for subscriber filtering.

---

## Publishing Tasks

```elixir
Platform.AMQP.publish_task("agent.analysis", %{
  task_id: "task-xyz",
  prompt: "Analyze sales data",
  priority: 1
})
```

Publishes to the `miosa.tasks` topic exchange with the given `routing_key`. Consumers bind queues to patterns like `"agent.*"` or `"agent.analysis"`.

---

## Offline Buffer

When the AMQP connection is down, messages are stored in `:daemon_amqp_buffer` (`:ordered_set` ETS):

- Keyed by `System.monotonic_time()` for FIFO ordering.
- Maximum buffer size: 1 000 messages.
- When full, the oldest entry is dropped before inserting the new one.
- On reconnection, `flush_buffer/1` replays all buffered messages and clears the table.

---

## Reconnection

The GenServer monitors the AMQP connection PID via `Process.monitor/1`. On `:DOWN`:
- Clears `conn` and `channel` in state.
- Schedules `:connect` after 1 second.

On initial connection failure: retries after 5 seconds.

---

## Consuming Events

Consumer setup (binding a queue to the fanout exchange) is not handled by `Platform.AMQP` itself — consumers are typically set up by platform subscribers in separate processes. Example:

```elixir
{:ok, conn} = AMQP.Connection.open(amqp_url)
{:ok, channel} = AMQP.Channel.open(conn)
{:ok, %{queue: queue}} = AMQP.Queue.declare(channel, "", exclusive: true)
:ok = AMQP.Queue.bind(channel, queue, "miosa.events")
{:ok, _tag} = AMQP.Basic.consume(channel, queue, nil, no_ack: true)
```

---

## See Also

- [instances.md](instances.md) — OS instances that use AMQP for cross-instance events
- [../events/bus.md](../events/bus.md) — Local event bus (in-process)
- [../events/protocol.md](../events/protocol.md) — OSCP CloudEvents format for cross-instance messages
