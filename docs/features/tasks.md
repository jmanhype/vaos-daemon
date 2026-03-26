# Task System

The Task system gives Daemon structured, persistent task tracking across three integrated subsystems: a live per-session Tracker, an LLM-decomposed Workflow engine, and a durable distributed Queue. All three are unified under a single GenServer (`Agent.Tasks`) and a single public API.

---

## Quick Start

```elixir
# Tracker — lightweight checklist
{:ok, id} = Tasks.add_task(session_id, "Implement auth middleware")
:ok       = Tasks.start_task(session_id, id)
:ok       = Tasks.complete_task(session_id, id)

# Workflow — LLM-decomposed multi-step plan
{:ok, workflow} = Tasks.create_workflow("Refactor the auth module", session_id)
{:ok, workflow} = Tasks.advance_workflow(workflow.id, "Refactored to use Plug.Builder")

# Queue — durable job queue for multi-agent work
Tasks.enqueue(task_id, agent_id, %{type: :analyze, path: "lib/auth.ex"})
{:ok, task} = Tasks.lease(agent_id)
Tasks.complete_queued(task.id, result)
```

---

## Architecture

```
Agent.Tasks (GenServer — single serialized writer)
├── Tracker   — per-session live checklist, emits Bus events
├── Workflow  — LLM decomposition, disk-persisted, step machine
└── Queue     — atomic leasing, SQLite write-through, retries
```

Registration, state updates, and disk writes all go through the GenServer. Hook chain execution and ETS reads run in the caller's process — no bottleneck.

---

## Subsystem 1: Tracker

The Tracker maintains a per-session checklist. Tasks transition through states:

```
:pending → :in_progress → :completed
                       → :failed
```

Every transition emits an event on `Events.Bus` so the CLI and HTTP channels can display live progress.

**Persistence:** `~/.daemon/sessions/{session_id}/tasks.json` — atomic `.tmp` → rename writes.

### API

| Function | Description |
|----------|-------------|
| `add_task(session_id, title)` | Create a new pending task. Returns `{:ok, task_id}`. |
| `add_tasks(session_id, [titles])` | Batch create. Returns `{:ok, [task_id]}`. |
| `start_task(session_id, task_id)` | Transition to `:in_progress`. |
| `complete_task(session_id, task_id)` | Transition to `:completed`. |
| `fail_task(session_id, task_id, reason)` | Transition to `:failed`. |
| `get_tasks(session_id)` | All tasks for a session. |
| `get_next_task(session_id)` | Next unblocked pending task. |
| `add_dependency(session_id, task_id, blocker_id)` | Block a task on another. |
| `remove_dependency(session_id, task_id, blocker_id)` | Unblock. |
| `update_task_fields(session_id, task_id, updates)` | Update description, owner, metadata. |
| `record_tokens(session_id, task_id, count)` | Async — track LLM cost per task. |
| `show_checklist(session_id)` | Emit `task_checklist_show` event to render in UI. |
| `hide_checklist(session_id)` | Emit `task_checklist_hide` event. |
| `clear_tasks(session_id)` | Remove all tasks for a session. |

### Auto-Extraction

When the Hooks system fires `post_response`, the Tasks GenServer inspects the agent's text response. If it finds 3 or more checklist-like items (using `Tracker.extract_from_response/1`) and the session has no tasks yet, those items are added automatically. This hook is registered at priority 80 after a 500ms startup delay.

### Task Struct

```elixir
%Task{
  id:           "task_abc123",
  title:        "Implement auth middleware",
  description:  nil,
  reason:       nil,
  owner:        nil,
  status:       :pending,          # :pending | :in_progress | :completed | :failed
  tokens_used:  0,
  blocked_by:   [],                # list of task_ids that must complete first
  metadata:     %{},
  created_at:   ~U[...],
  started_at:   nil,
  completed_at: nil
}
```

---

## Subsystem 2: Workflow

Workflows handle long-horizon tasks by decomposing a natural-language description into sequential steps via an LLM call. Each step has a status, tools list, acceptance criteria, and result.

**Persistence:** `~/.daemon/workflows/{workflow_id}.json` — survives restarts.

### Lifecycle

```
create_workflow("Refactor auth module", session_id)
  → LLM decomposes into N steps
  → Step 0 marked :in_progress
  → Persisted to disk

advance_workflow(id, result)
  → Current step marked :completed
  → Next step marked :in_progress
  → Persisted

complete_workflow_step(id, result)   # explicit step completion
skip_workflow_step(id, reason)       # skip without completing
pause_workflow(id)                   # pause for human review
resume_workflow(id)                  # continue after pause
```

### Auto-Detection

