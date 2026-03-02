# Doc 4: Frontend Display States — What the User Sees

> Every TUI state mapped to its visual output and the backend events that drive it.

---

## 1. State Machine

```
                     ┌──────────────┐
    app starts ────►│ Connecting   │
                     └──────┬───────┘
                            │ health OK
                     ┌──────▼───────┐
                     │ Banner       │ (2s splash)
                     └──────┬───────┘
                            │ timeout
                     ┌──────▼───────┐◄──────── Ctrl+C (cancel)
              ┌─────►│ Idle         │◄──────── response received
              │      └──┬───┬───┬───┘          plan rejected
              │         │   │   │              edit plan
              │    send │   │/K │/model
              │    msg  │   │   │
              │  ┌──────▼─┐ │ ┌─▼──────────┐
              │  │Process-│ │ │ModelPicker  │
              │  │  ing   │ │ └─────────────┘
              │  └──┬─────┘ │
              │     │       ▼
              │     │  ┌────────────┐
              │     │  │ Palette    │ (Ctrl+K)
              │     │  └────────────┘
              │     │
              │     │ response_type="plan"
              │  ┌──▼──────────┐
              │  │ PlanReview  │
              │  └──┬──┬──┬───┘
              │  Y  │  │N │E
              │  ┌──▼┐ │  │
              │  │Pro-│ │  │
              │  │cess│ │  │
              │  │ing │ │  │
              │  └────┘ │  │
              └─────────┴──┘
```

---

## 2. Visual Layout Per State

### StateConnecting
```
┌─────────────────────────────────────────┐
│                                         │
│         ╔═══╗ ╔═══╗ ╔═══╗              │
│         ║ O ║ ║ S ║ ║ A ║              │
│         ╚═══╝ ╚═══╝ ╚═══╝              │
│                                         │
│   ⠿ Connecting to backend...            │
│     (retrying in 5s if failed)          │
│                                         │
└─────────────────────────────────────────┘
Backend events: health check polling every 5s
SSE: not connected
Input: disabled
```

### StateBanner (2-second splash)
```
┌─────────────────────────────────────────┐
│  OSA v0.8.0                             │
│  ─────────                              │
│  Provider: anthropic                    │
│  Model:    claude-opus-4-6              │
│  Tools:    14 available                 │
│  Path:     ~/Desktop/MIOSA/OSA          │
│                                         │
│  Type a message or /help to get started │
│                                         │
└─────────────────────────────────────────┘
Backend events: HealthResult received
SSE: connecting (session_id assigned)
Input: disabled (waiting for banner timeout)
```

### StateIdle (ready for input)
```
┌─────────────────────────────────────────┐
│  OSA │ anthropic/claude-opus            │ ← header
├─────────────────────────────────────────┤
│                                         │
│  [User messages and agent responses]    │ ← chat area
│  │ scrollable                           │
│  │                                      │
│  ┌─ You ──────────────────────────────┐ │
│  │ build me a todo app                │ │
│  └────────────────────────────────────┘ │
│  ┌─ OSA (BUILD·DIRECT) ── 2340ms ────┐ │
│  │ ## Plan                            │ │
│  │ 1. Create Phoenix project          │ │
│  │ 2. Add Ecto schemas               │ │
│  │ ...                                │ │
│  └────────────────────────────────────┘ │
│                                         │
├─────────────────────────────────────────┤
│ BUILD │ 2.3k in │ 450 out │ Ctx: 12%  │ ← status bar
├─────────────────────────────────────────┤
│ > █                                     │ ← input (focused)
└─────────────────────────────────────────┘
```

