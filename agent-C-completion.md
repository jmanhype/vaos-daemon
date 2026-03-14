# Agent-C: Backend Scheduler — Completion Report

## Branch: ws2/backend-scheduler

## Deliverables

### 1. Migration: `scheduled_runs` table
**File:** `priv/repo/migrations/20260314000000_create_scheduled_runs.exs`

Columns: scheduled_task_id, agent_name, status (pending/running/succeeded/failed/timed_out/cancelled), trigger_type (schedule/manual/event/assignment), started_at, completed_at, duration_ms, exit_code, stdout, stderr, token_usage (map), session_state (map), error_message, metadata (map), timestamps.

Indexes on: scheduled_task_id, status, inserted_at.

### 2. HeartbeatExecutor (Paperclip-style)
**File:** `lib/optimal_system_agent/agent/scheduler/heartbeat_executor.ex`

GenServer implementing the full heartbeat protocol:
- **Lock**: Per-agent mutex prevents concurrent runs (ETS-free GenServer state)
- **Budget check**: Queries Treasury.get_balance/0, aborts if available <= 0
- **Execute**: Spawns one-shot agent loop via JobExecutor.execute_task/2
- **Capture**: Stdout captured, compressed (gzip+base64) if > 10KB
- **Persist**: Writes run record to scheduled_runs via Ecto Repo
- **Emit**: SSE events via Bus.emit for task_run_started, task_run_completed, task_run_failed
- **Timeout**: Configurable per-task (default 5 min, max 30 min), kills process on timeout

### 3. CronPresets
**File:** `lib/optimal_system_agent/agent/scheduler/cron_presets.ex`

- 8 presets: every_minute, every_5_minutes, every_15_minutes, every_30_minutes, hourly, daily_9am, weekly_monday, monthly_first
- `describe/1`: Returns human-readable string for any cron expression (preset or custom)
- `next_run/1`: Calculates next DateTime by walking forward minute-by-minute from now

### 4. Scheduler Routes
**File:** `lib/optimal_system_agent/channels/http/api/scheduler_routes.ex`
**Forwarded at:** `/api/v1/scheduled-tasks`

| Method | Path | Description |
|--------|------|-------------|
| GET | / | List all scheduled tasks with next_run, description |
| POST | / | Create task { name, cron, prompt, agent_name, timeout_ms } |
| PUT | /:id | Update task fields |
| DELETE | /:id | Delete task |
| POST | /:id/trigger | Manual trigger (run now) via HeartbeatExecutor |
| PUT | /:id/toggle | Enable/disable { enabled: true/false } |
| GET | /:id/runs | Paginated run history |
| GET | /:id/runs/:run_id | Single run detail with stdout |
| GET | /presets | 8 cron presets with next_run timestamps |

### 5. SSE Events
Emitted via Bus.emit(:system_event, ...):
- `task_run_started` → { task_id, run_id, agent_name, trigger_type }
- `task_run_completed` → { run_id, status, duration_ms, token_usage }
- `task_run_failed` → { run_id, error_message }

### 6. Tests
- `test/agent/scheduler/cron_presets_test.exs` — 8 tests (presets, describe, next_run)
- `test/agent/scheduler/heartbeat_executor_test.exs` — 8 tests (init, lock, module API)
- `test/channels/http/api/scheduler_routes_test.exs` — 2 tests (presets endpoint, 404 catch-all)

## Verification
- [x] `mix compile` — clean (only pre-existing governance/approvals.ex typespec error)
- [x] `mix test test/agent/scheduler/` — 16 tests, 0 failures
- [x] `mix test test/channels/http/api/scheduler_routes_test.exs` — 2 tests, 0 failures
- [x] GET /api/v1/scheduled-tasks/presets returns 8 presets
- [x] Route forwarding wired in api.ex

## Architecture Notes
- HeartbeatExecutor is a standalone GenServer — can be added to supervision tree
- Routes follow exact codebase patterns: try/rescue/catch, json_error/4, pagination_params
- CronPresets is a pure module with no state
- Budget check is optional (graceful fallback if Treasury not available)
- Output compression uses zlib.gzip for runs > 10KB
