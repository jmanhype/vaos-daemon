# God-File Refactor Plan

**Date:** 2026-03-03
**Status:** Proposed
**Scope:** Research only — no source files modified

---

## Overview

Four files have grown past the maintainability threshold. Each conflates 3-7 distinct
responsibilities. This document maps every function to its new home, defines the public
API surface of each proposed module, calls out shared-state risks, and prescribes a
safe migration sequence.

```
File                                    Lines   New modules
lib/.../commands.ex                     2938    8
lib/.../channels/http/api.ex            1831    8
lib/.../agent/orchestrator.ex           1441    4
lib/.../agent/scheduler.ex              1222    4
```

---

## 1. `commands.ex` — 2938 lines

### Current responsibilities (monolith)

| Group | Functions |
|-------|-----------|
| GenServer lifecycle | `start_link/1`, `init/1`, `handle_call/2` (register) |
| ETS / settings | `get_setting/3`, `put_setting/3`, `@ets_table`, `@settings_table` |
| Command registry | `execute/2`, `list_commands/0`, `register/3`, `lookup/1`, `builtin_commands/0`, `category_for/1` |
| Info commands | `cmd_help/2`, `cmd_status/2`, `cmd_skills/2`, `cmd_memory/2`, `cmd_soul/2` |
| Model / provider | `cmd_model/2`, `cmd_model_show/0`, `cmd_model_list/0`, `cmd_model_switch/2`, `do_model_switch/3`, `format_tier_refresh/0`, `validate_ollama_model/1`, `cmd_ollama_models/0`, `cmd_model_set_ollama_url/1`, `cmd_models_shortcut/2`, `active_model_for/1`, `cmd_providers/2` |
| Session management | `cmd_new/2`, `cmd_sessions/2`, `cmd_resume/2` |
| History | `cmd_history/2`, `cmd_history_list/1`, `cmd_history_session/2`, `cmd_history_search/2`, `extract_channel_flag/1` |
| Channels | `cmd_channels/2`, `cmd_channels_overview/0`, `resolve_channel_name/1`, `cmd_whatsapp/2`, `cmd_whatsapp_status/0`, `cmd_whatsapp_connect/0`, `cmd_whatsapp_disconnect/0`, `cmd_whatsapp_test/0` |
| Context / token usage | `cmd_compact/2`, `cmd_usage/2`, `context_utilization_bar/1` |
| Config | `cmd_verbose/2`, `cmd_think/2`, `cmd_plan/2`, `cmd_config/2` |
| Intelligence | `cmd_cortex/2` |
| Agent ecosystem | `cmd_agents/2`, `cmd_tiers/2`, `cmd_tier_set/2`, `cmd_swarms/2`, `cmd_hooks/2`, `cmd_learning/2` |
| Budget / thinking | `cmd_budget/2`, `cmd_thinking/2` |
| Scheduler | `cmd_schedule/2`, `cmd_cron/2`, `cmd_triggers/2`, `cmd_heartbeat/2`, `format_duration/1` |
| Tasks | `cmd_tasks/2` |
| Workflow / priming | `cmd_workflow/2`, `cmd_prime/2`, `cmd_security/2`, `cmd_memory_cmd/2`, `cmd_utility/2` |
| Auth | `cmd_login/2`, `cmd_logout/2` |
| System | `cmd_reload/2`, `cmd_doctor/2`, `cmd_setup/2`, `cmd_reset/2`, `cmd_logs/2`, `cmd_completion/2`, `cmd_docs/2`, `cmd_update/2`, `cmd_create/2`, `cmd_exit/2`, `cmd_clear/2`, `cmd_machines/2`, `cmd_export/2` |
| Doctor helpers | `check_soul/0`, `check_providers/0`, `check_ollama/0`, `check_tools/0`, `check_memory/0`, `check_cortex/0`, `check_scheduler/0`, `check_http/0` |
| Completion codegen | `generate_bash_completion/1`, `generate_zsh_completion/1`, `generate_fish_completion/1` |
| Custom commands I/O | `load_custom_commands/0`, `parse_command_file/1`, `persist_command/3`, `parse_create_args/1` |
| Formatting helpers | `format_timestamp/1`, `format_categories/1`, `format_pipeline_steps/1`, `format_number/1`, `format_bytes/1`, `indent/2` |

### Shared state that needs care

| State | Location | Access pattern |
|-------|----------|---------------|
| `:osa_commands` ETS table | Created in `Commands.init/1` | `:set, :public, :named_table` — any process reads/writes |
| `:osa_settings` ETS table | Created in `Commands.init/1` | Per-session key `{session_id, atom}` → value |
| `Process.put(:osa_current_cmd, ...)` | Set in `execute/2` before dispatch | Read by `cmd_workflow/2`, `cmd_prime/2`, `cmd_security/2`, `cmd_memory_cmd/2`, `cmd_utility/2` — within same call stack, safe |

Both ETS tables must stay owned by the GenServer (the owner process must not die before
them). Sub-command modules access the tables via module calls back to `Commands`; they
must not directly call `:ets.new`.

### Proposed module tree

