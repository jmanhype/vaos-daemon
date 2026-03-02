# Doc 5: Gap Analysis & Improvement Roadmap

> Issues found from comparing OSA to Claude Code, Cursor, Windsurf, OpenCode, Cline, Gemini CLI.

---

## 1. Critical Gaps (Fix Now)

### GAP-01: No Prompt Caching
**Impact**: Every ReAct iteration rebuilds the full system prompt. With 5 iterations avg, that's 5x the input tokens for the same Tier 1 content.

**What others do**: OpenCode collapses system prompt to exactly 2 parts for Anthropic prompt caching. First call caches, subsequent iterations hit cache.

**Fix**: In `context.ex:build/2`, split system prompt into:
- Part 1: Static content (security + identity + soul + tool_process + environment) — CACHEABLE
- Part 2: Dynamic content (signal overlay + plan mode + tools + rules + memory + tasks) — per-call

Pass as separate system messages with cache breakpoints for Anthropic.

**Estimated savings**: 60-80% input tokens on multi-iteration requests.

---

### GAP-02: No Provider-Specific Prompts
**Impact**: Claude, GPT, Gemini, and Ollama models all get the same system prompt. Each has different strengths, token limits, and instruction-following patterns.

**What others do**: OpenCode has `anthropic.txt`, `beast.txt`, `gemini.txt`, `codex_header.txt`, `trinity.txt`, `qwen.txt`. Each tuned to provider capabilities.

**Fix**: In `soul.ex`, add provider routing:
```elixir
def system_prompt(signal, provider) do
  base = case provider do
    :anthropic -> load_prompt("anthropic.md")
    :openai    -> load_prompt("openai.md")
    :ollama    -> load_prompt("ollama.md")  # simpler, no TodoWrite
    _          -> load_prompt("default.md")
  end
  base <> signal_overlay(signal)
end
```

