# Execution Engine

## Agent.Loop GenServer

`Daemon.Agent.Loop` is the core reasoning engine. It is a GenServer
that owns one session's full execution context and processes messages serially
within that session.

### GenServer Message Handling

```elixir
# Synchronous — used for message processing (blocks until response)
handle_call({:process, message, opts}, from, state)
handle_call(:get_state, from, state)
handle_call(:get_metadata, from, state)

# Asynchronous — used for internal signaling
handle_cast({:set_provider, provider, model}, state)
```

All user-facing message processing goes through `handle_call/3` with `:infinity`
timeout. This serializes execution within a session while allowing BEAM process
concurrency across sessions.

## Pre-LLM Gate Pipeline

Before the LLM is invoked, every message passes through four ordered gates:

```
Message received
    │
    ▼
[Gate 0] Prompt injection check (Guardrails.prompt_injection?/1)
         Hard block — no memory write, immediate refusal
    │
    ▼
[Gate 1] Noise filter (NoiseFilter.check/2)
         :filtered → discard silently
         :clarify  → return clarification request
         :pass     → continue
    │
    ▼
[Gate 2] Genre routing (GenreRouter)
         Some signal genres return a canned response without tool invocation
    │
    ▼
[Gate 3] Plan mode check
         plan_mode == true → single LLM call, no tools
    │
    ▼
[Gate 4] Full ReAct loop
```

### Signal Weight Tool Gating

Messages carry a signal weight in the range `0.0–1.0`. When weight is below the
threshold of `0.20`, the LLM is called without any tools:

```elixir
# Minimum signal weight required to pass a tool list to the LLM.
@tool_weight_threshold 0.20
```

This prevents hallucinated tool sequences for low-information inputs like
acknowledgements ("ok", "thanks") or conversational filler ("lol", "hm").

## Bounded ReAct Loop

The ReAct loop implements Reason + Act cycles. The loop is bounded by
`max_iterations` (default: `20`, configured via
`Application.get_env(:daemon, :max_iterations, 30)`):

```
iteration 0 → think → call LLM → tool_calls? → yes → execute tools → append results
iteration 1 → re-prompt with tool results → tool_calls? → yes → execute tools
...
iteration N → no tool_calls → return final response
iteration max_iterations → forced stop → summarize findings
```

### Iteration Structure

```elixir
defp run_loop(state, messages) when state.iteration >= max_iterations() do
  {:max_iterations, "Reached #{max_iterations()} iterations — summarizing."}
end

defp run_loop(state, messages) do
  case :ets.lookup(:daemon_cancel_flags, state.session_id) do
    [{_, true}] -> {:cancelled, "Loop cancelled"}
    [] ->
      case LLMClient.call(state, messages) do
        {:ok, response, tool_calls} when tool_calls == [] ->
          {:done, response}
        {:ok, _response, tool_calls} ->
          results = ToolExecutor.execute_all(tool_calls, state)
          run_loop(%{state | iteration: state.iteration + 1}, append_results(messages, results))
      end
  end
end
```

## LLM Client Dispatch

`Agent.Loop.LLMClient` dispatches to `MiosaProviders.Registry`, which routes
to the active provider module via the goldrush-compiled `:daemon_provider_router`:

```elixir
# In LLMClient:
MiosaProviders.Registry.call(provider, model, messages, tools, opts)

# In MiosaProviders.Registry — goldrush routing:
:glc.handle(:daemon_provider_router, event)
# → dispatches to MiosaProviders.Anthropic | OpenAI | Groq | Ollama | ...
```

If the active provider fails, the loop consults the `fallback_chain` configured
at boot and retries with the next provider.

## Tool Execution

`Agent.Loop.ToolExecutor` receives the list of tool calls from the LLM response
and executes each through `Tools.Registry`:

```elixir
defp execute_tool(tool_call, state) do
  name = tool_call["name"]
  args = tool_call["input"] || %{}

  case Tools.Registry.execute(name, args, state) do
    {:ok, result} -> format_tool_result(tool_call["id"], result)
    {:error, reason} -> format_tool_error(tool_call["id"], reason)
  end
end
```

### JSON Schema Validation

Before execution, tool arguments are validated against the tool's JSON Schema
using `ex_json_schema`:

