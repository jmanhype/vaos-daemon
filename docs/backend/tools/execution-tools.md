# Execution Tools

Execution tools run code and commands in controlled environments. They range from shell command execution (with blocklist enforcement) to fully sandboxed Docker containers for arbitrary code, browser automation, and Jupyter notebook editing.

---

## `shell_execute`

Execute a shell command in a controlled workspace environment.

**Module:** `Daemon.Tools.Builtins.ShellExecute`
**Safety:** `:terminal`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string | yes | Shell command to execute |
| `cwd` | string | no | Working directory (default: `~/.daemon/workspace`) |

### Security

Commands pass through two validation layers before execution:

**1. Pre-processing**
- Trailing `&` (background operator) is stripped — forces foreground execution
- Leading `nohup` is stripped

**2. `ShellPolicy.validate/1`**

The shell policy maintains a blocklist of dangerous operations. Blocked commands include (but are not limited to):
- `rm -rf /` and similar recursive root deletion
- `chmod 777` on system paths
- Writing to `/etc/` via shell
- Fork bombs (`:(){ :|:& };:`)
- Commands that exfiltrate secrets (`cat ~/.ssh/id_rsa`, etc.)

**3. `cd` restriction**

`cd` outside `~/.daemon/` is blocked. Relative paths are resolved against the workspace (`~/.daemon/workspace/`), not the Elixir process CWD.

### Execution

Dispatches to `Daemon.Sandbox.Executor` which wraps `System.cmd` with the configured working directory and timeout.

- Default timeout: 300,000ms (5 minutes)
- Override: `DAEMON_SHELL_TIMEOUT_MS` environment variable
- Output cap: 100KB (controlled by `ShellPolicy.max_output_bytes/0`)

### Exit codes

- Exit 0: `{:ok, output}`
- Non-zero exit: `{:error, "Exit N:\n<output>"}`

---

## `code_sandbox`

Execute code in an isolated Docker container with strict resource limits.

**Module:** `Daemon.Tools.Builtins.CodeSandbox`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `language` | string | yes | `python`, `javascript`, `go`, `elixir`, `ruby`, or `rust` |
| `code` | string | yes | Source code to execute |
| `timeout` | integer | no | Max execution seconds (default: 30, max: 60) |
| `stdin` | string | no | Input to provide via stdin |

### Docker isolation

Each execution runs in an ephemeral container with:

```
docker run
  --rm                          # container removed on exit
  --network=none                # no network access
  --memory=256m                 # memory cap
  --cpus=0.5                    # CPU cap
  --read-only                   # read-only root filesystem
  --tmpfs /tmp:size=64m         # writable tmpfs for temp files
  --security-opt=no-new-privileges
  -v <code_dir>:/code:ro        # code mounted read-only
  <image>
  sh -c <run_command>
```

Code is written to a temp file — never interpolated into shell arguments — before mounting.

### Language images

| Language | Image |
|----------|-------|
| Python | `python:3.12-slim` |
| JavaScript | `node:22-slim` |
| Go | `golang:1.23-alpine` |
| Elixir | `elixir:1.18-slim` |
| Ruby | `ruby:3.3-slim` |
| Rust | `rust:1.77-slim` |

### Fallback (no Docker)

When Docker is unavailable, the tool checks `:code_sandbox_fallback_enabled` config:

- `true`: Elixir code runs unsandboxed via `Code.eval_string` in a Task; Python and JavaScript run via system executables. All fallback output is prefixed `[UNSANDBOXED]`.
- `false` (default): Returns an error instructing the user to install Docker.

Go, Ruby, and Rust have no fallback — they require Docker.

### Availability check

`available?/0` returns `false` if Docker is not installed and fallback is disabled. The agent loop skips unavailable tools when building the tool list.

---

## `browser`

Automate a real browser (Chromium via Playwright) for web interaction and scraping.

**Module:** `Daemon.Tools.Builtins.Browser`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `navigate`, `click`, `type`, `screenshot`, `extract`, `wait`, `scroll`, `close` |
| `url` | string | no | URL to navigate to |
| `selector` | string | no | CSS selector for element interaction |
| `text` | string | no | Text to type |
| `session_id` | string | no | Reuse an existing browser session |

### Browser server

Browser sessions are managed by `Browser.Server`, a GenServer that maintains a pool of Playwright browser instances. Sessions are identified by `session_id` and persist across multiple tool calls, enabling multi-step automation.

### Actions

| Action | Description |
|--------|-------------|
| `navigate` | Load a URL, wait for page load |
| `click` | Click an element by CSS selector |
| `type` | Type text into a focused element |
| `screenshot` | Capture viewport as base64 PNG |
| `extract` | Extract text content from a selector |
| `wait` | Wait for a selector to appear |
| `scroll` | Scroll the page or an element |
| `close` | Close the browser session |

### Availability

Requires Playwright to be installed. Returns `{:error, "Browser automation unavailable"}` when Playwright is not found.

---

## `computer_use`

Control the desktop: mouse, keyboard, and screen capture.

**Module:** `Daemon.Tools.Builtins.ComputerUse`
**Safety:** `:write_destructive`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `screenshot`, `click`, `type`, `key`, `move`, `scroll` |
| `x` | integer | no | X coordinate for mouse operations |
| `y` | integer | no | Y coordinate for mouse operations |
| `text` | string | no | Text to type or key sequence |
| `button` | string | no | `left`, `right`, or `middle` (default: `left`) |

Computer use requires system-level accessibility permissions. It is disabled by default and must be explicitly enabled via config.

---

## `notebook_edit`

Read and modify Jupyter notebooks (`.ipynb` files).

**Module:** `Daemon.Tools.Builtins.NotebookEdit`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `read`, `add_cell`, `edit_cell`, `delete_cell`, `run_cell` |
| `path` | string | yes | Path to the `.ipynb` file |
| `cell_index` | integer | no | 0-based cell index for `edit_cell`, `delete_cell`, `run_cell` |
| `cell_type` | string | no | `code` or `markdown` for `add_cell` |
| `source` | string | no | Cell source content for `add_cell` or `edit_cell` |
| `position` | string | no | `before` or `after` for `add_cell` (relative to `cell_index`) |

### Notebook format

Reads and writes standard Jupyter notebook JSON format. The `read` action returns a summary of each cell with type, execution count, and truncated source. The `run_cell` action requires Jupyter to be installed and runs the cell via `jupyter nbconvert --execute`.

---

## See Also

- [Tools Overview](./overview.md)
- [File Tools](./file-tools.md)
- [Integration Tools](./integration-tools.md)
