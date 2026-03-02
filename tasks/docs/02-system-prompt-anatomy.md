# Doc 2: System Prompt Anatomy — How AI Coding Tools Build Their Prompts

> Side-by-side comparison of prompt architecture across 7 tools.

---

## 1. Prompt Assembly Strategy

| Tool | Strategy | Prompt Size | Dynamic? |
|---|---|---|---|
| **Claude Code v1** | Monolithic static | ~192 lines | Env block only |
| **Claude Code v2** | Monolithic + detailed tool schemas | ~1150 lines | Env + tools |
| **Cursor** | Agent prompt + todo state | ~800 lines | Status updates injected |
| **Windsurf** | Flow prompt + plan state + memory | ~600 lines | Plan + memory dynamic |
| **Codex CLI** | Minimal prompt + git context | ~300 lines | Git status dynamic |
| **Cline/Gemini** | Workflow prompt + convention | ~400 lines | Project conventions |
| **OpenCode** | Provider-specific .txt files | ~500 lines + env | Per-model files |
| **OSA** | 4-tier token-budgeted builder | Dynamic (up to ~3000 lines) | Everything dynamic |

---

## 2. Section-by-Section Breakdown

### A. Identity Layer

```
CLAUDE CODE v1:
  "You are an interactive CLI tool that helps users with software engineering tasks."
  (1 sentence, minimal)

CLAUDE CODE v2:
  "You are a Claude agent, built on Anthropic's Claude Agent SDK."
  "You are an interactive CLI tool..."
  (2 sentences, framework-aware)

CURSOR:
  "You are a powerful agentic AI coding assistant, powered by GPT-5."
  "You are pair programming with a USER..."
  (Self-aware of model + role)

WINDSURF:
  "You are Cascade, an AI coding assistant created by Codeium."
  "Built on the AI Flow paradigm..."
  (Brand + paradigm)

CODEX CLI:
  "You are a remote teammate, knowledgeable and eager to help."
  (Personality-first, warm)

CLINE:
  "You are Cline, a highly skilled software engineer..."
  (Competence-first)

GEMINI:
  "You are an interactive CLI agent specializing in software engineering."
  (Function-first)

OSA:
  Security guardrail (150 words)
  + IDENTITY.md (400+ words: capabilities, signal modes, constraints)
  + SOUL.md (500+ words: personality, communication style, values)
  + Signal overlay (dynamic: mode/genre behavior directives)
  (MOST DETAILED by far — personality + signal theory + constraints)
```

### B. Tool Instructions

```
CLAUDE CODE v1:
  "Do NOT use Bash to run commands when a relevant dedicated tool is provided."
  (4 anti-pattern rules, no tool schemas)

CLAUDE CODE v2:
  Full JSON schemas for 15 tools with descriptions, parameters, types.
  "Use dedicated tools instead of bash equivalents."
  Priority hierarchy: Search → File ops → Execution → Meta

CURSOR:
  "DEFAULT TO PARALLEL: Unless you have specific reason operations MUST be sequential"
  "Maximize parallel tool calls" (3-5 per turn)
  cite_blocks for referencing existing code

WINDSURF:
  "IMPORTANT: Only call tools when absolutely necessary"
  "If you state you will use a tool, immediately call that tool"
  Tool minimalism (opposite of Cursor)

CODEX CLI:
  Minimal tool instructions.
  "Apply patches inline in responses."
  Trust the sandbox environment.

CLINE:
  XML-style tool tags (custom format).
  Sequential: one tool per message.
  "explain_command_before_running" for safety.

GEMINI:
  "Use tools for actions; text ONLY for communication."
  Same workflow as Cline (test → lint → build mandatory).
  Absolute paths enforced.

OSA:
  "## How to Use Tools" (5-step process)
  "## Tool Routing Rules (CRITICAL)" (9 routing rules)
  "## When to Use Each Tool" (9 items)
  + Full tool signatures in Tier 2 with parameter types
```

### C. Mode / Planning System

```
CLAUDE CODE v1:
  NO explicit modes.

CLAUDE CODE v2:
  Plan Mode: ExitPlanMode tool → user approval gate.
  Working Mode: TodoWrite tracking.
  Agent Mode: Task tool spawns subagents.

CURSOR:
  todo_write(merge=true) before/after edits.
  Reconcile todo list each turn.
  No formal "plan mode" — planning is embedded in todo creation.

WINDSURF:
  update_plan tool on every significant discovery.
  Plan is session state, not approval gate.
  Memory system persists across sessions.

CODEX CLI:
  No modes. Git state IS the plan.
  git log, git diff, git status as context.

CLINE:
  Two workflows: SOFTWARE ENGINEERING (5 steps) vs NEW APPLICATIONS (6 steps).
  Step 3 of NEW APPLICATIONS = user approval gate.

GEMINI:
  Same as Cline: Understand → Plan → Implement → Verify(tests) → Verify(lint+build).

OSA:
  Signal-driven automatic detection.
  should_plan?() triggers on: mode∈{build,execute,maintain} + weight≥0.75
  Plan overlay injected into system prompt: "## PLAN MODE — ACTIVE"
  skip_plan=true on approval bypasses classifier.
  + 5 mode overlays (EXECUTE/BUILD/ANALYZE/MAINTAIN/ASSIST)
  + 5 genre overlays (DIRECT/INFORM/COMMIT/DECIDE/EXPRESS)
```

### D. Output Formatting

