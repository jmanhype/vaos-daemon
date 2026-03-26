# Auto-Fixer

Iterative test/lint/typecheck/compile fix loop. Runs a check command, parses failures, dispatches a mini agent loop to apply fixes, and repeats until all checks pass or the iteration limit is reached.

**Module:** `Daemon.Agent.AutoFixer`

---

## Supported Types

| Type | Default command detection |
|------|--------------------------|
| `:test` | `mix test`, `npx vitest run`, `npx jest`, `go test ./...`, `cargo test`, `pytest` |
| `:lint` | `mix credo`, `npx eslint .`, `npx biome check`, `golangci-lint run`, `cargo clippy`, `ruff check .` |
| `:typecheck` | `mix dialyzer`, `npx tsc --noEmit`, `mypy .` |
| `:compile` | `mix compile --warnings-as-errors`, `go build ./...`, `cargo build`, `npx tsc` |
| `:custom` | Requires explicit `:command` in opts |

Command detection inspects the working directory for marker files (`mix.exs`, `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, etc.). For JavaScript projects, `package.json` is parsed to distinguish vitest, jest, mocha, eslint, biome, etc.

---

## Invocation

```elixir
# Synchronous
{:ok, fix_result} = AutoFixer.run(%{
  type: :test,
  session_id: session_id,
  command: "mix test",         # optional: override detected command
  max_iterations: 5,           # optional: default 5, max 20
  timeout_ms: 120_000,         # optional: per-check timeout
  cwd: "/path/to/project",     # optional: defaults to Workspace.get_cwd()
  stale_only: true             # optional: add --stale / --lf / --onlyChanged
})

# Asynchronous
{:ok, task} = AutoFixer.run_async(opts)
result = Task.await(task)
```

`stale_only: true` adds the appropriate flag for the detected runner:

| Runner | Flag added |
|--------|-----------|
| `mix test` | `--stale` |
| `pytest` | `--lf` (last failed) |
| `jest` | `--onlyChanged` |

---

## Fix Loop

```
run_loop/1:
  if iteration >= max_iterations → return {success: false, reason: :max_iterations}

  1. Emit :auto_fixer_iteration event
  2. run_check/3 — execute command via Sandbox.Executor
  3. If exit_code == 0 → emit :auto_fixer_completed, return {success: true}
  4. If exit_code != 0:
       a. parse_errors(type, output) — extract error lines (max 10)
       b. If no parseable errors → return {success: false}
       c. attempt_fix(state, errors, iteration)
       d. On fix success → append to fixes_applied, recurse
       e. On fix failure → return {success: false}
```

---

## Error Parsing

Each type uses parser heuristics to extract the most actionable error lines (capped at 10):

| Type | Parser logic |
|------|-------------|
| `:test` | Dispatch by output content: ExUnit patterns (`** (ExUnit`, `test/*.exs:N`), Jest bullets, Go `--- FAIL:`, pytest `FAILED` / `short test summary` |
| `:lint` | Lines containing `:` with `error`, `warning`, or `:N:N:` pattern |
| `:typecheck` | Lines matching `error\|TypeError\|type.*mismatch` |
| `:compile` | Lines matching `error\|Error\|undefined\|cannot find` |
| Generic | Lines matching `error\|fail\|exception\|assert`, length 10–500 chars |

---

## Fix Agent

`attempt_fix/3` builds a structured prompt with the error summary and dispatches `run_fix_agent/5` — a mini stateless ReAct loop that runs against the configured LLM provider directly (not through the full `Loop` GenServer):

```
run_fix_agent calls:
  Providers.chat(messages, tools: fix_tools, temperature: 0.2, max_tokens: 4000)

fix_tools: file_read, file_edit, file_write, shell_execute

Max inner iterations: 10
```

The fix agent is given a type-specific system prompt:

| Type | System prompt focus |
|------|---------------------|
| `:test` | Read failing test + implementation; fix the smaller side; never change correct assertions |
| `:lint` | Read the file; apply idiomatic style fix; ensure no functional change |
| `:typecheck` | Understand expected vs actual types; fix annotation or value; propagate if needed |
| `:compile` | Understand the syntax/semantic error; apply minimal fix; check for related errors |

---

## Error Pattern Cache

Successful fixes are cached in the `:daemon_autofix_cache` ETS table (`:set`, `:public`, `:named_table`). The cache key is an `:erlang.phash2` of the error type + normalized error patterns. Normalization strips line/column numbers, numeric literals, and string literals to make keys stable across minor code changes:

```
"lib/foo.ex:42:5: undefined variable x"
  → "lib/foo.ex:N:N: undefined variable S"
  → truncated to 100 chars
```

On the next `attempt_fix` call, if a cached hint exists it is prepended to the fix prompt as "Previous Fix Hint: ...". The cache persists for the process lifetime; `AutoFixer.clear_cache/0` wipes it.

---

## Events Emitted

| Event | When |
|-------|------|
| `:system_event / :auto_fixer_started` | Before first iteration |
| `:system_event / :auto_fixer_iteration` | Start of each iteration |
| `:system_event / :auto_fixer_completed` | On success or max iterations reached |

---

## Return Type

```elixir
{:ok, %{
  success: boolean(),
  iterations: non_neg_integer(),
  final_output: String.t(),
  fixes_applied: [String.t()],   # summary of each applied fix
  remaining_errors: [String.t()] # error lines still present on failure
}}
| {:error, String.t()}
```

---

## Public API

```elixir
AutoFixer.run(opts)          :: {:ok, fix_result()} | {:error, String.t()}
AutoFixer.run_async(opts)    :: {:ok, Task.t()} | {:error, String.t()}
AutoFixer.detect_command(type, cwd)  :: String.t() | nil
AutoFixer.clear_cache()      :: :ok
```

See also: [loop.md](loop.md)