### StateProcessing (agent working)
```
┌─────────────────────────────────────────┐
│  OSA │ anthropic/claude-opus            │
├─────────────────────────────────────────┤
│                                         │
│  ┌─ You ──────────────────────────────┐ │
│  │ build me a todo app                │ │
│  └────────────────────────────────────┘ │
│                                         │
│  ┌─ Processing ───────────────────────┐ │
│  │ ◼ Iteration 1                      │ │ ← llm_request event
│  │ ├─ 💭 thinking...                  │ │ ← thinking_delta events
│  │ ├─ 🔧 shell_execute               │ │ ← tool_call start event
│  │ │  └─ mix phx.new todo_app        │ │ ← tool args
│  │ │  └─ ✓ 1.2s                      │ │ ← tool_call end event
│  │ ├─ 🔧 file_edit                   │ │
│  │ │  └─ lib/todo/router.ex          │ │
│  │ │  └─ ⏳ running...               │ │
│  │ └─ Streaming:                      │ │
│  │    Here's what I'm building...     │ │ ← streaming_token events
│  └────────────────────────────────────┘ │
│                                         │
├─────────────────────────────────────────┤
│ EXEC │ 4.1k in │ 890 out │ Ctx: 18%  │
├─────────────────────────────────────────┤
│ ⏳ Processing... (Ctrl+C to cancel)    │ ← input (blurred)
└─────────────────────────────────────────┘

Events driving this display:
  streaming_token  → live text in "Streaming:" area
  thinking_delta   → "💭 thinking..." indicator
  llm_request      → "◼ Iteration N" header
  tool_call(start) → "🔧 tool_name" with args
  tool_call(end)   → "✓ Ns" duration badge
  tool_result      → result preview (200 chars)
  llm_response     → token counts in status bar
  signal_classified→ mode badge in status bar
  context_pressure → "Ctx: N%" in status bar
```

### StatePlanReview (plan approval)
```
┌─────────────────────────────────────────┐
│  OSA │ anthropic/claude-opus            │
├─────────────────────────────────────────┤
│                                         │
│  ┌─ You ──────────────────────────────┐ │
│  │ build me a todo app                │ │
│  └────────────────────────────────────┘ │
│                                         │
│  ┌─ Plan Review ──────────────────────┐ │
│  │                                    │ │
│  │  ## Plan                           │ │
│  │                                    │ │
│  │  ### Goal                          │ │
│  │  Build a Phoenix LiveView todo     │ │
│  │  application with CRUD operations. │ │
│  │                                    │ │
│  │  ### Steps                         │ │
│  │  1. Create new Phoenix project     │ │
│  │  2. Add Todo Ecto schema           │ │
│  │  3. Build LiveView components      │ │
│  │  4. Add CSS styling                │ │
│  │  5. Write tests                    │ │
│  │                                    │ │
│  │  ### Files                         │ │
│  │  - lib/todo/todos/todo.ex          │ │
│  │  - lib/todo_web/live/todo_live.ex  │ │
│  │  - test/todo/todos_test.exs        │ │
│  │                                    │ │
│  │  ### Risks                         │ │
│  │  - None significant                │ │
│  │                                    │ │
│  │  ### Estimate                      │ │
│  │  Medium (~5 minutes)               │ │
│  │                                    │ │
│  ├────────────────────────────────────┤ │
│  │  [Y] Approve  [N] Reject  [E] Edit│ │
│  └────────────────────────────────────┘ │
│                                         │
├─────────────────────────────────────────┤
│ BUILD │ plan mode │ Ctx: 8%            │
├─────────────────────────────────────────┤
│ Press Y to approve, N to reject,       │ ← input (special mode)
│ E to edit the plan                     │
└─────────────────────────────────────────┘

Triggered by: response_type="plan" (REST or SSE)
Y → orchestrateWithOpts("Approved. Execute.", true) → StateProcessing
N → "Plan rejected." → StateIdle
E → input prefilled "Regarding the plan: " → StateIdle
```

### StateModelPicker
```
┌─────────────────────────────────────────┐
│  OSA │ Select Model                     │
├─────────────────────────────────────────┤
│                                         │
│  ► ollama/llama3.2:latest     7.4 GB   │ ← highlighted
│    ollama/mistral:7b          4.1 GB   │
│    ollama/codellama:34b      19.0 GB   │
│    anthropic/claude-opus-4-6    —      │
│    anthropic/claude-sonnet-4-6  —      │
│    openai/gpt-4o                —      │
│                                         │
├─────────────────────────────────────────┤
│ ↑↓ navigate │ Enter select │ Esc back  │
└─────────────────────────────────────────┘
```

### StatePalette (Ctrl+K command palette)
```
┌─────────────────────────────────────────┐
│  ╔═══════════════════════════════════╗   │
│  ║ > /ag█                           ║   │
│  ╠═══════════════════════════════════╣   │
│  ║ /agents    List agent roster     ║   │
│  ║ /analytics Usage analytics       ║   │
│  ║                                  ║   │
│  ║                                  ║   │
│  ╚═══════════════════════════════════╝   │
│                                         │
│  (filtered as you type, Enter to run)   │
└─────────────────────────────────────────┘
```

---

## 3. Event → Display Mapping