```
lib/optimal_system_agent/
  commands/
    registry.ex          # GenServer core: ETS, settings, execute/2, list/0, register/3
    info.ex              # cmd_help, cmd_status, cmd_skills, cmd_memory, cmd_soul, cmd_cortex
    model.ex             # cmd_model family, provider switching, Ollama validation
    session.ex           # cmd_new, cmd_sessions, cmd_resume, cmd_history family
    channels.ex          # cmd_channels, cmd_whatsapp family
    agents.ex            # cmd_agents, cmd_tiers, cmd_tier_set, cmd_swarms, cmd_hooks, cmd_learning, cmd_budget, cmd_thinking, cmd_machines
    scheduler.ex         # cmd_schedule, cmd_cron, cmd_triggers, cmd_heartbeat
    system.ex            # cmd_reload, cmd_doctor + check_*, cmd_setup, cmd_reset, cmd_logs, cmd_completion, cmd_docs, cmd_update, cmd_create, cmd_exit, cmd_clear, cmd_auth (login/logout), cmd_export, cmd_tasks, cmd_config, cmd_verbose, cmd_think, cmd_plan, cmd_compact, cmd_usage, cmd_workflow, cmd_prime, cmd_security, cmd_memory_cmd, cmd_utility
  commands.ex            # Thin facade: delegates to Commands.Registry; kept for callers
```

#### Module 1.1 — `Commands.Registry`
**Path:** `lib/optimal_system_agent/commands/registry.ex`
**Replaces:** GenServer, ETS management, core dispatch

Public API:
```elixir
Commands.Registry.start_link/1
Commands.Registry.execute/2       # {:command|:prompt|:action|:unknown}
Commands.Registry.list_commands/0 # [{name, desc, category}]
Commands.Registry.register/3      # (name, desc, template) -> :ok | {:error, t}
Commands.Registry.get_setting/3   # (session_id, key, default) -> term
Commands.Registry.put_setting/3   # (session_id, key, value) -> :ok
Commands.Registry.builtin_commands/0  # keep private; or expose for testing
```

Functions moved here: `start_link/1`, `init/1`, `handle_call/2`, `execute/2`,
`list_commands/0`, `register/3`, `lookup/1`, `builtin_commands/0`, `category_for/1`,
`get_setting/3`, `put_setting/3`, `load_custom_commands/0`, `parse_command_file/1`,
`persist_command/3`, `parse_create_args/1`

**Interaction:** Dispatches to one of the sub-command modules. Each sub-module exposes
`handle(cmd_name, arg, session_id)` or is called directly as a named `cmd_*/2` private
function moved there.

#### Module 1.2 — `Commands.Info`
**Path:** `lib/optimal_system_agent/commands/info.ex`

Functions: `cmd_help/2`, `cmd_status/2`, `cmd_skills/2`, `cmd_memory/2`, `cmd_soul/2`,
`cmd_cortex/2`, formatting helpers needed only by these (`format_categories/1`,
`format_pipeline_steps/1`, `format_timestamp/1`, `indent/2`)

Public API: one function per command, each `(arg, session_id) -> command_result`.

#### Module 1.3 — `Commands.Model`
**Path:** `lib/optimal_system_agent/commands/model.ex`

Functions: `cmd_model/2`, `cmd_model_show/0`, `cmd_model_list/0`, `cmd_model_switch/2`,
`do_model_switch/3`, `format_tier_refresh/0`, `validate_ollama_model/1`,
`cmd_ollama_models/0`, `cmd_model_set_ollama_url/1`, `cmd_models_shortcut/2`,
`active_model_for/1`, `cmd_providers/2`

Public API: `cmd_model/2`, `cmd_providers/2` (the rest are private).

#### Module 1.4 — `Commands.Session`
**Path:** `lib/optimal_system_agent/commands/session.ex`

Functions: `cmd_new/2`, `cmd_sessions/2`, `cmd_resume/2`, `cmd_history/2`,
`cmd_history_list/1`, `cmd_history_session/2`, `cmd_history_search/2`,
`extract_channel_flag/1`

Public API: `cmd_new/2`, `cmd_sessions/2`, `cmd_resume/2`, `cmd_history/2`.

#### Module 1.5 — `Commands.Channels`
**Path:** `lib/optimal_system_agent/commands/channels.ex`

Functions: `cmd_channels/2`, `cmd_channels_overview/0`, `resolve_channel_name/1`,
`cmd_whatsapp/2`, `cmd_whatsapp_status/0`, `cmd_whatsapp_connect/0`,
`cmd_whatsapp_disconnect/0`, `cmd_whatsapp_test/0`

Public API: `cmd_channels/2`, `cmd_whatsapp/2`.

#### Module 1.6 — `Commands.Agents`
**Path:** `lib/optimal_system_agent/commands/agents.ex`

Functions: `cmd_agents/2`, `cmd_tiers/2`, `cmd_tier_set/2`, `cmd_swarms/2`,
`cmd_hooks/2`, `cmd_learning/2`, `cmd_budget/2`, `cmd_thinking/2`, `cmd_machines/2`

Public API: one public function per command.

#### Module 1.7 — `Commands.Scheduler`
**Path:** `lib/optimal_system_agent/commands/scheduler.ex`

Functions: `cmd_schedule/2`, `cmd_cron/2`, `cmd_triggers/2`, `cmd_heartbeat/2`,
`format_duration/1`

Public API: four public `cmd_*` functions.

#### Module 1.8 — `Commands.System`
**Path:** `lib/optimal_system_agent/commands/system.ex`

Functions: `cmd_reload/2`, `cmd_doctor/2`, `cmd_setup/2`, `cmd_reset/2`, `cmd_logs/2`,
`cmd_completion/2`, `cmd_docs/2`, `cmd_update/2`, `cmd_create/2`, `cmd_exit/2`,
`cmd_clear/2`, `cmd_login/2`, `cmd_logout/2`, `cmd_export/2`, `cmd_tasks/2`,
`cmd_config/2`, `cmd_verbose/2`, `cmd_think/2`, `cmd_plan/2`, `cmd_compact/2`,
`cmd_usage/2`, `cmd_workflow/2`, `cmd_prime/2`, `cmd_security/2`, `cmd_memory_cmd/2`,
`cmd_utility/2`, `generate_bash_completion/1`, `generate_zsh_completion/1`,
`generate_fish_completion/1`, `check_soul/0`, `check_providers/0`, `check_ollama/0`,
`check_tools/0`, `check_memory/0`, `check_cortex/0`, `check_scheduler/0`, `check_http/0`,
`format_number/1`, `format_bytes/1`, `context_utilization_bar/1`

