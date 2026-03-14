# OSA Orchestration Map

> How OptimalSystemAgent wires 21 subsystems into a single agent lifecycle.

---

## Message Lifecycle (End-to-End)

```
USER MESSAGE
  │
  ▼
┌─────────────────────────────────────────────────────────┐
│  LOOP.process_message(session_id, message, opts)        │
│                                                         │
│  0. Vault.wake(session_id) — dirty-death detection      │
│  1. Noise filter / Signal classifier                    │
│  2. Memory.append(user message)                         │
│  3. Context.build() → [static soul + dynamic blocks     │
│       + vault_block (profiled vault context)]            │
│  4. Strategy.resolve() → reasoning algorithm            │
│  5. run_loop() ─┐                                       │
│                  │                                       │
│    ┌─────────────▼──────────────┐                       │
│    │  LLM CALL (streaming)      │                       │
│    │  Bus.emit(:llm_request)    │                       │
│    │  LLMClient.llm_chat_stream │                       │
│    │  Bus.emit(:llm_response)   │                       │
│    └─────────────┬──────────────┘                       │
│                  │                                       │
│    ┌─────────────▼──────────────┐                       │
│    │  TOOL EXECUTION (parallel) │                       │
│    │  For each tool_call:       │                       │
│    │    pre_hooks (sync)        │                       │
│    │    Registry.execute()      │                       │
│    │    post_hooks (async)      │                       │
│    └─────────────┬──────────────┘                       │
│                  │                                       │
│    Strategy.handle_result()                              │
│    Loop decision: respond | continue | halt              │
│                                                         │
│  6. Scratchpad.process_response()                       │
│  7. Memory.append(assistant response)                   │
│  8. Bus.emit(:agent_response)                           │
│  9. On terminate: Vault.sleep(session_id)               │
│     → flush observations, create handoff, clear dirty   │
└─────────────────────────────────────────────────────────┘
  │
  ▼
RESPONSE TO USER
```

---

## Subsystem Reference

### 1. Loop — `agent/loop.ex`

**Entry:** `Loop.process_message(session_id, message, opts)`

The core message processing pipeline. Every user interaction passes through here.

**Step-by-step (lines 187–426):**

| Step | What | Why |
|------|------|-----|
| Clear cancel flags | Reset stale ETS cancellation markers | Prevent ghost cancels from prior turns |
| Apply overrides | Provider, model, signal_weight from opts | Per-call LLM routing |
| Increment turn | Turn counter for memory nudge timing | "Save insights every N turns" |
| Noise filter | Classify trivial vs substantive input | Skip LLM for greetings/acks |
| Persist user msg | `Memory.append(session_id, %{role: "user", ...})` | Durable conversation log |
| Maybe compact | Summarize old messages if context pressure | Fit within context window |
| Auto-extract insights | Every N turns, prompt for insight save | Proactive memory building |
| Memory nudges | Inject "consider saving patterns" prompt | Encourage memory hygiene |
| Exploration directives | Inject exploration goals if idle | Autonomous learning |
| Genre routing | Route to specialized handler by signal genre | Specs vs code vs prose |
| Plan mode check | If complex task, ask user via survey | Confirm before multi-step execution |
| run_loop | Core LLM ↔ tool loop | The actual work |

**Key decision points:**
- `should_plan?()` → plan mode bypasses tools, temperature=0.3
- Doom loop detection → 3 consecutive tool failures → halt
- Context pressure → emit `:context_pressure` event, compact

---

### 2. Signal — `signal.ex`

**When:** Every event emitted through `Events.Bus.emit()`

Measures Signal-to-Noise ratio across 5 dimensions (M, G, T, F, W) per Signal Theory. Serializes to CloudEvents v1.0.2 format.

| Dimension | What |
|-----------|------|
| **M** (Mode) | How perceived? Linguistic, Visual, Code |
| **G** (Genre) | What form? Spec, Report, PR, ADR, Brief |
| **T** (Type) | What does it do? Direct, Inform, Commit, Decide |
| **F** (Format) | What container? Markdown, code, CLI output, diff |
| **W** (Structure) | Internal skeleton (genre template) |

**Used by:** Events.Classifier for intelligent routing. Signal quality score (0.0–1.0) attached to every event.

---

### 3. Context — `agent/context.ex`

