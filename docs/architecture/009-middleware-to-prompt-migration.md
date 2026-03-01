# ADR-009: Middleware-to-Prompt Migration

**Status:** Proposed
**Date:** 2026-03-02
**Author:** OSA Team
**Reviewers:** Pedro, Team

---

## Context

We built Elixir middleware (GenServers, ETS caches, hook pipelines) to handle Signal Theory classification, noise filtering, context assembly, and learning. But our own Claude Code setup (OSA Agent v3.3 / CLAUDE.md) proves these same capabilities work as **prompt instructions** — no middleware needed.

Claude Code with our CLAUDE.md runs Signal Theory, agent dispatch, tier routing, hooks, and learning as pure prompt text. Opus/Sonnet/frontier models follow these instructions natively. We reimplemented what the prompt already handles as code, adding ~1,500 lines of latency and complexity.

**Target models:** Claude Opus, Sonnet, Kimi K2.5, GLM-4, Qwen 72B+, and other frontier-class models (cloud and local via Ollama). All capable of following structured prompt instructions.

---

## The Proof: CLAUDE.md Already Works

Our Claude Code setup (`~/.claude/CLAUDE.md`) contains:

| Capability | In CLAUDE.md (prompt) | In OSA (Elixir code) | Redundant? |
|---|---|---|---|
| Signal Theory (5-tuple classification) | Full framework: 6 principles, 11 failure modes, 4 constraints, noise checklist | `Signal.Classifier` — 540-line GenServer + ETS cache + LLM call | **YES** |
| Noise elimination | "Does every sentence carry actionable intent? CUT." checklist | `Signal.NoiseFilter` — 180-line 2-tier filter with LLM fallback | **YES** |
| Agent dispatch | 22+ agents with tiers, triggers, territory, prompts | `Agent.Roster` + `Agent.Tier` — 850+ lines | Partially (roster metadata useful for orchestration) |
| Hook pipeline | 13 events, 10 active, described as behavior | `Agent.Hooks` — 858 lines, 16 hooks, priority chains | **Most hooks YES** |
| Learning engine | SICA pattern: OBSERVE/REFLECT/PROPOSE/TEST/INTEGRATE | `Agent.Learning` — 586 lines + ETS + disk I/O | **YES** (if patterns aren't read back) |
| Tier routing | opus=elite, sonnet=specialist, haiku=utility | `Agent.Tier` — 429 lines | Partially (useful for multi-agent cost control) |
| Batch processing | 5+5 agent batching, complexity detection | `Swarm.Orchestrator` — wave execution | NO (code needed for process management) |
| Context management | "Warn@850K, auto-compact@900K" | `Agent.Context` — 770 lines, 4-tier budgeting | Partially (token math needs code, assembly doesn't) |

**Key finding:** 6 of 8 capabilities are fully or mostly redundant with prompt instructions.

---

## Current Flow (12 steps, ~300ms pre-LLM overhead)

```
USER MESSAGE
  │
  ├─ 1. [CODE]  classify_fast()           <1ms   deterministic regex
  ├─ 2. [CODE]  classify_async()          async  EXTRA LLM call (background)
  ├─ 3. [CODE]  NoiseFilter.filter()      0-200ms  can trigger ANOTHER LLM call
  │              └─ if "noise" → "Noted." early exit (user gets nothing useful)
  ├─ 4. [CODE]  Memory.append()           <50ms
  ├─ 5. [CODE]  Compactor.maybe_compact() 0-500ms
  ├─ 6. [CODE]  should_plan?()            <1ms
  ├─ 7. [CODE]  Context.build()           ~20ms
  │              ├─ Static base (cached)
  │              ├─ Signal overlay (code-assembled per request)
  │              ├─ P2: memory, tasks, workflow
  │              ├─ P3: comm profile, cortex
  │              └─ P4: OS templates, machines
  ├─ 8. [CODE]  pre_tool hooks (5)        <100ms  security, budget, optimizer, mcp, tracker
  ├─ 9. [LLM]   llm_chat_stream()         1-30s   ← THE ACTUAL WORK
  ├─ 10. [CODE] Tool execution (parallel)  varies
  ├─ 11. [CODE] post_tool hooks (9)       async   learning, episodic, metrics, format...
  ├─ 12. [CODE] Bus.emit + HTTP response   dual delivery (race condition bugs)
  │
  └─ RESPONSE
```

**Problems:**
- Steps 2-3: Up to 400ms classification/filtering before LLM starts
- Step 3: Noise filter rejects valid messages ("ok", "thanks" are valid signals)
- Step 7: Signal overlay assembled in code; should be static prompt rules
- Step 8: 3 of 5 pre-tool hooks add no security value
- Step 12: Dual HTTP+SSE delivery caused BUG-017, BUG-018, BUG-019

---

## Proposed Flow (7 steps, ~5ms pre-LLM overhead)

```
USER MESSAGE
  │
  ├─ 1. [CODE]  classify_fast()           <1ms   deterministic (metadata only)
  ├─ 2. [CODE]  Memory.append()           <50ms
  ├─ 3. [CODE]  Compactor.maybe_compact() 0-500ms  (only if context full)
  ├─ 4. [CODE]  Context.build()           ~5ms
  │              ├─ Static base (cached, includes Signal Theory rules)
  │              ├─ Dynamic: env + memory + tasks (flat, no priority tiers)
  │              └─ Conversation history
  ├─ 5. [LLM]   llm_chat_stream()         1-30s   ← THE ACTUAL WORK
  │              └─ Model follows Signal Theory rules from prompt
  │              └─ Model classifies intent internally
  │              └─ Model calibrates response length naturally
  ├─ 6. [CODE]  Tool execution (parallel)  varies
  │              ├─ pre: security_check + spend_guard (2 hooks only)
  │              └─ post: cost_tracker + telemetry (2 hooks only)
  ├─ 7. [CODE]  Bus.emit(:agent_response)  SSE only (no dual delivery)
  │
  └─ RESPONSE (streamed via SSE)
```

**Improvements:**
- ~300ms faster to first token
- No noise filter (model handles via prompt: "brief input → brief response")
- No extra LLM classification call
- No dual delivery race conditions
- Signal Theory still active (in system prompt, not middleware)
- All tool capabilities preserved
- All security enforcement preserved

---

## What To Delete

| Module | Lines | Why |
|---|---|---|
| `signal/noise_filter.ex` | ~180 | Model handles via prompt. Frontier models don't need noise gating. Every user message IS a signal — that's the point. |
| `signal/classifier.ex` (LLM path) | ~300 | Move classification rules to SYSTEM.md. Keep `classify_fast` for metadata tagging only. |
| Signal overlay in `agent/context.ex` | ~100 | Move mode/genre behavior rules to static SYSTEM.md. |
| HTTP response path in TUI | ~200 | SSE-only delivery. Delete `handleOrchestrate()` response rendering, keep only SSE path. Eliminates dedup flags. |
| 10 hooks | ~400 | budget_tracker, context_optimizer, context_injection, quality_check, error_recovery, auto_format, episodic_memory, pattern_consolidation, metrics_dashboard, learning_capture |
| **Total** | **~1,180** | |

## What To Keep (all capabilities preserved)

| Module | Why |
|---|---|
| `classify_fast()` | Cheap (<1ms), provides metadata for plan mode gating and analytics |
| `agent/context.ex` (simplified) | Token budgeting + Anthropic cache hints still needed. Simplify from 4 tiers to 2 (static + dynamic) |
| `agent/hooks.ex` (4 hooks) | security_check, spend_guard (pre-tool), cost_tracker, telemetry (post-tool) |
| Tool execution loop | Core product — parallel execution, doom loop detection, 30-iteration cap |
| Memory persistence | Session JSONL + cross-session recall |
| Compactor | Long sessions fill context windows regardless of model |
| SSE streaming | Real-time token delivery to TUI |
| Tier system | Still useful for multi-agent orchestration cost control |
| Orchestrator / Swarms | Available when explicitly invoked (/orchestrate, /swarm) |
| Plan mode | Still gated by classify_fast signal weight |

## What Moves To SYSTEM.md (prompt-driven)

These capabilities are currently implemented as Elixir code but should be instructions in the system prompt, matching what we already do in CLAUDE.md:

```markdown
## Signal Theory (add to SYSTEM.md)

Every output is a Signal: S = (M, G, T, F, W)
- Before producing output, resolve Mode, Genre, Type, Format, Structure
- If user input is brief/low-information → proportionally brief response
- If BUILD mode → show your work, structure output
- If EXECUTE mode → concise, confirm done, no preamble
- Noise checklist: every sentence must carry intent. Cut filler, hedging, repetition.

## Error Recovery (add to SYSTEM.md)

When tools fail:
- Try alternative approaches before giving up
- If file not found: check similar paths
- If command fails: read error, adjust, retry once
- Never repeat the same failed action

## Response Calibration (add to SYSTEM.md)

- Match response length to input complexity
- Single-word ack → single-line response
- Complex task → structured multi-section response
- Never pad output for length
```

---

## Comparison: How Competitors Do It

| System | Pre-LLM Middleware | Where Intelligence Lives |
|---|---|---|
| **Claude Code** | Zero. Load CLAUDE.md → send to API. | System prompt (~1150 lines) |
| **Cursor** | Todo list injection (~200 tokens). | System prompt + todo state |
| **Cline** | Task type detection (new vs existing). | System prompt + XML tool format |
| **Codex CLI** | Git context injection (auto git status/diff). | System prompt (~300 lines) |
| **Aider** | Repository context assembly. | System prompt + repo map |
| **OpenClaw** | Zero. History + memory → LLM. | System prompt + skill definitions |
| **OSA (current)** | 6 steps: classify, filter, 4-tier context, hooks. | Split between middleware and prompt |
| **OSA (proposed)** | 1 step: classify_fast (metadata only). | System prompt (Signal Theory + rules) |

**Every successful competitor puts intelligence in the prompt, not middleware.**

The only pre-LLM processing that adds value is context assembly (what to include in the prompt). Classification, filtering, behavior rules, and response calibration all belong in the prompt where the model handles them in a single pass.

---

## Migration Plan

### Phase 1: Quick Wins (1-2 days)
1. Delete `noise_filter.ex` — every message goes to the LLM
2. Remove `classify_async` LLM path from `classifier.ex`
3. Move Signal Theory rules to SYSTEM.md (copy from CLAUDE.md)
4. Remove 10 low-value hooks

### Phase 2: Architecture (2-3 days)
5. Simplify `context.ex` from 4 tiers to 2 (static + dynamic)
6. Move signal overlay from code assembly to static SYSTEM.md
7. HTTP `/orchestrate` returns 202 immediately, all data via SSE
8. Delete TUI dual-delivery path (handleOrchestrate response rendering)
9. Remove dedup flags (responseReceived, cancelled) — single path needs no dedup

### Phase 3: Validation (1 day)
10. Verify streaming works end-to-end (TUI → SSE only)
11. Run full test suite
12. Test with Opus, Sonnet, GLM-4, Kimi K2.5 via Ollama
13. Compare first-token latency before/after

---

## Key Insight

> We already proved this works. Our CLAUDE.md has Signal Theory, agent dispatch,
> tier routing, hooks, and learning as prompt instructions. Claude Code follows
> them with zero middleware. We reimplemented what the prompt already handles
> as Elixir GenServers, adding 1,500 lines of latency between the user and the model.
>
> The fix isn't removing capabilities — it's moving intelligence back to where
> frontier models handle it naturally: the prompt.

---

## Decision

- [ ] Approved
- [ ] Rejected
- [ ] Needs revision

**Reviewers sign off:**
- [ ] Roberto
- [ ] Pedro
