# The ReAct Pattern: How AI Agents Reason

When you ask OSA to "find the bug in this file and fix it," OSA does not send
that message to an LLM and return whatever comes back. It runs a structured
loop: think about the problem, act to gather information or make a change,
observe the result, then think again. This is the ReAct pattern.

---

## What is ReAct?

ReAct stands for **Reasoning + Acting**. It is a pattern for building AI agents
that was described in a 2022 research paper from Google and Princeton. The core
idea is that a language model should interleave reasoning (thinking through a
problem) with acting (calling tools to interact with the world), rather than
doing all of its reasoning in one shot and then producing a final answer.

Compare two approaches:

**Without ReAct (one-shot):**
```
User: "Find the bug in auth.ex and fix it"
Agent: [calls LLM once with the question]
LLM: "I think the bug is on line 42, here is a fix..." [might be wrong, no verification]
```

**With ReAct:**
```
User: "Find the bug in auth.ex and fix it"
Agent: [Observe] I need to read the file first
Agent: [Think] The user wants me to find and fix a bug in auth.ex
Agent: [Act] file_read("lib/auth.ex")
Agent: [Observe] File contents received: 180 lines, sees a suspicious pattern on line 38
Agent: [Think] That pattern looks wrong. I should also check the test file.
Agent: [Act] file_read("test/auth_test.exs")
Agent: [Observe] Test file shows expected behavior. Confirms the bug.
Agent: [Think] I have enough information. I can write the fix now.
Agent: [Act] file_edit("lib/auth.ex", fix)
Agent: [Observe] Edit applied successfully
Agent: [Think] I should verify the fix compiles.
Agent: [Act] shell_execute("mix compile")
Agent: [Observe] Compilation successful, no errors
Agent: [Think] Done. The bug is fixed and verified.
Agent: [Respond] "I found and fixed the bug..."
```

ReAct produces better results because each action gives the agent new information
that informs the next decision. The agent adapts rather than guessing.

---

## The Loop: Think → Act → Observe → Repeat

The ReAct loop has three phases that cycle until the task is complete:

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│  THINK: Analyze current state, plan next action     │
│     ↓                                               │
│  ACT: Call a tool (read file, run command, etc.)    │
│     ↓                                               │
│  OBSERVE: Receive tool result, update understanding │
│     ↓                                               │
│  [repeat until done or max iterations reached]      │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Think** — The agent processes everything it knows so far: the original
request, the history of actions taken, and the results observed. It decides
what to do next. This is a call to the LLM. The LLM either returns a tool
call request (the agent needs more information or to take an action) or a
final response (the task is complete).

**Act** — The agent executes the tool the LLM requested. Tools in OSA include
reading files, writing files, running shell commands, searching the web, querying
memory, asking the user a question, and dozens more. The tool executes and
returns a result.

**Observe** — The tool result becomes part of the conversation context. The agent
"observes" what happened. This observation feeds into the next Think phase.

---

## How OSA Implements ReAct

OSA's ReAct implementation lives in
`OptimalSystemAgent.Agent.Strategies.ReAct`. It is one of five pluggable
reasoning strategies:

| Strategy | Module | Best for |
|---|---|---|
| `ReAct` | Strategies.ReAct | Simple tasks, tool-heavy workflows, action-oriented goals |
| `ChainOfThought` | Strategies.ChainOfThought | Analysis, research, structured reasoning |
| `TreeOfThoughts` | Strategies.TreeOfThoughts | Planning, design, architecture decisions |
| `Reflection` | Strategies.Reflection | Debugging, code review, refactoring |
| `MCTS` | Strategies.MCTS | Exploration, optimization, search problems |

ReAct is the default. The agent loop selects a strategy based on the Signal
Theory classification of the message:

```
Signal Mode: EXECUTE, Action-oriented  → ReAct
Signal Mode: ANALYZE, Research         → ChainOfThought
Signal Mode: BUILD, Architecture       → TreeOfThoughts
Signal Mode: MAINTAIN, Debugging       → Reflection
Signal Mode: EXECUTE, Optimization     → MCTS
```

You can also explicitly request a strategy in your message or via the API.

---

## Bounded Iteration: The 30-Iteration Limit

The ReAct loop has a maximum of 30 iterations by default. When the agent reaches
iteration 30, the strategy returns:

