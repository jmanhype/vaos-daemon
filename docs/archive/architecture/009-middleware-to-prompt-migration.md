# ADR-009: Middleware-to-Prompt Migration

**Status:** Proposed
**Date:** 2026-03-02
**Author:** OSA Team
**Reviewers:** Roberto, Pedro, Team

---

## TL;DR

We built Elixir middleware (GenServers, ETS caches, hook pipelines) that reimplements what our own Claude Code setup (CLAUDE.md) already does as prompt instructions. The model doesn't need middleware telling it how to classify signals or filter noise — it needs a well-loaded prompt and working tools. This ADR proposes removing ~1,180 lines of middleware, moving intelligence to the system prompt, and simplifying the message flow from 12 steps to 7.

**Target models:** Claude Opus, Sonnet, Kimi K2.5, GLM-4, Qwen 72B+, and other frontier-class models (cloud and local via Ollama). All capable of following structured prompt instructions and making tool calls.

---

## Table of Contents

1. [How It Actually Works (The Four Layers)](#how-it-actually-works-the-four-layers)
2. [The Proof: Our CLAUDE.md Setup](#the-proof-our-claudemd-setup)
3. [How Claude Code Loads and Executes Everything](#how-claude-code-loads-and-executes-everything)
4. [Current Flow (12 steps)](#current-flow-12-steps-300ms-pre-llm-overhead)
5. [Proposed Flow (7 steps)](#proposed-flow-7-steps-5ms-pre-llm-overhead)
6. [Detailed Module Analysis](#detailed-module-analysis-keep-move-or-kill)
7. [Competitor Comparison](#competitor-comparison)
8. [Migration Plan](#migration-plan)
9. [Risks and Mitigations](#risks-and-mitigations)

---

## How It Actually Works (The Four Layers)

The model doesn't magically "know" Signal Theory or "use" agents. There are four layers, each with a specific job:

```
LAYER 1: LOADER (code — reads files, assembles prompt)
  │  "Here's what exists"
  │
LAYER 2: PROMPT (text — injected by loader, model reads it)
  │  "Here's what you CAN do"
  │
LAYER 3: MODEL (LLM intelligence — decides what to use)
  │  "Here's what I WILL do"  →  emits tool_use calls
  │
LAYER 4: TOOLS (code — executes what the model requested)
     "Here's HOW it gets done"
```

### The Mechanism: tool_use

The model "uses" things by emitting structured `tool_use` blocks. This is an API feature — the model can output tool calls instead of text. The runtime catches these and executes actual code.

**Example: "debug this error in loop.ex"**

```
1. LOADER already ran at boot:
   ├─ Read CLAUDE.md → "KEYWORD→AGENT: bug→@debugger"
   ├─ Read agents/debugger.md → registered as Task subagent_type
   └─ All injected into system prompt

2. API REQUEST sent to Anthropic:
   {
     "system": "...CLAUDE.md contents... Available agents: debugger, backend-go...",
     "tools": [
       {"name": "Task", "input_schema": {"subagent_type": "string", "prompt": "string"}},
       {"name": "Read", "input_schema": {"file_path": "string"}},
       {"name": "Bash", "input_schema": {"command": "string"}}
     ],
     "messages": [{"role": "user", "content": "debug this error in loop.ex"}]
   }

3. API RESPONSE (model outputs a tool call, not text):
   {
     "content": [{
       "type": "tool_use",
       "name": "Task",
       "input": {"subagent_type": "debugger", "prompt": "Debug error in loop.ex"}
     }]
   }

4. RUNTIME catches tool_use:
   ├─ Reads ~/.claude/agents/specialists/debugger.md
   ├─ Creates NEW API conversation with debugger.md as system prompt
   ├─ Subprocess runs (can itself call Read, Bash, etc.)
   └─ Returns result

5. RESULT sent back to model:
   {"role": "user", "content": [{"type": "tool_result", "content": "Bug found at line 494..."}]}

6. Model reads result → writes final answer
```

**The model does three things: read prompt, decide, call tools. Everything else is CODE.**

### What's Code vs What's Prompt vs What's Model

| What | Who Does It | How |
|---|---|---|
| Discover files on disk | **CODE** (loader) | Glob `~/.osa/agents/*.md`, read, parse |
| Inject into system prompt | **CODE** (loader) | Concatenate static + dynamic + history |
| Know what agents/tools exist | **PROMPT** (text) | "Available: debugger, backend-go, file_read..." |
| Know Signal Theory rules | **PROMPT** (text) | "Maximize S/N, 6 encoding principles..." |
| Decide which agent to use | **MODEL** (intelligence) | "User said 'bug' → debugger" |
| Decide response length/style | **MODEL** (intelligence) | Follows Signal Theory rules from prompt |
| Actually spawn the agent | **CODE** (tool) | Task tool forks process, loads agent .md |
| Actually read/write files | **CODE** (tool) | Read/Write tool implementations |
| Block dangerous commands | **CODE** (hook) | security_check rejects `rm -rf /` |
| Track costs | **CODE** (hook) | telemetry logs token usage |
| Persist memory | **CODE** (tool + loader) | Write to MEMORY.md, loader injects next session |

### What This Means for OSA

OSA has code in the **wrong layers**:

```
WRONG (current):
  noise_filter.ex     ← CODE doing what the PROMPT should say
  classifier.ex LLM   ← CODE doing what the MODEL already does
  signal overlay       ← CODE assembling what should be STATIC PROMPT TEXT
  suggestion hooks     ← CODE generating hints the PROMPT should contain

RIGHT (proposed):
  SYSTEM.md            ← PROMPT: Signal Theory rules, noise handling, response calibration
  loader (context.ex)  ← CODE: reads SYSTEM.md, injects into prompt
  tools/*.ex           ← CODE: executes model decisions (already built)
  security hooks       ← CODE: blocks dangerous actions (keep)
```

---

## The Proof: Our CLAUDE.md Setup

Our Claude Code setup (`~/.claude/CLAUDE.md`, OSA Agent v3.3) contains all these capabilities as prompt instructions. Opus/Sonnet follows them with zero middleware:

| Capability | In CLAUDE.md (prompt) | In OSA (Elixir code) | Redundant? |
|---|---|---|---|
| Signal Theory (5-tuple) | Full framework: 6 principles, 11 failure modes, 4 constraints | `Signal.Classifier` — 540-line GenServer + ETS + LLM call | **YES** |
| Noise elimination | "Does every sentence carry intent? CUT." checklist | `Signal.NoiseFilter` — 180-line 2-tier filter + LLM fallback | **YES** |
| Agent dispatch | 22+ agents with tiers, triggers, territory | `Agent.Roster` + `Agent.Tier` — 850+ lines | Partial (roster metadata useful for orchestration) |
| Hook pipeline | 13 events, 10 active, described as behavior | `Agent.Hooks` — 858 lines, 16 hooks, priority chains | **Most hooks YES** |
| Learning engine | SICA: OBSERVE/REFLECT/PROPOSE/TEST/INTEGRATE | `Agent.Learning` — 586 lines + ETS + disk I/O | **YES** (patterns likely never read back) |
| Tier routing | opus=elite, sonnet=specialist, haiku=utility | `Agent.Tier` — 429 lines | Partial (useful for multi-agent cost control) |
| Batch processing | 5+5 agent batching, complexity detection | `Swarm.Orchestrator` — wave execution | **NO** (code needed for process management) |
| Context mgmt | "Warn@850K, auto-compact@900K" | `Agent.Context` — 770 lines, 4-tier budgeting | Partial (token math = code, assembly = prompt) |

**6 of 8 capabilities are fully or mostly redundant with prompt instructions.**

---

## How Claude Code Loads and Executes Everything

Claude Code has a file discovery system that reads from known directories at boot:

```
BOOT SEQUENCE:
│
├─ 1. CLAUDE.md DISCOVERY
│     ├─ ~/.claude/CLAUDE.md (global instructions)
│     ├─ <project>/.claude/CLAUDE.md (project-specific)
│     └─ ALL injected into system prompt
│
├─ 2. RULES DISCOVERY
│     ├─ ~/.claude/rules/**/*.md
│     ├─ Each has glob matcher — only injected when relevant files are active
│     └─ e.g., frontend/components.md only loads for .tsx/.svelte files
│
├─ 3. AGENT DISCOVERY
│     ├─ ~/.claude/agents/**/*.md (38 agent definitions)
│     ├─ YAML frontmatter: name, description, model, tier, tools, skills
│     ├─ Registered as Task tool subagent_types
│     └─ Listed in system prompt: "Available agent types..."
│
├─ 4. SKILL DISCOVERY
│     ├─ ~/.claude/skills/**/*.md
│     ├─ Registered as invocable via Skill tool
│     └─ Listed in system-reminder: "Available skills..."
│
├─ 5. HOOKS from settings.json
│     ├─ PreToolUse: security-check.sh, context-optimizer.py, mcp-cache.py
│     ├─ PostToolUse: auto-format.sh, learning-capture.py, episodic-memory.py
│     ├─ UserPromptSubmit: validate-prompt.py
│     ├─ Stop: log-session.sh, pattern-consolidation.py
│     └─ Run as SHELL SUBPROCESSES (not in-process code)
│
├─ 6. MCP SERVERS from mcp.json
│     └─ Each exposes tools registered in system prompt
│
├─ 7. MEMORY
│     ├─ ~/.claude/projects/<project>/memory/MEMORY.md
│     └─ ALWAYS loaded into conversation context
│
└─ 8. SETTINGS from settings.json
      └─ model, permissions, preferences, routing, cost config
```

**Key insight:** The loader is ~200 lines of "read files, assemble prompt." The intelligence is in the FILES. The code is plumbing that gets files into the prompt so the model can read them and act via tool_use.

### What OSA's Loader Should Look Like

```
FILES ON DISK                    LOADER (code)                 SYSTEM PROMPT
─────────────                    ─────────────                 ─────────────
~/.osa/SYSTEM.md          ──→   read + cache           ──→   system message[0]
~/.osa/rules/**/*.md      ──→   glob + context filter  ──→   appended to system
~/.osa/agents/**/*.md     ──→   read YAML frontmatter  ──→   registered as tools
~/.osa/skills/**/*.md     ──→   read + register        ──→   listed as available
~/.osa/hooks/             ──→   settings config        ──→   shell subprocess hooks
~/.osa/memory/MEMORY.md   ──→   always loaded          ──→   injected into context
config.json               ──→   provider, model, prefs ──→   runtime config
```

---

## Current Flow (12 steps, ~300ms pre-LLM overhead)

```
USER MESSAGE
  │
  ├─ 1.  [BLOCK <1ms]     classify_fast()           deterministic regex
  ├─ 2.  [ASYNC]          classify_async()           EXTRA LLM call (background)
  ├─ 3.  [BLOCK 0-200ms]  NoiseFilter.filter()       can trigger ANOTHER LLM call
  │                         └─ if "noise" → "Noted." early exit
  ├─ 4.  [BLOCK <50ms]    Memory.append(user msg)
  ├─ 5.  [BLOCK 0-500ms]  Compactor.maybe_compact()
  ├─ 6.  [BLOCK <1ms]     should_plan?()
  ├─ 7.  [BLOCK ~20ms]    Context.build()
  │                         ├─ Static base (cached) ~30K tokens
  │                         ├─ Signal overlay (code-assembled per request)
  │                         ├─ P2: memory, tasks, workflow
  │                         ├─ P3: comm profile, cortex
  │                         └─ P4: OS templates, machines
  ├─ 8.  [BLOCK <100ms]   pre_tool hooks (5 hooks)
  │                         security, budget, optimizer, mcp, tracker
  ├─ 9.  [LLM 1-30s]      llm_chat_stream()          ← THE ACTUAL WORK
  │                         ├─ each token → Bus.emit(:streaming_token) → SSE
  │                         └─ blocks until {:done, result}
  ├─ 10. [BLOCK varies]   Tool execution (parallel, up to 10 concurrent)
  │                         ├─ pre: 5 hooks per tool
  │                         ├─ Tools.execute() via Task.async_stream
  │                         └─ post: 9 hooks fire-and-forget
  ├─ 11. [BLOCK <50ms]    Memory.append(response)
  ├─ 12. [ASYNC+BLOCK]    Bus.emit(:agent_response) + HTTP 200
  │                         ├─ SSE gets agent_response event
  │                         └─ HTTP response also returns full body (DUAL DELIVERY)
  │
  └─ RESPONSE
```

### Problems with Current Flow

| Problem | Impact | Root Cause |
|---|---|---|
| Steps 2-3: 400ms of classification/filtering | Delayed first token | Middleware doing model's job |
| Step 3: Noise filter rejects valid messages | "ok"/"thanks" get "Noted." instead of real response | Every prompt IS a signal — user sent it intentionally |
| Step 7: Signal overlay assembled in code per request | Unnecessary computation | Should be static prompt text |
| Step 8: 3 of 5 pre-tool hooks add no security value | Extra blocking latency | Suggestion hooks don't need to block |
| Step 10: 9 post-tool hooks fire per tool call | Resource waste | Most outputs never read |
| Step 12: Dual HTTP+SSE delivery | Race conditions → BUG-017, BUG-018, BUG-019 | Two paths delivering same data |

---

## Proposed Flow (7 steps, ~5ms pre-LLM overhead)

```
USER MESSAGE
  │
  ├─ 1. [BLOCK <1ms]     classify_fast()            deterministic (metadata only)
  ├─ 2. [BLOCK <50ms]    Memory.append(user msg)
  ├─ 3. [BLOCK 0-500ms]  Compactor.maybe_compact()   (only if context full)
  ├─ 4. [BLOCK ~5ms]     Context.build()
  │                        ├─ Static base (cached, includes Signal Theory rules)
  │                        ├─ Dynamic: env + memory + tasks (flat, no priority tiers)
  │                        └─ Conversation history
  ├─ 5. [LLM 1-30s]      llm_chat_stream()           ← THE ACTUAL WORK
  │                        ├─ Model follows Signal Theory rules from prompt
  │                        ├─ Model classifies intent internally (no extra LLM call)
  │                        ├─ Model calibrates response length naturally
  │                        └─ each token → SSE stream
  ├─ 6. [BLOCK varies]   Tool execution (parallel)
  │                        ├─ pre: security_check + spend_guard (2 hooks ONLY)
  │                        ├─ Tools.execute() via Task.async_stream
  │                        └─ post: cost_tracker + telemetry (2 hooks ONLY)
  ├─ 7. [ASYNC]          Bus.emit(:agent_response)    SSE ONLY (no dual delivery)
  │
  └─ RESPONSE (streamed via SSE)
```

### Improvements

| Metric | Current | Proposed | Change |
|---|---|---|---|
| Pre-LLM latency | ~300ms | ~5ms | **60x faster** to first token |
| LLM calls per message | 1 main + 0-2 middleware (classifier, noise) | 1 main only | **Up to 2 fewer LLM calls** |
| Pre-tool hooks | 5 (blocking) | 2 (blocking) | **3 removed** |
| Post-tool hooks | 9 (async) | 2 (async) | **7 removed** |
| Response delivery | Dual (HTTP+SSE, race bugs) | SSE only | **No more dedup bugs** |
| Lines of code | ~46K | ~44.8K | **~1,180 lines removed** |
| Capabilities | All | All (moved to prompt) | **Zero loss** |

---

## Detailed Module Analysis: KEEP, MOVE, or KILL

### KEEP — Essential code that CAN'T be prompt-driven

| Module | Lines | Why Keep | Pros | Cons of Removal |
|---|---|---|---|---|
| **Tool execution loop** (`loop.ex` run_loop) | ~300 | Core product. Parallel tool execution, doom loop detection, 30-iteration cap, context overflow retry. | The actual agent capability. | System stops working. |
| **`classify_fast()`** (`classifier.ex` deterministic path) | ~100 | <1ms deterministic metadata. Used for plan mode gating, analytics, signal weight. No LLM call. | Cheap, useful metadata. | Lose plan mode auto-gating, lose signal analytics. |
| **`security_check` hook** | ~50 | Blocks `rm -rf /`, `sudo`, `DROP TABLE`, fork bombs. Must be code enforcement, not prompt suggestion. | Hard security boundary. | Dangerous commands could execute. |
| **`spend_guard` hook** | ~40 | Enforces per-agent token budgets. Must be code — model can't enforce its own limits. | Cost control. | Runaway token usage. |
| **`cost_tracker` hook** | ~30 | Records actual API costs for billing/analytics. Operational. | Financial tracking. | Lose cost visibility. |
| **`telemetry` hook** | ~30 | Emits tool execution metrics. Operational observability. | Debugging, monitoring. | Lose observability. |
| **Memory persistence** | ~200 | Session JSONL append + cross-session recall. Disk I/O is code. | Cross-session memory. | Stateless per session (like Claude Code). |
| **Compactor** | ~300 | Token budget overflow → compression. Long sessions fill windows regardless of model. | Prevents context overflow. | Crashes on long sessions. |
| **SSE streaming** | ~150 | Real-time token delivery to TUI. Infrastructure plumbing. | Live streaming. | Batch-only responses. |
| **Context.build()** (simplified) | ~200 | Token budgeting + Anthropic cache hints. Math that code must do. | Optimal token usage, 90% cache hits. | Wasted tokens, no caching. |
| **Tier system** (`tier.ex`) | ~429 | Multi-agent cost control. Maps roles to model tiers. | Budget-aware orchestration. | All agents use same model (expensive). |
| **Orchestrator / Swarms** | ~2000 | Wave execution, 10-agent parallel, 9 roles. Process management is code. | Multi-agent capability. | Single-agent only. |
| **Plan mode** | ~100 | Gated by classify_fast signal weight. Extra LLM call to confirm approach on complex tasks. | Safety for destructive operations. | May execute without confirmation. |

### MOVE TO PROMPT — Currently code, should be prompt instructions

| Module | Lines | What Moves | Current (code) | Proposed (prompt) | Pros of Move | Cons of Move |
|---|---|---|---|---|---|---|
| **Signal Theory rules** | ~100 | Mode/genre/type classification behavior | `classifier.ex` LLM call asks model to classify, then injects result as context overlay | SYSTEM.md tells model: "Classify each message internally. Adjust behavior by mode." | Eliminates extra LLM call. Model classifies in same pass it responds. | If model ignores prompt (unlikely with frontier models). |
| **Signal overlay** | ~100 | Mode-specific behavior rules | `context.ex` assembles: "Active Signal: BUILD×DIRECT (weight: 0.95)" per request | SYSTEM.md static rules: "If BUILD: show work. If EXECUTE: be concise." | Zero runtime cost. Same rules, always loaded. | Slightly larger static prompt (~500 tokens). |
| **Noise handling** | ~180 | Response calibration for low-info messages | `noise_filter.ex` rejects "ok"/"thanks" with "Noted." before LLM sees them | SYSTEM.md: "Brief input → proportionally brief response." | Every message reaches the model. No valid signals rejected. | Model processes trivial messages (negligible cost with frontier models). |
| **Error recovery patterns** | ~50 | Tool failure suggestions | `error_recovery` hook injects: "Try alternative path" | SYSTEM.md: "When tools fail, try alternatives before giving up." | No hook overhead. Same guidance. | None — prompt handles this better than post-hoc injection. |
| **Quality check** | ~40 | Response length/format checking | `quality_check` hook checks content length | SYSTEM.md: "Match response length to input complexity." | No hook overhead. | None. |
| **Auto-format suggestions** | ~30 | Code formatting hints | `auto_format` hook suggests formatter runs | SYSTEM.md: "After writing code, consider if formatting is needed." | No hook overhead. | None. |
| **Context optimization hints** | ~40 | Lazy loading suggestions | `context_optimizer` hook suggests after 20 tools | SYSTEM.md: "For large codebases, search before reading." | No hook overhead. | None. |

### KILL — Remove entirely, no replacement needed

| Module | Lines | Why Kill | What It Does Today | Why It's Not Needed | Risk of Keeping |
|---|---|---|---|---|---|
| **`classify_async()` LLM path** | ~300 | Redundant with prompt-driven classification | Spawns background Task, calls LLM to classify message into 5-tuple, caches in ETS, emits Bus event | Model classifies in the same pass it responds. Extra LLM call adds cost + complexity with no user-visible benefit. | Wasted LLM calls, latency, code complexity. |
| **`noise_filter.ex`** (entire module) | ~180 | Every user message IS a signal | 2-tier filter: regex patterns (<1ms) + optional LLM call (200ms). Rejects messages with weight <0.3 with "Noted." | Users send messages intentionally. A 5-year-old saying "ok" still deserves a real response, not middleware rejection. Frontier models handle brief inputs gracefully. | Rejects valid user messages. Adds latency. Extra LLM call for uncertain cases. |
| **`budget_tracker` hook** | ~20 | Just sets a flag, no enforcement | Annotates tool calls with budget metadata | spend_guard already enforces limits. This hook just marks data that nothing reads. | Dead code overhead. |
| **`context_injection` hook** | ~20 | Just marks a flag | Sets `context_loaded: true` on session start | Memory loading happens elsewhere. This flag is never checked. | Dead code overhead. |
| **`episodic_memory` hook** | ~40 | Writes JSONL that nothing reads | Appends tool interactions to `~/.osa/learning/episodic/*.jsonl` | No code path reads these files back. Disk I/O with no consumer. Verify by grepping for usage before final deletion. | Disk bloat, I/O waste. |
| **`pattern_consolidation` hook** | ~40 | Part of learning engine, likely orphaned | Runs on session end, consolidates patterns to `patterns.json` | If `Learning.patterns()` is never called, this writes data nobody reads. Verify before deletion. | Disk waste. |
| **`metrics_dashboard` hook** | ~30 | Writes metrics nobody views | Writes daily metrics to `~/.osa/metrics/*.json` | No dashboard reads these. If we want metrics, use telemetry hook + proper observability stack. | Disk waste, false sense of monitoring. |
| **`learning_capture` hook** | ~40 | Part of learning engine | Emits `:tool_learning` events for the learning engine | If learning engine is orphaned, this feeds nothing. | Unnecessary Bus events. |
| **Dual HTTP+SSE delivery** (TUI) | ~200 | Single delivery path eliminates bugs | TUI receives response via BOTH HTTP response AND SSE agent_response event. Uses `responseReceived`/`cancelled` flags to deduplicate. | Caused BUG-017 (double render), BUG-018 (fake cancel), BUG-019 (theme stale render). SSE handles everything — HTTP path is redundant. | Bug factory. Complexity. Dedup logic. |

---

## Competitor Comparison

### How Each System Processes a Message

| System | Pre-LLM Steps | Where Intelligence Lives | Tool Mechanism |
|---|---|---|---|
| **Claude Code v2** | 0. Load CLAUDE.md → send to API. | System prompt (~1150 lines) | tool_use API |
| **Cursor** | 1. Inject todo list (~200 tokens) | System prompt + todo state | tool_use API |
| **Cline** | 1. Task type detection (new vs existing) | System prompt + XML tools | XML tool blocks |
| **Codex CLI** | 1. Auto-inject git status/diff | System prompt (~300 lines) | tool_use API |
| **Aider** | 1. Assemble repo map | System prompt + repo context | Custom tool format |
| **OpenClaw** | 0. History + memory → LLM | System prompt + skills | WebSocket tool calls |
| **OSA (current)** | 6. Classify, filter, 4-tier context, hooks | Split between middleware + prompt | tool_use API |
| **OSA (proposed)** | 1. classify_fast (metadata only) | System prompt (Signal Theory + rules) | tool_use API |

### Key Architectural Patterns

**Pattern: Every successful system puts intelligence in the prompt, not middleware.**

- Claude Code: Monolithic 1150-line system prompt. Zero pre-processing. ReAct loop with parallel tool batching.
- Cursor: "DEFAULT TO PARALLEL TOOL USE" — one sentence in the prompt, not a parallelism engine.
- Cline: "ONE TOOL PER MESSAGE" — architectural constraint in XML format, not middleware.
- All of them: user message → prompt assembly → API call → tool loop → stream back.

**What makes OSA unique (and should stay unique):**
- Multi-agent wave orchestration (code — can't be prompt-driven)
- 18-provider tier routing (code — runtime config)
- OTP fault tolerance (code — supervision trees)
- Memory persistence across sessions (code — disk I/O)
- Security hooks (code — hard enforcement)

**What OSA does that nobody else does but shouldn't be code:**
- Signal classification via extra LLM call (should be prompt)
- Noise filtering (should be prompt or nothing)
- 4-tier priority context assembly (should be simplified)
- 16-hook pipeline with suggestion hooks (should be prompt + 4 essential hooks)

---

## Migration Plan

### Phase 1: Quick Wins (1-2 days)

| Task | Files Changed | Risk | Reversible? |
|---|---|---|---|
| Delete `noise_filter.ex` | `signal/noise_filter.ex`, `agent/loop.ex` (remove filter call) | Low — messages just go straight to LLM | Yes — re-add module |
| Remove `classify_async` LLM path | `signal/classifier.ex` (delete ~300 lines) | Low — classify_fast still provides metadata | Yes — re-add function |
| Move Signal Theory to SYSTEM.md | `priv/prompts/SYSTEM.md` (add ~500 tokens) | Low — additive change | Yes — remove from prompt |
| Remove 10 low-value hooks | `agent/hooks.ex` (delete hook registrations) | Low — hooks are independent | Yes — re-register |

### Phase 2: Architecture (2-3 days)

| Task | Files Changed | Risk | Reversible? |
|---|---|---|---|
| Simplify `context.ex` (4 tiers → 2) | `agent/context.ex` (~200 lines removed) | Medium — must preserve token budgeting + cache hints | Yes — staged refactor |
| Move signal overlay to static SYSTEM.md | `agent/context.ex`, `priv/prompts/SYSTEM.md` | Low — moves text from code to file | Yes |
| HTTP 202 immediate response | `channels/http/api.ex` | Medium — changes API contract, TUI must handle | Requires TUI update |
| SSE-only TUI delivery | `priv/go/tui/app/app.go` (~200 lines removed) | Medium — delete handleOrchestrate response path | Must keep SSE working |
| Remove dedup flags | `priv/go/tui/app/app.go` | Low — single path needs no dedup | Yes |

### Phase 3: Validation (1 day)

| Task | Method |
|---|---|
| Verify streaming end-to-end (TUI → SSE only) | Manual test: send message, confirm live token streaming |
| Run full test suite | `mix test` — all ~797 tests must pass |
| Test with Opus, Sonnet | Cloud API test |
| Test with GLM-4, Kimi K2.5 via Ollama | Local model test — verify tool calling works |
| Compare first-token latency before/after | Time from Enter to first visible token |
| Verify Signal Theory in prompt works | Check model follows mode/genre/calibration rules |

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Smaller models ignore Signal Theory in prompt | Low (targeting frontier-class only) | Medium — less structured responses | Keep classify_fast for metadata; can re-add middleware for utility tier |
| SSE connection drops mid-stream | Medium | High — user loses response | Add reconnection logic + message replay from memory |
| Learning engine data IS being read somewhere | Low | Low — can restore module | Grep for `Learning.patterns()` / `Learning.solutions()` before deletion |
| HTTP 202 change breaks external integrations | Low (only TUI uses /orchestrate) | Medium | Version the API: /v2/orchestrate returns 202, /v1 stays sync |
| Team disagrees on hook removal | Medium | Low — hooks are independent | Remove one at a time, validate each removal |

---

## Key Insight

Our CLAUDE.md is the proof of concept. It has Signal Theory, agent dispatch, tier routing, hooks, and learning engine — all as prompt instructions. Claude Code follows them with zero middleware. We use it every day and it works.

We rebuilt the same capabilities as ~1,500 lines of Elixir GenServers, ETS caches, and hook pipelines. The model would've handled all of it from the prompt — we just added middleware between the user and the model.

**The fix isn't removing capabilities — it's moving intelligence back to where it belongs.** The prompt tells the model WHAT to do. The tools let the model DO it. The code is plumbing that connects them. No middleware needed in between.

```
CURRENT:  user → middleware (code reimplements prompt) → model → tools → response
PROPOSED: user → loader (code reads files) → model (follows prompt) → tools → response
```

---

## Decision

- [ ] Approved
- [ ] Approved with modifications
- [ ] Rejected — needs revision
- [ ] Deferred

**Reviewers:**
- [ ] Roberto
- [ ] Pedro
- [ ] Team

**Comments:**
_Add review comments here_