`Tasks.should_create_workflow?(message)` checks whether an incoming user message implies a multi-step plan. The agent loop can call this before routing to decide whether to create a workflow automatically.

### Context Injection

`Tasks.workflow_context_block(session_id)` returns a markdown string summarizing the active workflow's current step, completed steps, and remaining work. The agent loop injects this block into the system prompt so the LLM stays oriented during long-running tasks.

### API

| Function | Description |
|----------|-------------|
| `create_workflow(description, session_id)` | Decompose and start. Returns `{:ok, workflow}`. |
| `active_workflow(session_id)` | Get the active workflow for a session. |
| `advance_workflow(workflow_id, result)` | Move to next step. |
| `complete_workflow_step(workflow_id, result)` | Mark step done with output. |
| `skip_workflow_step(workflow_id, reason)` | Skip current step. |
| `pause_workflow(workflow_id)` | Pause execution. |
| `resume_workflow(workflow_id)` | Resume from paused. |
| `workflow_status(workflow_id)` | Get status map. |
| `list_workflows(session_id)` | All workflows for a session. |
| `workflow_context_block(session_id)` | Markdown context for prompt injection. |

### Workflow Struct

```elixir
%Workflow{
  id:           "wf_abc123",
  name:         "Refactor auth module",
  description:  "...",
  status:       :active,        # :active | :completed | :paused | :failed
  steps:        [%Step{...}],
  current_step: 1,
  context:      %{},
  session_id:   "cli_abc123",
  created_at:   "2026-03-08T10:00:00Z",
  updated_at:   "2026-03-08T10:15:00Z"
}

%Step{
  id:                  "step_001",
  name:                "Understand Current Design",
  description:         "...",
  status:              :completed,    # :pending | :in_progress | :completed | :skipped | :failed
  tools_needed:        ["file_read", "shell_execute"],
  acceptance_criteria: "Architecture understood and documented",
  result:              "Found 3 auth modules, centralized in Plug...",
  started_at:          "...",
  completed_at:        "..."
}
```

---

## Subsystem 3: Queue

The Queue provides durable, atomic job distribution for multi-agent scenarios where multiple agent processes pick up work independently.

**Persistence:** SQLite via Ecto (`Store.Repo` + `Store.Task` schema). Falls back to in-memory only when the database is unavailable.

### Lease Model

Agents claim tasks with an atomic lease. A leased task becomes invisible to other agents for the lease duration (default 5 minutes). If the agent crashes or times out, the lease expires and the task returns to `:pending` — picked up by the periodic reaper (every 60 seconds).

```
:pending → :leased (by agent_id) → :completed
                                 → :failed (after max_attempts=3)
         ↑_____________________________|  (reaper re-queues expired leases)
```

### API

| Function | Description |
|----------|-------------|
| `enqueue(task_id, agent_id, payload)` | Async enqueue. |
| `enqueue_sync(task_id, agent_id, payload)` | Sync enqueue, returns `{:ok, task}`. |
| `lease(agent_id, lease_ms \\ 300_000)` | Atomically claim oldest pending task. Returns `{:ok, task}` or `:empty`. |
| `complete_queued(task_id, result)` | Mark complete and write to DB. |
| `fail_queued(task_id, error)` | Increment attempt count, mark failed if at max. |
| `list_tasks(opts)` | List active queue tasks. |
| `get_task(task_id)` | Fetch a single task. |
| `list_history(opts)` | Query completed/failed tasks from DB. |
| `reap_expired_leases()` | Manual reap trigger (auto runs every 60s). |

---

## Events Emitted

The task system emits these events on `Events.Bus` (`:system_event` topic):

| Event | When |
|-------|------|
| `task_tracker_task_added` | New tracker task created |
| `task_created` | Same — alias used by CLI display |
| `task_started` | Task moved to `:in_progress` |
| `task_completed` | Task marked `:completed` |
| `task_failed` | Task marked `:failed` |
| `task_checklist_show` | Checklist UI requested |
| `task_checklist_hide` | Checklist UI dismissed |
| `task_enqueued` | Queue task enqueued |

---

## ETS Tables

| Table | Type | Purpose |
|-------|------|---------|
| `:daemon_files_read` | Public set | Tracks files read per session (used by read-before-write hook) |

The Tasks GenServer itself holds session and workflow state in process memory. Queue state lives in ETS-backed in-memory maps plus the SQLite DB.

---

## See Also

- [Hooks](hooks.md) — the `task_auto_extract` hook that populates the tracker automatically
- [Recipes](recipes.md) — step-based guided workflows built on a separate execution engine
- [Proactive Mode](proactive-mode.md) — autonomous task scheduling via cron and heartbeat
