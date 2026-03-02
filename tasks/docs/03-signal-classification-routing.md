# Doc 3: Signal Classification & Mode Routing

> How the signal shapes every downstream decision — compared to how other tools handle it.

---

## 1. The OSA Signal Pipeline

```
USER MESSAGE
    │
    ▼
╔══════════════════════════════════════════╗
║  TIER 1: DETERMINISTIC CLASSIFICATION    ║
║  classifier.ex:classify_fast()  (<1ms)   ║
╚══════════════════════════════════════════╝
    │
    ├── MODE detection (keyword matching):
    │   "build/create/generate/make"     → :build
    │   "run/execute/trigger/deploy"     → :execute
    │   "analyze/report/explain/review"  → :analyze
    │   "update/fix/migrate/patch"       → :maintain
    │   everything else                  → :assist
    │
    ├── GENRE detection (phrase + punctuation):
    │   command phrases ("do this", imperative) → :direct
    │   "I will"/"let me"/"going to"           → :commit
    │   "approve"/"reject"/"choose"            → :decide
    │   "thanks"/"love"/"hate"/emotional       → :express
    │   everything else                        → :inform
    │
    ├── TYPE detection:
    │   contains "?" or "how/what/why/where"   → "question"
    │   contains "error/bug/broken/crash"      → "issue"
    │   contains "remind/schedule"             → "scheduling"
    │   contains "summarize/brief"             → "summary"
    │   everything else                        → "general" or "request"
    │
    └── WEIGHT calculation:
        base = 0.5
        + length_bonus (0.2 if >50 chars)
        + question_bonus (0.15 if question)
        + urgency_bonus (0.2 if urgent keywords)
        - noise_penalty (-0.3 if greeting/filler)
        clamped [0.0, 1.0]

    │
    ▼
╔══════════════════════════════════════════╗
║  TIER 2: ASYNC LLM ENRICHMENT           ║
║  classifier.ex:classify_async()          ║
║  (background task, ~200ms)               ║
╚══════════════════════════════════════════╝
    │
    │ LLM prompt: "Classify into mode/genre/type/weight"
    │ Temperature: 0.0 (deterministic)
    │ Max tokens: 80
    │ Cached: ETS, SHA256 key, 10-min TTL
    │
    │ Result emitted via Bus.emit(:signal_classified)
    │ → TUI updates signal badge in real-time
    │
    ▼
%Signal{
  mode:   :build,
  genre:  :direct,
  type:   "request",
  format: "message",
  weight: 0.85,
  channel: :cli
}
```

---

## 2. How Signal Routes Decisions

### Decision Point 1: Noise Filter

```
Signal weight → NoiseFilter

weight < 0.3 OR pattern_match (hi/ok/thanks)
  → {:noise, reason}
  → Ack only ("👍"), NO LLM call
  → SAVES: ~$0.01-0.10 per filtered message

weight 0.3-0.6 (uncertain)
  → LLM noise check: "Is this signal or noise?"
  → Cached 5 min
  → {:noise, :llm_classified} OR {:signal, weight}

weight > 0.6
  → {:signal, weight}
  → Proceed to plan check
```

### Decision Point 2: Plan Mode

```
Signal → should_plan?(signal, state)

ALL conditions must be true:
  ✓ plan_mode_enabled (config)
  ✓ mode ∈ [:build, :execute, :maintain]
  ✓ weight >= 0.75
  ✓ type ∈ ["request", "general"]
  ✓ skip_plan == false

Examples:
  "build me a todo app"     → mode=:build, w=0.85  → PLAN
  "what time is it"         → mode=:assist, w=0.40  → NO PLAN
  "fix the login bug"       → mode=:maintain, w=0.80 → PLAN
  "explain how auth works"  → mode=:analyze, w=0.70  → NO PLAN
  "hi"                      → filtered as noise      → NO LLM CALL
  "run the tests"           → mode=:execute, w=0.78  → PLAN
  "thanks that looks good"  → filtered as noise      → NO LLM CALL
```

### Decision Point 3: System Prompt Overlay

```
Signal → Context.build() → Soul.system_prompt(signal)

Mode overlay injected:
  :execute → "Be concise and action-oriented. Do the thing, confirm done."
  :build   → "Create with quality. Show your work. Structure the output."
  :analyze → "Be thorough and data-driven. Show reasoning."
  :maintain → "Be careful and precise. Check before changing."
  :assist  → "Guide and explain. Match the user's depth."

Genre overlay injected:
  :direct  → "The user is commanding. Respond with action, not explanation."
  :inform  → "The user is sharing information. Acknowledge, process."
  :commit  → "The user is committing to something. Confirm and track."
  :decide  → "The user needs a decision. Validate, recommend, execute."
  :express → "The user is expressing emotion. Lead with empathy."

Weight guidance:
  weight < 0.4 → "Low-weight signal. Brief acknowledgment."
  weight > 0.8 → "High-weight signal. Be thorough and comprehensive."
```

---

## 3. How Other Tools Handle This (They Don't)

### Claude Code
```
NO signal classification.
NO mode detection.
NO weight gating.

All messages → same system prompt → LLM decides behavior.
Plan mode: LLM calls EnterPlanMode tool (LLM-decided, not classifier-decided).
Output style: Fixed rules ("fewer than 4 lines" in v1, "adaptive" in v2).
```