Public API: one public `cmd_*` per command.

**Note:** `Commands.System` still ends up around 600 lines. A second-pass split can
extract `Commands.Diagnostics` (doctor + checks) and `Commands.Config` (verbose, think,
plan, config, compact, usage) if desired.

### Interaction diagram

```
Commands (facade)
  └── Commands.Registry (GenServer + ETS)
        ├── dispatches to Commands.Info
        ├── dispatches to Commands.Model
        ├── dispatches to Commands.Session
        ├── dispatches to Commands.Channels
        ├── dispatches to Commands.Agents
        ├── dispatches to Commands.Scheduler
        └── dispatches to Commands.System
```

All sub-modules call back into `Commands.Registry.get_setting/3` and
`Commands.Registry.put_setting/3` rather than touching ETS directly.

### Migration sequence for `commands.ex`

1. Extract `Commands.Registry` first — GenServer, ETS, `execute/2`. All handler
   functions stay inline initially (copy-forwarding stubs).
2. Extract `Commands.Model` — highest standalone cohesion, no cross-dependencies.
3. Extract `Commands.Info` — simple read-only callers of other modules.
4. Extract `Commands.Session` — depends on `Memory` and `Repo`, no other commands.
5. Extract `Commands.Channels` — depends only on `Channels.Manager` and `WhatsAppWeb`.
6. Extract `Commands.Agents` — depends on `Roster`, `Tier`, `Hooks`, `Learning`.
7. Extract `Commands.Scheduler` — depends only on `Agent.Scheduler`.
8. Extract `Commands.System` — largest, most miscellaneous; last because depends on
   formatters needed by earlier modules.
9. Delete `commands.ex` body; keep as a pure alias/delegate file if callers import it.

---

## 2. `channels/http/api.ex` — 1831 lines

### Current responsibilities (monolith)

| Group | Routes / Functions |
|-------|--------------------|
| Plug pipeline | `call/2` override, `authenticate/2`, plug declarations |
| Agent core | `POST /orchestrate`, `GET /stream/:session_id`, SSE loop |
| Tools & skills | `GET /tools`, `POST /tools/:name/execute`, `GET /skills`, `POST /skills/create` |
| Commands | `GET /commands`, `POST /commands/execute` |
| Orchestration | `POST /orchestrate/complex`, `GET /orchestrate/:task_id/progress`, `GET /orchestrate/tasks` |
| Swarm | `POST /swarm/launch`, `GET /swarm`, `GET /swarm/:id`, `DELETE /swarm/:id` |
| Memory | `POST /memory`, `GET /memory/recall` |
| Models | `GET /models`, `POST /models/switch` |
| Scheduler | `GET /scheduler/jobs`, `POST /scheduler/reload` |
| Webhooks | `POST /webhooks/:trigger_id` |
| Analytics | `GET /analytics` |
| CloudEvents | `POST /events`, `GET /events/stream` |
| Fleet | `POST /fleet/register`, `GET /fleet/:agent_id/instructions`, `POST /fleet/heartbeat`, `GET /fleet/agents`, `GET /fleet/:agent_id`, `POST /fleet/dispatch` |
| Channel webhooks | `GET+POST /channels/whatsapp/webhook`, `POST /channels/telegram/webhook`, `POST /channels/discord/webhook`, `POST /channels/slack/events`, `POST /channels/signal/webhook`, `POST /channels/matrix/webhook`, `POST /channels/email/inbound`, `POST /channels/qq/webhook`, `POST /channels/dingtalk/webhook`, `POST /channels/feishu/events`, `GET /channels` |
| Sessions | `GET /sessions`, `POST /sessions`, `GET /sessions/:id`, `GET /sessions/:id/messages` |
| Auth | `POST /auth/login`, `POST /auth/logout`, `POST /auth/refresh` |
| OSCP | `POST /oscp`, routing helpers `route_oscp_event/1` |
| Task history | `GET /tasks/history` |
| Helpers | `authenticate/2`, `validate_session_owner/2`, `sse_loop/2`, `cloud_events_sse_loop/1`, `generate_session_id/0`, `json_error/4`, `unwrap_ok/1`, `swarm_to_map/1`, `parse_swarm_pattern_opts/1`, `await_orchestration_http/2`, `do_await_orchestration_http/2`, `maybe_put/3`, `verify_telegram_signature/2`, `verify_whatsapp_signature/3`, `verify_dingtalk_signature/3`, `verify_email_signature/2`, `route_oscp_event/1`, `parse_task_status/1`, `parse_int/1` |

### Shared state that needs care

| State | Notes |
|-------|-------|
| Plug pipeline ordering | `authenticate` → `Integrity` → `match` → `Parsers` → `dispatch` must remain intact |
| Webhook auth bypass | Channel webhook routes intentionally skip JWT. The bypass logic lives in `authenticate/2` pattern matching on path prefix. Sub-routers must replicate or delegate to the same plug. |
| SSE blocking loops | `sse_loop/2` and `cloud_events_sse_loop/1` block the request process. Must stay in the module that sends the chunked response (not in GenServers). |

### Proposed module tree

The Plug.Router composition model allows a parent router to forward to child routers
with `forward/2`. Each child is a fully independent `use Plug.Router` module.

