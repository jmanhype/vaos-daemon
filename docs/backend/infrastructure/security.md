# Infrastructure: Security

`Security.ShellPolicy` is the single source of truth for shell command validation across all OSA callers. Any subsystem that executes shell commands — the `shell_execute` tool, the Scheduler job runner, and the pre-tool-use security hook — delegates to this module.

---

## Overview

```
shell_execute tool
Scheduler (command-type jobs)
Agent hooks (PreToolUse: security_check)
    |
    v
Security.ShellPolicy.validate/1
    |-> blocked command names (MapSet)
    |-> blocked regex patterns (list)
    |
    :ok | {:error, reason}
```

The policy is a compile-time constant — blocked commands and patterns are module attributes baked into BEAM bytecode at compile time. There is no runtime configuration surface for the blocklist.

---

## Blocked Commands

Commands blocked by name. The check applies to the first token of every pipe/semicolon/ampersand-separated segment:

| Category | Commands |
|----------|----------|
| Filesystem destruction | `rm`, `dd`, `mkfs`, `fdisk`, `format` |
| Privilege escalation | `sudo` |
| System shutdown | `shutdown`, `reboot`, `halt`, `poweroff`, `init`, `telinit` |
| Process termination | `kill`, `killall`, `pkill` |
| Storage management | `mount`, `umount` |
| Network firewall | `iptables` |
| Service management | `systemctl` |
| User management | `passwd`, `useradd`, `userdel` |
| Network tools | `nc`, `ncat` |

Both the bare command name and the `Path.basename/1` of the first token are checked, preventing bypasses via absolute paths like `/bin/rm`.

---

## Blocked Patterns

Regex patterns checked against the full command string after segment validation. Categories:

### Privilege escalation
- `rm` removing from `/` (e.g., `rm -rf /`)
- `sudo` in any position
- `dd`, `mkfs` in any position
- Fork bomb: `:(){:|:&};:` (with flexible whitespace)
- `rm -rf /` explicit form (defence-in-depth alongside the general rm pattern)
- `dd if=` (targeted dd with input file)

### Output redirection to system paths
- `> /etc/`
- `> ~/.ssh/`
- `> /boot/`
- `> /usr/`
- `> /dev/sd*` (raw device writes)

### SQL destructive statements
- `DROP TABLE` (case-insensitive)
- `DROP DATABASE` (case-insensitive)

### Shell injection / subshell execution
- Backtick subshells: `` `...` ``
- `$()` command substitution
- `${}` variable expansion

### Chained blocked commands
Pipe, semicolon, `&&`, and `||` operators followed by `rm`, `sudo`, `dd`, `mkfs`, or `shutdown`.

### Remote execution
- `curl ... | sh`
- `wget ... | sh`

### Absolute path invocations
- `/bin/rm`, `/bin/dd`, `/bin/mkfs`
- `/usr/bin/sudo`, `/usr/bin/pkill`, `/usr/bin/killall`

### Dangerous permission / ownership changes
- `chmod 777` and variants (`chmod 0777`, `chmod 00777`)
- `chown root`

### Sensitive file reads
Reads of `/etc/shadow`, `/etc/passwd`, `/etc/sudoers`, `.ssh/id_rsa`, `.ssh/id_ed25519`, `.ssh/id_ecdsa`, `.ssh/id_dsa`, or `.env` files via `cat`, `less`, `more`, `head`, `tail`, `strings`, or `xxd`.

### Path traversal
- `../` in any position

### File-writing curl / wget
- `curl -o`, `curl --output`
- `wget -O`, `wget --output-document`

### Destructive git operations
- `git push --force` / `git push -f`
- `git reset --hard`
- `git clean -f`
- `git checkout -- .`
- `git branch -D`
- `git ... --no-verify`

---

## API

```elixir
# Validate a command string
Security.ShellPolicy.validate("ls -la /tmp")
# => :ok

Security.ShellPolicy.validate("sudo rm -rf /")
# => {:error, "Command contains blocked command: sudo rm -rf /"}

Security.ShellPolicy.validate("echo hello && shutdown now")
# => {:error, "Command contains blocked pattern"}

# Maximum output bytes before truncation
Security.ShellPolicy.max_output_bytes()
# => 100_000
```

### Validation algorithm

```
1. Split command on /[|;&]/
2. For each segment:
   a. Extract first token (strip whitespace, split on spaces)
   b. Check token and Path.basename(token) against blocked_commands MapSet
   c. Return {:error, ...} on first match
3. Check full command string against every blocked_patterns regex
4. Return {:error, ...} on first match
5. Return :ok
```

The segment check uses `Path.basename/1` so `/usr/bin/sudo` is caught even though only `sudo` is in the blocklist.

---

## Output Truncation

`max_output_bytes/0` returns `100_000` (100 KB). The `shell_execute` tool truncates subprocess output to this limit before returning it to the agent.

---

## Extending the Policy

The blocked command set and pattern list are compiled-time module attributes in `Security.ShellPolicy`. To extend the policy, add entries to `@blocked_commands` (a `MapSet`) or `@blocked_patterns` (a list of `~r/.../` regexes) and recompile.

Both lists are documented with inline comments identifying which prior call site each entry was consolidated from (hooks, scheduler, shell_execute) to maintain auditability.

---

## See Also

- [sandbox.md](sandbox.md) — Additional isolation via Docker/BEAM Task/WASM
- [../infrastructure/scheduler.md](scheduler.md) — Command-type cron jobs subject to this policy
- [../../tools/shell_execute.md](../../tools/shell_execute.md) — Tool that calls `validate/1` before execution