**When:** Before every LLM call (cached between calls with same key).

**Two-tier architecture:**

**Tier 1 — Static Base (persistent_term, ~90% cache hit):**
```
Soul.static_base() = SYSTEM.md interpolated with:
  {{TOOL_DEFINITIONS}}  — available tools for this session
  {{RULES}}             — user rules from ~/.osa/rules/
  {{USER_PROFILE}}      — user preferences from memory
```

**Tier 2 — Dynamic Blocks (per-request, token-budgeted):**

| Block | Source | Priority |
|-------|--------|----------|
| tool_process | Current tool call context | High |
| runtime | Agent uptime, iteration count | Medium |
| environment | cwd, git status, workspace overview | Medium |
| plan_mode | Active plan if in plan mode | High |
| memory_relevant | `Memory.recall_relevant(message, budget)` | High |
| episodic | Recent learnings from ETS index | Medium |
| task_state | Current task tracker status | Medium |
| workflow | Workspace workflow state | Low |
| skills | Available custom skills | Low |
| scratchpad | Think instructions (non-Anthropic only) | Low |
| knowledge | Knowledge graph context | Low |
| vault | Vault profiled context (facts, decisions, prefs) | Low |

Each block fitted to: `dynamic_budget = max_tokens - static_tokens - conversation - reserve`

**Cache key:** `{plan_mode, session_id, memory_version, channel}` — invalidates on memory save.

---

### 4. Memory — `agent/memory/`

**Three-store architecture:**

| Store | Location | Purpose | Durability |
|-------|----------|---------|------------|
| **Session** | `~/.osa/sessions/{id}.jsonl` | Append-only conversation log | Persistent |
| **Long-term** | `~/.osa/MEMORY.md` | Structured knowledge (decisions, patterns, preferences) | Persistent |
| **Episodic Index** | ETS `:osa_memory_index` | Inverted keyword index for fast recall | In-memory (rebuilt on start) |

**When called:**

| Operation | Trigger | Location |
|-----------|---------|----------|
| `append(session_id, entry)` | Every user/assistant message | Loop:241, Loop:412 |
| `recall_relevant(message, max_tokens)` | During Context.build | Context:195 |
| `remember(category, content, metadata)` | By `memory_save` tool | builtins/memory_save.ex |

**Smart retrieval (`recall_relevant`):**
1. Extract keywords from current message
2. Lookup in ETS inverted index
3. Score by: keyword overlap + recency + importance
4. Return top entries within token budget

---

### 5. Strategy — `agent/strategy.ex` + `agent/strategies/`

**When:** Resolved at loop init, consulted every iteration.

| Strategy | When Selected | Behavior |
|----------|---------------|----------|
| **ReAct** (default) | General tasks | Reason + Act alternation |
| **Chain of Thought** | Explicit reasoning tasks | Step-by-step thinking |
| **Tree of Thoughts** | Complex exploration | Branching paths with evaluation |
| **Reflection** | Self-improvement tasks | Critique + revision loop |
| **MCTS** | Optimization problems | Monte Carlo tree search |

**Contract (3 callbacks per iteration):**
```elixir
next_step(state, context)       → {:think | :act | :observe | :respond | :done}
handle_result(phase, results)   → new_state | {:switch_strategy, name}
init_state(context)             → initial_state
```

Strategies can trigger mid-loop switches (e.g., ReAct → Reflection when self-correction needed).

---

### 6. LLM Client — `agent/loop/llm_client.ex`

**When:** Every iteration in `run_loop`.

| Path | When | Config |
|------|------|--------|
| **Plan mode** | `should_plan?()` returns true | Single call, no tools, temperature=0.3 |
| **Normal mode** | Default path | Streaming, full tool list |
| **Extended thinking** | Anthropic + thinking enabled | Native thinking blocks |
| **Scratchpad mode** | Non-Anthropic providers | `<think>` injection |

**Events emitted:**
- `:llm_request` — before call (session_id, iteration)
- `:llm_response` — after call (duration_ms, token usage)

---

### 7. Tools — `tools/`

**Three tool types:**
- **Built-in** — Elixir modules in `tools/builtins/`
- **Skills** — `.md` files from `~/.osa/skills/`
- **MCP tools** — Auto-discovered from `~/.osa/mcp.json`

