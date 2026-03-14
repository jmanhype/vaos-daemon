# Security Boundaries

Audience: operators configuring production deployments and developers
understanding OSA's sandboxing architecture.

OSA runs untrusted code — LLM-generated tool arguments and shell commands —
and uses multiple layers of sandboxing to contain the blast radius of any
mistake or adversarial prompt.

---

## Layer 1: Shell Policy (All Deployments)

The first and always-active boundary is `OptimalSystemAgent.Security.ShellPolicy`.
It validates every command before execution regardless of sandbox type.

The policy runs in the `security_check` hook at priority 10 (the first hook
in the `pre_tool_use` pipeline). No shell command reaches the OS without
passing this check.

See [permission-model.md](./permission-model.md) for the full blocklist.

### Policy Outcome

```
shell_execute tool called
    │
    ▼
security_check hook (p10)
    ├── Command in blocklist?
    │       └── YES → {:block, "Command contains blocked command: <cmd>"}
    ├── Command matches blocked pattern?
    │       └── YES → {:block, "Command contains blocked pattern"}
    └── NO  → :ok → execute in configured sandbox
```

---

## Layer 2: Sandbox Execution Backends

When a shell command passes the policy check, it is dispatched to the
configured execution backend. Three backends are supported:

### Native (No Sandbox)

The default for development. Commands execute directly in the OSA process
user's environment.

```bash
# config/runtime.exs (default)
config :optimal_system_agent, :sandbox_backend, :native
```

Suitable for: local development on a trusted machine.
Not suitable for: any deployment handling untrusted input.

### Docker Sandbox

Full OS-level isolation via Docker containers. Each tool call spawns a
short-lived container.

```bash
config :optimal_system_agent,
  sandbox_backend: :docker,
  docker_image: "osa-sandbox:latest",
  docker_options: [
    cap_drop: "ALL",
    read_only_root: true,
    network: "none",          # or "host" for tools that need network
    memory: "512m",
    cpus: "1.0",
    tmpfs: "/tmp:size=100m"
  ]
```

Security properties:
- `CAP_DROP ALL`: All Linux capabilities dropped. The container process has
  no elevated privileges.
- `--read-only`: Root filesystem is read-only. Writes go to tmpfs mounts only.
- `--network none`: No network access by default. Tools requiring network
  access use `--network host` with explicit firewall rules.
- Resource limits prevent runaway memory or CPU from LLM-generated loops.

### WASM Sandbox (wasmtime)

WebAssembly execution via wasmtime for language runtimes that support WASM
compilation (Python, JavaScript, Rust, Go, C).

```bash
config :optimal_system_agent,
  sandbox_backend: :wasm,
  wasm_fuel_limit: 1_000_000_000,   # Instruction limit (~1B ops)
  wasm_memory_pages: 256            # 256 * 64KB = 16MB
```

Security properties:
- Memory-safe by construction: WASM has no unsafe memory access.
- Fuel limits cap execution time without OS-level process management.
- No filesystem access except explicit WASI mounts.
- Capability-based: network, filesystem, and clock access must be explicitly
  granted at the wasmtime host level.

### Sprites.dev (Firecracker microVMs)

Cloud-based execution via Sprites.dev, which uses Firecracker microVMs for
hardware-isolated execution. Suitable for high-throughput multi-tenant workloads.

```bash
config :optimal_system_agent,
  sandbox_backend: :sprites,
  sprites_endpoint: "https://api.sprites.dev",
  sprites_api_key: System.get_env("SPRITES_API_KEY")
```

Security properties:
- Firecracker microVM: hardware virtualisation boundary (KVM).
- Each tool call runs in a fresh VM; no state persists between calls.
- Network egress is configurable per VM.
- Sub-100ms VM startup time (Firecracker design goal).

---

## Layer 3: Hook Pipeline

The hook pipeline is the third boundary. Hooks can inspect, transform, or
block tool calls before they reach any execution layer.

### Built-in Security Hooks

| Hook | Priority | Event | Action |
|---|---|---|---|
| `spend_guard` | 8 | `:pre_tool_use` | Block if daily or monthly budget is exceeded |
| `security_check` | 10 | `:pre_tool_use` | Block dangerous shell commands via ShellPolicy |

Custom hooks can be registered to add organisation-specific controls
(rate limiting, audit logging, IP allowlists, etc.).

See [permission-model.md](./permission-model.md) for hook registration.

---

## Layer 4: Input and Output Guardrails

`OptimalSystemAgent.Agent.Loop.Guardrails` applies checks at the LLM boundary:

**Input (before calling the LLM):**
- `Guardrails.prompt_injection?/1`: Detects prompt injection attempts in
  user messages (e.g. "Ignore previous instructions and..."). Hard blocks
  before the message is written to memory.

**Output (after receiving the LLM response):**
- `Guardrails.response_contains_prompt_leak?/1`: Detects if the LLM echoed
  the system prompt in its response. Replaces the response with a refusal.

Known limitation: see [secret-handling.md Bug 17](./secret-handling.md).

---

## Threat Model

### In Scope

| Threat | Mitigation |
|---|---|
| LLM-generated destructive commands | ShellPolicy blocklist (all deployments) |
| Prompt injection via user input | Input guardrail in Agent.Loop |
| Runaway resource consumption | Docker/WASM resource limits |
| Container escape | CAP_DROP ALL, read-only rootfs, seccomp |
| Lateral movement between sessions | Session-keyed storage; no cross-session memory |
| System prompt extraction | Output guardrail (partial; see Bug 17) |
| Unauthenticated API access | JWT authentication when `OSA_REQUIRE_AUTH=true` |
| Budget exhaustion attacks | spend_guard hook at p8 |

### Out of Scope (Current Version)

| Threat | Notes |
|---|---|
| Malicious MCP server responses | MCP tools run with same privileges as built-in tools |
| Side-channel attacks on JWT timing | Signature comparison uses constant-time `secure_compare`; other timing leaks not audited |
| LLM output causing XSS in web clients | Clients are responsible for escaping LLM output |
| Secrets in tool argument logs | Tool argument logging level is `debug`; avoid debug logging in production |

---

## Network Isolation

For the Docker sandbox, network isolation is configured per-tool at dispatch time:

```elixir
# Tools requiring network access (web_fetch, web_search)
docker_options: [network: "host"]

# Tools that should not have network access (file operations, shell scripts)
docker_options: [network: "none"]
```

The default is `network: "none"`. Tools that require network access must
explicitly opt in via their sandbox configuration.

For WASM and Sprites, network access is managed via WASI capability grants
and Sprites API parameters respectively.

---

## Workspace Isolation

All file operations default to `~/.osa/workspace/` as the working directory.
The shell_execute tool resolves relative paths within this directory:

```elixir
# In ShellExecute.execute/1:
workspace = Path.expand("~/.osa/workspace")
File.mkdir_p(workspace)

effective_cwd = case params["cwd"] do
  nil  -> workspace
  ""   -> workspace
  path -> Path.expand(path)
end
```

Path traversal patterns (`../`) are blocked by the ShellPolicy regex
`~r/\.\.\//`. Tools that need to operate outside the workspace require
explicit absolute paths, which are then subject to the security check.
