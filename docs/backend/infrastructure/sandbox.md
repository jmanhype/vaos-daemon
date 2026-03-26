# Infrastructure: Sandbox

The sandbox system provides isolated execution environments for agent-generated code. Daemon supports three sandbox backends: Docker containers, BEAM Tasks (in-process isolation), and WASM runtimes. Sandboxes are managed by a pool, provisioner, and registry.

---

## Overview

```
Agent.Loop
  -> Tools.CodeSandbox
     -> Sandbox.Pool.acquire()
        -> Sandbox.Provisioner.start()
        -> Sandbox.Registry.register()
     -> execute(code, sandbox)
     -> Sandbox.Pool.release(sandbox)
```

The `code_sandbox` builtin tool is the primary consumer. Sandboxes are pooled for efficiency — a warm Docker container or WASM runtime can be reused across multiple tool calls within a session.

---

## Backends

### Docker

Runs code in isolated Docker containers. Each container:
- Has a configurable image (default: a lightweight language-specific runtime image).
- Has resource limits: CPU, memory, and execution timeout.
- Has no network access by default.
- Is removed after release (or on pool eviction).

**Configuration:**

```elixir
config :daemon,
  sandbox_backend: :docker,
  sandbox_docker_image: "osa-sandbox:latest",
  sandbox_timeout_ms: 30_000,
  sandbox_memory_mb: 256,
  sandbox_cpu_shares: 512
```

### BEAM Tasks

Runs code in an isolated BEAM `Task` under a dedicated supervisor with a restricted process dictionary. Suitable for Elixir/Erlang code evaluation.

- No file system access outside a temp directory.
- No network access.
- Killed after timeout.

**Configuration:**

```elixir
config :daemon,
  sandbox_backend: :beam_task,
  sandbox_timeout_ms: 10_000
```

### WASM

Runs code in a WebAssembly runtime (e.g. Wasmtime). Provides the strongest isolation for untrusted code but supports only WASM-compiled languages.

**Configuration:**

```elixir
config :daemon,
  sandbox_backend: :wasm,
  sandbox_wasm_runtime: :wasmtime,
  sandbox_timeout_ms: 15_000
```

---

## Pool

`Sandbox.Pool` maintains a pool of warm sandbox instances per backend type. Configuration:

```elixir
config :daemon,
  sandbox_pool_size: 4,          # max concurrent sandboxes
  sandbox_pool_overflow: 2       # allow up to 2 overflow instances
```

`Pool.acquire/1` returns a sandbox handle within `checkout_timeout_ms`. `Pool.release/1` returns it to the pool for reuse.

---

## Provisioner

`Sandbox.Provisioner` handles the creation of new sandbox instances for each backend:

- **Docker:** Calls `docker run` with the configured image and resource limits.
- **BEAM Task:** Spawns a supervised task with restricted capabilities.
- **WASM:** Initialises a WASM module instance.

Provisioning includes a readiness check before handing the instance to the pool.

---

## Registry

`Sandbox.Registry` maintains the map of active sandbox handles. Enables:

- Listing all running sandboxes.
- Forcefully terminating a sandbox by ID.
- Attaching metadata (session ID, tool call ID) to each sandbox for observability.

---

## Security

Sandboxes enforce these constraints regardless of backend:

- Execution timeout (kills the process/container on expiry).
- Memory limit (OOM kills the container/task).
- No network access (Docker `--network=none`, WASM no-network capability).
- No host filesystem access (Docker volume mounts excluded, BEAM task temp dir only).
- Resource limits prevent CPU starvation.

Additional shell-level security is enforced by the shell policy — see [security.md](security.md).

---

## Platform Sandboxes

`OsInstance.sandbox_id` and `OsInstance.sandbox_url` link an OS instance to a provisioned sandbox environment. These are set by the platform provisioning workflow after instance creation.

The Command Center API provides sandbox management:

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/command-center/sandboxes` | Provision a new sandbox |

---

## See Also

- [security.md](security.md) — Shell policy and command blocklist
- [../platform/instances.md](../platform/instances.md) — OS instance sandbox fields