```
CLAUDE CODE v1:
  "fewer than 4 lines", "minimize tokens"
  "MUST avoid preamble/postamble"
  "One word answers for simple questions"
  (EXTREME minimization)

CLAUDE CODE v2:
  "match complexity level"
  "briefly confirm completion"
  (Adaptive — softened from v1)

CURSOR:
  Status updates: 1-3 sentences per phase.
  Markdown only where semantically correct.
  Code changes NOT output — use tools.

WINDSURF:
  Step-by-step narrative.
  "Brief summaries of changes (not 'what I did' but 'what changed')."
  High-signal output.

CODEX CLI:
  "Brief bullet points + high-level description."
  Transparency: show tool calls and code.

CLINE/GEMINI:
  "<3 lines of text output per response"
  "No preamble/postamble"
  (Similar to Claude Code v1 extreme)

OSA:
  Signal-adaptive via Soul overlays:
    EXECUTE mode: "Be concise. Do the thing, confirm done. No preamble."
    BUILD mode: "Show your work. Structure the output."
    ANALYZE mode: "Be thorough. Show reasoning. Use structure."
    ASSIST mode: "Guide and explain. Match user's depth."
  + Weight calibration: low=brief, high=detailed
  (MOST NUANCED — adapts per message, not globally)
```

---

## 3. Prompt Assembly Order (Each Tool)

### Claude Code v2
```
1. Identity (2 sentences)
2. Security guardrails
3. Help/feedback routing
4. Documentation lookup rules
5. Professional objectivity
6. Tone & Style (adaptive)
7. Proactiveness balance
8. Task Management (TodoWrite rules)
9. Doing tasks (workflow)
10. Tool usage policy
11. Environment info
12. Model info
13. [Tool schemas appended by framework]
```

### Cursor
```
1. Identity + model declaration
2. Tool instructions (parallel-first)
3. Status update rules
4. TODO management protocol
5. Code output policy (never show code)
6. Citation format rules
7. Markdown formatting
8. Verification loop (linter → fix → retry)
9. [Context: active file, cursor position, selection]
```

### Windsurf
```
1. Identity + paradigm declaration
2. Tool calling rules (minimal)
3. Plan system (update_plan protocol)
4. Memory system (proactive creation)
5. Code editing protocol
6. Safety judgement rules
7. Output format (step-by-step)
8. [Context: workspace, active file, terminal]
```

### OSA (context.ex tier assembly)
```
TIER 1 — CRITICAL (always full):
  1. Security guardrail (prompt injection defense)
  2. IDENTITY.md (capabilities, signal modes, constraints)
  3. SOUL.md (personality, communication style, values)
  4. Signal overlay (mode+genre behavior directives)
  5. Tool process block (routing rules, when to use)
  6. Runtime block (timestamp, channel, session)
  7. Plan mode block (if active)
  8. Environment block (OS, git, provider, model)

TIER 2 — HIGH (40% budget):
  9. Tools block (signatures + parameters)
  10. Rules block (project rules from priv/rules/)
  11. Memory block (keyword-relevant long-term memory)
  12. Workflow block (active workflow context)
  13. Task state block (active tasks + status)

TIER 3 — MEDIUM (30% budget):
  14. User profile (USER.md)
  15. Communication intelligence (formality, topics, style)
  16. Cortex bulletin (memory snapshot)

TIER 4 — LOW (remaining):
  17. OS templates (OS-specific guidance)
  18. Machines (machine-specific context)
```

---

## 4. What OSA Does That Nobody Else Does

| Feature | OSA | Closest Competitor |
|---|---|---|
| **Signal classification** | Dual (deterministic + LLM) | None — all implicit |
| **Signal-adaptive system prompt** | Mode/genre overlays change behavior per message | Windsurf plan updates (but not per-message) |
| **Token-budgeted assembly** | 4-tier priority with overflow truncation | None — all static |
| **Noise filtering** | 2-tier gate prevents LLM calls on low-signal | None — all messages hit LLM |
| **Security guardrail as Tier 1** | Prompt injection defense first | Claude Code v2 has it but not first |
| **Soul/personality layer** | 500+ word personality definition | Codex CLI "remote teammate" (1 sentence) |
| **Communication profiler** | Adapts to user style over time | None |
| **Memory relevance filter** | Keyword-overlap filtering per query | Windsurf memory (but unfiltered) |

## 5. What Others Do That OSA Doesn't

| Feature | Who Has It | OSA Gap |
|---|---|---|
| **Prompt caching** | OpenCode (2-part collapse for Anthropic) | No — full rebuild each iteration |
| **Provider-specific prompts** | OpenCode (anthropic.txt, beast.txt, gemini.txt) | Single prompt for all providers |
| **Per-agent tool permissions** | OpenCode, Cline | Global tool availability only |
| **Plan file persistence** | OpenCode (.opencode/plans/*.md) | Plans in memory only |
| **Instruction file discovery** | OpenCode (walk up dirs), Claude Code (CLAUDE.md) | priv/rules/ only |
| **Doom loop detection** | OpenCode (3 identical calls) | max_iterations=30 only |
| **Structured output mode** | OpenCode (StructuredOutput tool) | No equivalent |
| **Status updates (in-prompt)** | Cursor (mandatory micro-updates) | Via SSE only |
| **Tool necessity gating** | Windsurf ("only if absolutely necessary") | All tools always available |
| **Convention verification** | Gemini (check before using any library) | No equivalent |
| **Parallel batching directive** | Cursor ("3-5 per turn"), Claude Code v2 | Not in prompt |
