# Fleet

Fleet manages the registry, monitoring, and remote administration of OSA agent instances. A "fleet" in OSA is the collection of active agent sessions, running tasks, and orchestration state visible across a deployment.

---

## Scope

Fleet-level concerns sit above individual sessions and orchestrated tasks:

- **Registry** — which agent instances are running and where
- **Sentinels** — health watchers that detect and report degraded agents
- **Dashboard** — aggregated view of all active agents, tasks, and swarms
- **Remote management** — start, stop, or redirect agent instances

This functionality is exposed through the HTTP fleet API routes at `lib/optimal_system_agent/channels/http/api/fleet_routes.ex`.

---

## Fleet Registry

The fleet registry tracks active OSA instances. Each entry describes a running agent identified by node, session, and metadata.

### Registration

Agents register on startup via the fleet supervisor. The registry maps `session_id` to agent metadata:

```elixir
%{
  session_id: "ses_abc123",
  node: :osa@hostname,
  started_at: ~U[2026-03-08 12:00:00Z],
  status: :active,
  model: "claude-sonnet-4-6",
  tier: :specialist
}
```

### Discovery

The fleet registry supports:
- `list_agents/0` — all registered agents
- `get_agent/1` — agent metadata by session_id
- `deregister/1` — remove a terminated agent

---

## Sentinels

Sentinels are lightweight monitors that watch individual agents for health signals. A sentinel:

1. Subscribes to the agent's session event stream
2. Tracks heartbeat intervals and error counts
3. Emits `:sentinel_alert` events when thresholds are breached
4. Can trigger automatic recovery via the auto-fixer

### Alert conditions

| Condition | Threshold |
|-----------|----------|
| No heartbeat | Configurable, default 60s |
| Repeated tool errors | > 5 consecutive failures |
| Token budget exhausted | > 90% of configured budget |
| LLM provider errors | Rate limiting or service degradation |

---

## Fleet Dashboard

The fleet dashboard aggregates real-time state across all active components:

```
Active agents:   12
Running tasks:   3
Active swarms:   1
Queued tasks:    8
Events (1m):     247
```

Dashboard data is pulled from:
- `Orchestrator.list_tasks/0` — active and completed tasks
- `SwarmMode.list_swarms/0` — active swarms
- `Tasks` queue — pending work
- Event bus metrics — event throughput

---

## HTTP Fleet API

Fleet operations are accessible via the HTTP API:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/fleet` | List all registered agents |
| `GET` | `/api/fleet/:session_id` | Get agent by session |
| `POST` | `/api/fleet/:session_id/stop` | Gracefully stop an agent |
| `GET` | `/api/fleet/dashboard` | Aggregated fleet metrics |
| `GET` | `/api/fleet/tasks` | All orchestrated tasks (running + recent) |
| `GET` | `/api/fleet/tasks/:task_id` | Task progress and agent statuses |
| `GET` | `/api/fleet/swarms` | All active swarms |

All fleet endpoints require authentication. See [HTTP channel docs](../channels/http.md) for authentication details.

---

## Remote Agent Management

### Graceful stop

Stopping an agent sends a shutdown signal to the session supervisor, which:
1. Finishes any in-flight tool call
2. Persists the current session state
3. Drains the event queue
4. Removes the agent from the fleet registry

### Redirecting agents

An agent can be redirected to a new session by creating a new session with the prior session's memory context loaded. This preserves continuity without keeping the original process alive.

---

## Supervision Tree

Fleet components run under a dedicated supervisor subtree:

```
AgentServices.Supervisor
├── FleetRegistry (GenServer — agent registration)
├── SentinelSupervisor (DynamicSupervisor — one sentinel per agent)
└── FleetDashboard (GenServer — aggregated metrics cache)
```

---

## See Also

- [Orchestrator](./orchestrator.md)
- [Swarm Mode](./swarm.md)
- [HTTP Channel](../channels/http.md)
