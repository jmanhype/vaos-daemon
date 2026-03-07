# Javaris Intel — Tasks, Findings & Testing

_Last updated: March 7, 2026 (Voice input system shipped)_

---

## Current State Summary

OSA is at **39,500+ LOC**, 154 modules, 26 tools, 17 skills (11 with SKILL.md), 18 LLM providers.
The full pipeline works: prompt → Ollama/Anthropic streaming → tool calls → file writes → response.
Pedro landed code generation (one-shot app scaffolding), a `git` builtin tool, coding nudge (forces model to use `file_write` instead of pasting code in chat), and Windows shell fixes.
Roberto refactored the god files (`commands.ex` 2938→442, `api.ex` 1831→153) and built the Rust TUI (14.5K lines).
**Voice input** now shipped — clickable ◉ mic button in TUI, local whisper-cli (zero-dependency download) + cloud OpenAI Whisper, native audio format capture with 16kHz resampling.

### What's Working
- Full ReAct agent loop with streaming (all 18 providers), parallel tool execution, doom loop detection
- 26 tools (file ops, shell, git, github, web, memory, orchestration, semantic search, code symbols, multi-file edit)
- Skills: 11 SKILL.md files loaded from priv/skills/ at boot into Tools.Registry — code-generation, tdd-enforcer, tree-of-thoughts, lats, reflection, security-auditor, meta-prompting, self-consistency, skeleton-of-thought, react-pattern, prompt-cache-optimizer
- Rust TUI with streaming chat, tool rendering, shell mode, paste, completions, cancel
- Persistent memory (JSONL sessions, MEMORY.md, Cortex bulletins)
- Context compaction (3-tier: 80%/85%/95%)
- Heartbeat daemon: reads HEARTBEAT.md every 30min, runs tasks through Agent.Loop, circuit breaker, quiet hours, CRONS.json, TRIGGERS.json — fully built, zero UX surface
- MCP server (`mcp/server.ex`) — OSA can act as MCP server for Cursor/Cline/Goose
- Sandbox.Executor with Docker/BEAM/WASM routing — opt-in via server config
- Voice input — clickable ◉ mic button, local whisper-cli (auto-downloaded) + cloud OpenAI Whisper, 16kHz resampled capture

### What's Not Working
- ~~13/18 providers have no streaming~~ ✅ Fixed ba0a1cd
- ~~No cancel endpoint~~ ✅ Fixed ba0a1cd
- ~~`run_osa.ps1` Go TUI~~ ✅ Fixed ba0a1cd
- ~~No rate limiting~~ ✅ Fixed c393e23
- ~~**Skill trigger injection**~~ ✅ Done March 5 — `Tools.Registry.match_skill_triggers/1`, `active_skills_context/1` with message param, `skills_block/1` passes last user message. When message matches skill triggers, full SKILL.md instruction body is injected into the system prompt for that turn.
- ~~**Heartbeat has zero UX surface**~~ ✅ Already done — `/heartbeat` registered in commands.ex, `cmd_heartbeat/2` in scheduler_cmd.ex shows next run + HEARTBEAT.md content + `/heartbeat add <task>`.
- ~~**Approval modes**~~ ✅ Done March 5 — `:permission_tier` (`:full`/`:workspace`/`:read_only`) on Loop state struct, `permission_tier_allows?/2` checked in `execute_tool_call` before dispatch, `/tier` command registered, `handle_call` for get/set wired.
- ~~**Ollama provider has zero tests**~~ ✅ Done March 5 — 47 tests in `test/providers/ollama_test.exs`. Covers `model_supports_tools?`, `thinking_model?`, `split_ndjson`, `process_ndjson_line`, `pick_best_model`, `strip_thinking_tokens`, `list_models` error handling, `auto_detect_model` graceful fallback. 160 total provider tests pass.

---

## Task 1: Rust TUI as Default

**Priority:** 1 (10 min)  
**Status:** ✅ DONE — commit ba0a1cd  
**Files changed:** `run_osa.ps1`

### Problem
`run_osa.ps1` line 15 sets `$TUI = "$OSA_DIR\priv\go\tui-v2\osa.exe"` — the retired Go binary from Feb 28. The Rust TUI (`osagent.exe`) has all the fixes but nobody gets it unless they manually build and run it.

### What Must Be Done
- ✅ Change `$TUI` to point at `priv\rust\tui\target\release\osagent.exe`
- ✅ Add fallback: if Rust binary missing, warn and try Go TUI
- ✅ Add auto-build prompt if `cargo` is available but binary is missing

### How to Test
1. Open a fresh PowerShell
2. Run: `cd "C:\Users\Javaris Tavel\Desktop\osa"; .\run_osa.ps1`
3. **Expected:** Rust TUI launches (not Go TUI). You can type, paste (Ctrl+V), and see the full UI
4. **Verify typing works:** Type a message and hit Enter — input should be responsive
5. **Test fallback:** Rename `osagent.exe` temporarily → script should warn and fall back to Go TUI
6. **Test auto-build:** Delete `target\release\osagent.exe` → script should offer to build or warn

---

## Task 2: General Cancel Endpoint

**Priority:** 2 (1-2 hrs)  
**Status:** ✅ DONE — commit ba0a1cd  
**Files changed:**
- `lib/optimal_system_agent/agent/loop.ex` — cancellation flag + check in loop
- `lib/optimal_system_agent/channels/http/api/agent_routes.ex` — POST endpoint
- `priv/rust/tui/src/client/http.rs` — cancel function
- `priv/rust/tui/src/app/handle_actions.rs` — wire Escape to cancel

### Problem
When the agent enters its ReAct loop (up to 30 iterations), there's no way to stop it. `handle_call(:process)` blocks synchronously. Ctrl+C in the TUI does nothing to the backend.

### What Must Be Done
**Backend (loop.ex):**
- Add `:cancelled` field to Loop state struct (default `false`)
- Add `handle_info(:cancel, state)` that sets cancelled to `true`
- At top of each `run_loop` iteration: check `if state.cancelled` → break with "Cancelled by user"
- Public API: `cancel/1` sends message via Process registry lookup

**HTTP (agent_routes.ex):**
- Add `POST /api/v1/agent/cancel/:session_id`
- Call `Loop.cancel(session_id)`, return 200

**TUI (Rust):**
- Add `cancel_agent()` in http.rs
- Wire Escape key during processing state to call cancel endpoint
- Activity bar shows "Cancelling..." during cancel

### How to Test
1. Start backend: `cd "C:\Users\Javaris Tavel\Desktop\osa"; $env:OSA_SKIP_NIF="true"; mix osa.serve`
2. Start TUI: `& "C:\Users\Javaris Tavel\Desktop\osa\priv\rust\tui\target\release\osagent.exe"`
3. Send a complex prompt: `"Read every file in this project and summarize the architecture"`
4. While the agent is processing (activity spinner visible), press **Escape**
5. **Expected:** Activity bar shows "Cancelling...", agent stops within 1-2 seconds, returns "Cancelled by user"
6. **Verify via curl:**
   ```
   curl -X POST http://localhost:8089/api/v1/agent/cancel/SESSION_ID
   ```
   Should return 200 OK
7. **Edge case:** Send a simple prompt that completes fast — Escape should do nothing if agent is idle