**Execution pipeline (`ToolExecutor.execute_tool_call`):**

```
1. Permission tier check (:full | :workspace | :read_only)
2. Bus.emit(:tool_call, phase: :start)
3. Pre-tool hooks (sync, blocking):
   ├─ spend_guard    (p8)  → MiosaBudget.check_budget()
   ├─ security_check (p10) → ShellPolicy.validate()
   ├─ read_before_write (p12) → warn on unread file edits
   └─ mcp_cache      (p15) → inject cached schemas
4. Tools.Registry.execute(name, arguments)
5. Post-tool hooks (async, fire-and-forget):
   ├─ track_files_read (p5)  → ETS marker
   ├─ cost_tracker     (p25) → budget spend emission
   ├─ vault_checkpoint (p80) → auto-checkpoint vault every 10 tool calls
   └─ telemetry        (p90) → timing metrics
6. Bus.emit(:tool_result)
7. Return {tool_msg, result_str}
```

Tool calls execute in parallel via `Task.async_stream` (max_concurrency: 10).

---

### 8. Budget — `miosa_budget` + `budget_emitter.ex`

**When checked:** Pre-tool hook (`spend_guard`, priority 8).

```
MiosaBudget.Budget.check_budget()
  → {:ok, remaining}       → allow tool execution
  → {:over_limit, period}  → block tool, return "Budget exceeded"
```

**When recorded:** Post-tool hook (`cost_tracker`, priority 25).

```
Emit {:budget_spent, %{tokens_in, tokens_out, cost_usd, provider, model}}
  → Routed through BudgetEmitter → Events.Bus
```

The budget system is purely hook-driven — the Loop never calls it directly.

---

### 9. Events / Bus — `events/bus.ex`

**The nervous system.** Fire-and-forget event dispatch via goldrush-compiled router.

```elixir
Bus.emit(event_type, payload, opts)
  → Event.new() with Signal classification
  → Goldrush route via :osa_event_router
  → Append to per-session Stream
  → Dispatch to registered handlers
```

**40+ event types emitted across the lifecycle:**

| Phase | Events |
|-------|--------|
| Message entry | `user_message` |
| LLM calls | `llm_request`, `llm_response` |
| Tool execution | `tool_call` (start/end), `tool_result` |
| Agent response | `agent_response`, `agent_cancelled` |
| Orchestration | `orchestrator_task_started`, `_decomposed`, `_wave_started`, `_agent_progress`, `_completed` |
| System | `context_pressure`, `doom_loop_detected`, `memory_saved`, `hook_blocked` |
| Swarm | `swarm_started`, `swarm_completed`, `swarm_failed` |
| Auto-fixer | `auto_fixer_started`, `_iteration`, `_completed`, `_failed` |
| DLQ | `algedonic_alert` (max retries exhausted) |

**Design:** Async Task.Supervisor dispatch. Never blocks the agent loop. Goldrush compiles routing rules to BEAM instructions for ~ns dispatch.

---

### 10. Events / Stream — `events/stream.ex`

**When:** After every `Bus.emit()`.

Durable append-only log per session: `~/.osa/streams/{session_id}.jsonl`

Separate from Memory (conversations) — Stream captures all system events for replay, debugging, observability. TUI subscribes to stream for live progress display.

---

### 11. Events / DLQ — `events/dlq.ex`

**When:** Event handler crashes or times out.

```
enqueue(event, handler_mfa, error)
  → ETS :osa_dlq table
  → Retry every 60s with exponential backoff (1s → 2s → 4s... max 30s)
  → After 3 retries → emit algedonic_alert, drop event
```

Stores MFA tuples `{mod, fun, args}` (not closures) so retries survive process restarts.

---

### 12. Scratchpad — `agent/scratchpad.ex`

**When:** LLM response processing, non-Anthropic providers only.

| Provider | Mechanism |
|----------|-----------|
| Anthropic | Native `extended_thinking` (no scratchpad needed) |
| Others | Inject `<think>` instruction → extract `<think>` blocks from response |

Extracted thinking blocks emit `:thinking_delta` (for TUI display) and `:thinking_captured` (for learning engine).

---

### 13. Orchestrator — `agent/orchestrator.ex`

**When:** User explicitly invokes the `orchestrate` tool for complex multi-step tasks.