```
lib/optimal_system_agent/channels/http/
  api.ex                  # Thin top-level router: auth plug, then forward to sub-routers
  api/
    agent_routes.ex       # POST /orchestrate, GET /stream/:session_id
    tool_routes.ex        # GET /tools, POST /tools/:name/execute, GET /skills, POST /skills/create, GET /commands, POST /commands/execute
    orchestration_routes.ex # POST /orchestrate/complex, GET /orchestrate/:id/progress, GET /orchestrate/tasks, POST /swarm/*, GET/DELETE /swarm/*
    data_routes.ex        # POST /memory, GET /memory/recall, GET /models, POST /models/switch, GET /analytics, GET /scheduler/jobs, POST /scheduler/reload, POST /webhooks/:trigger_id
    fleet_routes.ex       # POST /fleet/register, GET /fleet/:agent_id/instructions, POST /fleet/heartbeat, GET /fleet/agents, GET /fleet/:agent_id, POST /fleet/dispatch
    channel_routes.ex     # GET /channels, POST/GET /channels/*/webhook (all 10 platforms)
    session_routes.ex     # GET /sessions, POST /sessions, GET /sessions/:id, GET /sessions/:id/messages
    auth_routes.ex        # POST /auth/login, POST /auth/logout, POST /auth/refresh
    protocol_routes.ex    # POST /events, GET /events/stream, POST /oscp, GET /tasks/history, GET /machines
    shared.ex             # json_error/4, maybe_put/3, generate_session_id/0, parse_int/1, parse_task_status/1, unwrap_ok/1
    sse.ex                # sse_loop/2, cloud_events_sse_loop/1
    webhook_verify.ex     # verify_telegram_signature/2, verify_whatsapp_signature/3, verify_dingtalk_signature/3, verify_email_signature/2
```

#### Module 2.1 — `API` (top-level router)
**Path:** `lib/optimal_system_agent/channels/http/api.ex` (same filename, gutted body)

Responsibilities:
- Global error rescue around `call/2`
- `authenticate/2` plug (JWT check + dev-mode bypass)
- `validate_session_owner/2`
- `forward "/auth", to: AuthRoutes` (no auth on this prefix)
- `forward "/channels", to: ChannelRoutes` (webhook bypass handled in that module)
- `forward "/", to: ...` for remaining sub-routers

Functions kept here: `call/2`, `authenticate/2`, `validate_session_owner/2`

#### Module 2.2 — `AgentRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/agent_routes.ex`

Routes: `POST /orchestrate`, `GET /stream/:session_id`
Private functions: `sse_loop/2` (or delegated to `SSE`)

Public surface: none — routes are handled internally by Plug.

#### Module 2.3 — `ToolRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/tool_routes.ex`

Routes: `GET /tools`, `POST /tools/:name/execute`, `GET /skills`, `POST /skills/create`,
`GET /commands`, `POST /commands/execute`

#### Module 2.4 — `OrchestrationRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/orchestration_routes.ex`

Routes: `POST /orchestrate/complex`, `GET /orchestrate/:task_id/progress`,
`GET /orchestrate/tasks`, `POST /swarm/launch`, `GET /swarm`, `GET /swarm/:id`,
`DELETE /swarm/:id`

Private functions: `await_orchestration_http/2`, `do_await_orchestration_http/2`,
`swarm_to_map/1`, `parse_swarm_pattern_opts/1`

#### Module 2.5 — `DataRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/data_routes.ex`

Routes: `POST /memory`, `GET /memory/recall`, `GET /models`, `POST /models/switch`,
`GET /analytics`, `GET /scheduler/jobs`, `POST /scheduler/reload`,
`POST /webhooks/:trigger_id`, `GET /machines`

#### Module 2.6 — `FleetRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/fleet_routes.ex`

Routes: `POST /fleet/register`, `GET /fleet/:agent_id/instructions`,
`POST /fleet/heartbeat`, `GET /fleet/agents`, `GET /fleet/:agent_id`,
`POST /fleet/dispatch`

#### Module 2.7 — `ChannelRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/channel_routes.ex`

Routes: `GET /channels`, `POST /channels/telegram/webhook`, `POST /channels/discord/webhook`,
`POST /channels/slack/events`, `GET /channels/whatsapp/webhook`,
`POST /channels/whatsapp/webhook`, `POST /channels/signal/webhook`,
`POST /channels/matrix/webhook`, `POST /channels/email/inbound`,
`POST /channels/qq/webhook`, `POST /channels/dingtalk/webhook`,
`POST /channels/feishu/events`

Private functions (or delegated to `WebhookVerify`): `verify_telegram_signature/2`,
`verify_whatsapp_signature/3`, `verify_dingtalk_signature/3`, `verify_email_signature/2`

**Note:** This module does not sit behind the JWT authenticate plug because webhooks
carry their own per-platform auth. The top-level router forwards to this module before
auth runs, or the module re-implements the bypass check at its top.

#### Module 2.8 — `SessionRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/session_routes.ex`

Routes: `GET /sessions`, `POST /sessions`, `GET /sessions/:id`,
`GET /sessions/:id/messages`

#### Module 2.9 — `AuthRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/auth_routes.ex`

Routes: `POST /auth/login`, `POST /auth/logout`, `POST /auth/refresh`

#### Module 2.10 — `ProtocolRoutes`
**Path:** `lib/optimal_system_agent/channels/http/api/protocol_routes.ex`

Routes: `POST /events`, `GET /events/stream`, `POST /oscp`, `GET /tasks/history`

Private functions: `route_oscp_event/1`, `cloud_events_sse_loop/1`

#### Module 2.11 — `API.Shared`
**Path:** `lib/optimal_system_agent/channels/http/api/shared.ex`

Pure utility functions used across multiple route modules:
`json_error/4`, `maybe_put/3`, `generate_session_id/0`, `parse_int/1`,
`parse_task_status/1`, `unwrap_ok/1`