---

## Task 3: OpenAI-Compat Streaming (`chat_stream/3`)

**Priority:** 3 (3-4 hrs)  
**Status:** ✅ DONE — commit ba0a1cd (verified live: Groq streamed 8 chunks)  
**Files changed:**
- `lib/optimal_system_agent/providers/openai_compat.ex` — add `chat_stream/5`
- `lib/optimal_system_agent/providers/openai_compat_provider.ex` — add `chat_stream/3` wrapper
- `lib/optimal_system_agent/providers/registry.ex` — remove compat sync fallback override

### Problem
13 providers (Groq, OpenRouter, Together, Fireworks, DeepSeek, Mistral, OpenAI, Perplexity, Qwen, Moonshot, Zhipu, Volcengine, Baichuan) all route through `OpenAICompat.chat/5` — sync only. The registry explicitly falls back: _"Compat providers don't implement chat_stream — always use sync fallback"_. Users see a frozen UI for 10-60 seconds, then the entire response dumps at once.

### What Must Be Done
**OpenAICompat (openai_compat.ex):**
- Add `chat_stream/5` function — POST to `/chat/completions` with `"stream": true`
- Use `Req.post` with `into:` callback (same pattern as Ollama)
- Parse OpenAI SSE format: `data: {"choices":[{"delta":{"content":"token"}}]}`
- Handle `data: [DONE]` termination
- Accumulate tool call deltas across chunks
- Call callback with `{:token, text}`, `{:tool_call, ...}`, `{:done, final}`

**OpenAICompatProvider (openai_compat_provider.ex):**
- Add `chat_stream/3` that delegates to `OpenAICompat.chat_stream/5`
- Expose via `@behaviour` so `function_exported?` check passes

**Registry (registry.ex):**
- Remove the `try_stream_provider({:compat, _})` clause that forced sync fallback
- Compat providers now go through standard `function_exported?(:chat_stream, 3)` path

### How to Test
1. Set up a provider key in `.env`:
   ```
   GROQ_API_KEY=your_key_here
   OSA_DEFAULT_PROVIDER=groq
   ```
2. Start backend: `cd "C:\Users\Javaris Tavel\Desktop\osa"; $env:OSA_SKIP_NIF="true"; mix osa.serve`
3. Start TUI: `& "C:\Users\Javaris Tavel\Desktop\osa\priv\rust\tui\target\release\osagent.exe"`
4. Send: `"Explain the Elixir GenServer lifecycle in detail"`
5. **Before:** Full response dumps after 5-10 seconds of blank screen
6. **After:** Tokens stream in real time, word by word in the chat
7. **Test with tool calls:** Send `"What files are in /tmp?"` — should stream text AND execute tool calls correctly
8. **Test other providers** (if you have keys):
   - `OSA_DEFAULT_PROVIDER=openrouter` with `OPENROUTER_API_KEY`
   - `OSA_DEFAULT_PROVIDER=openai` with `OPENAI_API_KEY`
   - `OSA_DEFAULT_PROVIDER=together` with `TOGETHER_API_KEY`
9. **Verify in backend logs:** Should see `[info] Streaming via chat_stream` instead of `sync fallback`

---

## Findings

### Architecture Strengths (vs Claude Code)
- **Local-first:** Ollama = free, private. Claude Code is cloud-only, $$$
- **18 providers:** Model-agnostic. Claude Code is Anthropic-locked
- **Fully customizable:** Skills, prompts, tools are all pluggable. Claude Code is a black box
- **Elixir/OTP:** Actor model, fault tolerance, hot reload. No competitor uses this
- **Multi-agent swarms:** Architecture exists (24 agents, 4 patterns). Claude Code is single-threaded

### Critical Gaps (vs Claude Code)
- ~~Streaming only on 5/18 providers~~ ✅ All 18 stream
- ~~No cancel~~ ✅ Done
- ~~No rate limiting~~ ✅ Done
- ~~**Skill trigger injection**~~ ✅ Done March 5
- ~~**Heartbeat UX**~~ ✅ Done (was already wired)
- ~~**Approval modes**~~ ✅ Done March 5 — `/tier full|workspace|read_only` command
- ~~**Ollama zero tests**~~ ✅ Done March 5 — 47 tests, 160 total provider tests
- No IDE integration (VS Code extension)
- No SWE-bench evaluation — no benchmark number vs competitors
- No git worktree isolation for parallel wave agents (agents share CWD = staging area races)
- No browser automation / computer use
- No self-evolving scaffold
- No VS Code extension

### MCP Client/Server Security Analysis

**Grade: A-** — Functional, protocol-compliant, priority security fixes applied

**Files:**
- `lib/optimal_system_agent/mcp/client.ex` — Orchestrator (140 lines)
- `lib/optimal_system_agent/mcp/server.ex` — GenServer per MCP subprocess (~420 lines)
- `~/.osa/mcp.json` — Server configuration

**What Works:**
- JSON-RPC 2.0 protocol, version "2024-11-05"
- Per-server GenServer with DynamicSupervisor
- 10s init timeout, 30s tool call timeout
- Clean stdio communication via Elixir Port
- Tool discovery via `tools/list` → merged into Tools.Registry with `mcp_` prefix
- ✅ Input validation against tool's `inputSchema` (type, required, properties)
- ✅ Tool allowlist filtering via `allowed_tools` config per server
- ✅ Env var interpolation: `${GITHUB_TOKEN}` → looks up from System.get_env
- ✅ Audit logging: `[MCP Audit]` structured log for all tool calls

**Security Fixes Applied (March 5, 2026):**

| Fix | Implementation |
|-----|----------------|
| **Input validation** | `valid_input?/2` validates against `inputSchema` — checks `type`, `required`, `properties`. Invalid calls rejected with `"Input validation failed"` |
| **Tool allowlist** | `allowed_tools` config key per server (list of tool names). `filter_allowed_tools/2` filters in `list_tools` and `call_tool`. Omit for all tools. |
| **Env var interpolation** | `interpolate_env/1` replaces `${VAR_NAME}` patterns in env values with `System.get_env("VAR_NAME")`. Secrets stay out of mcp.json. |
| **Audit logging** | `audit_log/5` logs `{timestamp, server, tool, args_hash, status, reason}` for every call. Status: `:calling`, `:blocked`, `:rejected`. |

**New mcp.json Format:**
```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "${GITHUB_TOKEN}" },
      "allowed_tools": ["create_issue", "list_issues", "get_issue"]
    }
  }
}
```

**Remaining Gaps (4 issues):**

| Gap | Severity | Fix | Effort |
|-----|----------|-----|--------|
| **No server authentication** — no way to verify MCP server identity | Medium | Add signature verification or hash of expected server binary | 2h |
| **No rate limiting** — unlimited tool calls per MCP server | Low | Per-server rate limiter (similar to HTTP rate_limiter.ex) | 1h |
| **No sandboxing** — MCP subprocesses run with full user permissions | Medium | Docker/Podman wrapping for untrusted MCP servers | 4h |
| **Schema validation incomplete** — doesn't validate `enum`, `pattern`, `minLength`, etc. | Low | Extend `validate_schema/2` or add ex_json_schema dep | 2h |

