# OSA — Progress Report
**Date:** 2026-03-09  |  **Branch:** `fix/inline-providers-miosa-shims`  |  **Status:** Ready for PR

---

## What Was Shipped This Session

### Critical Fix: Project Compilation Restored

The previous refactoring had extracted core provider, memory, and signal modules into separate Mix path dependencies (`miosa_providers`, `miosa_llm`, `miosa_memory`, `miosa_signal`, `miosa_budget`, `miosa_tools`, `miosa_knowledge`). Those sibling directories did not exist in the repo, so `mix compile` failed immediately with 7 missing dependency errors — the project could not start at all.

**Fix strategy (two-part):**

1. **Restored providers inline.** The full provider layer (`anthropic.ex`, `ollama.ex`, `openai_compat.ex`, `openai_compat_provider.ex`, `cohere.ex`, `google.ex`, `replicate.ex`, `registry.ex`, `health_checker.ex`, `tool_call_parsers.ex`, `behaviour.ex`) was recovered from git history and placed back under `lib/optimal_system_agent/providers/`. Also restored: `agent/treasury.ex` (497 lines).

2. **Miosa shims layer added.** Rather than deleting all Miosa-namespaced references scattered across the codebase, `lib/miosa/shims.ex` was created: 698 lines, 28 modules aliasing `Miosa*` names to their real `OptimalSystemAgent.*` equivalents. This preserves forward compatibility with the eventual MIOSA monorepo split without breaking compilation today. `lib/miosa/memory_store.ex` (1,317 lines, full `MiosaMemory.Store` GenServer) was also restored.

The 7 path deps were removed from `mix.exs`. The project now compiles cleanly.

**Scope of change:** 15 files, 6,240 lines added, 20 lines changed in `mix.exs`.

---

### Bug 4 Fixed: Tool Execution Restored

Identified in `TEST_REPORT.md` as a blocker: every tool call came back as raw XML text in the chat (`<function name="file_write" ...></function>`), meaning nothing ever actually executed — no files written, no shell commands run, no memory searches.

**Root cause:** `lib/optimal_system_agent/providers/ollama.ex` only sent the tools payload in the API request when the model name matched `@tool_capable_prefixes`. The default model is `llama3.2:latest`. The prefix list contained `llama3.3` and `llama3.1` but not `llama3.2` or `llama3`. Tools were silently omitted from the request, so Groq/Ollama fell back to generating XML-formatted pseudo-tool-calls as text content.

**Fix:** Added `llama3.2` and `llama3` to `@tool_capable_prefixes`. Tools are now included in the API request for the default model. The existing XML parser in `parse_tool_calls_from_content/1` handles any residual text-format responses as a fallback.

---

### Files Added / Changed

| File | Lines | Description |
|------|-------|-------------|
| `lib/miosa/shims.ex` | 698 | 28 Miosa-namespace alias modules |
| `lib/miosa/memory_store.ex` | 1,317 | MiosaMemory.Store GenServer (restored) |
| `lib/optimal_system_agent/providers/anthropic.ex` | 640 | Anthropic provider (restored) |
| `lib/optimal_system_agent/providers/openai_compat.ex` | 743 | OpenAI-compat + XML tool parser (restored) |
| `lib/optimal_system_agent/providers/registry.ex` | 616 | Provider registry + circuit breaker (restored) |
| `lib/optimal_system_agent/providers/ollama.ex` | 419 | Ollama provider + Bug 4 fix |
| `lib/optimal_system_agent/providers/health_checker.ex` | 207 | Provider health + 429 handling (restored) |
| `lib/optimal_system_agent/providers/tool_call_parsers.ex` | 327 | Unified tool call parsing (restored) |
| `lib/optimal_system_agent/agent/treasury.ex` | 497 | Budget/token treasury (restored) |
| `lib/optimal_system_agent/providers/{cohere,google,replicate,behaviour,openai_compat_provider}.ex` | 618 | Remaining providers (restored) |
| `mix.exs` | -20 | Removed 7 non-existent path deps |

---

## Current State

### What Works

