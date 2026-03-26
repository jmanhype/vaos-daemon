# BUG-002: :signal_classified Missing from Event Registry

> **Severity:** HIGH
> **Status:** Fixed — v0.2.5
> **Component:** `lib/daemon/bridge/pubsub.ex`, `lib/daemon/signal/classifier.ex`
> **Reported:** 2026-03-14
> **Fixed:** 2026-03-14

---

## Summary

`Signal.Classifier` emitted `:signal_classified` events via `Bus.emit/2` at
`classifier.ex` line 96, but the PubSub bridge at `bridge/pubsub.ex` did not
include `:signal_classified` in `@tui_event_types`. As a result, every
classification event was processed and stored, but never forwarded to the TUI
SSE stream or the Go TUI subscriber. The TUI received no feedback about signal
classification outcomes — the "genre" and "weight" fields were invisible to
connected clients.

## Symptom

TUI and desktop app showed no signal classification metadata (genre badges,
signal weight bars) even though the `Signal.Classifier` was running and the
events appeared in server-side debug logs. The `/classify` HTTP endpoint worked
correctly (returning JSON), but the SSE stream carried no classification events.

## Root Cause

`@tui_event_types` in `pubsub.ex` (line 95) listed:

```elixir
@tui_event_types ~w(llm_chunk llm_response agent_response tool_result tool_error
                    thinking_chunk agent_message)a
```

`:signal_classified` was emitted by `Classifier.classify/2` (line 96 of
`classifier.ex`) but was absent from this list, so `tui_event?/1` returned
`false` for all `:signal_classified` events. The bridge discarded them without
forwarding.

## Fix Applied

Added `:signal_classified` to `@tui_event_types`:

```elixir
@tui_event_types ~w(llm_chunk llm_response agent_response tool_result tool_error
                    thinking_chunk agent_message signal_classified)a
```

This is visible at `bridge/pubsub.ex` line 96 in the current codebase.

## Verification

After the fix, the TUI SSE stream receives `signal_classified` events within
~1ms of each message being classified. The desktop genre badge updates in real
time.

## Version

Fixed in v0.2.5.
