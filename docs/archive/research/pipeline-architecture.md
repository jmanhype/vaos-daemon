# OSA Prompt Pipeline Architecture — Full Tree + OpenCode Comparison

> Generated 2026-02-28. Traces every path from user keystroke → backend → LLM → display.

---

## 1. Complete Message Flow Tree

```
USER TYPES TEXT (Go TUI: app.go:handleIdleKey)
│
├─ [1] SLASH COMMAND ("/help", "/agents", "/model", etc.)
│   │
│   ├─ [1a] UI-ONLY COMMANDS (no backend)
│   │   ├─ /clear    → chat.Clear(), stay StateIdle
│   │   ├─ /exit     → tea.Quit
│   │   ├─ /theme    → cycle theme, re-render
│   │   ├─ /bg       → move current task to background
│   │   ├─ /session  → session picker UI
│   │   └─ /model    → StateModelPicker (arrow-key navigation)
│   │
│   └─ [1b] BACKEND COMMANDS
│       │   POST /api/v1/commands/execute {command, arg, session_id}
│       │
│       ├─ Backend: Commands.execute(cmd, arg, session_id)
│       │   Returns: {kind, output, action}
│       │
│       └─ TUI: handleCommand()
│           ├─ kind="text"   → chat.AddSystemMessage(output)
│           ├─ kind="error"  → chat.AddSystemError(output)
│           ├─ kind="prompt" → submitPrompt(output) [feeds into path 2]
│           └─ kind="action" → handleCommandAction(action, output)
│               ├─ :new_session  → closeSSE, new session ID, fresh chat
│               ├─ :switch_model → fetch models, show picker
│               └─ :load_session → load history, display messages
│
├─ [2] NORMAL MESSAGE (everything without "/" prefix)
│   │
│   │   submitInput(text) → app.go:765
│   │     state = StateProcessing
│   │     activity.Start()        (spinner visible)
│   │     streamBuf.Reset()       (clear streaming buffer)
│   │     responseReceived = false (dedup flag)
│   │     cancelled = false       (cancel flag)
│   │
│   ├─── HTTP: POST /orchestrate {input, session_id, skip_plan: false}
│   │    │
│   │    │   api.ex:167 → POST /orchestrate handler
│   │    │
│   │    ├─ [2a] SESSION INIT FAILURE
│   │    │   Session.ensure_loop() returns {:error, _}
│   │    │   → HTTP 503 {error: "session_unavailable"}
│   │    │   → TUI: handleOrchestrate(Err) → chat.AddSystemError()
│   │    │
│   │    └─ [2b] SESSION OK → Loop.process_message(sid, input, opts)
│   │        │
│   │        │   loop.ex:93 — handle_call({:process, message, opts})
│   │        │
│   │        ├─ PHASE 1: SIGNAL CLASSIFICATION (<1ms)
│   │        │   classifier.ex → classify_fast(message, channel)
│   │        │   Returns: %Signal{mode, genre, type, format, weight}
│   │        │   Also kicks: classify_async() → background LLM enrichment
│   │        │   Emits: Bus.emit(:signal_classified, ...)
│   │        │
│   │        ├─ PHASE 2: NOISE FILTER
│   │        │   noise_filter.ex → filter(message)
│   │        │   │
│   │        │   ├─ [2b-i] {:noise, reason}
│   │        │   │   Reasons: :empty, :too_short, :pattern_match, :low_weight
│   │        │   │   Memory.append(user msg + ack)
│   │        │   │   Return {:ok, "👍"} — NO LLM call
│   │        │   │   → TUI shows thumbs up, back to idle
│   │        │   │
│   │        │   └─ [2b-ii] {:signal, weight} — proceed
│   │        │
│   │        ├─ PHASE 3: COMPACTION
│   │        │   Compactor.maybe_compact(messages)
│   │        │   If >3000 tokens: summarize old messages
│   │        │
│   │        ├─ PHASE 4: PLAN MODE CHECK
│   │        │   should_plan?(signal, state) when ALL:
│   │        │     - plan_mode_enabled == true
│   │        │     - signal.mode ∈ [:build, :execute, :maintain]
│   │        │     - signal.weight >= 0.75
│   │        │     - signal.type ∈ ["request", "general"]
│   │        │     - skip_plan == false
│   │        │   │
│   │        │   ├─ [2b-iii] PLAN MODE TRIGGERS
│   │        │   │   context = Context.build(state, signal)
│   │        │   │   LLM call: tools=[], temperature=0.3
│   │        │   │   Emits: Bus.emit(:agent_response, response_type: "plan")
│   │        │   │   │
│   │        │   │   ├─ LLM OK → {:plan, plan_text, signal}
│   │        │   │   │   → API: HTTP 200 {response_type: "plan", output: plan_text}
│   │        │   │   │   → TUI: handleOrchestrate() sees "plan"
│   │        │   │   │         plan.SetPlan(text), state = StatePlanReview
│   │        │   │   │
│   │        │   │   │   USER DECISION (plan.go → PlanDecision):
│   │        │   │   │   ├─ [Y] APPROVE
│   │        │   │   │   │   orchestrateWithOpts("Approved. Execute the plan.", true)
│   │        │   │   │   │   skip_plan=true → bypasses should_plan?
│   │        │   │   │   │   → Full ReAct loop with tools [path 2b-iv]
│   │        │   │   │   │
│   │        │   │   │   ├─ [N] REJECT
│   │        │   │   │   │   chat.AddSystemMessage("Plan rejected.")
│   │        │   │   │   │   → StateIdle, input focused
│   │        │   │   │   │
│   │        │   │   │   └─ [E] EDIT
│   │        │   │   │       input.SetValue("Regarding the plan: ")
│   │        │   │   │       → StateIdle, user types refinement
│   │        │   │   │
│   │        │   │   └─ LLM FAIL → fallthrough to normal execution [path 2b-iv]
│   │        │   │
│   │        │   └─ [2b-iv] NORMAL ReAct LOOP
│   │        │       │
│   │        │       │   run_loop(state) → do_run_loop(state)
│   │        │       │
│   │        │       ├─ PHASE 5: SYSTEM PROMPT ASSEMBLY (context.ex)
│   │        │       │   Token budget: max_context - 4096(reserve) - conversation
│   │        │       │   │
│   │        │       │   ├─ TIER 1 (CRITICAL — always full):
│   │        │       │   │   Soul.system_prompt(signal)  ← identity + signal overlay
│   │        │       │   │   tool_process_block()        ← how to call tools
│   │        │       │   │   runtime_block()             ← time, git, workspace
│   │        │       │   │   plan_mode_block()           ← (if plan_mode active)
│   │        │       │   │   environment_block()         ← env vars, host
│   │        │       │   │
│   │        │       │   ├─ TIER 2 (HIGH — 40% of budget):
│   │        │       │   │   tools_block()               ← tool signatures
│   │        │       │   │   rules_block()               ← project rules
│   │        │       │   │   memory_block_relevant()     ← query-relevant memories
│   │        │       │   │   workflow_block()             ← active workflow
│   │        │       │   │   task_state_block()           ← current tasks
│   │        │       │   │
│   │        │       │   ├─ TIER 3 (MEDIUM — 30% of budget):
│   │        │       │   │   Soul.user_block()           ← USER.md profile
│   │        │       │   │   intelligence_block()        ← communication profiler
│   │        │       │   │   cortex_block()              ← cortex bulletin
│   │        │       │   │
│   │        │       │   └─ TIER 4 (LOW — remaining budget):
│   │        │       │       os_templates_block()        ← OS-specific guidance
│   │        │       │       machines_block()            ← machine addendums
│   │        │       │
│   │        │       ├─ PHASE 6: LLM CALL (streaming)
│   │        │       │   llm_chat_stream(messages, tools, temperature=0.7)
│   │        │       │   Emits per token: Bus.emit(:streaming_token)
│   │        │       │   Emits thinking:  Bus.emit(:thinking_delta)
│   │        │       │   │
│   │        │       │   ├─ {:ok, content, tool_calls=[]}
│   │        │       │   │   FINAL RESPONSE → return content
│   │        │       │   │
│   │        │       │   ├─ {:ok, content, tool_calls=[...]}
│   │        │       │   │   │
│   │        │       │   │   ├─ PHASE 7: TOOL EXECUTION (per tool_call)
│   │        │       │   │   │   │
│   │        │       │   │   │   ├─ PRE-HOOKS (sync — can block)
│   │        │       │   │   │   │   security_check → blocks dangerous cmds
│   │        │       │   │   │   │   budget_guard   → blocks if over budget
│   │        │       │   │   │   │   │
│   │        │       │   │   │   │   ├─ {:blocked, reason} → "Blocked: ..."
│   │        │       │   │   │   │   └─ :ok → proceed
│   │        │       │   │   │   │
│   │        │       │   │   │   ├─ Tools.execute(name, args)
│   │        │       │   │   │   │   ├─ {:ok, content}  → string result
│   │        │       │   │   │   │   ├─ {:ok, {:image, ...}} → base64 image
│   │        │       │   │   │   │   └─ {:error, reason} → "Error: ..."
│   │        │       │   │   │   │
│   │        │       │   │   │   ├─ POST-HOOKS (async — fire and forget)
│   │        │       │   │   │   │   cost_tracker, telemetry, learning_capture
│   │        │       │   │   │   │
│   │        │       │   │   │   ├─ EMIT EVENTS:
│   │        │       │   │   │   │   Bus.emit(:tool_call, phase: :start)
│   │        │       │   │   │   │   Bus.emit(:tool_call, phase: :end)
│   │        │       │   │   │   │   Bus.emit(:tool_result, ...)
│   │        │       │   │   │   │
│   │        │       │   │   │   └─ Append tool result to messages
│   │        │       │   │   │
│   │        │       │   │   └─ LOOP BACK → run_loop(state) [Phase 5]
│   │        │       │   │       iteration++ (max 30)
│   │        │       │   │
│   │        │       │   └─ {:error, reason}
│   │        │       │       │
│   │        │       │       ├─ context_overflow? AND iteration < 3
│   │        │       │       │   Compact messages, retry [Phase 5]
│   │        │       │       │
│   │        │       │       ├─ context_overflow? AND iteration >= 3
│   │        │       │       │   "I've exceeded the context window..."
│   │        │       │       │
│   │        │       │       └─ other error
│   │        │       │           "I encountered an error..."
│   │        │       │
│   │        │       └─ PHASE 8: FINALIZATION
│   │        │           Memory.append(assistant response)
│   │        │           emit_context_pressure(state)
│   │        │           Bus.emit(:agent_response, response_type: nil)
│   │        │           Return {:ok, response}
│   │        │
│   │        └─ API RESPONSE MAPPING:
│   │            {:plan, text, signal}  → HTTP 200 {response_type: "plan"}
│   │            {:ok, response}        → HTTP 200 {response_type: "response"}
│   │            {:filtered, signal}    → HTTP 422 {error: "signal_filtered"}
│   │            {:error, reason}       → HTTP 500 {error: "agent_error"}
│   │
│   └─── CONCURRENT: SSE Stream /api/v1/stream/:session_id
│        │
│        │   sse.go: ListenCmd → parseSSEEvent → p.Send(msg)
│        │
│        ├─ streaming_token  → streamBuf append, live text display
│        ├─ thinking_delta   → thinking indicator in activity view
│        ├─ llm_request      → "Iteration N" spinner
│        ├─ tool_call        → tool name + args in activity panel
│        ├─ tool_result      → result preview (200 chars)
│        ├─ llm_response     → token counts + timing in status bar
│        ├─ signal_classified → mode/genre/type badge
│        ├─ context_pressure → "Context: 45%" in status bar
│        ├─ agent_response   → FINAL response (see dedup below)
│        │   ├─ response_type="plan" → plan.SetPlan(), StatePlanReview
│        │   └─ response_type=""     → chat.AddAgentMessage()
│        ├─ orchestrator_*   → multi-agent progress panel
│        ├─ swarm_*          → swarm status display
│        ├─ hook_blocked     → system error toast
│        └─ budget_*         → budget warning toast
│
├─ [3] USER CANCELS (Ctrl+C during StateProcessing)
│   cancelled = true
│   activity.Stop()
│   state = StateIdle
│   Late responses silently dropped (both REST and SSE check cancelled flag)
│
└─ [4] SPECIAL KEYS
    ├─ Ctrl+K    → StatePalette (command palette overlay)
    ├─ Ctrl+O    → toggle expanded activity view
    ├─ Ctrl+T    → toggle thinking display
    ├─ Ctrl+N    → new session
    ├─ Ctrl+L    → clear screen
    ├─ Up/Down   → scroll chat history
    └─ Ctrl+C    → cancel (if processing) or quit (if idle)
```

