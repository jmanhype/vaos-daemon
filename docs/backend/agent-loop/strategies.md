# Reasoning Strategies

Pluggable modules that shape how the agent loop reasons about a task. The active strategy injects guidance into each loop iteration and tracks progress in its own state.

**Behaviour:** `Daemon.Agent.Strategy`
**Registry function:** `Strategy.resolve/1`, `Strategy.resolve_by_name/1`

---

## Strategy Behaviour

Every strategy implements five callbacks:

```elixir
@callback name()                                  :: atom()
@callback select?(context())                      :: boolean()
@callback init_state(context())                   :: strategy_state()
@callback next_step(strategy_state(), context())  :: {step(), strategy_state()}
@callback handle_result(step(), term(), strategy_state()) :: strategy_state()
```

**Step types** returned by `next_step/2`:

| Step | Loop action |
|------|-------------|
| `{:think, thought}` | Injects a system guidance message into context |
| `{:act, type, info}` | No guidance injected; LLM picks tools naturally |
| `{:observe, observation}` | Injects an observation system message |
| `{:respond, text}` | Injects a response guidance message |
| `{:done, info}` | Injects a summarization hint; LLM produces final answer |

`handle_result/3` receives the step type, the tool results (as `[%{tool: name, result: string}]`), and the current strategy state. It returns an updated state map, or `{:switch_strategy, name}` to trigger a mid-session strategy change.

---

## Strategy Selection

`Strategy.resolve/1` selects a strategy in priority order:

1. **Explicit name**: if the context map has a `:strategy` key with an atom name, resolve by name.
2. **`select?/1` heuristics**: each registered strategy's `select?/1` is called in order; first match wins.
3. **Task-type mapping**: if the context has a `:task_type` key, use the task-type map below.
4. **Complexity scoring**: falls back based on the `:complexity` integer in context.

**Task-type to strategy mapping:**

| Task type | Strategy |
|-----------|----------|
| `:simple`, `:action` | ReAct |
| `:analysis`, `:research` | ChainOfThought |
| `:planning`, `:design`, `:architecture` | TreeOfThoughts |
| `:debugging`, `:review`, `:refactor` | Reflection |
| `:exploration`, `:optimization`, `:search` | MCTS |

**Complexity score fallback:**

| Score | Strategy |
|-------|----------|
| ≤ 3 | ReAct |
| 4–5 | ChainOfThought |
| 6–7 | TreeOfThoughts |
| 8–9 | Reflection |
| ≥ 10 | MCTS |

The default (no context) is ReAct. Strategy can be changed at runtime via `Loop.handle_call({:set_strategy, name})`.

---

## ReAct

**Module:** `Daemon.Agent.Strategies.ReAct`
**Name:** `:react`
**Best for:** Simple tasks, tool-heavy workflows, action-oriented goals.

The default strategy. Cycles through Think → Act → Observe phases.

**Select heuristics:**
- `task_type` is `:simple` or `:action`
- Tools list is non-empty
- Complexity ≤ 3

**State:**
```elixir
%{
  iteration: 0,
  max_iterations: 30,   # configurable
  phase: :think,
  thoughts: [],
  actions: [],
  observations: []
}
```

**Loop behavior:**
- `:think` — injects an "Analyzing task" message on iteration 0, or a progress note on subsequent iterations. Advances to `:act`.
- `:act` — no guidance injected; LLM picks tools freely. Advances to `:observe`.
- `:observe` — notes the tool result. Advances to `:think` and increments iteration.
- When `iteration >= max_iterations` — signals `{:done, %{reason: :max_iterations}}`.

---

## Chain of Thought

**Module:** `Daemon.Agent.Strategies.ChainOfThought`
**Name:** `:chain_of_thought`
**Best for:** Analysis tasks, research, reasoning-heavy problems.

Prompts numbered step-by-step reasoning with an optional self-verification pass.

**Select heuristics:**
- `task_type` is `:analysis` or `:research`
- Complexity in `4..5`

**State:**
```elixir
%{
  phase: :reason,
  verify: false,         # set :verify true in context to enable verification pass
  task: "",
  steps: [],
  final_answer: nil,
  reasoning: nil,
  verification: nil
}
```

**Phase sequence:**

```
:reason  → injects "Think through this step-by-step. Number each step. FINAL ANSWER: ..."
         → advances to :parse

:parse   → if verify and no verification yet:
             injects a critique prompt → advances to :verify
           else:
             signals {:done, %{steps, final_answer, verified, verification}}

:verify  → signals {:done, %{steps, final_answer, verified: true, verification}}
```

**Parsing:** `parse_steps/1` extracts lines matching `^\s*\d+[.)]\s*(.+)`. `extract_final_answer/1` captures text after `FINAL ANSWER:`.

---

## Reflection

**Module:** `Daemon.Agent.Strategies.Reflection`
**Name:** `:reflection`
**Best for:** Debugging, code review, refactoring tasks.

Iteratively improves a response through Generate → Critique → Revise cycles.

