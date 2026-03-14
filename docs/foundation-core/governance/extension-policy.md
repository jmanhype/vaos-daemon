# Extension Policy

## Overview

Extensions are optional subsystems that add capability to OSA without being
required for core agent functionality. The core agent — receiving messages,
calling LLMs, executing tools, persisting memory — must work correctly when
all extensions are disabled.

---

## Definition

An extension is any subsystem that:

1. Is started conditionally based on an environment variable or configuration
   flag
2. Has a dependency on an external service, process, or binary not bundled
   with the OSA release
3. Adds functionality that is not required for a minimal agent session

Examples of current extensions: Sandbox, Treasury, Fleet, Wallet, OTA Updater,
AMQP publisher, Go/Python sidecars, WhatsApp Web sidecar.

---

## Rules for Extensions

### 1. Opt-in via Environment Variable

Extensions must not start by default. Each extension must check its enabling
condition in `Supervisors.Extensions.init/1` before adding children:

```elixir
defp sandbox_children do
  if Application.get_env(:optimal_system_agent, :sandbox_enabled, false) do
    [OptimalSystemAgent.Sandbox.Supervisor]
  else
    []
  end
end
```

The default must be `false`. An extension must never start unless explicitly
configured.

Environment variable naming convention: `OSA_<FEATURE>_ENABLED=true`.
For extensions activated by a connection URL (AMQP, PostgreSQL), the presence
of the URL is the enabling condition.

### 2. Must Not Break Core When Disabled

When an extension is not started, any code path that calls into that extension
must handle its absence gracefully. Acceptable patterns:

- Check for the extension process before calling:
  ```elixir
  if Process.whereis(OptimalSystemAgent.Fleet.Supervisor) do
    OptimalSystemAgent.Fleet.register(session_id)
  end
  ```
- Return a default value from the extension's public API when its GenServer
  is not running:
  ```elixir
  def get_fleet_status(session_id) do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, :not_enabled}
      _pid -> GenServer.call(__MODULE__, {:status, session_id})
    end
  end
  ```
- Gate extension calls behind feature detection in the caller

Pattern-matching on `{:error, :noproc}` from `GenServer.call` is not
acceptable — it is fragile and conflates process absence with process error.

### 3. Fail Silently If Dependencies Are Unavailable

If an extension depends on an external binary (Go sidecar, Python runtime,
Docker) and that dependency is unavailable, the extension must log a warning
and exit gracefully without crashing the application:

```elixir
def init(:ok) do
  case find_go_binary() do
    {:ok, path} ->
      {:ok, %{binary: path, port: nil}}
    {:error, :not_found} ->
      Logger.warning("[Go.Tokenizer] go binary not found — tokenizer disabled")
      :ignore
  end
end
```

Returning `:ignore` from `GenServer.init/1` causes the DynamicSupervisor to
skip the child without counting it as a failure.

### 4. Must Be Supervised

Every extension process must run under `Supervisors.Extensions`. No extension
may spawn unsupervised processes. The supervision strategy for Extensions is
`:one_for_one` — a crashed extension does not restart other extensions.

Extensions that manage child processes internally must use their own named
Supervisor or DynamicSupervisor (e.g., `OptimalSystemAgent.Fleet.Supervisor`,
`OptimalSystemAgent.Python.Supervisor`). These internal supervisors are the
children of `Supervisors.Extensions`, not their individual workers.

### 5. Extension Restart Behavior

Extensions under `Supervisors.Extensions` use the default restart strategy
(`:permanent`). If an extension GenServer crashes, OTP will restart it.

If an extension consistently crashes on startup (e.g., its external dependency
is permanently unavailable), it should return `:ignore` from `init/1` rather
than crash. Repeated crashes would otherwise trigger the supervisor's max
restart intensity and bring down the Extensions supervisor, which could affect
other enabled extensions.

---

## Current Extensions

| Extension | Environment Variable | External Dependency | Supervisor |
|---|---|---|---|
| Sandbox | `OSA_SANDBOX_ENABLED=true` | Docker or OS process group | `Sandbox.Supervisor` |
| Treasury | `OSA_TREASURY_ENABLED=true` | None (in-process) | GenServer |
| Fleet | `OSA_FLEET_ENABLED=true` | None (in-process) | `Fleet.Supervisor` |
| Wallet | `OSA_WALLET_ENABLED=true` | External wallet API | GenServer |
| OTA Updater | `OSA_UPDATE_ENABLED=true` | GitHub Releases API | GenServer |
| AMQP Publisher | `AMQP_URL` present | RabbitMQ / AMQP broker | GenServer |
| Go Tokenizer | `OSA_GO_TOKENIZER_ENABLED=true` | Go binary | GenServer (Port) |
| Go Git | `OSA_GO_GIT_ENABLED=true` | Go binary + git | GenServer (Port) |
| Go Sysmon | `OSA_GO_SYSMON_ENABLED=true` | Go binary | GenServer (Port) |
| Python Sidecar | `OSA_PYTHON_SIDECAR_ENABLED=true` | Python 3.x | `Python.Supervisor` |
| WhatsApp Web | `OSA_WHATSAPP_WEB_ENABLED=true` | Node.js, Puppeteer | GenServer (Port) |
| Intelligence | Always started | None (dormant until wired) | `Intelligence.Supervisor` |
| Swarm | Always started | None (in-process) | DynamicSupervisor |
| Platform DB | `DATABASE_URL` present | PostgreSQL | `Platform.Repo` (root level) |

Intelligence and Swarm are always started because their GenServers are
lightweight and dormant until explicitly wired to a session. Starting them
unconditionally keeps the code simple and avoids conditional call-site checks.

---

## Adding a New Extension

1. Implement the extension as a GenServer or Supervisor under a descriptive
   namespace (e.g., `OptimalSystemAgent.MyFeature`)
2. Add a private function `defp my_feature_children do ... end` to
   `Supervisors.Extensions`
3. Call the function in `Extensions.init/1` and concatenate its result to
   `children`
4. Document the enabling environment variable in:
   - `docs/foundation-core/governance/extension-policy.md` (this file)
   - `docs/getting-started/` (configuration guide)
   - `README.md` (configuration table)
5. Write a test that verifies core agent behavior is unaffected when the
   extension is not started
