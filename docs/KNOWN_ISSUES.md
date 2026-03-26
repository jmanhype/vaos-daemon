# Daemon Known Issues

> Last updated: 2026-03-14
> Version: 0.2.6

This document catalogs all known bugs, missing features, and UX issues
identified through codebase analysis and user testing.

---

## Severity Definitions

| Level | Meaning |
|---|---|
| **CRITICAL** | Core functionality broken — agent cannot perform primary tasks |
| **HIGH** | Important feature broken or missing — significant user impact |
| **MEDIUM** | Feature degraded or missing — workaround available |
| **LOW** | Cosmetic or minor inconvenience |

---

## CRITICAL

### BUG-004: Tools Never Execute — Raw XML Returned Instead

**Status:** Partially fixed (llama3.2 added to `@tool_capable_prefixes`)
**Component:** `Daemon.AgentLoop`, LLM response parsing
**Symptom:** When the LLM returns tool calls, they appear as raw XML/JSON in the
chat output instead of being executed. The agent loop does not recognize the
response as containing tool invocations.
**Root Cause:** Tool call extraction regex/parser does not match the format
returned by certain providers. The `@tool_capable_prefixes` list gates which
models attempt tool use, and many models were missing.
**Impact:** Agent is effectively read-only — cannot perform file operations,
web searches, or any tool-based actions.

### BUG-017: System Prompt Leaks on Direct Request (SECURITY)

**Status:** Open
**Component:** System prompt assembly, response filtering
**Symptom:** Asking the agent to reveal its system prompt results in the full
prompt being output. No output filtering prevents this.
**Root Cause:** No post-processing filter checks for system prompt content in
responses.
**Impact:** Security — exposes internal instructions, tool definitions, and
architectural details to end users.
**Mitigation:** Add response-level filtering that detects and redacts system
prompt fragments before delivery.

### BUG-009: LLM Picks Wrong Tools / Hallucinates Actions

**Status:** Open
**Component:** Tool selection, context assembly
**Symptom:** The LLM selects tools that don't exist, uses wrong parameter names,
or invents tool calls that aren't in the schema.
**Root Cause:** Tool descriptions in the system prompt may be ambiguous, or the
model's tool-use capability is insufficient for the provider being used.
**Impact:** Failed tool executions, confusing error messages, wasted LLM calls.

---

## HIGH

### BUG-005: Tool Name Mismatch on Iteration 2+

**Status:** Open
**Component:** `Daemon.AgentLoop` tool call formatting
**Symptom:** On the second iteration of the agent loop, tool parameters get
appended to the tool name (e.g., `file_read{"path": "..."}` instead of
`file_read` with params). This causes tool dispatch to fail.
**Root Cause:** String concatenation bug in how tool call results are formatted
back into the conversation for the next LLM turn.

### BUG-006: Noise Filter Not Working

**Status:** Open
**Component:** `Daemon.NLU.NoiseFilter`
**Symptom:** Trivial messages like "ok", "thanks", "hi" trigger full LLM calls
instead of being handled locally. The noise filter is either not in the
request path or its classification is not being checked.
**Impact:** Unnecessary token spend and latency for messages that don't need LLM.

### BUG-011: /api/v1/orchestrator/complex Returns 404

**Status:** Open
**Component:** HTTP router
**Symptom:** The `POST /api/v1/orchestrator/complex` endpoint is not registered
in the Bandit/Plug router despite being documented.
**Impact:** Multi-agent orchestration API is inaccessible over HTTP.

### BUG-012: /api/v1/swarm/status/:id Returns 404

**Status:** Open
**Component:** HTTP router
**Symptom:** No status endpoint exists for checking swarm execution progress.
**Impact:** Clients cannot poll for swarm job completion.

---

## MEDIUM

### BUG-007: Ollama Always in Fallback Chain

**Status:** Open
**Component:** Provider configuration
**Symptom:** Ollama is included in the provider fallback chain even when not
installed on the system. This causes unnecessary connection timeout errors
when Ollama is unreachable.
**Workaround:** The timeout eventually falls through to the next provider, but
adds latency.

### BUG-008: /analytics Command Has No Handler

**Status:** Open
**Component:** CLI command router
**Symptom:** Typing `/analytics` returns "unknown command" — no handler is
registered despite analytics data being collected.

### BUG-010: Negative uptime_seconds in /health

