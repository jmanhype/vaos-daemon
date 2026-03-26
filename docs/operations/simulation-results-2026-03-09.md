# Simulation Results — 2026-03-09

## Overview

End-to-end live simulation testing of the Daemon agent framework covering:
- Multi-turn conversation memory (6-turn progressive build)
- Multi-agent swarm orchestration (all 4 patterns)
- Edge case handling and error recovery
- LLM connection reliability

Model: `kimi-k2.5:cloud` via Ollama
Server: `mix daemon.serve` on port 5050

---

## Test 1: Swarm Orchestration — All 4 Patterns

### Parallel (7 agents)
- **Task**: Design a complete microservices architecture for an e-commerce platform (10 services)
- **Agents**: architect, backend, services x2, data, infra x2
- **Duration**: ~200s (workers done by 120s, synthesis 80s)
- **Result**: 15,684 chars — comprehensive architecture with service topology table, communication patterns, data stores
- **Verdict**: PASS

### Pipeline (3 agents, sequential)
- **Task**: MySQL-to-PostgreSQL migration plan (analyze → scripts → rollback)
- **Agents**: data → backend → qa
- **Duration**: ~180s
- **Result**: 14,394 chars — each agent built on the previous output
- **Verdict**: PASS

### Debate (4 agents)
- **Task**: Best database for real-time collaborative editor (PostgreSQL vs MongoDB vs CockroachDB)
- **Agents**: researcher (PostgreSQL), data (MongoDB), infra (CockroachDB), critic (evaluator)
- **Duration**: ~60s
- **Result**: 6,565 chars — critic evaluated all 3 proposals, selected PostgreSQL with justification
- **Verdict**: PASS (previously FAILED due to double-zip bug + max_children exhaustion)

### Review Loop (2 agents, iterative)
- **Task**: Go rate limiter with token bucket algorithm
- **Agents**: coder, reviewer (3 iterations max)
- **Duration**: ~120s
- **Result**: 6,561 chars — coder produced code, reviewer critiqued, iterated
- **Verdict**: PASS

### Concurrent Execution
All 4 swarms ran simultaneously (16 total workers under AgentPool DynamicSupervisor).
After completion, all workers were properly terminated and new swarms could launch.

---

## Test 2: 6-Turn Multi-Turn Conversation (Deep Integration)

**Task**: Clone AFFiNE (open-source Notion), explore its architecture, build a standalone mini Notion clone from scratch, then add features progressively.

| Turn | Task | Duration | Iterations | Result |
|------|------|----------|------------|--------|
| 1 | Clone AFFiNE repo (`git clone --depth 1`) | 30s | 2 | Repo cloned, README + package.json read |
| 2 | Deep architecture exploration | ~120s | 13 | 4,555 char architecture map (React Router, Jotai, Yjs CRDT, Vanilla Extract) |
| 3 | Build notion-mini from scratch | ~180s | 4 | 10 files: Next.js 14 + SQLite + Tailwind, API routes, db layer, npm install + build |
| 4 | Add polished UI components | ~300s | 3 | PageEditor, Sidebar, globals.css, contentEditable editor with slash commands |
| 5 | Quick Capture feature | ~180s | 3 | FAB button, Modal, QuickCapture, Ctrl+Shift+N keyboard shortcut |
| 6 | Summary + verify | ~120s | 2 | 5,563 char summary, dir_list verification, memory_save |

### Files Created (19 total, ~2,100 lines)

```
notion-mini/
├── package.json              # Next.js 14, React, Tailwind, better-sqlite3
├── tailwind.config.js        # Custom indigo/purple theme
├── next.config.js            # Static export config
├── postcss.config.js
├── tsconfig.json
├── scripts/init-db.js        # DB initialization with sample data
├── src/
│   ├── lib/db.ts             # SQLite CRUD layer (120 lines)
│   ├── app/
│   │   ├── layout.tsx        # Root layout with Sidebar + QuickCapture
│   │   ├── page.tsx          # Homepage with page list (228 lines)
│   │   ├── globals.css       # Tailwind + Notion theme CSS (280 lines)
│   │   ├── page/[id]/page.tsx    # Rich editor with contentEditable (169 lines)
│   │   ├── pages/[id]/page.tsx   # Original editor with textarea (225 lines)
│   │   └── api/pages/
│   │       ├── route.ts      # GET all, POST new
│   │       └── [id]/route.ts # GET, PUT, DELETE single page (110 lines)
│   └── components/
│       ├── Sidebar.tsx       # Collapsible sidebar with search (301 lines)
│       ├── PageEditor.tsx    # Rich-text editor component (170 lines)
│       ├── QuickCapture.tsx  # FAB + capture modal (202 lines)
│       └── Modal.tsx         # Reusable modal with focus trap (92 lines)
└── README.md
```

