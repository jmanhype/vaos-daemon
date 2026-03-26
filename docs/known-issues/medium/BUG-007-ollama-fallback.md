# BUG-007: Ollama Included in Fallback Chain When Not Installed

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/daemon/providers/registry.ex`
> **Reported:** 2026-03-14

---

## Summary

When `config :daemon, :fallback_chain, [:anthropic, :openai, :ollama]`
is set, the fallback chain includes `:ollama` as a last resort. If Ollama is
not running at boot time, `init/1` marks it as excluded via
`Process.put(:daemon_ollama_excluded, true)`. However, the exclusion is stored only
in the process dictionary of the `Providers.Registry` GenServer process. When
the fallback chain is evaluated in `filter_boot_excluded_providers/1`, it reads
`Process.get(:daemon_ollama_excluded, false)` — but if this function is called from
a different process (e.g. a Task spawned by the agent loop), the process
dictionary lookup returns `false`, and Ollama is attempted anyway, producing a
flood of `:econnrefused` connection errors.

## Symptom

After starting Daemon with no Ollama instance running, log shows:

```
[Providers.Registry] Ollama not reachable at boot — skipping in fallback chain
```

But subsequent LLM calls still log:

```
Ollama connection failed: %Req.TransportError{reason: :econnrefused}
```

The connection attempt adds ~2 seconds of timeout to every failed fallback.

## Root Cause

`filter_boot_excluded_providers/1` at line 367 in `registry.ex`:

```elixir
defp filter_boot_excluded_providers(chain) do
  if Process.get(:daemon_ollama_excluded, false) do
    Enum.reject(chain, &(&1 == :ollama))
  else
    chain
  end
end
```

`Process.get/2` is per-process. The value set in `init/1` via
`Process.put(:daemon_ollama_excluded, not ollama_reachable)` (line 272) is visible
only inside the GenServer process. When `call_with_fallback/4` delegates to
`chat_with_fallback/3` which calls `filter_boot_excluded_providers/1` from
within a spawned `Task`, the flag is not inherited.

## Impact

- Spurious 2-second connection timeouts on every LLM call when Ollama is absent.
- Log noise: dozens of `econnrefused` lines per session.
- May cause subtle performance regressions in high-traffic deployments.

## Suggested Fix

Replace `Process.put/get` with `:persistent_term` so the flag is visible to all
processes:

```elixir
# In init/1:
:persistent_term.put({__MODULE__, :ollama_excluded}, not ollama_reachable)

# In filter_boot_excluded_providers/1:
defp filter_boot_excluded_providers(chain) do
  if :persistent_term.get({__MODULE__, :ollama_excluded}, false) do
    Enum.reject(chain, &(&1 == :ollama))
  else
    chain
  end
end
```

## Workaround

Remove `:ollama` from the `fallback_chain` configuration when Ollama is not
installed, or set `config :daemon, :default_provider, :anthropic`
(or another cloud provider) to avoid Ollama being included in the chain at all.
