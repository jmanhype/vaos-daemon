# BUG-006: Noise Filter Signal-Weight Path Never Receives a Weight

> **Severity:** HIGH
> **Status:** Open
> **Component:** `lib/daemon/channels/noise_filter.ex`, `lib/daemon/agent/loop.ex`
> **Reported:** 2026-03-14

---

## Summary

`NoiseFilter.check/2` has a two-tier architecture: Tier 1 is deterministic
regex, Tier 2 uses a numeric signal weight (0.0–1.0) to gate uncertain messages.
In practice, Tier 2 is never activated because the signal weight is almost never
passed to the filter. The `loop.ex` call path passes `nil` for the weight, so
every message that survives Tier 1 regex is treated as full signal and triggers
a complete LLM call.

## Symptom

Messages like "hmm", "let me think", and single-word utterances that match no
Tier 1 regex bypass the filter and reach the LLM. The filter module's docstring
claims it reduces LLM calls by 40–60%, but this is only achievable when signal
weights are wired in. Without weights, the reduction is limited to the narrow
set of exact-match patterns in `@tier1_patterns`.

## Root Cause

`NoiseFilter.check/2` signature at line 65 in `noise_filter.ex`:

```elixir
def check(message, signal_weight \\ nil) when is_binary(message) do
```

The Tier 2 branch at lines 79–84 only activates when `is_number(signal_weight)`.
When called with `nil`, the `cond` falls through to `:pass` immediately.

In `loop.ex` the filter is invoked at the start of `handle_call({:process, ...})`.
The signal weight is stored in `state.signal_weight` (set from the `:signal_weight`
opt at initialisation), but the call to `NoiseFilter.check/2` does not pass it.
The HTTP orchestration routes (`orchestration_routes.ex` lines 47–54) do read the
`x-signal-weight` header and write it into `session_signal_weight`, but the value
is not threaded through to the loop state that `NoiseFilter.check/2` reads.

Additionally, the `Signal.Classifier` that computes weights is available but is
only called in the inline `/classify` endpoint (`api.ex` line 150), not
automatically before every message enters the loop.

## Impact

- Tier 2 filtering is completely inactive in the current codebase.
- Every borderline message ("hmm", "wait", "interesting") triggers a full LLM
  call that should be a cheap acknowledgment.
- Increases latency and API cost proportionally to the number of low-signal
  user messages in a session.

## Suggested Fix

Wire signal classification into the message-receive path in `loop.ex` before the
noise filter call. Compute weight only when it is not already provided:

```elixir
weight = state.signal_weight || Classifier.classify(message, state.channel).weight
NoiseFilter.check(message, weight)
```

Ensure the `Classifier` call is capped at ~5ms so it does not add visible
latency. The existing `Classifier.classify/2` is synchronous and deterministic,
so this is safe.

## Workaround

Set the `x-signal-weight` header manually in HTTP API calls if you control the
client. CLI and desktop clients have no workaround.
