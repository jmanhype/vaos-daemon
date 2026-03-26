# Computer Use — Desktop & Browser Control

Daemon's computer use tool gives agents the ability to see and interact with any desktop environment — local or remote. It follows the same adapter pattern used across Daemon: a single tool interface backed by platform-specific implementations that are auto-detected at runtime.

## Architecture

```
computer_use.ex                     Tool interface (MiosaTools.Behaviour)
│                                   Validation, lazy GenServer start
│
├── server.ex                       GenServer — platform detection, dispatch,
│                                   AX tree cache, element refs, idle shutdown
│
├── adapter.ex                      Behaviour contract (10 callbacks)
│                                   + detect_platform/0, adapter_for/1
│
├── accessibility.ex                Tree parsing, ref assignment, diffing,
│                                   compact text formatting (~800 tokens/page)
│
└── adapters/
    ├── macos.ex                    screencapture, osascript, Python/Quartz
    ├── linux_x11.ex                maim/scrot, xdotool
    ├── linux_wayland.ex            grim, ydotool
    ├── remote_ssh.ex               SSH forwarding to remote Linux VMs
    ├── docker.ex                   docker exec/cp to containers
    └── platform_vm.ex              Firecracker microVMs via Sprites.dev API
```

## How It Works

### 1. Platform Detection

When the GenServer starts (lazily, on first tool call), `Adapter.detect_platform/0` resolves the target platform in priority order:

| Priority | Check | Platform |
|----------|-------|----------|
| 1 | `config :computer_use_vm` has `:sprite_id` | `:platform_vm` |
| 2 | `config :computer_use_docker` has `:container` | `:docker` |
| 3 | `config :computer_use_remote` has `:host` | `:remote_ssh` |
| 4 | `:os.type() == {:unix, :darwin}` | `:macos` |
| 5 | `:os.type() == {:unix, :linux}` + `$WAYLAND_DISPLAY` or `$XDG_SESSION_TYPE=wayland` | `:linux_wayland` |
| 6 | `:os.type() == {:unix, :linux}` (default) | `:linux_x11` |
| 7 | `:os.type() == {:win32, _}` | `:windows` (not yet supported) |

`adapter_for/1` maps the platform atom to the concrete adapter module. The server verifies `adapter.available?()` before accepting commands.

### 2. Action Dispatch

All actions flow through the same path:

```
Agent calls tool "computer_use" with action + params
  → computer_use.ex validates params
  → ensures GenServer is running (lazy start)
  → GenServer.call to Server
  → Server dispatches to adapter callback
  → adapter executes platform-native command
  → {:ok, result} | {:error, reason}
```

### 3. Idle Shutdown

The server shuts itself down after 10 minutes of inactivity. Each action resets the timer. This prevents resource leaks when computer use is intermittent.

## Available Actions

| Action | Parameters | Description |
|--------|-----------|-------------|
| `screenshot` | `region?` | Capture full screen or region `{x, y, width, height}` |
| `click` | `x, y` or `target` | Click at coordinates or element ref |
| `double_click` | `x, y` | Double-click at coordinates |
| `type` | `text` | Type a string (max 4096 bytes) |
| `key` | `text` | Press key combo: `"cmd+c"`, `"enter"`, `"ctrl+shift+v"` |
| `scroll` | `direction, amount?` | Scroll `up/down/left/right` by N units (default 3) |
| `move_mouse` | `x, y` | Move cursor without clicking |
| `drag` | `x, y, region` | Drag from `(x,y)` to `(region.x, region.y)` |
| `get_tree` | `force_refresh?` | Fetch accessibility tree with element refs |

## Element Refs — Structured Targeting

Instead of guessing coordinates from screenshots, the agent can:

1. Call `get_tree` to fetch the accessibility tree
2. Receive element refs like `e0`, `e1`, `e2`... assigned to every interactive element (buttons, links, text fields, checkboxes, etc.)
3. Call `click` with `target: "e3"` to click that element by ref

This is deterministic and reliable — no coordinate estimation errors.

### How Refs Are Assigned

The `Server` walks the accessibility tree and assigns sequential refs (`e0`, `e1`, ...) to every node whose role is interactive:

```
button, link, textfield, textarea, checkbox, radio, menuitem,
tab, slider, combobox, switch, toggle, searchfield, toolbar, ...
```