### Cursor
```
NO classification.
Message → same prompt → LLM decides.
Planning: LLM creates todo_write if "medium-to-large task".
Output: Mandatory status updates between tool batches.
```

### Windsurf
```
NO classification.
Message → same prompt → LLM decides.
Planning: LLM calls update_plan on "significant discovery".
Output: Step-by-step narrative, always.
```

### Codex CLI / Cline / Gemini
```
NO classification.
Message → same prompt → LLM decides everything.
No adaptive behavior at all.
```

### OpenCode
```
NO classification.
Provider-specific prompt file selected at startup (not per-message).
Mode: LLM decides by calling EnterPlanMode tool.
```

---

## 4. The Signal Advantage (and Its Current Limits)

### What Signal Classification Gives Us

| Benefit | Mechanism | Impact |
|---|---|---|
| **Cost savings** | Noise filter blocks ~30% of messages from hitting LLM | ~$0.03/msg saved |
| **Faster response** | Low-weight acks in <5ms vs 2-30s LLM call | 1000x faster for noise |
| **Automatic plan mode** | Classifier triggers plan mode deterministically | <1ms vs ~2s for LLM to decide |
| **Adaptive persona** | Mode/genre overlays change per message | Each message gets tailored behavior |
| **Weight-based depth** | High weight → thorough, low → brief | Bandwidth-matched responses |

### Current Limits

| Limit | Issue | How Others Avoid It |
|---|---|---|
| **Keyword-only fast path** | "refactor auth" might classify as :maintain not :build | Claude Code: LLM decides (slower but smarter) |
| **No learning from corrections** | If user says "no, I meant build" → classifier doesn't adapt | No competitor does this either |
| **Binary plan threshold** | weight=0.74 → no plan, weight=0.76 → plan (cliff edge) | Could use soft ramp |
| **No sub-mode detection** | Can't distinguish "build from scratch" vs "build on existing" | Cursor uses todo complexity |
| **Signal not shown in output** | User never knows what mode the system is in | Could show mode badge |
| **No per-tool signal routing** | All tools available regardless of mode | OpenCode: per-agent tool permissions |

---

## 5. Signal Flow Visualization

```
"build me a REST API for user management"
 │
 ▼
CLASSIFY FAST (<1ms):
 mode=:build  (matched "build")
 genre=:direct (imperative phrasing)
 type="request"
 weight=0.87   (long, specific, actionable)
 │
 ├─ Noise filter: {:signal, 0.87} → PASS
 │
 ├─ Plan check: build + 0.87 + request + enabled → YES
 │
 ├─ System prompt overlay:
 │   "Mode: BUILD — Create with quality. Show your work."
 │   "Genre: DIRECT — Respond with action, not explanation."
 │
 ├─ Plan mode prompt injected:
 │   "## PLAN MODE — ACTIVE
 │    Produce structured plan. NO tools."
 │
 └─ LLM receives:
     [security guardrail]
     [identity: OSA capabilities]
     [soul: personality + values]
     [signal: BUILD × DIRECT, weight 0.87]
     [tool process: how to use tools — BUT tools=[]]
     [plan mode: produce structured plan]
     [runtime: timestamp, channel, session]
     [environment: OS, git, provider]
     [rules, memory, user profile...]

     → LLM produces plan (no tools available)
     → {:plan, plan_text, signal}
     → TUI: StatePlanReview
```

```
"what does the auth middleware do?"
 │
 ▼
CLASSIFY FAST (<1ms):
 mode=:analyze (matched "what does")
 genre=:inform  (question, not command)
 type="question" (contains "?")
 weight=0.65    (medium length, question)
 │
 ├─ Noise filter: {:signal, 0.65} → PASS
 │
 ├─ Plan check: analyze → NOT in [:build,:execute,:maintain] → NO
 │
 ├─ System prompt overlay:
 │   "Mode: ANALYZE — Be thorough and data-driven. Show reasoning."
 │   "Genre: INFORM — User is sharing/asking. Acknowledge, process."
 │
 └─ Normal ReAct loop with full tools
     → LLM reads files, explains code
     → {:ok, response}
```

```
"hi"
 │
 ▼
CLASSIFY FAST (<1ms):
 mode=:assist
 weight=0.15 (2 chars, greeting pattern)
 │
 ├─ Noise filter: {:noise, :pattern_match}
 │
 └─ Return "👍" — NO LLM CALL
     → TUI shows "👍"
     → Cost: $0.00
```

---

## 6. Comparison Matrix: Mode Detection

| Input | OSA Signal | Claude Code | Cursor | Windsurf |
|---|---|---|---|---|
| "build me a todo app" | :build, w=0.85, PLAN | LLM decides (plan?) | LLM creates todo | LLM calls update_plan |
| "fix the login bug" | :maintain, w=0.80, PLAN | LLM decides | LLM creates todo | LLM investigates |
| "what does auth do?" | :analyze, w=0.65, NO PLAN | Same prompt | Same prompt | Same prompt |
| "run the tests" | :execute, w=0.78, PLAN | Same prompt | Same prompt | Same prompt |
| "hi" | NOISE, w=0.15, filtered | LLM responds "Hello!" | LLM responds | LLM responds |
| "ok thanks" | NOISE, w=0.20, filtered | LLM responds | LLM responds | LLM responds |
| "deploy to prod" | :execute, w=0.82, PLAN | LLM decides | LLM executes | LLM executes |

Key insight: OSA is the ONLY tool that doesn't waste an LLM call on "hi" and "ok thanks".