---

## 2. REST vs SSE Race Condition (Dedup Logic)

Both REST response and SSE `agent_response` deliver the final output independently:

```
                REST POST          SSE Stream
                   │                    │
                   ▼                    ▼
T=0ms        send request         listening...
T=100ms           │            streaming_token →→→ streamBuf
T=200ms           │            tool_call →→→ activity panel
T=500ms      HTTP 200 arrives        │
             handleOrchestrate()     │
             responseReceived=true   │
             chat.AddAgentMessage()  │
T=600ms           │            agent_response arrives
                  │            handleClientAgentResponse()
                  │            CHECK: responseReceived? YES → DROP
                  │
          ═══════════════════════════════════
          FLAG: responseReceived prevents duplicates
          FIRST responder wins, second is silently dropped
```

---

## 3. TUI Display States

| State | Header | Main Area | Status Bar | Input |
|---|---|---|---|---|
| **Connecting** | OSA logo | "Connecting..." (retry in 5s) | — | disabled |
| **Banner** | OSA logo | Version, provider, model, tools, workspace | — | disabled |
| **Idle (empty)** | Header | Welcome tips | signal + tokens | focused |
| **Idle (chat)** | Header | Chat history (scrollable) | signal + tokens + context% | focused |
| **Processing** | Header | Chat + inline activity view | active indicator | blurred (Ctrl+C) |
| **PlanReview** | Header | Chat + plan text | — | Y/N/E keys only |
| **ModelPicker** | Header | Picker list (arrow keys) | — | search filter |
| **Palette** | Header | Command palette overlay | — | search input |