#### Module 2.12 — `API.WebhookVerify`
**Path:** `lib/optimal_system_agent/channels/http/api/webhook_verify.ex`

Functions: `verify_telegram_signature/2`, `verify_whatsapp_signature/3`,
`verify_dingtalk_signature/3`, `verify_email_signature/2`

All return `:ok | {:error, :no_secret | :invalid_signature}`.

### Interaction diagram

```
HTTP request
  └── API (call/2 error rescue + authenticate plug)
        ├── forward /auth       -> AuthRoutes
        ├── forward /channels   -> ChannelRoutes (webhook bypass internal)
        ├── forward /fleet      -> FleetRoutes
        ├── forward /sessions   -> SessionRoutes
        ├── forward /swarm      -> OrchestrationRoutes
        ├── forward /orchestrate -> OrchestrationRoutes
        ├── forward /tools      -> ToolRoutes
        ├── forward /skills     -> ToolRoutes
        ├── forward /commands   -> ToolRoutes
        ├── forward /memory     -> DataRoutes
        ├── forward /models     -> DataRoutes
        ├── forward /analytics  -> DataRoutes
        ├── forward /scheduler  -> DataRoutes
        ├── forward /webhooks   -> DataRoutes
        ├── forward /machines   -> DataRoutes
        ├── forward /events     -> ProtocolRoutes
        ├── forward /oscp       -> ProtocolRoutes
        ├── forward /tasks      -> ProtocolRoutes
        └── catch-all 404
```

All sub-routers `import API.Shared` for helpers. `ChannelRoutes` uses `WebhookVerify`.

### Migration sequence for `api.ex`

1. Create `API.Shared` and `API.WebhookVerify` — no routes, pure functions, zero risk.
2. Extract `AuthRoutes` — simplest (no dependencies on other route groups, straightforward
   JWT flows). Remove auth-path bypass from `authenticate/2` once forwarding is in place.
3. Extract `AgentRoutes` with `sse_loop/2`.
4. Extract `ChannelRoutes` with `WebhookVerify` imported.
5. Extract `SessionRoutes`.
6. Extract `FleetRoutes`.
7. Extract `DataRoutes`.
8. Extract `ToolRoutes`.
9. Extract `OrchestrationRoutes` (most complex — depends on `await_orchestration_http`).
10. Extract `ProtocolRoutes` with `cloud_events_sse_loop/1`.
11. Replace `api.ex` body with `forward` calls only.

---

## 3. `agent/orchestrator.ex` — 1441 lines

### Current responsibilities (monolith)

| Group | Functions |
|-------|-----------|
| GenServer lifecycle | `start_link/1`, `init/1` |
| Public API | `execute/3`, `progress/1`, `create_skill/4`, `list_tasks/0`, `find_matching_skills/1`, `suggest_or_create_skill/4` |
| GenServer callbacks | `handle_call/3` (5 clauses), `handle_cast/3`, `handle_continue/2` (3 clauses), `handle_info/2` (2 clauses) |
| Complexity analysis | `analyze_complexity/1`, `parse_complexity_response/1`, `parse_role/1` (11 clauses) |
| Task decomposition | `decompose_task/1`, `build_execution_waves/1`, `build_waves/3`, `build_dependency_context/2` |
| Wave execution | `handle_continue({:start_execution, ...})`, `handle_continue({:execute_wave, ...})`, `handle_continue({:synthesize, ...})`, `find_task_by_ref/2`, `record_agent_result/7` |
| Sub-agent lifecycle | `spawn_agent/4`, `resolve_agent_tier/1`, `run_agent_loop/8`, `run_sub_agent_iterations/10` (2 clauses) |
| Prompt building | `build_agent_prompt/1` |
| Synthesis | `synthesize_results/4`, `run_simple/2` |
| Skill management | `do_create_skill/4`, `do_find_matching_skills/1` |
| Helpers | `generate_id/1`, `estimate_tokens/1` (2 clauses) |

### Shared state that needs care

| State | Notes |
|-------|-------|
| `state.tasks` map | Lives in the GenServer. All wave execution reads/writes through `handle_continue`. Must remain in one process to preserve OTP message ordering guarantees. |
| `state.agent_pool` | Currently unused but declared in `defstruct`. |
| `state.skill_cache` | In-memory cache of created skills within this GenServer. |
| `Task.async` refs in `state.tasks[id].wave_refs` | Refs are received back by the GenServer as messages. Ref tracking must stay in the process that spawned the tasks — cannot be split across processes without a ref-forwarding layer. |

**Critical constraint:** `handle_continue`, `handle_info`, and `handle_cast` for wave
execution must all remain in the same GenServer module. Wave ref tracking is tightly
coupled to the OTP message loop.

### Proposed module tree

```
lib/optimal_system_agent/agent/
  orchestrator/
    complexity.ex         # analyze_complexity/1, parse_complexity_response/1, parse_role/1
    decomposer.ex         # decompose_task/1, build_execution_waves/1, build_waves/3, build_dependency_context/2
    agent_runner.ex       # spawn_agent/4, resolve_agent_tier/1, run_agent_loop/8, run_sub_agent_iterations/10, build_agent_prompt/1
    skill_manager.ex      # do_create_skill/4, do_find_matching_skills/1
  orchestrator.ex         # GenServer shell: all handle_*, public API, synthesize_results/4, run_simple/2, record_agent_result/7, find_task_by_ref/2 — delegates heavy logic to sub-modules
```

#### Module 3.1 — `Orchestrator.Complexity`
**Path:** `lib/optimal_system_agent/agent/orchestrator/complexity.ex`