Each ref maps to the center coordinates of the element's bounding box. The ref map is cached for 5 seconds (configurable via `@tree_ttl_ms`).

### Compact Text Format

The `Accessibility` module formats the tree as compact text for LLM consumption:

```
[e0] button "Submit" (500,300)
[e1] textfield "Email" value="user@..." (200,150)
[e2] link "Home" (100,50)
  [e3] checkbox "Remember me" checked (200,400)
```

This uses ~800 tokens per page vs ~10,000+ for screenshots — a 5-13x cost reduction.

### Tree Diffing

After each action, the agent can call `get_tree` again. `Accessibility.diff_trees/2` computes incremental changes:

```
+ [e5] button "New Button" (300,200)       # appeared
- [e2] link "Old Link" (100,50)            # disappeared
~ [e1] textfield "Email" moved (200,150) -> (200,180)   # position changed
```

Only the diff is sent to the LLM, further reducing token usage.

## Platform Adapters

### macOS (`adapters/macos.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `screencapture` (ships with macOS) |
| Mouse | Python/Quartz via `osascript do shell script` — `CGEventCreateMouseEvent` |
| Keyboard | AppleScript `tell app "System Events" to keystroke/key code` |
| Key codes | 27 named keys (enter, tab, escape, F1-F12, arrows, etc.) |
| Accessibility | Stubbed — planned AXorcist integration |

**Requirements:**
- macOS (auto-detected)
- Accessibility API permission: System Settings → Privacy & Security → Accessibility

### Linux X11 (`adapters/linux_x11.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim` (preferred) or `scrot` (fallback) |
| Mouse | `xdotool mousemove`, `click`, `mousedown/mouseup` |
| Keyboard | `xdotool type`, `xdotool key` |
| Scroll | `xdotool click` with buttons 4/5/6/7 |
| Accessibility | Stubbed — planned AT-SPI2 integration |

**Requirements:**
- Linux with X11
- `xdotool` installed
- `maim` or `scrot` for screenshots

### Linux Wayland (`adapters/linux_wayland.ex`)

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `grim` (full screen or region via `-g`) |
| Mouse/Keyboard | `ydotool` (requires `ydotoold` daemon) |
| Key codes | Linux input event names (`KEY_ENTER`, `KEY_LEFTMETA`, etc.) |

**Requirements:**
- Linux with Wayland (`$WAYLAND_DISPLAY` set or `$XDG_SESSION_TYPE=wayland`)
- `ydotool` + `ydotoold` running
- `grim` for screenshots

### Remote SSH (`adapters/remote_ssh.ex`)

Forwards all commands over SSH to a remote Linux machine. The agent controls the remote desktop as if it were local.

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim`/`grim` on remote, transferred via `scp` |
| Input | `xdotool`/`ydotool` via `ssh user@host "command"` |
| Auth | Public key or SSH agent (BatchMode=yes, no passwords) |
| Cleanup | Remote screenshots deleted after SCP transfer |

**Configuration:**

```elixir
config :daemon, :computer_use_remote,
  host: "192.168.1.100",        # required
  port: 22,                      # default: 22
  user: "ubuntu",                # default: "root"
  key_path: "~/.ssh/id_rsa",    # optional (omit for SSH agent auth)
  remote_display: ":0",          # X11 DISPLAY on remote (default: ":0")
  remote_platform: :linux_x11   # :linux_x11 (default) | :linux_wayland
```

**Diagnostics:**

```elixir
RemoteSSH.test_connection()
# {:ok, %{connected: true, system: "Linux vm-1 5.15.0 ..."}}
```

### Docker (`adapters/docker.ex`)

Forwards commands into a running Docker container via `docker exec`. Designed for headless desktop containers (e.g., Anthropic's computer-use reference image with Xvfb + xdotool).

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim`/`scrot` inside container, `docker cp` to host |
| Input | `xdotool` via `docker exec container bash -c "DISPLAY=:1 ..."` |
| Container check | `docker inspect -f {{.State.Running}}` |
| Cleanup | Container screenshots deleted after `docker cp` |

**Configuration:**

```elixir
config :daemon, :computer_use_docker,
  container: "osa-desktop",          # container name or ID (required)
  display: ":1",                     # DISPLAY inside container (default: ":1")
  screenshot_path: "/tmp/screenshots" # screenshot dir inside container
```

**Diagnostics:**