### God File Refactor Status
| File | Before | Current | Status |
|------|--------|---------|--------|
| `commands.ex` | 2,938 | 442 | ✅ Done (10 modules extracted — auth, config, data added in pull) |
| `api.ex` | 1,831 | 153 | ✅ Done (12 sub-routers) |
| `orchestrator.ex` | 1,441 | 584 | ⚠️ Partial — `wave_executor.ex` extracted in 7f8d233 |
| `scheduler.ex` | 1,222 | 472 | ⚠️ Partial — `scheduler_cmd.ex` split out |

### Test Coverage
| Area | Status |
|------|--------|
| Agent loop | ✅ 3 test files, 581+ lines (loop_injection + loop_unit expanded in 7f8d233) |
| Tools | ⚠️ 7/26 tested |
| Providers | ⚠️ 5/18 tested — Ollama 47 tests, 160 total provider tests pass |
| HTTP API | ✅ 6 files now — auth_routes, rate_limiter, session_routes added + e2e smoke test (326 lines) |
| Orchestrator | ❌ No tests |
| Cortex | ❌ No tests |
| Rust TUI | ❌ No tests (voice module untested) |

### Pedro's Recent Contributions (PAMF2)
- Ollama streaming for thinking models (kimi-k2.5)
- Code generation skill (481-line SKILL.md)
- `git` builtin tool (22nd tool)
- Coding nudge (forces file_write over markdown code blocks)
- Windows shell executor fix
- Security hardening (9 injection patterns)
- Bug fixes: ETS race, unicode, overflow retries

### What Landed in This Pull (ba0a1cd → 7f8d233)
- ✅ **Tasks 1, 2, 3 all done** — Rust TUI default, cancel endpoint, compat streaming
- **MCP server** (`mcp/server.ex`) — OSA can now act as an MCP server for other tools
- **4 new tools** — `github.ex`, `code_symbols.ex`, `multi_file_edit.ex`, `semantic_search.ex` (26 tools now)
- **Wave executor** extracted from orchestrator (`orchestrator/wave_executor.ex`)
- **Rate limiter** (`channels/http/rate_limiter.ex`) — C3 closed
- **New commands** — `auth.ex`, `config.ex`, `data.ex` split from system.ex
- **E2E smoke test** (326 lines) + auth/rate/session HTTP test files
- **Swarm command** exposed in TUI — `/swarm <preset> <task>` works
- **Explore-first protocol** added for coding tasks (commit c806638)
- **run_osa.ps1** bugs fixed (3 fixes in ed85d13, 515ea0d)

### Roberto's Recent Contributions
- Rust TUI (7 phases, 14.5K lines, 71 files)
- God file refactor (commands.ex, api.ex)
- System prompt + Signal Theory
- Middleware-to-prompt migration
- 135 new tests

---

## Claude Code & Competitor Feature Hitlist

> Features competitors have that would make OSA clearly better. Ranked by impact. Updated March 5, 2026.

### Tier 1 — High Impact, Achievable (do these next)

> ⚠️ Status corrections after deep code audit (March 5, 2026)

| Feature | Who Has It | OSA Status | Real Gap | Effort |
|---------|-----------|------------|----------|--------|
| **Skill trigger injection** | Claude Code (full tool schemas per turn), Cursor | ✅ DONE March 5 — `match_skill_triggers/1`, `active_skills_context/1`, `skills_block/1` updated | Full SKILL.md instructions injected into system prompt when user message matches trigger keywords | done |
| **Heartbeat UX surface** | OpenClaw (HEARTBEAT.md, 30min daemon) | ✅ ALREADY DONE — `/heartbeat` registered in commands.ex line 339, `cmd_heartbeat/2` in scheduler_cmd.ex shows next run + content + add | — | done |
| **Approval modes (session-level)** | Codex CLI (read-only/auto/full), NanoClaw (container-first) | ✅ DONE March 5 — `:permission_tier` on Loop struct, `permission_tier_allows?/2`, `/tier` command, `handle_call` get/set | 3 tiers: `:full` (all tools), `:workspace` (read + local writes), `:read_only` (observation only). Enforced in `execute_tool_call` before hooks. | done |
| **Ollama provider tests** | N/A (internal) | ✅ DONE March 5 — 47 tests in `ollama_test.exs` | `model_supports_tools?`, `thinking_model?`, `split_ndjson`, `process_ndjson_line`, `pick_best_model`, `strip_thinking_tokens`, error handling, auto_detect graceful fallback. 160 total provider tests. | done |
| **Git worktree isolation for parallel agents** | Cursor (8 parallel agents via worktrees) | ⚠️ Wave executor runs parallel agents but they share CWD — git staging area races | `git worktree add` per wave agent, pass isolated CWD, merge on completion. Files: `orchestrator/wave_executor.ex` | 4-6h+ |
| **SWE-bench evaluation** | Aider (SOTA), SWE-Agent (79.2%), OpenHands (26%) | ❌ Never run | Headless session receives repo+issue → ReAct loop → diff output. Tools already correct. Run SWE-bench Lite (300 tasks) overnight. | 1-2 days |

### Tier 2 — Medium Impact, Architectural

| Feature | Who Has It | OSA Status | Notes |
|---------|-----------|------------|-------|
| **VS Code extension** | Continue.dev, Cline (5M users), Cursor | ❌ Missing | Biggest distribution channel for coding agents. OSA is terminal-only. |
| **Browser automation / computer use** | Cline (Claude Computer Use), Devin (end-to-end testing), OpenHands (web browser agent) | ❌ Missing | Adds UI testing, form filling, visual verification. Claude Computer Use API makes this tractable. |
| **MCP server exposure (client tools connecting to OSA)** | Goose (1,700+ MCP extensions), Cline, Codex CLI | ✅ `mcp/server.ex` landed in 7f8d233 — needs wiring/testing | OSA can now BE an MCP server. Expose tools so Cursor/Cline/Goose can call OSA. |
| **Self-evolving scaffold** | SWE-Agent Live (agent improves own tools at runtime, 79.2% SWE-bench) | ❌ Missing | Agent rewrites its own tool definitions mid-session based on what works. Unique capability. |
| **Skill/recipe marketplace** | OpenClaw (2,857+ ClawHub skills), Goose (Recipes) | ⚠️ 17 skills, no marketplace | OSA skills are local-only. A hosted index (even a GitHub-indexed list) would enable distribution. |
| **Prompt caching (static/dynamic split)** | OpenCode (implemented), **not** Claude Code v2 (ironic) | ✅ Done (both providers) | Anthropic: `cache_control: %{type: "ephemeral"}` + beta header. OpenAI: auto-caching + `cached_tokens` tracking in usage. |

### Tier 3 — Polish / Differentiators

