# BUG-015: Invalid Swarm Pattern Silently Falls Back to Pipeline

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/daemon/channels/http/api/orchestration_routes.ex`, `lib/daemon/swarm/patterns.ex`
> **Reported:** 2026-03-14

---

## Summary

When a client sends `POST /api/v1/swarm/launch` with an unrecognised `"pattern"`
string that is not in `@execution_patterns` and not in the named presets from
`priv/swarms/patterns.json`, the `parse_swarm_pattern_opts/1` function should
return `{:error, :invalid_pattern, msg}` and the endpoint should respond with
HTTP 400. Instead, under some code paths, the pattern validation is bypassed and
the swarm launches with `:pipeline` as the default pattern, silently ignoring
the user's intent.

## Symptom

```json
POST /api/v1/swarm/launch
{"task": "analyze codebase", "pattern": "magic-pattern-xyz"}

→ 202 {"swarm_id": "swarm_abc", "pattern": "pipeline", ...}
```

No error is returned. The user does not know their pattern specification was
ignored.

## Root Cause

`parse_swarm_pattern_opts/1` in `orchestration_routes.ex` at line 472:

```elixir
defp parse_swarm_pattern_opts(nil), do: {:ok, []}

defp parse_swarm_pattern_opts(p) when is_binary(p) do
  cond do
    p in @execution_patterns ->
      {:ok, [pattern: String.to_existing_atom(p)]}

    true ->
      case SwarmPatterns.get_pattern(p) do
        {:ok, config} ->
          pattern_atom = case config["mode"] do ... end
          opts = if pattern_atom, do: [pattern: pattern_atom], else: []
          {:ok, opts}                                   # ← falls through without error

        {:error, :not_found} ->
          {:error, :invalid_pattern, "Unknown pattern '#{p}'..."}
      end
  end
end
```

When `SwarmPatterns.get_pattern/1` returns `{:ok, config}` but `config["mode"]`
is `nil` or an unrecognised string, `pattern_atom` is `nil` and `opts` is `[]`.
`Swarm.launch/2` then uses the `@valid_patterns` default in
`swarm/orchestrator.ex` line 38, which is `[:parallel, :pipeline, :debate, :review]`,
and picks `:pipeline` as the fallback.

## Impact

- User specifies a pattern that does not match their intent, but receives no
  error.
- Swarm executes with incorrect coordination strategy, potentially producing
  lower quality or incorrect results.
- Diagnosing why a swarm result was unexpected is difficult when the audit log
  shows "pipeline" rather than the requested pattern.

## Suggested Fix

In `parse_swarm_pattern_opts/1`, treat a `nil` `pattern_atom` as an error:

```elixir
{:ok, config} ->
  pattern_atom = case config["mode"] do
    "parallel" -> :parallel
    "pipeline" -> :pipeline
    "sequential" -> :pipeline
    "debate" -> :debate
    "review" -> :review
    mode ->
      Logger.warning("Unknown swarm mode '#{mode}' in pattern '#{p}'")
      nil
  end
  if pattern_atom do
    {:ok, [pattern: pattern_atom]}
  else
    {:error, :invalid_pattern, "Pattern '#{p}' has unrecognised mode '#{config["mode"]}'"}
  end
```

## Workaround

Only use documented pattern names: `parallel`, `pipeline`, `debate`, `review`,
or named presets from `priv/swarms/patterns.json` (`code-analysis`,
`full-stack`, `debug-swarm`, `performance-audit`, `security-audit`).