Pure functions — no GenServer dependency, no state.

```elixir
Orchestrator.Complexity.analyze/1         # (message) -> :simple | {:complex, [SubTask.t]}
Orchestrator.Complexity.parse_response/1  # (content) -> :simple | {:complex, [...]}
```

Private: `parse_role/1` (11 clauses)

Calls: `Providers.Registry.chat/2` (LLM call).

#### Module 3.2 — `Orchestrator.Decomposer`
**Path:** `lib/optimal_system_agent/agent/orchestrator/decomposer.ex`

Pure functions — no process state.

```elixir
Orchestrator.Decomposer.decompose/1            # (message) -> {:ok, [SubTask.t]} | {:error, t}
Orchestrator.Decomposer.build_waves/1          # ([SubTask.t]) -> [[SubTask.t]]
Orchestrator.Decomposer.dependency_context/2   # (depends_on, results_map) -> String.t | nil
```

Private: `build_waves/3` (recursive), `build_execution_waves/1`

Calls: `Orchestrator.Complexity.analyze/1`.

#### Module 3.3 — `Orchestrator.AgentRunner`
**Path:** `lib/optimal_system_agent/agent/orchestrator/agent_runner.ex`

Functions that run inside `Task.async` — no GenServer state access.

```elixir
Orchestrator.AgentRunner.spawn/4          # (sub_task, task_id, session_id, cached_tools) -> {agent_id, AgentState.t, Task.t}
Orchestrator.AgentRunner.build_prompt/1   # (sub_task) -> String.t
```

Private: `resolve_agent_tier/1`, `run_agent_loop/8`, `run_sub_agent_iterations/10`

Calls: `Providers.Registry.chat/2`, `Tier.model_for/2`, `Roster.find_by_trigger/1`,
`Tools.execute_direct/2`, `Bus.emit/2`

**Note:** `spawn/4` returns a `{agent_id, agent_state, task_ref}` tuple. The GenServer
retains the ref and registers its monitor — this function does not own the monitor.

#### Module 3.4 — `Orchestrator.SkillManager`
**Path:** `lib/optimal_system_agent/agent/orchestrator/skill_manager.ex`

```elixir
Orchestrator.SkillManager.create/4      # (name, desc, instructions, tools) -> {:ok, name} | {:error, t}
Orchestrator.SkillManager.find_matches/1 # (description) -> {:matches, [map]} | :no_matches
```

Calls: `Tools.Registry.search/1`, `File.write!/2`, `Bus.emit/2`.

#### `Orchestrator` (GenServer shell, kept)
**Path:** `lib/optimal_system_agent/agent/orchestrator.ex`

Responsibilities remaining:
- Public API (`execute/3`, `progress/1`, `create_skill/4`, `list_tasks/0`,
  `find_matching_skills/1`, `suggest_or_create_skill/4`)
- GenServer `init/1`, all `handle_call`, `handle_cast`, `handle_continue`, `handle_info`
- State mutation: `record_agent_result/7`, `find_task_by_ref/2`
- Synthesis: `synthesize_results/4`, `run_simple/2`
- Helpers: `generate_id/1`, `estimate_tokens/1`
- Sub-struct definitions: `SubTask`, `AgentState`, `TaskState`

Target size after extraction: ~500 lines.

### Interaction diagram

```
Orchestrator (GenServer)
  ├── handle_call {:execute} -> Orchestrator.Decomposer.decompose/1
  │                          -> Orchestrator.AgentRunner.spawn/4 (via handle_continue)
  │                          -> synthesize_results/4 (inline)
  ├── handle_call {:create_skill} -> Orchestrator.SkillManager.create/4
  ├── handle_call {:find_matching_skills} -> Orchestrator.SkillManager.find_matches/1
  └── Decomposer -> Complexity (for LLM analysis)
```

### Migration sequence for `orchestrator.ex`

1. Extract `Orchestrator.SkillManager` — fully self-contained, no GenServer coupling.
2. Extract `Orchestrator.Complexity` — pure LLM calls, no state.
3. Extract `Orchestrator.Decomposer` (depends on Complexity).
4. Extract `Orchestrator.AgentRunner` — the hardest; carefully preserve ref ownership
   contract: the returned `Task.t` must be received and monitored by the calling
   GenServer.
5. Update `Orchestrator` to call extracted modules. Run full test suite after each step.

---

## 4. `agent/scheduler.ex` — 1222 lines

### Current responsibilities (monolith)

| Group | Functions |
|-------|-----------|
| GenServer lifecycle | `start_link/1`, `init/1` |
| Public API | `heartbeat/0`, `reload_crons/0`, `list_jobs/0`, `fire_trigger/2`, `add_job/1`, `remove_job/1`, `toggle_job/2`, `run_job/1`, `add_trigger/1`, `remove_trigger/1`, `toggle_trigger/2`, `list_triggers/0`, `add_heartbeat_task/1`, `next_heartbeat_at/0`, `status/0`, `heartbeat_path/0` |
| GenServer cast handlers | `handle_cast/2` (:heartbeat, :reload_crons, {:fire_trigger, ...}) |
| GenServer call handlers | `handle_call/2` (:list_jobs, {:add_job, ...}, {:remove_job, ...}, {:toggle_job, ...}, {:run_job, ...}, {:add_trigger, ...}, {:remove_trigger, ...}, {:toggle_trigger, ...}, :list_triggers, {:add_heartbeat_task, ...}, :next_heartbeat_at, :status) |
| GenServer info handlers | `handle_info/2` (:heartbeat, :cron_check) |
| Cron loading | `crons_path/0`, `triggers_path/0`, `load_crons/1`, `load_triggers/1` |
| Cron execution | `run_cron_check/1`, `execute_cron_job/1` (4 clauses) |
| Trigger execution | `run_trigger/3`, `execute_trigger_action/2` (3 clauses) |
| Template interpolation | `interpolate/2`, `shell_escape/1` (2 clauses) |
| Shell execution | `run_shell_command/1` |
| Outbound HTTP | `validate_url/1`, `http_request/4` |
| Cron expression | `parse_cron_expression/1`, `parse_cron_field/3` (3 clauses), `parse_cron_single/3`, `cron_matches?/2` |
| Heartbeat | `run_heartbeat/1`, `run_heartbeat_tasks/1`, `execute_task/2`, `parse_pending_tasks/1`, `mark_completed/2` |
| JSON persistence | `atomic_update_crons/2`, `atomic_update_triggers/2` |
| Validation | `validate_job/1`, `validate_trigger/1` |
| Helpers | `generate_id/0`, `ensure_heartbeat_file/0`, `schedule_heartbeat/0`, `schedule_cron_check/0` |