- **Project compiles and starts.** `mix compile`, `mix osa.chat`, HTTP server all functional.
- **Tool execution.** Tools are included in Ollama/Groq API requests for `llama3.2` (default). File writes, shell commands, memory search, and web tools execute rather than printing XML.
- **Slash commands.** `/help`, `/doctor`, `/status`, `/agents`, `/skills`, `/tiers`, `/config`, `/verbose`, `/sessions`, `/cortex`, `/hooks` all pass (per `TEST_REPORT.md`).
- **Signal classification.** 5-tuple classifier (Mode / Genre / Type / Format / Weight) routes requests to the correct model tier with ETS caching.
- **Provider failover.** Registry with circuit breaker; health checker handles 429/5xx; Anthropic, OpenAI-compat, Cohere, Google, Replicate, Ollama all wired.
- **Multi-turn tool loop.** Tool call → result → next iteration cycle works end-to-end (Bugs 1–3 from TEST_REPORT fixed in prior commits).
- **Noise filtering, comm profiling, conversation depth tracking, proactive monitor.** Wired and unit-tested (see TODO.md — all P0/P1/P2 items checked off).
- **Test suite.** ~1,958 tests across all modules (README badge); CI workflow runs `mix test --no-start` on every push.

### Known Warnings (non-blocking)

- **`/analytics` command has no handler** — routes to LLM which hallucinates output. Documented in TEST_REPORT (Bug 8). Does not crash.
- **Ollama added to fallback chain unconditionally** — `Req.TransportError{reason: :econnrefused}` logged when Ollama is not running (Bug 7). Falls back cleanly; no crash.
- **Tool hallucination on low-weight inputs** — noise filter catches explicit noise patterns but some short messages (single word, emoji) still reach the LLM and trigger spurious tool calls (Bug 9). NoiseFilter deterministic tier is wired; LLM-tier classification is the gap.
- **Compile warnings** — some aliased shim modules may emit `redefines module` warnings depending on load order. Non-fatal.

---

## Architecture Overview

- **Signal Theory.** Every input is classified into `S = (Mode, Genre, Type, Format, Weight)` before the reasoning engine touches it. Weight drives model tier selection (0.0–0.35 → Utility/8B, 0.35–0.70 → Specialist/70B, 0.70–1.0 → Elite). LLM classifier with deterministic fallback; results cached in ETS (SHA256 key, 10-min TTL).
- **OTP supervision.** Full supervision tree: `Application` → `ProviderRegistry` + `HealthChecker` + `EventBus` + `MemoryStore` + `Treasury` + `ProactiveMonitor` + channel supervisors. Crash isolation per-provider; circuit breaker per endpoint.
- **Provider layer.** Unified `Providers.Behaviour` contract. Registry handles routing, health checks, 429 backoff, and fallback chain. Supports Anthropic, OpenAI-compat (Groq, OpenRouter), Ollama, Cohere, Google, Replicate.
- **Tool execution pipeline.** Tools registered via `Tools.Registry`; context-filtered per request. Tool calls parsed from both structured API responses and XML text fallback. Results injected back into conversation history for next iteration.
- **Miosa shim layer.** 28 alias modules in `lib/miosa/` bridge `Miosa*` namespaces to `OptimalSystemAgent.*` implementations, keeping the codebase split-ready for the eventual MIOSA monorepo extraction without any runtime cost.

---

## Next Steps

**1. Fix `/analytics` handler (Bug 8 — P1)**
Add a dedicated slash command handler in the CLI/HTTP channel that calls `Telemetry.Metrics` directly and formats the output. Remove the LLM fallback for this command. Estimated: 1 file, ~40 lines.

**2. Reachability check for Ollama at boot (Bug 7 — P1)**
In `ProviderRegistry.init/1`, attempt `GET /api/tags` before adding Ollama to the active provider list. If `econnrefused`, log a startup notice and skip. Prevents noisy error logs on every fallback cycle.

**3. Harden noise filter LLM tier (Bug 9 — P2)**
The deterministic tier correctly catches length-zero / pure-emoji inputs. The LLM classification tier is not blocking the agent loop for inputs that score low-weight. Add a hard gate in `loop.ex`: if `signal.weight < 0.15` after classification, return a canned short response without entering the tool loop. This closes the "lol triggers web_search" class of hallucinations.