| Backend Event | SSE Event Type | TUI Component | Visual Update |
|---|---|---|---|
| classify_fast() | (internal) | — | Immediate routing, no display |
| classify_async() done | `signal_classified` | status.SetSignal() | Mode badge: "BUILD" |
| LLM call starts | `llm_request` | activity.Update() | "◼ Iteration 1" |
| Token generated | `streaming_token` | streamBuf.WriteString() | Live text character-by-character |
| Thinking token | `thinking_delta` | activity.Update() | "💭 thinking..." |
| Tool starts | `tool_call` (start) | activity.Update() | "🔧 tool_name (args)" |
| Tool finishes | `tool_call` (end) | activity.Update() | "✓ 1.2s" duration |
| Tool output | `tool_result` | activity.Update() | Preview (200 chars) |
| LLM done | `llm_response` | status.SetStats() | "4.1k in │ 890 out" |
| Context check | `context_pressure` | status.SetContext() | "Ctx: 18%" |
| Plan response | `agent_response` (plan) | plan.SetPlan() | StatePlanReview screen |
| Final response | `agent_response` (response) | chat.AddAgentMessage() | Full response in chat |
| Budget warning | `system_event` (budget) | toasts.Add() | Toast notification |
| Hook blocked | `system_event` (hook) | chat.AddSystemError() | Error message |

---

## 4. What Claude Code's Frontend Shows (Comparison)

Claude Code is a CLI (not TUI). Its display model is simpler:

```
CLAUDE CODE v2 DISPLAY:
┌─────────────────────────────────────────┐
│ $ claude                                │
│                                         │
│ > build me a todo app                   │ ← user input (readline)
│                                         │
│ ⠋ Thinking...                           │ ← spinner (no detail)
│                                         │
│ I'll help you build a todo app.         │ ← streaming text
│                                         │
│ [TodoWrite] Creating task list...       │ ← tool use indicator
│ [Read] reading package.json             │ ← tool use indicator
│ [Write] creating src/App.tsx            │ ← tool use indicator
│                                         │
│ Done! I've created a todo app with:     │ ← final summary
│ - React frontend                        │
│ - Local storage persistence             │
│ - Add/remove/toggle functionality       │
│                                         │
│ > █                                     │ ← back to readline
└─────────────────────────────────────────┘

WHAT CLAUDE CODE DOESN'T SHOW:
  - Signal classification (no signal system)
  - Token counts (not visible)
  - Context utilization (not visible)
  - Iteration count (not visible)
  - Tool timing (not visible)
  - Thinking content (optional, not default)
```

### OSA Advantages Over Claude Code Display

| Feature | OSA TUI | Claude Code CLI |
|---|---|---|
| Signal mode badge | Yes (BUILD, ANALYZE, etc.) | No |
| Token counters | Yes (in/out in status bar) | No |
| Context utilization | Yes ("Ctx: 18%") | No |
| Tool timing | Yes ("✓ 1.2s" per tool) | No |
| Thinking display | Yes (toggleable Ctrl+T) | Optional flag |
| Iteration tracking | Yes ("◼ Iteration 1, 2, ...") | No |
| Plan review UI | Yes (dedicated screen) | Inline text |
| Tool arg preview | Yes (first 60 chars) | Tool name only |
| Tool result preview | Yes (200 chars) | Not shown |
| Background tasks | Yes (/bg + counter) | No |
| Session switching | Yes (/session picker) | Separate command |
| Model picker | Yes (arrow-key UI) | /model command |
| Command palette | Yes (Ctrl+K) | /help list |

---

## 5. Display Issues Found

1. **Plan mode transition is abrupt** — No animation or visual cue when switching from Processing → PlanReview. User might not notice the state changed.

2. **Streaming text gets replaced** — During processing, streamBuf accumulates tokens. When final agent_response arrives, the streaming content is replaced by the full response. If there's a mismatch (SSE vs REST race), user might see a flash.

3. **No signal mode explanation** — Status bar shows "BUILD" but doesn't explain what that means. New users won't understand why behavior differs.

4. **No plan diff on edit** — When user presses E (edit), they start from scratch with "Regarding the plan: ". No diff view of what to change.

5. **Background task count only** — Status shows "1 bg" but not WHICH task is running. No way to see background task details without scrolling.

6. **Tool result preview too short** — 200 chars for tool results means most file reads/shell outputs are truncated to uselessness in the activity view.

7. **No execution cost display** — Token counts shown but no dollar cost estimate. Claude Code also doesn't show this, but since OSA tracks budgets, it should surface them.