### Shared state that needs care

| State | Notes |
|-------|-------|
| `state.cron_jobs` | List of job maps. Mutated only inside GenServer calls via `atomic_update_crons/2`. |
| `state.trigger_handlers` | Map of trigger_id -> trigger for O(1) lookup. Rebuilt on every `load_triggers/1`. |
| `state.triggers_raw` | Full list for `list_triggers/0`. |
| `state.failures` | Circuit breaker counters for both jobs and triggers, keyed by id. |
| `state.last_run` | DateTime of last heartbeat — used by `next_heartbeat_at/0` and `status/0`. |
| CRONS.json / TRIGGERS.json | Disk files written atomically via tmp-then-rename. Concurrent writes are serialized by the GenServer. |

### Proposed module tree

```
lib/optimal_system_agent/agent/
  scheduler/
    cron_engine.ex        # parse_cron_expression/1, parse_cron_field/3, parse_cron_single/3, cron_matches?/2
    job_executor.ex       # execute_cron_job/1, execute_trigger_action/2, run_shell_command/1, validate_url/1, http_request/4, interpolate/2, shell_escape/1, execute_task/2
    heartbeat.ex          # run_heartbeat/1, run_heartbeat_tasks/1, parse_pending_tasks/1, mark_completed/2, ensure_heartbeat_file/0
    persistence.ex        # load_crons/1, load_triggers/1, atomic_update_crons/2, atomic_update_triggers/2, validate_job/1, validate_trigger/1, crons_path/0, triggers_path/0
  scheduler.ex            # GenServer shell: all public API, handle_*, run_cron_check/1, run_trigger/3, schedule_heartbeat/0, schedule_cron_check/0, generate_id/0
```

#### Module 4.1 — `Scheduler.CronEngine`
**Path:** `lib/optimal_system_agent/agent/scheduler/cron_engine.ex`

Pure parsing / matching — no side effects.

```elixir
Scheduler.CronEngine.parse/1        # (expr :: String.t) -> {:ok, map} | {:error, String.t}
Scheduler.CronEngine.matches?/2     # (fields_map, DateTime.t) -> boolean
```

Private: `parse_cron_field/3`, `parse_cron_single/3`

#### Module 4.2 — `Scheduler.JobExecutor`
**Path:** `lib/optimal_system_agent/agent/scheduler/job_executor.ex`

Stateless execution — returns `{:ok, result} | {:error, reason}`.

```elixir
Scheduler.JobExecutor.run_cron_job/1       # (job_map) -> {:ok, t} | {:error, t}
Scheduler.JobExecutor.run_trigger_action/2  # (trigger, payload) -> {:ok, t} | {:error, t}
Scheduler.JobExecutor.run_shell/1          # (command) -> {:ok, output} | {:error, t}
Scheduler.JobExecutor.run_task/2           # (description, session_id) -> {:ok, t} | {:error, t}
```

Private: `validate_url/1`, `http_request/4`, `interpolate/2`, `shell_escape/1`

Calls: `Agent.Loop.process_message/2`, `Security.ShellPolicy.validate/1`.

#### Module 4.3 — `Scheduler.Heartbeat`
**Path:** `lib/optimal_system_agent/agent/scheduler/heartbeat.ex`

File I/O for HEARTBEAT.md.

```elixir
Scheduler.Heartbeat.run/1            # (state) -> state  — reads file, executes tasks, marks done
Scheduler.Heartbeat.ensure_file/0    # () -> :ok
Scheduler.Heartbeat.path/0           # () -> String.t
```

Private: `run_tasks/1`, `parse_pending_tasks/1`, `mark_completed/2`

Calls: `Scheduler.JobExecutor.run_task/2`, `HeartbeatState.*`, `Bus.emit/2`.

#### Module 4.4 — `Scheduler.Persistence`
**Path:** `lib/optimal_system_agent/agent/scheduler/persistence.ex`

Disk I/O, validation, state reloading.

```elixir
Scheduler.Persistence.load_crons/1         # (state) -> state
Scheduler.Persistence.load_triggers/1      # (state) -> state
Scheduler.Persistence.update_crons/2       # (state, update_fn) -> {:ok, state} | {:error, t}
Scheduler.Persistence.update_triggers/2    # (state, update_fn) -> {:ok, state} | {:error, t}
Scheduler.Persistence.validate_job/1       # (map) -> :ok | {:error, String.t}
Scheduler.Persistence.validate_trigger/1   # (map) -> :ok | {:error, String.t}
```

Private: `crons_path/0`, `triggers_path/0`

#### `Scheduler` (GenServer shell, kept)
**Path:** `lib/optimal_system_agent/agent/scheduler.ex`