```elixir
case ExJsonSchema.Validator.validate(schema, args) do
  :ok -> execute(name, args)
  {:error, errors} -> {:error, "Invalid arguments: #{format_errors(errors)}"}
end
```

Tool errors are returned to the LLM as tool result messages so the LLM can
self-correct on the next iteration rather than crashing the loop.

### Hook Pipeline

Tool execution runs through the hook pipeline before and after each tool call:

```elixir
# Pre-execution hooks (priority order, lower = first)
case Hooks.run(:pre_tool_use, %{tool: name, args: args, session_id: id}) do
  {:ok, payload} -> execute_tool(payload)
  {:blocked, reason} -> {:error, "Blocked: #{reason}"}
end

# Post-execution hooks
Hooks.run(:post_tool_use, %{tool: name, result: result, duration_ms: elapsed})
```

Built-in hooks:

| Hook | Event | Priority | Action |
|------|-------|----------|--------|
| `security_check` | `pre_tool_use` | 10 | Block dangerous shell commands |
| `spend_guard` | `pre_tool_use` | 8 | Block when budget exceeded |
| `mcp_cache` | `pre_tool_use` | 15 | Inject cached MCP schemas |
| `cost_tracker` | `post_tool_use` | 25 | Record actual API spend |
| `mcp_cache_post` | `post_tool_use` | 15 | Populate MCP schema cache |
| `telemetry` | `post_tool_use` | 90 | Emit tool timing metrics |

## Reasoning Strategies

`Agent.Loop` supports pluggable reasoning strategies via the
`Daemon.Agent.Strategy` behaviour. The active strategy module is
stored in `state.strategy`; strategy-specific state is in `state.strategy_state`.

### Available Strategies

| Module | Atom | Best for |
|--------|------|----------|
| `Strategies.ReAct` | `:react` | Default; simple tasks, tool-heavy workflows |
| `Strategies.ChainOfThought` | `:chain_of_thought` | Complex reasoning, multi-step analysis |
| `Strategies.Reflection` | `:reflection` | Self-critique and refinement loops |
| `Strategies.MCTS` | `:mcts` | Exploration under uncertainty; Monte Carlo Tree Search |
| `Strategies.TreeOfThoughts` | `:tree_of_thoughts` | Parallel hypothesis exploration |

### Strategy Selection

Strategy is auto-selected based on task context at the start of each
`process_message/3` call:

```elixir
strategy = Strategy.select(context)
# context includes: task_type, complexity, tools available, signal genre
```

Each strategy implements:

```elixir
@callback name() :: atom()
@callback select?(context :: map()) :: boolean()
@callback init_state(context :: map()) :: map()
@callback next_step(state :: map(), context :: map()) :: {step, new_state}
```

## Auto-Fixer Loop

`Agent.AutoFixer` implements an automatic fix loop for test and lint failures.
After tool execution produces test/lint output, the auto-fixer:

1. Parses failure output to extract error signatures
2. Emits a follow-up prompt to the LLM with the failures
3. Runs the fix iteration
4. Re-runs the test/lint tool to verify

The loop exits on success, max iterations reached, or when the same failure
signature repeats (detected via `recent_failure_signatures` in loop state to
prevent infinite cycles).

## Checkpoint Integration

After every completed tool-result cycle, if the vault checkpoint interval is
reached, the loop writes a checkpoint:

```elixir
if rem(state.turn_count, vault_checkpoint_interval()) == 0 do
  Vault.SessionLifecycle.checkpoint(state.session_id)
  Checkpoint.checkpoint_state(state)
end
```

`Loop.Checkpoint` persists conversation messages, iteration count, plan mode,
and turn count to `~/.daemon/checkpoints/<session_id>.json`. On `init/1`, the loop
attempts to restore from this file, enabling crash recovery without losing
conversation context.

## Output Guardrail

After the LLM returns a response, an output-side prompt-leak guard scrubs any
response that contains system prompt content:

```elixir
defp maybe_scrub_prompt_leak(response) do
  if Guardrails.response_contains_prompt_leak?(response) do
    Guardrails.prompt_extraction_refusal()
  else
    response
  end
end
```

This handles weak models that may echo the system prompt despite the input-side
injection block.
