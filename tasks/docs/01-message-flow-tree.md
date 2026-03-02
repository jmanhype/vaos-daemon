# Doc 1: Message Flow & Branching Tree

> Every possible path from user keystroke to final display.

---

## The Complete Tree

```
USER INPUT (Go TUI: app.go:handleIdleKey)
│
╠══ [A] SLASH COMMAND (starts with "/")
║   │
║   ├── [A1] UI-ONLY (no backend round-trip)
║   │   ├── /clear    → chat.Clear(), StateIdle
║   │   ├── /exit     → tea.Quit
║   │   ├── /theme    → cycle theme in-place
║   │   ├── /bg       → move processing to background
║   │   ├── /session  → open session picker (StateModelPicker variant)
║   │   └── /model    → open model picker (StateModelPicker)
║   │
║   └── [A2] BACKEND COMMAND
║       │   POST /api/v1/commands/execute {command, arg, session_id}
║       │   Backend: Commands.execute(cmd, arg, session_id)
║       │
║       ├── kind="text"   → chat.AddSystemMessage(output)
║       ├── kind="error"  → chat.AddSystemError(output)
║       ├── kind="prompt" → re-enters tree at [B] with output as input
║       └── kind="action" → handleCommandAction()
║           ├── :new_session   → close SSE, fresh session, welcome screen
║           ├── :switch_model  → fetch models, picker UI
║           ├── :load_session  → load history, re-render chat
║           └── :toggle_*      → state toggle, system message
║
╠══ [B] NORMAL MESSAGE (no "/" prefix)
║   │
║   │   submitInput(text) → state=StateProcessing, activity.Start()
║   │   DUAL CHANNELS OPEN SIMULTANEOUSLY:
║   │
║   ├──── [B-REST] HTTP POST /api/v1/orchestrate
║   │     │   {input, session_id, skip_plan: false}
║   │     │
║   │     │   api.ex:167 → POST /orchestrate
║   │     │
║   │     ├── [B-REST-1] SESSION INIT FAILURE
║   │     │   Session.ensure_loop() → {:error, _}
║   │     │   HTTP 503 → TUI: chat.AddSystemError("session_unavailable")
║   │     │
║   │     └── [B-REST-2] SESSION OK → Loop.process_message(sid, input, opts)
║   │         │
║   │         │   ╔══════════════════════════════════════╗
║   │         │   ║  BACKEND AGENT LOOP (loop.ex:93)     ║
║   │         │   ╚══════════════════════════════════════╝
║   │         │
║   │         ├── STEP 1: SIGNAL CLASSIFY (< 1ms)
║   │         │   classify_fast(message, channel)
║   │         │   → %Signal{mode, genre, type, format, weight}
║   │         │   Also fires: classify_async() → background LLM enrichment
║   │         │
║   │         ├── STEP 2: NOISE FILTER
║   │         │   │
║   │         │   ├── {:noise, :empty}         → "" (blank ack)
║   │         │   ├── {:noise, :too_short}     → "👍"
║   │         │   ├── {:noise, :pattern_match} → "👍" (hi/ok/thanks/lol)
║   │         │   ├── {:noise, :low_weight}    → "Got it."
║   │         │   ├── {:noise, :llm_classified}→ "Noted."
║   │         │   │   ALL → {:ok, ack_string}, NO LLM CALL
║   │         │   │   TUI shows ack, back to idle
║   │         │   │
║   │         │   └── {:signal, weight} → PROCEED
║   │         │
║   │         ├── STEP 3: COMPACTION
║   │         │   Compactor.maybe_compact(state.messages)
║   │         │   If >3000 est. tokens → truncate old messages
║   │         │
║   │         ├── STEP 4: PLAN MODE DECISION
║   │         │   │
║   │         │   │ CONDITIONS (ALL must be true):
║   │         │   │   plan_mode_enabled == true
║   │         │   │   signal.mode ∈ [:build, :execute, :maintain]
║   │         │   │   signal.weight >= 0.75
║   │         │   │   signal.type ∈ ["request", "general"]
║   │         │   │   skip_plan == false
║   │         │   │
║   │         │   ├── [PLAN] YES → PLAN MODE PATH
║   │         │   │   │
║   │         │   │   │ Context.build(state, signal)
║   │         │   │   │   System prompt includes: ## PLAN MODE — ACTIVE
║   │         │   │   │   "Produce a structured plan, NO tools"
║   │         │   │   │
║   │         │   │   │ LLM call: tools=[], temperature=0.3
║   │         │   │   │ Emits: Bus.emit(:agent_response, response_type: "plan")
║   │         │   │   │
║   │         │   │   ├── LLM OK → {:plan, plan_text, signal}
║   │         │   │   │   API: HTTP 200 {response_type: "plan", output: plan_text}
║   │         │   │   │
║   │         │   │   │   TUI: handleOrchestrate() detects response_type="plan"
║   │         │   │   │     plan.SetPlan(plan_text)
║   │         │   │   │     state = StatePlanReview
║   │         │   │   │
║   │         │   │   │   USER DECISION (Y/N/E keys):
║   │         │   │   │   │
║   │         │   │   │   ├── [Y] APPROVE
║   │         │   │   │   │   orchestrateWithOpts("Approved. Execute.", true)
║   │         │   │   │   │   skip_plan=true → bypasses STEP 4 entirely
║   │         │   │   │   │   → Falls through to [EXEC] below
║   │         │   │   │   │
║   │         │   │   │   ├── [N] REJECT
║   │         │   │   │   │   "Plan rejected." → StateIdle
║   │         │   │   │   │
║   │         │   │   │   └── [E] EDIT
║   │         │   │   │       Input prefilled: "Regarding the plan: "
║   │         │   │   │       → StateIdle, user types refinement
║   │         │   │   │       → Re-enters tree at [B]
║   │         │   │   │
║   │         │   │   └── LLM FAIL → Log warning, fallthrough to [EXEC]
║   │         │   │
║   │         │   └── [EXEC] NO → NORMAL ReAct LOOP
║   │         │       │
║   │         │       │   ╔════════════════════════════════════╗
║   │         │       │   ║  ReAct LOOP (run_loop → do_run_loop) ║
║   │         │       │   ║  Max 30 iterations                    ║
║   │         │       │   ╚════════════════════════════════════╝
║   │         │       │
║   │         │       ├── STEP 5: SYSTEM PROMPT ASSEMBLY
║   │         │       │   Context.build(state, signal)
║   │         │       │   4-tier token budget (see Doc 2)
║   │         │       │
║   │         │       ├── STEP 6: LLM CALL (streaming)
║   │         │       │   llm_chat_stream(messages, tools, temp=0.7)
║   │         │       │   │
║   │         │       │   │ DURING CALL (via streaming callback):
║   │         │       │   │   {:text_delta, t}    → Bus.emit(:streaming_token)
║   │         │       │   │   {:thinking_delta, t} → Bus.emit(:thinking_delta)
║   │         │       │   │   {:done, result}      → stash in Process dict
║   │         │       │   │
║   │         │       │   ├── {:ok, content, tool_calls=[]}
║   │         │       │   │   FINAL RESPONSE — exit loop
║   │         │       │   │
║   │         │       │   ├── {:ok, content, tool_calls=[tc1, tc2, ...]}
║   │         │       │   │   │
║   │         │       │   │   │ STEP 7: TOOL EXECUTION (per tool_call)
║   │         │       │   │   │ ┌──────────────────────────────────┐
║   │         │       │   │   │ │ FOR EACH tool_call:              │
║   │         │       │   │   │ │                                  │
║   │         │       │   │   │ │ 7a. PRE-HOOKS (sync, can block)  │
║   │         │       │   │   │ │   ├─ security_check             │
║   │         │       │   │   │ │   │  blocks: rm -rf /, sudo, etc│
║   │         │       │   │   │ │   └─ budget_guard               │
║   │         │       │   │   │ │      blocks: over token budget  │
║   │         │       │   │   │ │   ├─ {:blocked, reason}         │
║   │         │       │   │   │ │   │  → "Blocked: {reason}"      │
║   │         │       │   │   │ │   └─ :ok → proceed              │
║   │         │       │   │   │ │                                  │
║   │         │       │   │   │ │ 7b. EXECUTE                     │
║   │         │       │   │   │ │   Tools.execute(name, args)     │
║   │         │       │   │   │ │   ├─ {:ok, string}              │
║   │         │       │   │   │ │   ├─ {:ok, {:image, ...}}       │
║   │         │       │   │   │ │   └─ {:error, reason}           │
║   │         │       │   │   │ │                                  │
║   │         │       │   │   │ │ 7c. POST-HOOKS (async)          │
║   │         │       │   │   │ │   cost_tracker                  │
║   │         │       │   │   │ │   telemetry                     │
║   │         │       │   │   │ │   learning_capture              │
║   │         │       │   │   │ │                                  │
║   │         │       │   │   │ │ 7d. EMIT SSE EVENTS             │
║   │         │       │   │   │ │   :tool_call (start)            │
║   │         │       │   │   │ │   :tool_call (end + duration)   │
║   │         │       │   │   │ │   :tool_result (name, success)  │
║   │         │       │   │   │ │                                  │
║   │         │       │   │   │ │ 7e. APPEND to messages          │
║   │         │       │   │   │ │   {role: "tool", content: ...}  │
║   │         │       │   │   │ └──────────────────────────────────┘
║   │         │       │   │   │
║   │         │       │   │   │ iteration++ → LOOP BACK to STEP 5
║   │         │       │   │   │ (until no tool_calls or max_iter)
║   │         │       │   │
║   │         │       │   └── {:error, reason}
║   │         │       │       ├── context_overflow? AND iter < 3
║   │         │       │       │   compact + retry (LOOP BACK to STEP 5)
║   │         │       │       ├── context_overflow? AND iter >= 3
║   │         │       │       │   "Exceeded context window..."
║   │         │       │       └── other error
║   │         │       │           "Error processing request..."
║   │         │       │
║   │         │       └── STEP 8: FINALIZATION
║   │         │           Memory.append(assistant response)
║   │         │           emit_context_pressure(utilization%)
║   │         │           Bus.emit(:agent_response, response)
║   │         │           Return {:ok, response}
║   │         │
║   │         └── API RESPONSE → HTTP 200
║   │             {:plan, t, s}    → {response_type: "plan"}
║   │             {:ok, response}  → {response_type: "response"}
║   │             {:filtered, s}   → HTTP 422
║   │             {:error, reason} → HTTP 500
║   │
║   └──── [B-SSE] CONCURRENT: SSE /api/v1/stream/:session_id
║         │
║         │ Events arrive in real-time during processing:
║         │
║         ├── streaming_token  → streamBuf.WriteString(text)
║         │                      chat.SetStreamingContent(buf)
║         │                      [User sees text appear character-by-character]
║         │
║         ├── thinking_delta   → activity.Update(ThinkingDelta)
║         │                      [Thinking indicator pulses]
║         │
║         ├── llm_request      → activity.Update(LLMRequest{iter})
║         │                      ["Iteration N" in spinner]
║         │
║         ├── tool_call(start) → activity.Update(ToolCallStart{name, args})
║         │                      [Tool name + arg hint shown]
║         │
║         ├── tool_call(end)   → activity.Update(ToolCallEnd{name, ms})
║         │                      [Duration badge appears]
║         │
║         ├── tool_result      → activity.Update(ToolResult{name, preview})
║         │                      [Result preview 200 chars]
║         │
║         ├── llm_response     → status.SetStats(duration, tokens)
║         │                      [Token counts in status bar]
║         │
║         ├── signal_classified→ status.SetSignal(mode, genre, weight)
║         │                      [Signal badge updates]
║         │
║         ├── context_pressure → status.SetContext(util%, max, est)
║         │                      ["Context: 45%" in status bar]
║         │
║         └── agent_response   → handleClientAgentResponse()
║             ├── response_type="plan" → plan.SetPlan(), StatePlanReview
║             └── response_type=""     → chat.AddAgentMessage()
║
║   DEDUP: First responder (REST or SSE) sets responseReceived=true
║          Second responder checks flag → silently drops
║
╠══ [C] CANCEL (Ctrl+C during StateProcessing)
║   cancelled = true
║   activity.Stop()
║   chat.ClearProcessingView()
║   state = StateIdle, input.Focus()
║   Late REST/SSE responses check cancelled → drop silently
║
╠══ [D] KEYBOARD SHORTCUTS
║   ├── Ctrl+K  → StatePalette (command palette overlay)
║   ├── Ctrl+O  → toggle expanded activity detail
║   ├── Ctrl+T  → toggle thinking display
║   ├── Ctrl+N  → new session (close SSE, fresh chat)
║   ├── Ctrl+L  → clear screen
║   ├── Up/Down → scroll chat history
║   └── PgUp/Dn→ page scroll
║
╚══ [E] BACKGROUND TASKS
    ├── /bg moves current processing to background
    │   state = StateIdle (processing continues)
    │   bgTasks list tracks active background work
    │   On completion: "Background task completed" system message
    └── status.SetBackgroundCount(len(bgTasks))
```