Responsibilities remaining:
- All public API (thin GenServer.call/cast wrappers)
- `init/1`, all `handle_call`, `handle_cast`, `handle_info`
- `run_cron_check/1` (loops over jobs, calls `JobExecutor.run_cron_job/1`, updates circuit breakers)
- `run_trigger/3` (circuit breaker check, calls `JobExecutor.run_trigger_action/2`)
- `schedule_heartbeat/0`, `schedule_cron_check/0`
- `generate_id/0`

Target size after extraction: ~450 lines.

### Interaction diagram

```
Scheduler (GenServer)
  ├── handle_info :heartbeat -> Scheduler.Heartbeat.run/1
  ├── handle_info :cron_check -> run_cron_check/1 -> CronEngine.matches?/2
  │                                                -> JobExecutor.run_cron_job/1
  ├── handle_cast {:fire_trigger} -> run_trigger/3 -> JobExecutor.run_trigger_action/2
  ├── handle_call {:add_job}    -> Persistence.validate_job/1
  │                             -> Persistence.update_crons/2
  ├── handle_call {:add_trigger} -> Persistence.validate_trigger/1
  │                              -> Persistence.update_triggers/2
  └── init/1 -> Persistence.load_crons/1
             -> Persistence.load_triggers/1
             -> Heartbeat.ensure_file/0
```

### Migration sequence for `scheduler.ex`

1. Extract `Scheduler.CronEngine` — pure parsing, zero dependencies on other modules.
2. Extract `Scheduler.Persistence` — pure file I/O, calls only `load_*` helpers.
3. Extract `Scheduler.JobExecutor` — depends on `Loop`, `ShellPolicy`; no GenServer state.
4. Extract `Scheduler.Heartbeat` — depends on `JobExecutor`.
5. Update `Scheduler` to delegate. Run tests after each step; the scheduler has 30s
   timeouts on `run_job` calls that can surface in integration tests.

---

## Cross-Cutting Concerns

### Naming consistency

Follow the pattern: `OptimalSystemAgent.<Domain>.<SubModule>`. Examples:
- `OptimalSystemAgent.Commands.Registry`
- `OptimalSystemAgent.Channels.HTTP.API.FleetRoutes`
- `OptimalSystemAgent.Agent.Orchestrator.Complexity`
- `OptimalSystemAgent.Agent.Scheduler.CronEngine`

### Test impact

Each extracted module becomes independently testable. Current integration tests in
`test/integration/conversation_test.exs` call `Commands.execute/2` and
`Agent.Scheduler` public APIs — these remain stable since the facades are preserved.
New unit tests can be added for:
- `CronEngine.parse/1` and `matches?/2`
- `Orchestrator.Complexity.analyze/1` (mock LLM)
- `Scheduler.Persistence.validate_job/1`
- `API.WebhookVerify.*`

### Recommended split order (cross-file)

Execute in this order to minimise breakage. Each step is independently committable:

| Step | Module | Risk |
|------|--------|------|
| 1 | `Scheduler.CronEngine` | None — pure functions |
| 2 | `API.Shared` + `API.WebhookVerify` | None — pure functions |
| 3 | `Orchestrator.SkillManager` | Low — no GenServer coupling |
| 4 | `Commands.Model` | Low — stateless helpers |
| 5 | `Scheduler.Persistence` | Low — file I/O only |
| 6 | `Orchestrator.Complexity` | Medium — LLM call, mock in tests |
| 7 | `API.AuthRoutes` | Medium — auth flows |
| 8 | `Commands.Info` / `Commands.Session` | Medium — in-module ETS access |
| 9 | `Scheduler.JobExecutor` | Medium — shell execution |
| 10 | `Orchestrator.Decomposer` | Medium — depends on Complexity |
| 11 | `API.ChannelRoutes` + `API.FleetRoutes` | Medium — webhook auth |
| 12 | `Orchestrator.AgentRunner` | High — Task.async ref contract |
| 13 | `API.OrchestrationRoutes` | High — async polling |
| 14 | Remaining API sub-routers | Medium |
| 15 | Remaining Commands sub-modules | Low |
| 16 | `Scheduler.Heartbeat` | Low |
| 17 | Final GenServer cleanup passes | Low |

---

## ADR-001: God-File Decomposition Strategy

```
# ADR-001: God-File Decomposition via Responsibility-First Module Extraction
## Status: Proposed
## Date: 2026-03-03

## Context
Four modules each exceed 1000 lines. Each conflates 5-8 distinct
responsibilities. This creates high review friction, slow test feedback, and
merge conflicts on every feature branch.

## Decision
Split along single-responsibility lines using the module tree defined in
tasks/god-file-refactor-plan.md. Sub-modules are pure Elixir modules (no
GenServer), extracted one at a time with the facade module preserved for
backward compatibility throughout.

## Consequences
### Positive
- Each sub-module is independently testable with unit tests
- Faster compile times per file (Elixir compiles per module)
- Parallel team work without merge conflicts on the god files
- Clear ownership: one module = one domain

### Negative
- More files to navigate (24 new files across all 4 splits)
- Inter-module call overhead is negligible in Elixir but adds indirection
- Documentation must be updated to reflect new module locations

### Neutral
- Public APIs of `Commands`, `API`, `Orchestrator`, `Scheduler` remain stable
- Existing callers (CLI, HTTP, integration tests) do not change

## Alternatives Considered
- Single-file with better section comments: Rejected — does not solve the
  root cause (functions from different concerns competing for context space)
- Full microservice extraction: Rejected — overkill; all modules live in the
  same OTP application

## References
- Elixir guidelines: https://hexdocs.pm/elixir/module-attributes.html
- Plug.Router composition: https://hexdocs.pm/plug/Plug.Router.html#forward/2
```
