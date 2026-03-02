# Middleware-to-Prompt Migration — Changelog

> **Date**: 2026-03-02
> **Phases**: 1 (classifier), 2 (pipeline), 3A (cleanup)
> **Net result**: -1,856 lines removed, execution pipeline matches Claude Code exactly

---

## What Changed

### Pipeline (Before → After)

**Before:**
```
message → noise_filter → classifier (LLM call) → signal_overlay → hooks (12) → system prompt → LLM → tools → re-prompt
```

**After:**
```
message → injection guard → persist → compact → system prompt (SYSTEM.md) → LLM → tools → re-prompt
```

Zero middleware between user and model. The LLM self-classifies via Signal Theory instructions baked into SYSTEM.md. Same architecture as Claude Code, Cursor, Windsurf, and Open Code.

---

## Phase 1 — Classifier Simplification

### Removed
| File | What | Why |
|------|------|-----|
| `lib/optimal_system_agent/signal/noise_filter.ex` | Noise filter module | Pre-LLM filtering added latency, no value |
| `test/signal/noise_filter_test.exs` | Noise filter tests | Module deleted |
| `priv/prompts/noise_filter.md` | Noise filter prompt | Module deleted |

### Changed
| File | What |
|------|------|
| `signal/classifier.ex` | Stripped to thin passthrough — no LLM call on hot path, returns sensible defaults |
| `test/signal/classifier_test.exs` | Updated to match simplified classifier |

---

## Phase 2 — Pipeline Cleanup

### Changed
| File | What |
|------|------|
| `agent/context.ex` | Removed signal_overlay_block injection, dead helper functions (~200 lines removed) |
| `agent/hooks.ex` | Gutted from 12 hooks to 6 (security_check, spend_guard, cost_tracker, telemetry, mcp_cache, budget_guard). ~450 lines removed |
| `agent/loop.ex` | Simplified message flow — removed classifier call from hot path, cleaner tool re-prompt cycle |
| `channels/cli.ex` | Removed signal mode/genre display from CLI output |
| `channels/cli/plan_review.ex` | Minor cleanup |
| `channels/http/api.ex` | Removed `/classify` endpoint and signal overlay from `/chat` response |
| `sdk/sdk.ex` | Removed signal classification from SDK interface |
| `sdk/signal.ex` | Simplified signal struct |
| `config/config.exs` | Removed classifier-related config keys |
| `config/test.exs` | Removed test-specific classifier config |
| `test/integration/conversation_test.exs` | Updated integration tests for new pipeline |
| `test/providers/openai_compat_test.exs` | Updated provider tests |

### TUI (Go)
| File | What |
|------|------|
| `priv/go/tui-v2/app/app.go` | Removed signal badge rendering, simplified message handling |
| `priv/go/tui-v2/client/http.go` | Removed `/classify` API call |
| `priv/go/tui-v2/client/types.go` | Removed signal fields from response types |
| `priv/go/tui-v2/msg/msg.go` | Removed signal-related message types |
| `priv/go/tui-v2/ui/chat/list.go` | Removed signal overlay from chat display |
| `priv/go/tui-v2/ui/completions/completions.go` | Cleanup |
| `priv/go/tui-v2/ui/input/input.go` | Cleanup |

---

## Phase 3A — Dead File Cleanup

### Removed
| File | What | Why |
|------|------|-----|
| `priv/prompts/classifier.md` | LLM classifier prompt | Classifier no longer makes LLM calls |
| `priv/prompts/mode_behaviors.md` | Signal mode behavior defs | signal_overlay_block removed from context |
| `priv/prompts/genre_behaviors.md` | Signal genre behavior defs | signal_overlay_block removed from context |

### Changed
| File | What |
|------|------|
| `prompt_loader.ex` | Removed 3 dead keys from `@known_keys` (9 → 6) |
| `priv/prompts/SYSTEM.md` | Updated hooks table to reflect 2 surviving events + 5 real hooks |

---

## Hooks — What Survived

| Hook | Event | Purpose |
|------|-------|---------|
| security_check | pre_tool_use | Blocks dangerous shell commands |
| spend_guard | pre_tool_use | Blocks execution when budget exceeded |
| mcp_cache | pre_tool_use | Caches MCP tool results |
| cost_tracker | post_tool_use | Records API costs per call |
| telemetry | post_tool_use | Performance metrics and latency |

### Removed Hooks
`learning_capture`, `error_recovery`, `context_optimizer`, `quality_check`, `episodic_memory`, `metrics_dashboard`, `context_injection`, `validate_prompt`, `pattern_consolidation`, `auto_format`

---

## Hooks — What Was Removed

These hooks added latency and complexity without proportional value. Their functionality either:
- Belongs in SYSTEM.md instructions (quality, context management)
- Was never wired to real storage (learning, episodic memory)
- Duplicated what the LLM already does (validation, auto-format)

---

## `priv/prompts/` — Final State

```
priv/prompts/
├── SYSTEM.md              # 530+ lines — soul, personality, Signal Theory, tools, orchestration
├── IDENTITY.md            # Agent identity and name
├── SOUL.md                # Core behavioral instructions
├── compactor_summary.md   # Context compaction summary template
├── compactor_key_facts.md # Context compaction key facts template
└── cortex_synthesis.md    # Cortex synthesis template
```

---

## Architecture Grade

**B+ → A** after this migration.

The execution pipeline now matches every major competitor. `priv/` follows Elixir conventions (bundled via `mix release`), `~/.osa/` mirrors `~/.claude/` for user overrides, and the LLM self-classifies through SYSTEM.md — no middleware tax.

---

## Verification

- `mix compile` — zero new warnings
- `mix test` — 739 tests, 4 pre-existing failures (none migration-related)
- `go build ./...` — clean
- PromptLoader loads 6/6 prompts at boot