---

## Branching Decision Matrix

| Decision Point | Condition | Path | Result |
|---|---|---|---|
| Slash vs Normal | `text[0] == '/'` | A vs B | Command handler vs orchestrate |
| UI vs Backend cmd | hardcoded list | A1 vs A2 | Local action vs HTTP POST |
| Session init | ensure_loop result | B-REST-1 vs B-REST-2 | Error vs proceed |
| Noise filter | filter(message) | noise vs signal | Ack-only vs LLM call |
| Plan trigger | 5 conditions AND'd | PLAN vs EXEC | Plan review vs ReAct loop |
| Tool calls | tool_calls length | 0 vs N | Final response vs tool execution |
| Tool blocked | pre-hook result | blocked vs ok | "Blocked" string vs execute |
| Context overflow | error string match | retry vs fail | Compact+retry vs error msg |
| Max iterations | iter >= 30 | stop vs continue | "Reasoning limit" vs next iter |
| Plan decision | Y/N/E key | approve/reject/edit | Execute/idle/refinement |
| REST vs SSE | responseReceived flag | first vs second | Display vs drop |
| User cancel | Ctrl+C | cancelled=true | Drop all late responses |

---

## Timing Profile (Typical "build me a todo app")

```
T=0ms      User presses Enter
T=1ms      submitInput() → StateProcessing
T=2ms      HTTP POST /orchestrate sent
T=3ms      SSE already connected from previous message

           BACKEND:
T=5ms      Session.ensure_loop() — exists, returns :ok
T=6ms      classify_fast() — mode=:build, weight=0.82, type="request"
T=7ms      NoiseFilter.filter() — {:signal, 0.82}
T=8ms      Compactor check — under threshold, skip
T=9ms      should_plan?() — YES (build, 0.82, plan_mode_enabled)
T=10ms     Context.build() — assemble system prompt (~15ms)
T=25ms     LLM call starts (plan mode, no tools)

           SSE EVENTS:
T=150ms    streaming_token "## Plan\n\n" → streamBuf
T=200ms    streaming_token "1. Create Phoenix project..."
...
T=2500ms   LLM finishes plan text

T=2510ms   Bus.emit(:agent_response, response_type: "plan")
T=2520ms   HTTP 200 returned {response_type: "plan"}

           TUI:
T=2525ms   handleOrchestrate() → detects "plan"
           plan.SetPlan(text) → StatePlanReview
           [User sees plan with Y/N/E options]

T=5000ms   User presses Y (approve)
T=5001ms   orchestrateWithOpts("Approved. Execute.", true)
T=5002ms   HTTP POST {skip_plan: true}

           BACKEND:
T=5005ms   classify_fast() — mode=:execute
T=5006ms   should_plan?() — NO (skip_plan=true)
T=5007ms   run_loop() starts (full ReAct with tools)
T=5020ms   LLM call 1 (with tools)
T=6000ms   tool_call: shell_execute("mix phx.new todo_app")
T=6500ms   tool_call: file_edit(router.ex, ...)
T=7000ms   tool_call: file_write(todo_controller.ex, ...)
...         (3-5 more iterations)
T=15000ms  Final response: "Todo app created. Here's what I built..."

           TUI:
T=15005ms  handleOrchestrate() or handleClientAgentResponse()
           chat.AddAgentMessage(output, signal)
           StateIdle, input focused
```