For Ollama small models: strip Tier 2-4 entirely (they can't follow complex prompts).

---

### GAP-03: Instruction File Discovery (CLAUDE.md / AGENTS.md)
**Impact**: Users can't put per-project instructions in their repo. All rules come from `priv/rules/`.

**What others do**:
- Claude Code reads `CLAUDE.md` from project root
- OpenCode reads `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` (walks up from cwd)
- Cline reads `.clinerules`

**Fix**: In `context.ex`, add to Tier 2:
```elixir
defp instruction_files_block(state) do
  paths = discover_instruction_files(state.cwd)
  # Walk up from cwd: .osa/INSTRUCTIONS.md, CLAUDE.md, AGENTS.md, CONTEXT.md
  contents = Enum.map(paths, &File.read!/1)
  join_as_block("Project Instructions", contents)
end
```

---

## 2. High Priority Gaps (Fix This Sprint)

### GAP-04: No Compaction Agent
**Impact**: `Compactor.maybe_compact/1` truncates old messages heuristically. Lost context includes tool results, reasoning chains, and decisions.

**What others do**: OpenCode runs a dedicated compaction agent with a structured summary prompt:
```
## Goal / ## Instructions / ## Discoveries / ## Accomplished / ## Relevant files
```

**Fix**: Add `Agent.CompactionAgent` that runs a cheap LLM call (haiku-tier) to summarize:
```elixir
defmodule OptimalSystemAgent.Agent.CompactionAgent do
  def summarize(messages, opts \\ []) do
    prompt = """
    Summarize this conversation for context continuity. Include:
    ## Goal - What the user wants
    ## Progress - What's been done so far
    ## Key Decisions - Important choices made
    ## Relevant Files - Files read or modified
    ## Next Steps - What remains to be done
    """
    Providers.chat([%{role: "system", content: prompt} | messages],
      model: "haiku", max_tokens: 500)
  end
end
```

---

### GAP-05: No Doom Loop Detection
**Impact**: If the LLM calls the same tool with the same args 3+ times, we burn 30 iterations before stopping.

**What others do**: OpenCode detects 3 identical consecutive tool calls and stops.

**Fix**: In `loop.ex:do_run_loop/1`, after tool execution:
```elixir
defp detect_doom_loop(tool_calls, state) do
  recent = state.messages
    |> Enum.filter(&match?(%{role: "assistant", tool_calls: _}, &1))
    |> Enum.take(-3)
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(&{&1.name, &1.arguments})

  if length(recent) >= 3 and Enum.uniq(recent) |> length() == 1 do
    {:doom_loop, hd(recent)}
  else
    :ok
  end
end
```

---

### GAP-06: No Plan Persistence
**Impact**: Plans exist only in memory and the TUI. If user disconnects, plan is lost.

**What others do**: OpenCode writes to `.opencode/plans/<name>.md`.

**Fix**: On plan generation, persist to `~/.osa/plans/<session_id>_<timestamp>.md`. On approve, mark as executed. On reject, mark as rejected.

---

### GAP-07: No Parallel Batching Directive
**Impact**: The LLM doesn't know it CAN batch tool calls. It calls tools one at a time unless it decides otherwise.

**What others do**:
- Cursor: "DEFAULT TO PARALLEL: maximize parallel tool calls (3-5 per turn)"
- Claude Code v2: "Call multiple tools in a single response"

**Fix**: Add to `tool_process_block()`:
```
## Parallel Tool Calls

You can call multiple tools in a single response. When multiple operations are
independent (don't depend on each other's results), batch them together.

Examples of parallel-safe operations:
- Reading multiple files simultaneously
- Searching for different patterns
- Running independent shell commands

Call 3-5 tools per turn when possible. Only go sequential when output of one
tool is needed as input to the next.
```

---

## 3. Medium Priority Gaps (Next Sprint)

### GAP-08: No Status Update Directive
Cursor mandates micro status updates between tool batches. Our LLM sometimes goes silent for 30+ seconds during multi-tool iterations.

**Fix**: Add to Soul or tool_process_block:
```
After completing each batch of tool calls, provide a brief 1-sentence status
update before the next batch. Example: "Found the bug in auth.ex, now fixing."
```

---

### GAP-09: No Per-Agent Tool Permissions
OpenCode and Cline have per-agent allow/deny/ask rules. Our agents all get the same tool set.

**Fix**: In `agent/roster.ex`, add `tools: [:allowed_tools]` per agent definition. In `context.ex`, filter tools by agent.

---

### GAP-10: No Convention Verification
Gemini CLI mandates: "NEVER assume a library is available. Check package.json/requirements.txt/go.mod first."

**Fix**: Add to rules_block:
```
Before using any library or framework, verify it's available:
- Check package.json, go.mod, mix.exs, requirements.txt, or Cargo.toml
- Look at neighboring files for import patterns
- Don't assume — verify.
```

---

### GAP-11: No Structured Output Mode
OpenCode injects a StructuredOutput tool + system prompt when JSON output is needed.

**Fix**: When `opts[:schema]` is passed to `process_message/3`, add structured output tool and directive.

---

### GAP-12: Signal Weight Cliff Edge
weight=0.74 → no plan, weight=0.76 → plan. No soft ramp.

**Fix**: Add a "suggest plan" mode for weight 0.60-0.75 where the LLM is told "Consider whether this needs a plan" in the overlay, rather than forcing it.

---

## 4. Low Priority Gaps (Backlog)

### GAP-13: No Tool Call Repair
OpenCode has `experimental_repairToolCall` for case-insensitive tool name matching.

### GAP-14: No Max Steps Reminder
OpenCode injects `max-steps.txt` when approaching iteration limit.

### GAP-15: No Dynamic Tool Descriptions
OpenCode generates tool descriptions at runtime (bash includes cwd, task lists agent names).

### GAP-16: No Build Switch Injection
OpenCode injects "mode changed from plan to build" synthetic message. Our skip_plan flag works but doesn't tell the LLM "you were in plan mode, now you're executing."

---

## 5. Roadmap Priority Order

| # | Gap | Effort | Impact | Priority |
|---|---|---|---|---|
| 1 | GAP-07: Parallel batching directive | S | High | Now (prompt change only) |
| 2 | GAP-08: Status update directive | S | High | Now (prompt change only) |
| 3 | GAP-10: Convention verification | S | Medium | Now (prompt change only) |
| 4 | GAP-01: Prompt caching | M | Very High | This week |
| 5 | GAP-03: Instruction file discovery | M | High | This week |
| 6 | GAP-05: Doom loop detection | S | High | This week |
| 7 | GAP-02: Provider-specific prompts | L | High | This sprint |
| 8 | GAP-04: Compaction agent | M | High | This sprint |
| 9 | GAP-06: Plan persistence | S | Medium | This sprint |
| 10 | GAP-12: Signal weight soft ramp | S | Medium | This sprint |
| 11 | GAP-09: Per-agent tool permissions | M | Medium | Next sprint |
| 12 | GAP-11: Structured output mode | M | Medium | Next sprint |
| 13 | GAP-16: Build switch injection | S | Low | Next sprint |
| 14 | GAP-14: Max steps reminder | S | Low | Backlog |
| 15 | GAP-15: Dynamic tool descriptions | M | Low | Backlog |
| 16 | GAP-13: Tool call repair | S | Low | Backlog |

**S** = Small (< 2 hours), **M** = Medium (2-8 hours), **L** = Large (1-2 days)

---

## 6. Quick Wins (Prompt-Only Changes, Zero Code)

These 3 gaps can be fixed by editing `priv/prompts/` or `tool_process_block()` in context.ex:

1. **GAP-07**: Add parallel batching instruction to tool_process_block
2. **GAP-08**: Add status update directive to Soul
3. **GAP-10**: Add convention verification to rules

Total effort: ~30 minutes. Expected impact: noticeably better tool usage patterns and user visibility during long operations.