```elixir
Docker.test_connection()
# {:ok, %{connected: true, container: "osa-desktop", system: "Linux ... + /usr/bin/xdotool"}}
```

### Platform VM (`adapters/platform_vm.ex`)

Forwards commands into Firecracker microVMs managed by the Sprites.dev sandbox backend (`Sandbox.Sprites`). The VMs run Linux with Xvfb + xdotool.

| Capability | Implementation |
|-----------|---------------|
| Screenshots | `maim` inside VM, base64-encoded and decoded on host |
| Input | `xdotool` via `Sprites.execute/2` |
| Transfer | Base64 over API (no SCP/docker cp needed) |
| VM management | Sprites.dev API (create, checkpoint, restore, destroy) |

**Configuration:**

```elixir
config :daemon, :computer_use_vm,
  sprite_id: "abc123",    # Sprites.dev VM identifier (required)
  display: ":1"           # DISPLAY inside VM (default: ":1")
```

**Requirements:**
- `SPRITES_TOKEN` environment variable set
- Sprites.dev VM provisioned with Xvfb + xdotool

**Diagnostics:**

```elixir
PlatformVM.test_connection()
# {:ok, %{connected: true, sprite_id: "abc123", system: "Linux ...", preview_url: "https://..."}}
```

## Configuration

### Enable Computer Use

Computer use is gated by a config flag (default `false`):

```elixir
config :daemon, :computer_use_enabled, true
```

### Platform Override

For local use, the platform is auto-detected. For remote/container/VM targets, set the appropriate config block. Detection priority: Platform VM → Docker → SSH → local OS.

## Security

### Input Sanitization

- **AppleScript** (macOS): Backslashes and double quotes are escaped before interpolation into AppleScript string literals.
- **Shell commands** (SSH, Docker, Platform VM): All user text is wrapped in POSIX single-quote escaping (`'...'\\''...'`), preventing command injection.
- **Key combos**: Validated against `[a-zA-Z0-9+\-_ ]` — rejects semicolons, backticks, dollar signs, quotes.
- **Text length**: Capped at 4096 bytes to prevent abuse.
- **Coordinates**: Must be non-negative integers.

### SSH Security

- `BatchMode=yes` — no interactive password prompts
- `ConnectTimeout=10` — fast failure on unreachable hosts
- `StrictHostKeyChecking=no` — convenience for VM/container workflows. Override for production.

### Permission Gating

- Safety level: `:write_destructive`
- Every action except `screenshot` requires user confirmation through Daemon's permission system
- Tool disabled by default (`computer_use_enabled: false`)

## Workflow: How the Agent Uses Computer Use

### Screenshot-First (Fallback)

```
1. screenshot → see the screen
2. Identify UI element and estimate coordinates
3. click(x, y) → interact
4. screenshot → verify result
```

### Accessibility-Tree-First (Preferred)

```
1. get_tree → structured element list with refs
2. Identify element by role + name
3. click(target: "e3") → interact by ref
4. get_tree → diff shows what changed
```

The accessibility tree approach is preferred because:
- 5-13x fewer tokens per perception step
- Deterministic targeting (no coordinate estimation errors)
- Incremental updates via diffing
- Works without vision model capabilities

## Testing

49 tests in `test/tools/computer_use_test.exs` covering:

- Tool metadata (name, description, safety, parameters)
- Availability gating (config flag behavior)
- Action validation (missing/invalid actions)
- Screenshot region validation (negative, zero, incomplete)
- Click validation (coordinates vs target, negative values, non-integers)
- Type validation (empty, non-string, too long)
- Key combo validation (injection characters, quotes, backticks, dollar signs, length)
- Scroll validation (missing/invalid direction)
- Move mouse / drag validation
- AppleScript sanitization
- Key combo parsing (modifiers, case-insensitivity)
- Screenshot command generation (integration, macOS only)

Run with:

```bash
mix test test/tools/computer_use_test.exs
```

## Future Work

- **AXorcist integration** (macOS): Wire native Accessibility API for real tree data
- **AT-SPI2 integration** (Linux): D-Bus accessibility tree on X11 and Wayland
- **Windows adapter**: AutoHotkey or UI Automation API
- **Browser tab awareness**: Integrate with `browser` tool for coordinated web + desktop control
- **Vision fallback**: Auto-switch to screenshot mode when AX tree is unavailable or sparse
- **Action recording/replay**: Record interaction sequences for automation