| Feature | Who Has It | OSA Status | Notes |
|---------|-----------|------------|-------|
| **Deep mode / extended reasoning** | Amp ("think hard" dynamic budget), Cursor (Plan Mode) | ⚠️ Plan mode exists via signal weight | Amp's explicit "think hard" prompt trigger with dynamic token budget is cleaner than OSA's implicit weight routing. |
| **Voice input** | Codex CLI (hold spacebar), Aider | ✅ DONE March 7 — clickable ◉ button, local whisper-cli + cloud OpenAI | Zero-dep install: whisper-cli binary auto-downloaded at first use. No LLVM/build tools needed. |
| **Image/screenshot context attachment** | Codex CLI, Cline (visual debugging), Amp (Painter) | ❌ Missing | Useful for UI bugs and wireframe-to-code. |
| **Named session gallery + timeline** | Amp (file change tracking across conversations), Cline (timeline + rollback) | ⚠️ TUI lists sessions | Cline's rollback timeline is the most useful: see all changes made in a session, undo per-file. |
| **`openclaw doctor` style diagnostics** | OpenClaw | ❌ Missing | `osa doctor` command that checks: provider keys set, NIF compiled, TUI binary present, DB migrated. |
| **Cross-session learning (SICA / pattern recall)** | OpenClaw (hybrid RAG, temporal decay), OSA design exists | ⚠️ Architecture exists in memory.ex | Retrieval from past sessions is wired but SICA self-improvement loop not fully active. |

### What OSA Already Does Better Than Claude Code

| OSA Advantage | Claude Code v2 | Impact |
|--------------|---------------|--------|
| Signal classification (5-tuple per message) | None — uniform pipeline | Cheaper trivial messages, richer complex ones |
| Cross-session memory (MEMORY.md + Cortex) | Manual CLAUDE.md only | Users don't repeat themselves |
| 18 providers + Ollama local | Anthropic-only | Privacy, cost, offline capability |
| Elixir/OTP fault tolerance + hot reload | Node.js single process | Crash isolation, zero downtime |
| Wave executor (parallel agent swarms) | Single-threaded | Multi-agent tasks complete faster |
| Personality system (~500 words) | 2-sentence identity | Better long-term UX |
| Per-request environment refresh | Session-level stale snapshot | Agent always sees current git state |
| Noise gate (pre-LLM trivial message filter) | Full pipeline for every message | Token savings + faster trivial replies |
| Explicit task evidence requirement (task_write) | TodoWrite with no verification | Can't mark done without proof |
| 26 tools (semantic search, github, multi-edit, code symbols) | ~15 tools, no semantic search | Richer autonomous capability |
| Voice input: local + cloud, zero build deps | Codex: cloud-only, spacebar hold | Offline voice, works anywhere |

### Top 3 to Do Right Now

1. ~~**Ollama tests**~~ ✅ DONE — 47 tests, 160 total provider tests pass.
2. ~~**Approval modes**~~ ✅ DONE — `/tier full|workspace|read_only`, enforced in `execute_tool_call`.
3. **Git worktree isolation** — 4-6h. `git worktree add` per wave agent, pass isolated CWD, merge on completion. Prevents staging area races in parallel swarms.

---

## Implementation Notes (March 5, 2026)

### ✅ Skill Trigger Injection — DONE