---

## 4. System Prompt Assembly (context.ex) — Tier Budget

```
┌────────────────────────────────────────────────────────┐
│                  MAX CONTEXT: 128,000 tokens            │
├─────────────┬──────────────────────────────────────────┤
│ RESPONSE    │ 4,096 tokens (reserved)                   │
│ RESERVE     │                                           │
├─────────────┼──────────────────────────────────────────┤
│ CONVERSATION│ estimate_tokens(messages)                  │
│ HISTORY     │ (grows with each turn)                    │
├─────────────┼──────────────────────────────────────────┤
│             │ ┌─ TIER 1: CRITICAL (always full)        │
│             │ │  Soul + tool_process + runtime          │
│             │ │  + plan_mode + environment              │
│  SYSTEM     │ ├─ TIER 2: HIGH (40% of remaining)       │
│  PROMPT     │ │  tools + rules + memory + workflow      │
│  BUDGET     │ │  + task_state                           │
│             │ ├─ TIER 3: MEDIUM (30% of remaining)     │
│  (dynamic)  │ │  user_profile + intelligence + cortex   │
│             │ ├─ TIER 4: LOW (leftover)                │
│             │ │  os_templates + machines                │
│             │ └─ (blocks truncated if over budget)      │
└─────────────┴──────────────────────────────────────────┘
```

