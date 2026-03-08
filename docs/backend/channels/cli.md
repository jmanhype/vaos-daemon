# Channels: CLI

The CLI channel is an interactive terminal REPL started with `mix osa.chat`. It provides a full-featured prompt with colored output, an animated spinner, readline-style history, markdown rendering, plan review, and live task tracking.

---

## Starting the CLI

```bash
mix osa.chat
```

`CLI.start/0` is the entry point. It:

1. Clears the screen and prints the OSA banner (version, model, tool count, soul status, proactive mode flag).
2. Starts a new `Agent.Loop` session under `SessionSupervisor` with a random `cli_<hex>` session ID.
3. Registers a `Permission` hook for the session.
4. Registers Bus event handlers for orchestrator events and task tracker events.
5. Initialises ETS tables for history (`:cli_history`) and active-request tracking (`:cli_active_request`).
6. Registers the async response handler and the proactive mode handler.
7. Calls `ProactiveMode.set_active_session/1` and optionally emits a greeting.
8. Enters the main `loop/1`.

---

## Main Loop

The loop reads a line with `LineEditor.readline/2`. Each iteration:

1. Checks `:cli_active_request` for a `:pending_plan` — handles plan review before reading new input.
2. Reads a line with the current prompt (`❯` when idle, `◉` when agent is active).
3. On `:eof` or `exit`/`quit`, halts.
4. On `Ctrl+C` (`:interrupt`), cancels any active request.
5. Routes slash commands through `Commands.execute/2`.
6. Applies `NoiseFilter` before forwarding non-command input to the agent.

Requests to the agent run in a `TaskSupervisor` child so the prompt stays responsive. The async response is delivered via a `:cli_agent_response_ready` system event.

### Session management

Commands can change the active session:
- `/new` — stops the current loop, starts a fresh session.
- `/resume <id>` — stops the current loop, starts a restored session with prior message history.
- `/strategy <name>` — sends `{:set_strategy, name}` to the loop process.

---

## LineEditor (`CLI.LineEditor`)

Provides readline-style terminal input:
- Arrow-key history navigation (up/down).
- Cursor movement (left/right).
- Delete and backspace.
- History is the per-session ETS store, capped at 100 entries. Consecutive duplicates are deduplicated.

---

## Markdown Rendering (`CLI.Markdown`)

`Markdown.render/1` converts markdown syntax to ANSI-colored terminal output:

| Markdown | ANSI output |
|----------|-------------|
| `**text**` | Bright white |
| `_text_`, `*text*` | Faint |
| `` `text` `` | Cyan |
| ` ``` ` blocks | Dim with border lines |
| `#`, `##` headers | Bold cyan |
| `- ` / `* ` list items | Indented with `•` |

Rendered output is word-wrapped to `terminal_width() - 4` before printing.

---

## Spinner (`CLI.Spinner`)

The spinner runs as a separate long-lived process. It shows elapsed time and cycles through animation frames while the agent is working. It accepts update messages via `Spinner.update/2`:

| Message | Effect |
|---------|--------|
| `{:tool_start, name, args}` | Shows tool name currently executing |
| `{:tool_end, name, duration_ms}` | Increments tool counter |
| `{:llm_response, usage}` | Accumulates token count |

`Spinner.stop/1` returns `{elapsed_ms, tool_count, total_tokens}`. These are displayed as a status line immediately after each response:

```
  ✓ 3s · 4 tools · 1.2k
```

Context pressure is appended when utilisation reaches 50%. Colour shifts yellow at 70%, red at 85%:

```
  ✓ 3s · 4 tools · 1.2k · ctx 72%
```

The pressure bar shown on standalone events:

| Utilisation | Bar label |
|-------------|-----------|
| 95%+ | `█████ CRITICAL` (red) |
| 90%+ | `████░ HIGH` (red) |
| 85%+ | `███░░ ELEVATED` (yellow) |
| 70%+ | `██░░░ WARM` (yellow) |

---

## Task Display (`CLI.TaskDisplay`)

`TaskDisplay` is a pure-function renderer — no IO, no GenServer, no side effects. It renders `Agent.Tasks.Tracker.Task` lists in three formats:

| Function | Output style |
|----------|-------------|
| `render/2` | Bordered box with header counter and token counts |
| `render_inline/1` | Claude Code-style `⎿` connector list |
| `render_compact/1` | Single-line `Tasks: 3/7 ✔✔✔◼◻◻◻` summary |

Status icons:

| Status | Icon | Colour |
|--------|------|--------|
| `pending` | `◻` | Dim |
| `in_progress` | `◼` | Cyan bold |
| `completed` | `✔` | Green |
| `failed` | `✘` | Red |

Task display is triggered by `task_tracker_task_*` system events on the Bus. It fires only when the session's `task_display_visible` setting is `true`.

---

## Plan Review (`CLI.PlanReview`)

When `Agent.Loop` returns `{:plan, plan_text}` instead of executing immediately, the CLI enters plan review mode. The pending plan is stored in the `:cli_active_request` ETS table so it is handled at the top of the next loop iteration.

`PlanReview.review/1`:
1. Renders the plan in a bordered box (markdown-rendered, word-wrapped to `terminal_width() - 4`).
2. Presents a three-option interactive selector:
   - **Approve** — sends the plan back to the agent with `skip_plan: true`.
   - **Reject** — discards the plan and returns to the prompt.
   - **Edit** — prompts for feedback text, sends revised plan back; loops up to 5 revisions.

Plan execution uses the synchronous path (`send_to_agent_sync/3`), which blocks while showing the spinner until the agent responds.

---

## Command Handling

Slash commands (`/cmd args`) are dispatched through `Commands.execute/2`. The CLI handles four return shapes:

| Return | Action |
|--------|--------|
| `{:command, output}` | Print output, continue same session |
| `{:prompt, expanded}` | Forward expanded text to agent |
| `{:action, action, output}` | Print output, execute action (new session, resume, clear, strategy) |
| `:unknown` | Print error with Levenshtein-based suggestion |

Unknown command suggestion uses inline Levenshtein distance with a maximum edit distance of 3.

---

## Proactive Mode Integration

The CLI registers a Bus handler for `:proactive_message` system events on session startup. Messages are prefixed by type:

| Type | Prefix colour |
|------|--------------|
| `:alert` | `⚠ OSA` yellow |
| `:work_complete` | `✓ OSA` dim |
| `:work_failed` | `✗ OSA` yellow |
| `:greeting` | `OSA` cyan |

On startup, `ProactiveMode.greeting/1` is called asynchronously in a `TaskSupervisor` child.

---

## Orchestrator Event Rendering

The CLI subscribes to `:system_event` on the Bus and renders live orchestrator feedback:

| Event | CLI output |
|-------|-----------|
| `orchestrator_task_started` | `▶ Spawning agents...` |
| `orchestrator_agents_spawning` | `▶ Deploying N agents` |
| `orchestrator_agent_started` | `├─ <name> started` |
| `orchestrator_agent_progress` | Live line (overwritten with `\r`) |
| `orchestrator_agent_completed` | `├─ <name> done` |
| `orchestrator_synthesizing` | `▶ Synthesizing results...` |
| `orchestrator_wave_started` | `▶ Wave N/M — K agents` |
| `orchestrator_task_appraised` | `⊕ Estimated: $X.XX · Y.Yh` |
| `context_pressure` | Pressure bar at >=70% utilisation |

---

## See Also

- [overview.md](overview.md) — Channel behaviour contract and lifecycle
- [http.md](http.md) — HTTP channel
- [messaging.md](messaging.md) — Telegram, Discord, Slack, and all messaging adapters