### Memory Verification
Each turn correctly built on the previous one:
- Turn 4 updated files created in Turn 3
- Turn 5 referenced the component structure from Turn 4
- Turn 6 produced accurate summary of all 6 turns
- Tool results (file_write, dir_list) were properly tracked in conversation history

---

## Test 3: Edge Cases

| Test | Input | Expected | Actual | Status |
|------|-------|----------|--------|--------|
| Empty task | `{"task": ""}` | Error | `"Task description cannot be empty"` | PASS |
| Invalid pattern | `{"pattern": "nonexistent"}` | Error | `"Unknown swarm pattern"` | PASS |
| Cancel running swarm | DELETE `/swarm/:id` | Cancelled | Workers terminated, status=cancelled | PASS |
| List all swarms | GET `/swarm` | Swarm list | All swarms with correct statuses | PASS |
| Worker cleanup | Launch → complete → launch again | No max_children error | New swarm launches fine | PASS |

---

## Bugs Found and Fixed

### 1. Worker leak on completion (`swarm_mode.ex`)
- **Symptom**: After 2-3 swarms, new swarms fail with `:max_children`
- **Root cause**: `terminate_workers()` only called on cancel/timeout, not on normal completion or failure
- **Fix**: Added `terminate_workers(swarm.workers)` in `synthesis_complete` and `swarm_failed` handlers

### 2. Debate pattern crash (`patterns.ex`)
- **Symptom**: Debate swarm hangs then times out, logs show `ArgumentError` in `Patterns.debate/3`
- **Root cause**: Double-zip — `workers` already contains `{spec, pid}` tuples, but code zipped with `agent_specs` again creating triple-nested tuples
- **Fix**: Removed redundant `Enum.zip(workers, agent_specs)` from all 4 patterns (parallel, pipeline, debate, review_loop)

### 3. DynamicSupervisor max_children too low (`extensions.ex`)
- **Symptom**: Concurrent swarms (16+ workers) exceed `max_children: 10`
- **Fix**: Raised to `max_children: 50`

### 4. Config parser crash (`onboarding.ex`)
- **Symptom**: Server fails to start with `Access.get/3` error
- **Root cause**: `get_in(config, ["provider", "default"])` assumes nested map, but config has flat `"provider": "ollama"`
- **Fix**: Handle both flat and nested config shapes with pattern matching

### 5. LLM stream silent hang (`llm_client.ex`)
- **Symptom**: Agent loop blocks indefinitely — no tokens, no error, no timeout
- **Root cause**: Cloud model drops streaming connection without closing it; no idle detection
- **Fix**: Idle-timeout watchdog using atomics heartbeat counter
  - Every streaming event increments an atomic counter (lock-free)
  - Watchdog polls every 10s; kills stream if no activity for 120s
  - Active streams run indefinitely (no total-duration cap)
  - 1-hour absolute safety net

---

## Architecture Validated

| Component | Status | Notes |
|-----------|--------|-------|
| ReAct agent loop | Working | Up to 13 iterations on exploration tasks |
| Tool execution (parallel) | Working | Task.async_stream, max 10 concurrent |
| Conversation memory (JSONL) | Working | Full history preserved across turns |
| Context.build (2-tier) | Working | Static cache + dynamic context + conversation |
| Checkpoint/recovery | Logging works | File writes need path expansion fix (non-blocking) |
| SwarmPlanner (decompose) | Working | Produces role-specific agents with correct task assignments |
| SwarmWorker (execution) | Working | Each worker gets independent LLM session |
| Mailbox (ETS) | Working | Composite keys, proper cleanup on completion |
| Patterns (4 types) | All working | Parallel, pipeline, debate, review_loop |
| Synthesis (LLM-powered) | Working | Merges multi-agent results into cohesive output |
| Guardrails | Working | Nudges for intent narration, code-in-text, verify gate |
| Idle timeout | Working | Atomics heartbeat + watchdog, kills only dead connections |