**Status:** Open
**Component:** Health endpoint
**Symptom:** The `/health` endpoint sometimes returns negative `uptime_seconds`
values due to a timestamp calculation error.
**Root Cause:** System monotonic time vs wall clock time mismatch, or the boot
timestamp is set after the calculation runs.

### BUG-015: Invalid Swarm Patterns Silently Fall Back to Pipeline

**Status:** Open
**Component:** Swarm pattern validation
**Symptom:** Passing an invalid swarm pattern name (e.g., `"foobar"`) does not
return an error. Instead, it silently falls back to the `pipeline` pattern.
**Expected:** Return an error listing valid patterns.

### BUG-016: Unicode Mangled in DB Storage

**Status:** Open
**Component:** SQLite/Ecto storage layer
**Symptom:** Japanese text, emoji, and other non-ASCII content is stored as
`?????` in the database. Retrieval returns garbled content.
**Root Cause:** Likely missing `PRAGMA encoding = 'UTF-8'` or binary encoding
issue in the Ecto adapter configuration.

### BUG-018: Missing Slash Command Handlers

**Status:** Open
**Component:** CLI command router
**Symptom:** The following slash commands are documented or referenced in code
but have no handler implementation:
- `/budget` — Token budget management
- `/thinking` — Extended thinking toggle
- `/export` — Session/conversation export
- `/machines` — Remote machine management
- `/providers` — Provider listing and management

---

## USER-REPORTED ISSUES

### UX-001: No API Key Detection Feedback

**Status:** Open
**Component:** Provider initialization, onboarding UX
**Symptom:** When no API key is configured for any provider, Daemon does not
clearly inform the user. It either fails silently or shows a generic error.
**Expected:** Clear message on startup: "No API keys detected. Set ANTHROPIC_API_KEY,
OPENAI_API_KEY, or install Ollama to get started."

### UX-002: Retry/Star Button Not Working in Desktop App

**Status:** Open
**Component:** Desktop Command Center (Tauri/SvelteKit)
**Symptom:** The retry and star/favorite buttons in the chat interface are
non-functional — clicking them does nothing.
**Root Cause:** Event handlers not wired or backend endpoints not implemented.

### UX-003: Ollama Not Showing as Selectable Option

**Status:** Open
**Component:** Desktop Command Center, provider selection UI
**Symptom:** Even when Ollama is installed and running locally, it does not
appear in the provider/model selection dropdown in the desktop app.
**Root Cause:** Provider detection not running on desktop startup, or results
not propagated to the frontend.

### UX-004: General Desktop Command Center UX Issues

**Status:** Open
**Component:** Desktop Command Center
**Symptom:** Various UX issues across the desktop application including
inconsistent styling, missing loading states, and incomplete feature parity
with the CLI interface.

---

## FIXED

### BUG-001: Onboarding Selector Crash ✓

**Fixed in:** v0.2.5
**Component:** Pattern matching in onboarding flow
**Fix:** Corrected pattern match clause ordering.

### BUG-002: Events.Bus Missing :signal_classified ✓

**Fixed in:** v0.2.5
**Component:** Event bus classifier
**Fix:** Added `:signal_classified` to the event type registry.

### BUG-003: Groq tool_call_id Missing in format_messages ✓

**Fixed in:** v0.2.5
**Component:** Groq provider adapter
**Fix:** Added `tool_call_id` field to Groq message formatting.

### BUG-004 (Partial): llama3.2 Tool Capability ✓

**Fixed in:** v0.2.6
**Component:** Tool capability detection
**Fix:** Added `llama3.2` to `@tool_capable_prefixes` list. Full fix
(proper tool call parsing for all providers) still pending.

---

## Issue Backlog by Component

| Component | Open Issues | Critical |
|---|---|---|
| Agent Loop / Tool Execution | BUG-004, BUG-005, BUG-009 | 2 |
| Security | BUG-017 | 1 |
| HTTP Router | BUG-011, BUG-012 | 0 |
| CLI Commands | BUG-008, BUG-018 | 0 |
| Provider System | BUG-007 | 0 |
| Noise Filter | BUG-006 | 0 |
| Data Storage | BUG-016 | 0 |
| Swarm System | BUG-015 | 0 |
| Health/Monitoring | BUG-010 | 0 |
| Desktop App | UX-001 through UX-004 | 0 |

**Total open:** 18 issues (3 critical, 4 high, 6 medium, 5 UX)
