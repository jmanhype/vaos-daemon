# Permission Model

Audience: operators configuring tool execution policies and developers
integrating the Daemon desktop app or building custom channel adapters.

Daemon uses a layered permission model for tool execution. The layers are:
shell command policy (always enforced), hook-level security checks, and
optional user-facing permission dialogs (desktop app only).

---

## Tool Safety Levels

Every tool declares its safety level via the optional `safety/0` callback
in `MiosaTools.Behaviour`. The safety level drives which permission gates apply.

| Safety Level | Description | Example Tools |
|---|---|---|
| `:read_only` | No state modification | `file_read`, `file_grep`, `web_search` |
| `:write_safe` | Modifiable, generally reversible | `file_write`, `web_fetch`, `memory_save` |
| `:write_destructive` | Irreversible changes possible | `file_edit` with delete ops |
| `:terminal` | Arbitrary shell execution | `shell_execute`, `code_sandbox` |

---

## Hook Pipeline: security_check

The `security_check` hook runs at priority 10 on `:pre_tool_use` — it is the
first hook in the pipeline, before any other processing. If it blocks a tool
call, no other hooks run and the tool is not invoked.

```
Hook pipeline (pre_tool_use):
  p8:  spend_guard       — block if budget exceeded
  p10: security_check    — block dangerous shell commands   ← runs first
  p15: mcp_cache         — inject MCP schemas
  p30+: custom hooks
```

Note: Lower priority number runs first. `spend_guard` (p8) and
`security_check` (p10) form the critical safety tier.

### What security_check Blocks

The `Daemon.Security.ShellPolicy` module defines the consolidated
blocklist applied by `security_check` to any `shell_execute` call.

**Blocked command names** (checked against the first token of each pipeline segment):

```
rm  sudo  dd  mkfs  fdisk  format
shutdown  reboot  halt  poweroff
init  telinit
kill  killall  pkill
mount  umount
iptables  systemctl
passwd  useradd  userdel
nc  ncat
```

**Blocked regex patterns** (checked against the full command string):

| Pattern | Description |
|---|---|
| `rm -rf /` variants | Recursive deletion of root or system paths |
| `sudo` anywhere | Privilege escalation |
| `dd if=` | Raw disk write |
| `: () { ... }` (fork bomb) | Process fork bomb |
| `> /etc/`, `> ~/.ssh/`, `> /boot/`, `> /usr/`, `> /dev/sd*` | Redirect to system paths |
| `DROP TABLE`, `DROP DATABASE` | SQL destructive statements |
| Backtick subshells, `$()`, `${}` | Command substitution |
| `curl ... | sh`, `wget ... | sh` | Remote code execution via pipe |
| `git push --force`, `git reset --hard`, `git clean -f` | Destructive git operations |
| `chmod 777`, `chown root` | Dangerous permission changes |
| `cat /etc/shadow`, `cat ~/.ssh/id_rsa`, `cat .env` | Sensitive file reads |
| `../` | Path traversal |

The blocklist is a strict union of all lists previously defined across the
agent loop, scheduler, and shell_execute modules. It is the single source of
truth for all callers.

### Hook Return

When a command matches a blocked pattern:

```elixir
{:block, "Command contains blocked pattern"}
# or
{:block, "Command contains blocked command: rm -rf /"}
```

The tool call is rejected. The LLM receives the block reason as a tool error
and is expected to find an alternative approach or ask the user for guidance.

---

## Shell Command Allowlist

For environments that want to constrain shell execution to a specific set of
safe commands, configure an allowlist in the application config:

```elixir
# config/runtime.exs
config :daemon, :shell_allowlist, [
  "ls", "cat", "echo", "pwd", "date",
  "git status", "git log", "git diff",
  "mix test", "mix compile",
  "kubectl get", "kubectl describe", "kubectl logs"
]
```

When an allowlist is configured, `shell_execute` only permits commands whose
first token (or first two tokens for two-word entries) appears in the list.
Blocklist checks remain active and are applied in addition to the allowlist.

---

## Desktop App Permission Dialog

The Daemon desktop app displays a permission dialog when a tool with
`:write_safe`, `:write_destructive`, or `:terminal` safety level is about
to execute. The dialog shows:

- Tool name and description
- The exact arguments the LLM is passing
- Safety level classification
- Three action buttons

### Dialog Actions

| Button | Effect |
|---|---|
| Allow | Execute this tool call once. Prompt again for the next call to this tool. |
| Allow Always | Execute and suppress future dialogs for this tool in this session. |
| Deny | Block the tool call. The LLM receives a denial message and must re-plan. |

"Allow Always" grants are stored per-session in ETS and reset when the
session ends.

---

## YOLO Mode

YOLO mode bypasses permission dialogs entirely. The agent executes all tool
calls without user confirmation. Shell policy blocklists remain active —
YOLO mode does not bypass the security hook.

### Enabling YOLO Mode

```bash
# Via environment variable
export DAEMON_YOLO=true

# Or via CLI at runtime
/yolo on
```

```elixir
# Programmatically
Application.put_env(:daemon, :yolo_mode, true)
```

### When to Use YOLO Mode

YOLO mode is appropriate for:

- Fully automated pipelines where no human is present to approve dialogs.
- Trusted development environments where the operator understands the risks.
- Scripted batch operations on non-production systems.

YOLO mode is not appropriate for:

- Production systems with access to sensitive data.
- Any environment where an LLM could be manipulated via prompt injection.
- Multi-user deployments where one user's YOLO grant could affect others.

### What YOLO Mode Does Not Bypass

- Shell policy blocklist (`security_check` hook at p10).
- Budget limits (`spend_guard` hook at p8).
- JWT authentication on HTTP endpoints.
- Grants-based cross-instance authorization.

---

## Permission Tier

The agent loop tracks a `permission_tier` per session:

| Tier | Tools Available | Description |
|---|---|---|
| `:full` | All tools | Default for trusted sessions. |
| `:workspace` | File and shell tools scoped to `~/.daemon/workspace/` | For sandboxed sessions. |
| `:read_only` | Read-only tools only | For viewer-role sessions or untrusted input. |

```elixir
# Set tier when starting a session
Daemon.Agent.Loop.process_message(session_id, message,
  permission_tier: :workspace
)
```