**Flow:**
```
1. Generate task_id, reply {:ok, task_id} immediately (async)
2. Complexity scoring → if >= 7, ask clarifying questions
3. Decompose task → LLM generates sub-tasks
4. Build dependency DAG → group into execution waves
5. Per wave:
   ├─ Spawn agents in parallel (AgentRunner)
   ├─ Monitor task refs
   └─ Collect results, proceed to next wave
6. Synthesize all agent results → final answer
7. State machine: idle → planning → executing → verifying → completed
```

**State machine transitions:**
```
idle → start_planning → planning
planning → approve_plan → executing
executing → waves_complete → verifying
verifying → verification_passed → completed
[any] → error → error_recovery
```

**Events emitted (10+ throughout):**
`orchestrator_task_started`, `_decomposed`, `_agents_spawning`, `_wave_started`, `_agent_progress`, `_task_completed`

---

### 14. Swarm — `swarm/`

**When:** Explicitly via `swarm` tool. Different from Orchestrator.

| Aspect | Orchestrator | Swarm |
|--------|-------------|-------|
| Pattern | Sequential waves | Parallel/pipeline/debate/review |
| Communication | Shared context | Mailbox message passing |
| Scale | Unbounded sub-tasks | Max 10 concurrent, 5 agents/swarm |
| Use case | Complex decomposition | Multi-perspective analysis |

**Patterns:**
- **Parallel** — all agents work independently, results merged
- **Pipeline** — agent A output feeds agent B input
- **Debate** — agents argue, judge synthesizes
- **Review** — agent produces, reviewers critique, iterate

---

### 15. Platform — `platform/`

**When:** Session initialization and permission enforcement.

```
Tenant
  └─ owns OS_Instances
       └─ has Grants (cross-OS permissions)
       └─ has Members (user access)
```

**Integration points:**
- **Auth** (`platform/auth.ex`) — JWT token verification, Bcrypt password hashing
- **Permission tier** — OS Instance grants determine tool access level (:full | :workspace | :read_only)
- **AMQP bridge** — Optional event forwarding to external message broker

Platform is a passive policy layer — it doesn't emit events, it enforces access.

---

### 16. Hooks — `agent/hooks.ex`

**The middleware system.** Priority-ordered, event-driven.

| Phase | Execution | Purpose |
|-------|-----------|---------|
| **Pre-tool** (sync) | Blocks until complete | Security, budget, validation |
| **Post-tool** (async) | Fire-and-forget | Telemetry, cost tracking, learning |

**ETS-backed (no GenServer bottleneck):**
```
:osa_hooks           — {event, name, priority, handler}
:osa_hook_metrics    — atomic counters for calls/blocks/timing
```

**Registration:** GenServer cast. **Reads:** Direct ETS lookup.

---

### 17. Directives — `agent/directive.ex`

**When:** Agents can return structured directives instead of raw text.

| Directive | Effect |
|-----------|--------|
| `:emit` | Publish event to Bus |
| `:spawn` | Launch sub-agent |
| `:schedule` | Delayed execution |
| `:stop` | Halt loop |
| `:delegate` | Route to another agent |
| `:batch` | Execute multiple actions |

Backward compatible — Loop interprets directives if present, treats raw strings normally.

---

### 18. Auto-Fixer — `agent/auto_fixer.ex`

**When:** Explicitly invoked via `auto_fixer` tool.

```
1. Run command (test/lint/compile)
2. If fails → extract first 10 errors
3. Send errors to agent for fixing
4. Agent edits files
5. Re-run command
6. Repeat until pass or max iterations (default 5)
```

**Events:** `auto_fixer_started`, `_iteration`, `_completed`, `_failed`

---

### 19. Knowledge — `miosa_knowledge`

**When:** Agent explicitly calls the `knowledge` tool.

Pure Elixir semantic knowledge graph. Three backends (ETS dev/test, Mnesia production/distributed, Riak optional). Native SPARQL engine and OWL 2 RL reasoner for facts, entities, and relationships.

Not injected into context by default — invoked on-demand when user asks about stored knowledge.

---

### 20. Vault — `vault/`

**When:** Automatically on session init/terminate + via 6 vault tools.

**Structured memory system with session lifecycle:**