```elixir
{:done, %{reason: :max_iterations, summary: "Reached max iterations (30). Summarizing findings."}}
```

The agent loop then asks the LLM to summarize what it found and returns that
summary to the user.

Why a limit? Two reasons:

**Token budget**: Each iteration adds messages to the conversation context. At
30 iterations with tool results, you might have 20,000–50,000 tokens in context.
Beyond that, cost grows fast and quality degrades as the LLM's attention spreads
too thin.

**Loop detection**: Some tasks are genuinely unsolvable (a command that always
fails, a file that does not exist). Without a limit, the agent would loop forever.
The limit ensures the agent eventually produces some output regardless of how
stuck it gets.

The limit is configurable per-session via the `max_iterations` parameter if you
need more iterations for a complex task.

---

## Tool Calls: How the LLM Requests Actions

When the LLM is in the Think phase and determines it needs to take an action, it
does not just say "I will read the file." It emits a structured tool call in its
response. For example, the Anthropic API returns something like:

```json
{
  "type": "tool_use",
  "name": "file_read",
  "input": {
    "path": "lib/auth.ex"
  }
}
```

OSA's agent loop receives this, extracts the tool name and input, routes the call
through the goldrush-compiled `:osa_tool_dispatcher`, gets the result, and adds
it to the conversation history as a tool result message. Then the loop calls the
LLM again with the updated context.

From the LLM's perspective, it is a normal conversation turn. It just happens
that some turns contain tool results rather than user messages.

Not all LLM providers support tool calling equally well. Some providers require
that tools be described in every request. Some parse tool calls from the text
output. OSA's provider adapters handle these differences so the agent loop does
not need to know.

---

## Comparison: ReAct vs Other Strategies

To make the difference concrete, here is how each strategy would approach
"find and fix the bug in auth.ex":

**ReAct** (default for most tasks)
- Read file → inspect → read tests → write fix → compile → verify
- Good: efficient, direct, uses tools to gather exactly what it needs

**ChainOfThought** (analysis-heavy tasks)
- Think through the problem step by step in natural language before acting
- "First, I need to understand what auth.ex is supposed to do. Then I need to
  understand the error. Then I can hypothesize about the cause..."
- Better for problems where reasoning matters more than tool use

**Reflection** (debugging)
- Actively critiques its own reasoning and previous answers
- After proposing a fix: "Wait, does this fix handle the edge case where the
  token is nil? Let me reconsider..."
- Better for tricky bugs where the first answer is often wrong

**TreeOfThoughts** (complex planning)
- Explores multiple solution paths simultaneously
- "Option A: change the validation logic. Option B: update the token format.
  Option C: add a fallback handler. Let me evaluate each..."
- Better for problems with multiple valid approaches that need comparison

**MCTS** (Monte Carlo Tree Search — search problems)
- Uses a tree search with scoring to explore solution space
- Better for optimization problems where you need to find the best path among
  many possibilities

OSA selects the strategy automatically based on signal classification. You can
override it by specifying `strategy: :reflection` in your request if you want
a specific approach.

---

## The Agent Loop in OSA's Architecture

The ReAct loop runs inside an `Agent.Loop` process. Each active session has its
own Loop process (under the `SessionSupervisor` DynamicSupervisor).

```
User message arrives via HTTP/CLI/Telegram
         ↓
Events.Bus routes :user_message to the session's Loop process
         ↓
Loop selects reasoning strategy (ReAct, CoT, ToT, Reflection, MCTS)
         ↓
Loop calls LLM via Providers.Registry
         ↓
LLM returns: tool call OR final response
         ↓
If tool call: Tools.Registry executes the tool
             Tool result added to context
             Loop iterates (up to 30 times)
         ↓
If final response: Loop emits :agent_response event
                   Events.Bus routes to channel (HTTP, CLI, etc.)
                   User receives the response
```

The loop is a single Elixir process. It holds the conversation history in its
process state. When the loop crashes, the supervisor restarts it with a fresh
state. The conversation history is lost unless it was written to the persistent
memory store before the crash.

---

## Next Steps

Read [llm-providers.md](./llm-providers.md) to understand how OSA talks to the
AI models that power the Think phase — the 18 supported providers, how fallback
chains work, and how streaming returns responses token by token.