---

## 5. OpenCode vs OSA — Pipeline Comparison

| Dimension | OpenCode (TypeScript) | OSA (Elixir + Go TUI) |
|---|---|---|
| **Signal Classification** | None — LLM decides behavior | Dual: deterministic (<1ms) + async LLM enrichment |
| **Noise Filter** | None — every message hits LLM | Two-tier: pattern + weight gating |
| **Plan Mode Trigger** | LLM calls `EnterPlanMode` tool | Classifier-driven: automatic when mode∈build,execute,maintain AND weight≥0.75 |
| **Plan Mode Prompt** | Separate `plan.txt` file, no tools | Same prompt + plan overlay injected, tools=[] |
| **Plan→Build Switch** | Synthetic message: "mode changed to build" | `skip_plan: true` flag bypasses should_plan? |
| **System Prompt** | Provider-specific .txt files (anthropic.txt, beast.txt, gemini.txt) | Single tiered builder (context.ex) with signal-aware Soul overlay |
| **Prompt Caching** | Collapse to 2-part array | Not implemented (opportunity) |
| **Tool Resolution** | Registry + MCP + Skills + StructuredOutput | Registry only (Tools.list_tools_direct) |
| **Tool Gating** | `tool_call: false` on model → no tools sent | Ollama: size≥7GB AND known prefix |
| **Streaming** | AI SDK `streamText()` | Custom `chat_stream` + process dictionary |
| **Context Management** | Compaction agent (dedicated LLM call) | Heuristic compaction (Compactor.maybe_compact) |
| **Instruction Files** | AGENTS.md, CLAUDE.md, CONTEXT.md (walk up dirs) | rules_block() from priv/rules/**/*.md |
| **Agents** | 7 native (build, plan, explore, compaction, title, summary, general) | 22+ roster (backend-go, frontend-react, debugger, etc.) |
| **Mode Switching** | Synthetic message injection into conversation | System prompt rebuild each iteration |
| **Permission Model** | Per-agent allow/deny/ask per tool | Pre-tool hooks (security_check, budget_guard) |
| **Response Delivery** | Single path (SSE from session processor) | Dual path: REST + SSE with dedup flag |