**Select heuristics:**
- `task_type` is `:debugging`, `:review`, or `:refactor`
- Complexity in `8..9`

**State:**
```elixir
%{
  phase: :generate,
  task: "",
  max_rounds: 3,        # configurable
  round: 0,
  content: nil,
  critiques: [],
  current_critique: nil
}
```

**Phase sequence:**

```
:generate     → injects "Provide a thorough response..."
              → advances to :critique

:critique     → if round >= max_rounds: signals {:done}
              → else: injects critique evaluation prompt → advances to :check_critique

:check_critique → if critique is substantive (not "NO ISSUES FOUND"):
                    injects revision prompt → advances to :revise
                  else:
                    signals {:done} — quality threshold met

:revise       → loops back to :critique, increments round
```

**Substantive critique detection:** matches against patterns including `"no issues found"`, `"response is excellent"`, `"nothing to improve"`. If none match, the critique is considered substantive.

---

## Tree of Thoughts

**Module:** `Daemon.Agent.Strategies.TreeOfThoughts`
**Name:** `:tree_of_thoughts`
**Best for:** Planning, design, architecture decisions.

Generates multiple candidate approaches, evaluates and ranks them, then executes the best one.

**Select heuristics:**
- `task_type` is `:planning`, `:design`, or `:architecture`
- Complexity in `6..7`

**State:**
```elixir
%{
  phase: :generate,
  task: "",
  num_candidates: 3,    # configurable
  candidates: [],
  ranked: [],
  selected_index: nil,
  backtrack_count: 0
}
```

**Phase sequence:**

```
:generate   → injects "Generate exactly N approaches... APPROACH 1: [Title]..."
            → advances to :evaluate

:evaluate   → if no candidates parsed: signals {:done, %{reason: :no_candidates}}
            → else: injects ranking prompt "Rate each 1-10... RANKING: [comma list]"
            → advances to :execute

:execute    → if ranked list empty: signals {:done, %{reason: :all_approaches_failed}}
            → else: executes top-ranked approach → advances to :done

:done       → signals {:done, %{candidates, ranked, selected_index, backtrack_count}}
```

**Parsing:** `parse_approaches/2` extracts content after `APPROACH N:` labels. `parse_ranking/2` extracts a comma-separated list after `RANKING:` and converts to 0-based indices.

---

## MCTS

**Module:** `Daemon.Agent.Strategies.MCTS`
**Name:** `:mcts`
**Best for:** Exploration tasks, optimization problems, complex search spaces.

Reasons at the operation level using Monte Carlo Tree Search. Builds a tree of 10 reasoning operations, runs UCT-guided iterations, then extracts the best operation sequence and prompts the LLM to execute it.

**Select heuristics:**
- `task_type` is `:exploration`, `:optimization`, or `:search`
- Complexity ≥ 10

**State:**
```elixir
%{
  phase: :search,
  task: "",
  iterations: 1_000,    # configurable
  max_depth: 20,        # configurable
  timeout: 60_000,      # milliseconds, configurable
  scorer: nil,          # optional custom scoring function
  tree: tree_map,
  root_id: root_id,
  best_path: [],
  iterations_run: 0,
  tree_size: 0
}
```

**The 10 reasoning operations:**

| Operation | Description |
|-----------|-------------|
| `decompose` | Break the problem into smaller sub-problems |
| `analyze` | Examine components, relationships, and structure |
| `synthesize` | Combine partial results into a coherent whole |
| `compare` | Compare alternatives, trade-offs, or approaches |
| `abstract` | Generalize from specifics to find broader patterns |
| `specialize` | Apply general principles to the specific case |
| `verify` | Check correctness, consistency, and completeness |
| `refute` | Find counterexamples or weaknesses in reasoning |
| `transform` | Reframe the problem or change representation |
| `evaluate` | Assess quality, feasibility, and completeness |

**MCTS loop (runs entirely in Elixir before LLM call):**

```
for each iteration until count exhausted or deadline reached:
  SELECT    — traverse tree via UCT to find a promising leaf
  EXPAND    — add child nodes (random unexplored operations)
  SIMULATE  — rollout from leaf using heuristic scoring
  BACKPROP  — update visit/win counts up the tree
```

After search, the best path is extracted by greedily following the highest-visit-count child from root to leaf. This path is formatted as a numbered reasoning plan and injected into the LLM prompt via a `:think` step.

**Phase sequence:**

```
:search → runs MCTS iterations → extracts best path → injects execution prompt
        → advances to :done

:done   → signals {:done, %{best_path, iterations, tree_size, root_visits}}
```

---

## Public API

```elixir
Strategy.resolve(context)
# Returns {:ok, module} | {:error, :unknown_strategy}

Strategy.resolve_by_name(name)
# Returns {:ok, module} | {:error, :unknown_strategy}

Strategy.all()
# Returns [%{name: atom, module: module}]

Strategy.names()
# Returns [:react, :chain_of_thought, :tree_of_thoughts, :reflection, :mcts]
```

See also: [loop.md](loop.md)