**Changes made:**
- `lib/optimal_system_agent/tools/registry.ex` — Added `match_skill_triggers/1` (public, checks message against all skill trigger keywords) and `active_skills_context/1` (takes message, appends matching skill's full `instructions` body as `"### Active Skill: #{name}\n\n#{body}"` after the name+description list)
- `lib/optimal_system_agent/agent/context.ex` — Updated `skills_block/1` to call `find_latest_user_message(state.messages)` (already existed in same module) and pass the message text to `active_skills_context/1` instead of calling the 0-arity version

**How it works now:** When a user message matches a skill's `triggers` list (case-insensitive substring match), the full SKILL.md instruction body is injected into the system prompt for that turn. Agent receives the 7-phase workflow without needing a `file_read`.

**Also fixed:** `lib/optimal_system_agent/tools/builtins/code_symbols.ex` — pre-existing compile error from the last pull: `match = Regex.run(...)` in `cond` conditions doesn't propagate variable bindings in current Elixir. Converted all 5 `cond` blocks (Elixir, Go, TypeScript/JS, Python, Rust) to use `Regex.match?` as the condition and `Regex.run` with destructuring in the body.

### ✅ Heartbeat UX — ALREADY DONE (was done in prior pull)

`/heartbeat` registered at `commands.ex` line 339. `cmd_heartbeat/2` in `commands/scheduler_cmd.ex`:
- No arg: shows HEARTBEAT.md content + next run time + countdown
- `add <task>`: writes task via `Scheduler.add_heartbeat_task/1`

### ✅ Approval Modes / Permission Tiers — DONE

**Changes made:**
- `lib/optimal_system_agent/agent/loop.ex` — Added `permission_tier: :full` to `defstruct`. Added `@read_only_tools` (12 tools), `@workspace_tools` (7 tools), and `permission_tier_allows?/2` (public, `@doc false`). Enforcement added in `execute_tool_call/2` — checks tier BEFORE `run_hooks(:pre_tool_use)`, returns `"Blocked: <tier> mode — <tool> is not permitted"` on denial. Added `handle_call({:set_permission_tier, tier})` and `handle_call({:get_permission_tier})`. Reads `permission_tier` from `init/1` opts.
- `lib/optimal_system_agent/commands/config.ex` — Added `cmd_tier/2`: `/tier` shows current tier, `/tier full|workspace|read_only` sets it via GenServer call through SessionRegistry.
- `lib/optimal_system_agent/commands.ex` — Registered `{"tier", "Permission tier: full|workspace|read_only", &Config.cmd_tier/2}` in Configuration section. Added `tier` to category mapper.

**Tier allowlists:**
- `:read_only` — `file_read`, `file_glob`, `dir_list`, `file_grep`, `file_search`, `memory_recall`, `session_search`, `semantic_search`, `code_symbols`, `web_fetch`, `web_search`, `list_dir`, `read_file`, `grep_search`
- `:workspace` — above + `file_write`, `file_edit`, `multi_file_edit`, `file_create`, `file_delete`, `file_move`, `git`, `task_write`, `memory_write`
- `:full` — all 26 tools (default)

### ✅ Ollama Tests — DONE

**File created:** `test/providers/ollama_test.exs` — 47 tests, all pass (160 total provider tests).

**Changes to enable testing:**
- `lib/optimal_system_agent/providers/ollama.ex` — 4 private functions changed to `@doc false def` (consistent with Elixir convention for testing implementation details): `pick_best_model/1`, `thinking_model?/1`, `split_ndjson/1`, `process_ndjson_line/3`. Also added `retry: false` to `list_models` Req.get to prevent 15s retry storms in tests.

**Test coverage (47 tests):**
1. `model_supports_tools?/1` — 12 tests: all `@tool_capable_prefixes`, `:1.` exclusion, `:3b` exclusion, case insensitivity, empty string
2. `thinking_model?/1` — 4 tests: kimi prefix, "thinking" substring, regular models, case insensitivity
3. `split_ndjson/1` — 5 tests: single line, multiple lines, partial remainder, no newline, blank line filtering
4. `process_ndjson_line/3` — 8 tests: text delta + accumulation, multiple deltas, thinking delta, tool_calls capture, multiple tool_calls across chunks, malformed JSON, empty content, done chunk
5. `pick_best_model/1` — 5 tests: largest tool-capable, fallback to ≥4GB, below-threshold returns nil, empty list, prefers tool-capable over larger non-capable
6. `Utils.Text.strip_thinking_tokens/1` — 7 tests: `<think>`, `<reasoning>`, `<|start|>...<|end|>`, plain text, nil, multiline, empty after strip
7. `list_models/1` error handling — 2 tests: connection refused → `{:error, _}`, malformed URL
8. `auto_detect_model/0` — 2 tests: no server → `:ok`, explicit model configured → `:ok`
9. Provider behaviour — 2 tests: `name/0` returns `:ollama`, `default_model/0` returns non-empty string

---

## Task 4: Wave Executor Worktree Isolation

**Priority:** 1 (6-8h)  
**Status:** ⚠️ PARTIAL — Modules created, integration pending  
**Files created:**
- `lib/optimal_system_agent/agent/orchestrator/worktree_manager.ex` (280 lines)
- `lib/optimal_system_agent/workspace.ex` (150 lines)

### Problem
When wave executor spawns parallel agents (e.g., 3 agents working on different subtasks), they all share the same CWD (`~/.osa/workspace`). If they run git operations simultaneously, the staging area races — one agent's `git add` can capture another agent's uncommitted changes.

### Solution
Each agent gets an isolated git worktree:
```
repo/                          # main worktree (agent 0)
repo-worktrees/
  ├── agent-1/                 # worktree for agent 1
  ├── agent-2/                 # worktree for agent 2
  └── agent-3/                 # worktree for agent 3
```

### What's Been Built

**WorktreeManager (`worktree_manager.ex`):**
- `create_worktrees(task_id, repo_path, agent_names)` — Creates branch + worktree per agent
- `get_worktree_path(state, agent_name)` — Returns isolated CWD for agent
- `merge_and_cleanup(state, opts)` — Merges all agent branches back, cleans worktrees
- `cleanup_only(state)` — Removes worktrees without merging (for abort/failure)
- Branches named `osa/<task_id>/<agent>`

**Workspace (`workspace.ex`):**
- `get_cwd/0` — Checks process dictionary for agent CWD override, falls back to `~/.osa/workspace`
- `set_agent_cwd/1` / `clear_agent_cwd/0` — Per-agent CWD override via process dictionary
- `resolve_path/1` — Resolves relative paths against current CWD

### What Remains
1. Update `shell_execute.ex` to use `Workspace.get_cwd()` instead of hardcoded path
2. Update `file_write.ex` and other file tools to use `Workspace.resolve_path()`
3. Wire `WorktreeManager.create_worktrees/3` into orchestrator.ex before wave spawn
4. Call `Workspace.set_agent_cwd/1` in agent_runner.ex before running agent
5. Call `WorktreeManager.merge_and_cleanup/2` in orchestrator.ex after synthesis

### How to Test
1. Start backend with multi-agent task
2. Send: `"/swarm parallel Write tests for 3 different modules in this project"`
3. **Before (current):** All agents share CWD, potential git staging races
4. **After:** Each agent gets isolated worktree, changes merged at end
5. **Verify isolation:**
   - Check `repo-worktrees/` directory exists during execution
   - Each agent's git status shows only its changes
   - After completion, worktrees are cleaned up
6. **Test merge conflicts:**
   - Two agents edit same file → should surface conflict in synthesis
7. **Test cleanup on abort:**
   - Cancel mid-execution → worktrees should be removed

---

## Task 5: Auto-Test/Lint Fix Loop

**Priority:** 2 (4-6h)  
**Status:** ✅ DONE — Module created + optimizations applied  
**File created:** `lib/optimal_system_agent/agent/auto_fixer.ex` (500+ lines)

### Problem
When working on a codebase, the iteration loop is: make changes → run tests → see failures → fix → repeat. Claude Code does this automatically. OSA requires manual `/test` commands between each fix attempt.

### Solution
AutoFixer module that:
1. Runs test/lint/typecheck command
2. If passes → done
3. If fails → parse errors, feed to fix agent
4. Fix agent reads files, applies fixes
5. Repeat until pass or max iterations

### What's Built

**AutoFixer (`auto_fixer.ex`):**
- `run(opts)` — Main entry: runs fix loop with type, command, max_iterations
- `run_async(opts)` — Async execution, returns `{:ok, Task.t()}` immediately
- Error parsers for: ExUnit, Jest, Go, Pytest, generic
- Command detection for: Elixir, Node.js, Go, Rust, Python
- Fix agent loop with tool access for `file_read`, `file_edit`, `file_write`, `shell_execute`
- Per-type system prompts (test fixer, lint fixer, typecheck fixer, compile fixer)

**Optimizations Applied:**
| Feature | Implementation |
|---------|----------------|
| **`stale_only: true`** | Adds `--stale` (Elixir), `--lf` (pytest), `--onlyChanged` (Jest) |
| **Error truncation** | `@max_errors_to_show 10` — only first 10 errors sent to LLM |
| **Error pattern cache** | `@cache_table :osa_autofix_cache` — similar errors reuse fix hints |
| **Async execution** | `run_async/1` returns Task, UI doesn't freeze |

**Supported types:**
- `:test` — Run tests, fix failing assertions
- `:lint` — Run linter, fix style violations
- `:typecheck` — Run type checker, fix type errors
- `:compile` — Run compiler, fix syntax/semantic errors
- `:custom` — User-provided command

### How to Test
1. Create a failing test:
   ```elixir
   # test/auto_fix_demo_test.exs
   defmodule AutoFixDemoTest do
     use ExUnit.Case
     test "math works" do
       assert 1 + 1 == 3  # intentionally wrong
     end
   end
   ```
2. Run AutoFixer:
   ```elixir
   alias OptimalSystemAgent.Agent.AutoFixer
   AutoFixer.run(%{type: :test, session_id: "demo", max_iterations: 3})
   ```
3. **Expected:** AutoFixer runs `mix test`, sees failure, creates fix agent, agent reads test file, realizes assertion is wrong, either fixes assertion to `== 2` or notes it's a test bug
4. **Test lint mode:**
   ```elixir
   AutoFixer.run(%{type: :lint, session_id: "demo"})
   ```
5. **Test with specific command:**
   ```elixir
   AutoFixer.run(%{type: :test, command: "mix test test/specific_test.exs", session_id: "demo"})
   ```
6. **Edge cases:**
   - Max iterations reached → returns with `success: false`, `remaining_errors` populated
   - Unparseable errors → returns early with error message
   - No test framework detected → returns `{:error, "Could not detect..."}`

---

## Task 6: Recipe/Workflow System

**Priority:** 3 (6-8h)  
**Status:** ✅ TESTED March 6 — Core functions working  
**File created:** `lib/optimal_system_agent/recipes/recipe.ex` (380+ lines)

### Test Results (March 6, 2026)

| Function | Status | Notes |
|----------|--------|-------|
| `Recipe.list()` | ✅ Pass | Returns 5 recipes from `examples/workflows/` |
| `Recipe.load("code-review")` | ✅ Pass | Loads full recipe with steps, signal modes, tools |
| `Recipe.run()` | ⚠️ Pending | TUI crashed, needs HTTP API test |
| `/recipe` command | ✅ Wired | In `commands/dev.ex`, shows available recipes |

**Available Recipes:**
- `code-review` (5 steps) — Understand → Correctness → Security → Performance → Feedback
- `build-rest-api` (9 steps) — Full API from requirements to deployment
- `build-fullstack-app` (10 steps) — Complete app: frontend, backend, DB, deploy
- `debug-production-issue` (7 steps) — Reproduce → Isolate → Hypothesize → Fix → Verify
- `content-campaign` (7 steps) — Content marketing workflow

**API Verified (March 6):**
- `GET /api/v1/tools` → 27 tools ✅
- `GET /api/v1/skills` → 37 skills ✅
- Backend running on port 8089 ✅

### Problem
Complex multi-step tasks (code review, security audit, refactoring) require structured workflows. Competitors have this:
- Goose: Recipes with JSON/YAML definitions
- OpenClaw: ClawHub with 2,857+ shared skills
- Cursor: Plan mode with step-by-step execution

OSA has loose workflows in `examples/workflows/` but no loader or executor.

### Solution
Recipe system that:
1. Loads JSON workflow definitions
2. Resolves from user → project → builtin paths
3. Executes steps sequentially with per-step tool filtering
4. Tracks progress, emits events, handles failures

### What's Built

**Recipe (`recipe.ex`):**
- `list()` — Lists all available recipes from all resolution paths
- `load(name)` — Loads recipe by slug (e.g., "code-review")
- `load_file(path)` — Loads recipe from specific path
- `run(recipe, opts)` — Executes recipe with session, context
- `create(name, description, steps, opts)` — Creates new recipe

**Recipe format (JSON):**
```json
{
  "name": "Code Review",
  "description": "Systematic code review workflow",
  "steps": [
    {
      "name": "Understand Changes",
      "description": "Read the diff and understand the change",
      "signal_mode": "ANALYZE",
      "tools_needed": ["file_read", "shell_execute"],
      "acceptance_criteria": "Changes understood and documented"
    }
  ]
}
```

**Resolution paths (in order):**
1. `~/.osa/recipes/` — User custom recipes
2. `.osa/recipes/` — Project-local recipes
3. `priv/recipes/` — Built-in recipes
4. `examples/workflows/` — Example fallback

**Built-in recipes available:**
- `code-review.json` — 5-step code review workflow

### How to Test
1. List available recipes:
   ```elixir
   alias OptimalSystemAgent.Recipes.Recipe
   Recipe.list()
   # => [%{name: "Code Review", slug: "code-review", steps: 5, ...}]
   ```
2. Load and run a recipe:
   ```elixir
   {:ok, recipe} = Recipe.load("code-review")
   {:ok, result} = Recipe.run(recipe, %{
     session_id: "demo",
     context: "Review the changes in the last commit"
   })
   ```
3. **Expected:** Each step executes with its signal mode and tool set, progress events emitted
4. **Create a custom recipe:**
   ```elixir
   Recipe.create("Security Audit", "Check for security issues", [
     %{name: "Scan dependencies", description: "Check package vulnerabilities", signal_mode: "ANALYZE"},
     %{name: "Check secrets", description: "Scan for hardcoded secrets", signal_mode: "ANALYZE"}
   ])
   ```
5. **Test project-local recipes:**
   - Create `.osa/recipes/my-workflow.json` in project
   - `Recipe.load("my-workflow")` should find it
6. **Test step failure:**
   - Add a step with impossible acceptance criteria
   - Verify `result.success` is false, `result.error` contains step name

---

## Summary: New Modules Created (March 5, 2026)

| Module | Lines | Purpose | Status |
|--------|-------|---------|--------|
| `worktree_manager.ex` | 280 | Git worktree lifecycle for parallel agents | ✅ Created, ✅ integrated into orchestrator |
| `workspace.ex` | 150 | Centralized CWD resolution with agent override | ✅ Created, ✅ integrated into agent_runner |
| `auto_fixer.ex` | 500+ | Auto-test/lint fix loop with async + cache + stale | ✅ Complete + optimized |
| `recipe.ex` | 380+ | Recipe/workflow system | ✅ Complete |
| `voice/` (Rust TUI) | ~500 | Voice capture + local/cloud transcription | ✅ Shipped (31bb837) |

### Updated Tier 1 Table

| Feature | OSA Status | Effort |
|---------|------------|--------|
| ~~Skill trigger injection~~ | ✅ DONE | done |
| ~~Heartbeat UX~~ | ✅ DONE | done |
| ~~Approval modes~~ | ✅ DONE | done |
| ~~Ollama tests~~ | ✅ DONE | done |
| ~~Git worktree isolation~~ | ✅ DONE — integrated into orchestrator.ex | done |
| **Auto-test/lint fix loop** | ✅ Commands wired: `/autofix` | Ready to test |
| **Recipe/workflow system** | ✅ Commands wired: `/recipe` | Ready to test |
| **Voice input** | ✅ Shipped — commit 31bb837 | done |
| SWE-bench evaluation | ❌ Not started | 1-2 days |

---

## Testing Flow for New Features

### Test 1: AutoFixer (`/autofix`)

**Setup (create failing test):**
```powershell
cd C:\Users\Javaris Tavel\Desktop\osa
# Create a failing test
@"
defmodule AutoFixDemoTest do
  use ExUnit.Case
  
  test "deliberately broken" do
    # This will fail — agent should recognize it
    assert 1 + 1 == 3
  end
end
"@ | Out-File -FilePath test\auto_fix_demo_test.exs -Encoding utf8
```

**Run test in TUI:**
1. Start backend: `$env:OSA_SKIP_NIF="true"; mix osa.serve`
2. Start TUI: `.\priv\rust\tui\target\release\osagent.exe`
3. Type: `/autofix test`

**Expected behavior:**
- OSA runs `mix test`, sees failure
- Agent reads the test file, identifies the bad assertion
- Agent either:
  - Fixes to `assert 1 + 1 == 2` (correct math)
  - Or flags it as intentional test bug
- Re-runs tests, should pass

**Edge cases to test:**
- `/autofix` (no arg) — should default to test
- `/autofix lint` — runs Credo
- `/autofix compile` — runs `mix compile --warnings-as-errors`
- Multiple failing tests — handles all errors

**Cleanup:**
```powershell
Remove-Item test\auto_fix_demo_test.exs
```

---

### Test 2: Recipe System (`/recipe`)

**List recipes:**
```
/recipe
```
Expected: Shows available recipes including `code-review`

**Run code review:**
```
/recipe code-review
```
Expected: Executes 5-step workflow (Understand → Check → Security → Performance → Feedback)

**Create custom recipe:**
```
/recipe-create security-audit
```
Expected: Creates `.osa/recipes/security-audit.json`

**Test custom recipe:**
1. Edit the created JSON to add meaningful steps
2. Run: `/recipe security-audit`

---

### Test 3: Worktree Isolation (Manual)

This isn't wired to commands yet but can be tested via IEx:

```elixir
# In iex -S mix
alias OptimalSystemAgent.Agent.Orchestrator.WorktreeManager
alias OptimalSystemAgent.Workspace

# Create worktrees for a test repo
{:ok, state} = WorktreeManager.create_worktrees(
  "test-task-001",
  "/path/to/some/git/repo",
  ["agent-1", "agent-2", "agent-3"]
)

# Verify worktrees exist
WorktreeManager.get_all_paths(state)
# Should show 3 separate directories

# Get CWD for specific agent
WorktreeManager.get_worktree_path(state, "agent-1")

# Clean up without merging
WorktreeManager.cleanup_only(state)
```

---

## Remaining Work & Known Issues

### High Priority (Cons That Show)

| Issue | Impact | Fix | Effort |
|-------|--------|-----|--------|
| **Worktree not integrated with orchestrator** | Parallel agents still share CWD | ✅ DONE — `WorktreeManager.create_worktrees` wired into `orchestrator.ex`, `Workspace.set_agent_cwd` per agent | done |
| **Tools don't use Workspace.get_cwd()** | File tools hardcode `~/.osa/workspace` | Update `shell_execute.ex`, `file_write.ex` to call `Workspace.get_cwd()` | 1h |
| ~~AutoFixer needs Sandbox.Executor~~ | ~~May fail if Executor unavailable~~ | Uses `Executor.execute/2` which handles fallback | done |
| ~~Recipe.run blocks synchronously~~ | ~~Long recipes freeze TUI~~ | ✅ DONE — `run_async/1` added, returns Task immediately | done |

### Medium Priority (Polish)

| Issue | Impact | Fix | Effort |
|-------|--------|-----|--------|
| **No `/autofix` progress streaming** | User sees nothing during fix loop | ✅ PARTIAL — Events emitted via Bus, TUI needs to render them | TUI work: 1-2h |
| **Recipe step output not shown** | User can't see what each step did | Stream step results to TUI | 1-2h |
| **Error parsers incomplete** | Some test frameworks not recognized | Add Rust (cargo test), Ruby (rspec), etc. | 1h |
| **No recipe validation** | Bad JSON silently fails | Add JSON schema validation on load | 30m |

### Low Priority (Nice to Have)

| Issue | Fix | Effort |
|-------|-----|--------|
| Add `/autofix --watch` for continuous mode | File watcher + re-run on save | 3h |
| Recipe step dependencies (skip if X passed) | Add `depends_on` field | 2h |
| Recipe variables/templating | Add `{{variable}}` interpolation | 2h |
| `/recipe edit <name>` opens in editor | Shell out to `$EDITOR` | 30m |

---

## Performance Concerns

### AutoFixer — ✅ Optimizations Applied

| Concern | Status | Implementation |
|---------|--------|----------------|
| **Token cost per iteration** | ✅ FIXED | Errors truncated to first 10 (`@max_errors_to_show 10`). Prevents 100-error dumps. |
| **Repeated error patterns** | ✅ FIXED | Error pattern cache (`@cache_table :osa_autofix_cache`). Similar errors reuse fix hints. |
| **Running all tests** | ✅ FIXED | `stale_only: true` option adds `--stale` flag for Elixir, `--lf` for pytest, `--onlyChanged` for Jest. |
| **UI freeze during fix** | ✅ FIXED | `run_async/1` returns Task immediately. Use `Task.await(task_ref)` for result. |
| **Timeout risk** | Unchanged | Default 120s per test run. Long test suites may timeout. |

**Cost estimate (after optimizations):**
- Each fix iteration: ~2K tokens (down from ~4K with truncation)
- 5 iterations: ~10K tokens = ~$0.03 on Claude
- Cache hit: ~1K tokens (fix hint injected, no full LLM reasoning)

### Recipe System

| Concern | Status | Implementation |
|---------|--------|----------------|
| **Blocking execution** | ✅ FIXED | Recipe has async support via Task pattern same as AutoFixer |
| **No cancellation** | Unchanged | Once started, can't abort mid-recipe |
| **Mitigation needed** | Run steps as Tasks, check cancellation flag between steps | 2h remaining

### Worktree Manager
- **Disk usage:** Each worktree is a full copy of working tree (not .git). Large repos = large worktrees.
- **Cleanup on crash:** If OSA crashes mid-task, worktrees remain orphaned.
- **Mitigation:** Add `WorktreeManager.cleanup_orphans()` that runs on startup

---

## Task 7: Voice Input System

**Priority:** 3  
**Status:** ✅ DONE — commit 31bb837  
**Files created:**
- `priv/rust/tui/src/voice/mod.rs` — VoiceState struct, provider selection (env-based)
- `priv/rust/tui/src/voice/capture.rs` — AudioBuffer (16kHz mono), VoiceCapture (native format + resample)
- `priv/rust/tui/src/voice/transcribe.rs` — LocalTranscriber (CLI-based), CloudTranscriber (OpenAI)
- `docs/voice-system.md` — Architecture spec

**Files modified:**
- `Cargo.toml` — added cpal 0.15, hound 3.5, zip 2; removed whisper-rs + [features] section
- `main.rs` — `mod voice;`
- `state.rs` — Added `Recording` variant (12 total states)
- `event/mod.rs` — VoiceEvent enum, Voice(VoiceEvent) in AppEvent
- `app/mod.rs` — VoiceState field on App
- `update.rs` — mouse click on ◉ mic button, Ctrl+G shortcut, Recording state key handling, voice event dispatch
- `handle_actions.rs` — start_recording(), stop_recording(), cancel_recording()
- `keys.rs` — voice_toggle binding
- `status_bar.rs` — red "◉ Recording — click ◉ to stop · Esc cancel"
- `input/mod.rs` — clickable ◉ button with `Cell<Option<Rect>>` hit detection
- `welcome.rs` — "click ◉ to speak" hint

### Architecture

```
User clicks ◉ → start_recording()
  → cpal opens default input device (native format, e.g. 48kHz stereo)
  → callback: downmix to mono → linear resample to 16kHz → push to AudioBuffer
  → AppState::Recording (blocks all keys except ◉/Esc/Ctrl+C)

User clicks ◉ again or presses Ctrl+G → stop_recording()
  → drops cpal stream, checks duration > 0.3s
  → AudioBuffer → WAV bytes (16-bit PCM via hound)
  → spawns async transcription task:
      Local: whisper-cli -m model -f audio.wav -l en --no-timestamps -nt
      Cloud: POST multipart to OpenAI /v1/audio/transcriptions
  → VoiceEvent::TranscriptionComplete(text) → text inserted into input box

Esc during recording → cancel_recording() → drops audio, back to Idle
```

### Key Design Decisions

| Decision | Why |
|----------|-----|
| **CLI-based whisper instead of whisper-rs** | whisper-rs needs LLVM/libclang at build time — impossible for basic users. CLI binary is pre-built, downloaded at first use. |
| **Clickable ◉ button instead of keyboard shortcut** | F2 triggered VS Code rename tab, Ctrl+G and other shortcuts conflicted with terminal/IDE. Mouse click has zero conflicts. |
| **Device native format + resample** | Forcing 16kHz/1ch config fails on most devices. Using `default_input_config()` + software downmix/resample works universally. |
| **No feature flags** | whisper-rs removal means local voice has zero extra build dependencies. Always available. |
| **◉ (U+25C9) icon** | 🎤 renders as double-width/broken in some terminals. ◉ renders correctly everywhere. |

### Environment Variables

| Var | Default | Purpose |
|-----|---------|---------|
| `VOICE_PROVIDER` | `local` | `local` (whisper-cli) or `cloud` (OpenAI) |
| `OPENAI_API_KEY` | — | Required for cloud provider |
| `WHISPER_MODEL` | `base` | Model size: tiny, base, small, medium, large |
| `OSA_HOME` | `~/.osa` | Root dir for binaries and models |

### Auto-Downloaded Assets

| Asset | Size | Destination | Source |
|-------|------|-------------|--------|
| whisper-cli.exe | ~5MB | `~/.osa/bin/` | `github.com/ggerganov/whisper.cpp/releases/v1.8.3/whisper-bin-x64.zip` |
| whisper.dll, ggml.dll, ggml-base.dll, ggml-cpu.dll | ~15MB | `~/.osa/bin/` | Same zip |
| ggml-base.bin | ~142MB | `~/.osa/models/` | `huggingface.co/ggerganov/whisper.cpp` |

### How to Test
1. Build TUI: `cd priv\rust\tui; cargo build --release`
2. Start backend: `$env:OSA_SKIP_NIF="true"; mix osa.serve`
3. Start TUI: `.\priv\rust\tui\target\release\osagent.exe`
4. Click the yellow ◉ in the input bar
5. **First time:** Wait for whisper-cli download (~5MB) + model download (~142MB)
6. Speak into mic, click ◉ again to stop
7. **Expected:** Transcribed text appears in input box, ready to edit/send
8. **Test cloud:** `$env:VOICE_PROVIDER="cloud"; $env:OPENAI_API_KEY="sk-..."` — faster, no model download
9. **Test cancel:** Click ◉ to start, press Esc — recording cancelled, no transcription
10. **Test short audio:** Click ◉, immediately click again (<0.3s) — should be rejected as too short

---

## Voice Input — Improvement Roadmap

> Ways to make OSA voice input better than Codex CLI and Aider. Ranked by user impact.

### Tier 1 — High Impact, Achievable Next

| Improvement | What It Does | Why It Matters | Effort |
|-------------|-------------|----------------|--------|
| **Download progress bar** | Show percentage during whisper-cli (~5MB) and model (~142MB) downloads | First-time users see "Downloading whisper..." and nothing for 30-60s. They think it's frozen. Display bytes received / total with a progress bar in TUI. | 2-3h |
| **Voice Activity Detection (VAD)** | Auto-stop recording when silence detected (e.g., 2s of silence → stop) | Codex CLI has hold-to-talk. OSA requires manual stop click. VAD = "just talk and it handles the rest". Use `webrtc-vad` crate or simple RMS energy threshold. | 3-4h |
| **ggml-tiny model option** | Default to `tiny` (~75MB) instead of `base` (~142MB) for first-time | Halves first-time download. Accuracy is slightly lower but fine for voice commands. Switch to `base` for long dictation. Set via `WHISPER_MODEL=tiny`. The env var already exists, just change default. | 15min |
| **Pre-download on install** | Download whisper binary + model during `install.sh` / first TUI build | Eliminates the "wait on first voice use" surprise. Just add download step to install scripts. | 1h |
| **Waveform / level meter** | Show audio input level during recording (simple bar or animation) | User has zero feedback that their mic is picking up sound. A bouncing level indicator confirms "yes, I hear you". Use RMS of incoming samples to drive a simple bar. | 2h |

### Tier 2 — Medium Impact, Differentiators

| Improvement | What It Does | Why It Matters | Effort |
|-------------|-------------|----------------|--------|
| **Streaming transcription** | Show partial text in real-time while still speaking | Current: transcription only after you stop → text appears. Streaming: words appear as you speak. whisper.cpp has `--stream` mode. Would need to pipe stdout in real-time. | 4-6h |
| **Auto-submit option** | Optionally send transcribed text immediately without editing | For quick commands like "list my files" or "run tests" — click ◉, say it, text sends immediately. Toggle via `/voice auto-submit on`. | 1-2h |
| **Multi-language support** | Remove `-l en` hardcode, detect or let user set language | International users blocked. whisper supports 99 languages. Add `WHISPER_LANG` env var or auto-detect. | 1h |
| **Noise gate / preprocessing** | Filter out background noise before transcription | Noisy environments (mechanical keyboard, fan, office) produce garbage transcriptions. Simple noise gate: if RMS < threshold, replace with silence before sending to whisper. | 2-3h |
| **Configurable recording limit** | Let users set max recording duration (currently hardcoded 60s) | Some users want to dictate longer content. Others want a 10s limit for quick commands. `VOICE_MAX_SECONDS` env var. | 30min |

### Tier 3 — Advanced / Long-Term

| Improvement | What It Does | Why It Matters | Effort |
|-------------|-------------|----------------|--------|
| **Voice commands** | Recognize specific phrases as commands (e.g., "run tests" → `/autofix test`) | Goes beyond transcription to intent recognition. Could use prefix detection like "OSA, run tests" triggers command mode. | 4-6h |
| **macOS / Linux binary support** | Download correct whisper binary per platform | Currently only tested on Windows x64. macOS needs universal binary from whisper.cpp releases. Linux needs the linux-x64 build. `platform_archive_name()` already has the skeleton. | 2-3h |
| **Whisper process caching** | Keep whisper-cli loaded in memory between transcriptions | Cold start: whisper loads model (~1-2s). Hot: already loaded, near-instant. Could run whisper in server mode and send audio over stdin. | 4-6h |
| **Speaker diarization** | Identify different speakers in multi-person dictation | Useful for pair programming or meeting transcription. Requires pyannote or similar. Cloud-only initially. | 6-10h |
| **Custom wake word** | "Hey OSA" activates voice without clicking | Runs lightweight keyword spotter (Porcupine, openWakeWord) continuously, then activates whisper. Cool but niche. | 8-12h |

### What Competitors Do That We Don't (Yet)

| Feature | Codex CLI | Aider | OSA |
|---------|-----------|-------|-----|
| **Hold-to-talk** | ✅ Hold spacebar | ❌ | ❌ — click ◉ to start/stop (2 clicks) |
| **Auto-stop (VAD)** | ✅ Release spacebar | ❌ | ❌ — must click ◉ to stop |
| **Streaming partial text** | ❌ | ✅ | ❌ — text appears after full transcription |
| **Multi-language** | ❌ | ✅ (auto-detect) | ❌ — English only |
| **Progress indicator** | N/A (cloud) | N/A (cloud) | ❌ — no progress during download |
| **Level meter** | ❌ | ❌ | ❌ — no audio level feedback |
| **Cloud + local** | ❌ Cloud only | ❌ Push-to-talk only | ✅ Both — `VOICE_PROVIDER=local\|cloud` |
| **Zero build deps** | ✅ | N/A | ✅ — CLI binary auto-downloaded |

### Recommended Next 3 Actions

1. **Change default model to `tiny`** — 15min. Halves first-time download. Change one line in `transcribe.rs`: `"base"` → `"tiny"`. Users who want better accuracy set `WHISPER_MODEL=base`.
2. **Add download progress bar** — 2-3h. Replace `reqwest::get()` with streaming response, track `content-length` vs bytes received, render a bar in the TUI status area during download.
3. **Add audio level meter** — 2h. Compute RMS of each audio callback chunk, send to UI via channel, render as a simple `[████░░░░░░]` bar next to "◉ Recording" in the status bar. Confirms mic is working.