---

## 6. Issues Identified in Our Pipeline

### Critical

1. **No prompt caching** — OpenCode collapses system prompt to 2 parts for Anthropic cache hits. We rebuild the full system prompt every iteration. With 5+ iterations per request, this wastes significant tokens.

2. **Plan mode `agent_response` event had no `response_type`** — Fixed in this session. Before the fix, SSE path used string matching (`## Plan`) which broke on any plan that didn't start with markdown headers.

3. **REST `/orchestrate` didn't pass `skip_plan`** — Fixed in this session. Approved plans re-triggered planning in an infinite loop.

### High

4. **No compaction agent** — OpenCode runs a dedicated compaction LLM call that produces structured summaries (Goal/Instructions/Discoveries/Accomplished/Relevant files). Our `Compactor.maybe_compact` is heuristic-only — it truncates but doesn't summarize intelligently.

5. **No instruction file discovery** — OpenCode walks up from cwd to find AGENTS.md/CLAUDE.md, reads global config dirs, even fetches HTTP URLs. We only read from `priv/rules/` — no per-project instruction file support.

6. **No MCP tool integration** — OpenCode dynamically fetches tools from configured MCP servers. Our tool registry is static (compile-time).

7. **No plan file persistence** — OpenCode writes plans to `.opencode/plans/<name>.md`. Our plans exist only in memory and the plan review UI — if the user disconnects, the plan is lost.

### Medium

8. **No structured output mode** — OpenCode injects a StructuredOutput tool + system prompt when the caller requests JSON schema output. We have no equivalent.

9. **No doom loop detection** — OpenCode detects 3 identical consecutive tool calls and stops. We rely on max_iterations (30) which is too high for a stuck loop.

10. **No per-agent tool permissions** — OpenCode has fine-grained per-agent allow/deny/ask rules. Our tools are either available or not, globally.

11. **No dynamic tool descriptions** — OpenCode generates tool descriptions at runtime (bash includes cwd, task lists available agents). Our tool descriptions are static.

