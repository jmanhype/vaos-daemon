# BUG-001: Pattern Match Crash in Onboarding on First Run

> **Severity:** CRITICAL
> **Status:** Fixed — v0.2.5
> **Component:** `lib/optimal_system_agent/onboarding.ex`
> **Reported:** 2026-03-14
> **Fixed:** 2026-03-14

---

## Summary

On first run, when no `~/.osa/config.json` existed and no provider was
configured, the onboarding module attempted a pattern match on `nil` — the
result of `Application.get_env(:optimal_system_agent, :default_provider)` before
any provider had been set. The VM raised `FunctionClauseError` and the
application crashed before the onboarding wizard could be displayed.

## Symptom

```
** (FunctionClauseError) no function clause matching in
   OptimalSystemAgent.Onboarding.auto_configure/0
```

Application exits immediately on `mix osa.chat` for new installs.

## Root Cause

`auto_configure/0` in `onboarding.ex` matched on the provider atom returned by
`Application.get_env/2` without handling `nil`:

```elixir
# Before fix:
def auto_configure do
  case Application.get_env(:optimal_system_agent, :default_provider) do
    :ollama -> configure_ollama()
    provider -> configure_cloud(provider)
    # nil was not matched — FunctionClauseError
  end
end
```

When no provider was configured, the `nil` case was unhandled.

## Fix Applied

Added a `nil` guard that falls through to the interactive onboarding wizard
when no provider is configured, and a default `_` catch-all for unknown atoms:

```elixir
def auto_configure do
  case Application.get_env(:optimal_system_agent, :default_provider) do
    :ollama -> configure_ollama()
    nil -> run_first_run_wizard()
    provider when is_atom(provider) -> configure_cloud(provider)
    _ -> run_first_run_wizard()
  end
end
```

## Verification

Fresh install with no `.env` file: `mix osa.chat` now presents the provider
selection wizard instead of crashing.

## Version

Fixed in v0.2.5.