```
Session Start (Loop.init)
  │
  ▼
Vault.wake(session_id)
  ├─ Check ~/.osa/vault/.vault/dirty/ for stale flags (dirty deaths)
  ├─ Recover any crashed sessions (load last handoff)
  └─ Touch dirty flag for this session
  │
  ▼
[Agent runs — tool calls happen]
  │
  ├─ vault_auto_checkpoint hook (post_tool_use, p80)
  │   └─ Every 10 tool calls: flush observer + refresh dirty flag
  │
  ├─ vault_remember tool → write markdown + extract facts + buffer observation
  │
  ├─ Context.build() includes vault_block()
  │   └─ ContextProfile.build(:default) → facts + vault files → prompt injection
  │
  ▼
Session End (Loop.terminate)
  │
  ▼
Vault.sleep(session_id)
  ├─ Flush observation buffer
  ├─ Create handoff document (summary, facts, next steps)
  └─ Clear dirty flag
```

**Data stores:**

| Store | Location | Access Pattern |
|-------|----------|---------------|
| Category files | `~/.osa/vault/{category}/*.md` | Filesystem read/write |
| Fact store | `:osa_vault_facts` ETS + `facts.jsonl` | ETS reads (concurrent), GenServer writes, JSONL persistence |
| Dirty flags | `~/.osa/vault/.vault/dirty/{session_id}` | Filesystem touch/rm |
| Handoffs | `~/.osa/vault/handoffs/` | Filesystem read/write |

---

### 21. Browser / ComputerUse / CodeSandbox — `tools/builtins/`

**Specialty tools invoked by LLM when task requires them:**

| Tool | When | How |
|------|------|-----|
| **Browser** | Web research, page scraping | Playwright via Node.js port, DynamicSupervisor managed |
| **ComputerUse** | GUI automation, screenshots | Screenshot capture + coordinate-based interaction |
| **CodeSandbox** | Safe code execution | Docker container per language, isolated filesystem |

---

## Design Invariants

1. **No GenServer in hot path** — Tools, Hooks, Events all read from ETS/persistent_term (lock-free)
2. **Per-session isolation** — Each session is its own Loop process, own memory stream, own ETS keys
3. **Token budgeting everywhere** — Context blocks, memory recall, LLM calls all respect token limits
4. **Event-driven observability** — 40+ event types, every phase instrumented, TUI subscribes for live updates
5. **Priority-based hooks** — Lower number = runs first. Pre-tool sync (security critical), post-tool async (telemetry)
6. **Fire-and-forget events** — Bus.emit never blocks the agent loop
7. **Crash recovery** — Checkpoint.checkpoint_state() after tool execution, Checkpoint.restore_checkpoint() on restart

---

## Integration Matrix

| Subsystem | Called By | Calls Into | Events |
|-----------|----------|-----------|--------|
| **Loop** | HTTP/CLI channels | Memory, Context, Strategy, LLM, Tools | llm_*, agent_*, tool_* |
| **Context** | Loop | Memory, Soul, Skills | (none — read-only) |
| **Memory** | Loop, Tools | ETS, Filesystem | memory_saved |
| **Tools** | Loop (parallel) | Hooks, Registry, Bus | tool_call, tool_result |
| **Hooks** | ToolExecutor | Budget, Security, ETS | hook_blocked |
| **Budget** | Hooks (spend_guard) | Events.Bus | budget_spent |
| **Events.Bus** | Everything | Stream, Goldrush, Signal | (routes all events) |
| **Orchestrator** | orchestrate tool | Loop (sub-agents), LLM | orchestrator_* |
| **Swarm** | swarm tool | Loop (workers), Mailbox | swarm_* |
| **Platform** | Auth middleware | Repo (DB) | (passive policy) |
| **Signal** | Events.Bus | Classifier | (attached to events) |
| **DLQ** | Event router errors | ETS, retry timer | algedonic_alert |
| **Auto-Fixer** | auto_fixer tool | Loop, Shell | auto_fixer_* |
| **Knowledge** | knowledge tool | Triple store backend | (none) |
| **Strategies** | Loop | (injects guidance) | (none) |
| **Directives** | Agent responses | Loop interpreter | (varies by type) |
| **Vault** | Loop (init/terminate), Hooks (checkpoint), Context (vault_block), Tools (6 vault_*) | Filesystem, ETS, Observer | (none — passive store) |