12. **Single system prompt vs provider-specific** — OpenCode has separate base prompts tuned per provider (Claude gets TodoWrite instructions, GPT gets different structure, Gemini gets Gemini-specific). We use one Soul for all providers.

### Low

13. **No prepareStep hook** — OpenCode dequeues pending subtasks between steps. We have no inter-step injection point.

14. **No tool call repair** — OpenCode has `experimental_repairToolCall` that fixes case-insensitive tool names. We'd fail on a misspelled tool call.

15. **No max-steps reminder** — OpenCode injects `max-steps.txt` when approaching the step limit. We hit the limit silently and return a generic message.

---

## 7. Signal-Aware Branching (Decision Table)

Every message is classified. Here's what triggers based on the signal:

| Signal Mode | Signal Weight | Plan Mode Enabled | skip_plan | Action |
|---|---|---|---|---|
| `:assist` | any | any | any | Normal ReAct (no plan) |
| `:analyze` | any | any | any | Normal ReAct (no plan) |
| `:build` | < 0.75 | any | any | Normal ReAct (no plan) |
| `:build` | >= 0.75 | false | any | Normal ReAct (no plan) |
| `:build` | >= 0.75 | true | false | **PLAN MODE** |
| `:build` | >= 0.75 | true | true | Normal ReAct (plan approved) |
| `:execute` | >= 0.75 | true | false | **PLAN MODE** |
| `:maintain` | >= 0.75 | true | false | **PLAN MODE** |

Signal type must be `"request"` or `"general"` for plan mode. Questions, issues, summaries bypass plan mode regardless.

---

## 8. Event Bus → SSE → TUI Mapping

```
Backend Bus Event          SSE Event Type        TUI Handler                  Display
─────────────────          ──────────────        ───────────                  ───────
:streaming_token      →    streaming_token   →   streamBuf.WriteString()  →   Live text in chat
:thinking_delta       →    thinking_delta    →   activity.Update()        →   Thinking indicator
:llm_request          →    llm_request       →   activity.Update()        →   "Iteration N" spinner
:tool_call (start)    →    tool_call         →   activity.Update()        →   Tool name + args
:tool_call (end)      →    tool_call         →   activity.Update()        →   Duration badge
:tool_result          →    tool_result       →   activity.Update()        →   Result preview
:llm_response         →    llm_response      →   status.SetStats()        →   Token count + timing
:signal_classified    →    signal_classified →   status.SetSignal()       →   Mode/genre badge
:context_pressure     →    context_pressure  →   status.SetContext()      →   "Context: N%"
:agent_response       →    agent_response    →   handleClientAgentResp()  →   Final message in chat
:system_event (various) → system_event      →   (per event routing)      →   Various UI updates
```

---

## 9. Error Recovery Paths

| Error | Detection | Recovery | TUI Display |
|---|---|---|---|
| Backend down | Health check fails | Retry every 5s, StateConnecting | "Backend unreachable — retrying" |
| SSE disconnect | Connection closed | Exponential backoff (2s→30s, 10 attempts) | SSEReconnectingEvent |
| Auth expired | 401 from SSE | Auto-refresh token, restart SSE | "Use /login" if refresh fails |
| Context overflow | LLM error contains "context_length" | Compact + retry (max 3) | "Exceeded context window" after 3 |
| Tool blocked | Pre-hook returns {:blocked, reason} | Skip tool, return "Blocked: reason" to LLM | Tool result shows blocked reason |
| Budget exceeded | Budget hook fires | Block further tool calls | Toast: "Budget exceeded" |
| Max iterations | iteration >= 30 | Stop loop, return partial | "Reached reasoning limit" |
| User cancel | Ctrl+C in StateProcessing | Set cancelled=true, drop late responses | Back to idle immediately |
| LLM error | {:error, reason} from provider | Return error message | "Error processing request" |
| Session init fail | ensure_loop returns error | HTTP 503 | "Error: session_unavailable" |
