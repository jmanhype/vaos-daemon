# Channels: Overview

OSA channels are the inbound/outbound transport layer between external platforms and the agent runtime. Every channel is an independent GenServer adapter that implements a common behaviour contract, receives messages from its respective platform, routes them through `Agent.Loop`, and sends the responses back.

---

## Behaviour Contract

Every channel adapter implements `OptimalSystemAgent.Channels.Behaviour`:

| Callback | Signature | Description |
|----------|-----------|-------------|
| `channel_name/0` | `() -> atom()` | Identifier atom, e.g. `:telegram`, `:slack` |
| `start_link/1` | `(keyword()) -> GenServer.on_start()` | Start the adapter as a named GenServer |
| `send_message/3` | `(chat_id, message, opts) -> :ok \| {:error, term()}` | Send a message to the platform |
| `connected?/0` | `() -> boolean()` | Whether the adapter is currently active |

An adapter returns `:ignore` from `init/1` when its required configuration is absent. This is the standard pattern for optional channels — only configured adapters start.

---

## Lifecycle Components

### Manager (`Channels.Manager`)

The Manager is the central registry and control point for all channel adapters. It holds a compile-time list of every known adapter module in `@channel_modules`.

**Key functions:**

| Function | Description |
|----------|-------------|
| `start_configured_channels/0` | Start all adapters whose config is present (called once at boot) |
| `list_channels/0` | List all known channels with name, module, pid, and connected flag |
| `active_channels/0` | List only connected channels |
| `send_to_channel/4` | Route an outbound message to a named channel |
| `start_channel/1` | Start a specific channel by name atom |
| `stop_channel/1` | Stop a running channel adapter |
| `channel_status/1` | Return full status map for a channel |
| `test_channel/1` | Probe a channel for liveness |

Starting and stopping emits `channel_connected` and `channel_disconnected` events on the Bus. Config is resolved from `~/.osa/config.json` first, falling back to `Application.get_env/2` for known platform keys.

### Session (`Channels.Session`)

`Session.ensure_loop/3` is called by every inbound channel adapter to guarantee an `Agent.Loop` process exists for the given session before processing a message. It looks up the session in `OptimalSystemAgent.SessionRegistry`. If no loop is found, it starts one under `SessionSupervisor`. A single retry (after 50 ms) handles supervisor contention races.

Session IDs follow the pattern `<channel>_<platform_id>`, e.g.:
- Telegram: `telegram_123456789`
- Slack: `slack_U01ABCDEF_C01GHIJKL`
- CLI: `cli_<8-byte-hex>`

### Starter (`Channels.Starter`)

`Channels.Starter` is a GenServer in the main supervision tree. Its sole purpose is to call `Manager.start_configured_channels/0` using `handle_continue/2` — after `init/1` returns, and therefore after all other supervised processes (ETS tables, registries) are fully initialised, but without any wall-clock sleep.

---

## NoiseFilter (`Channels.NoiseFilter`)

The NoiseFilter intercepts low-signal messages before they reach the LLM, eliminating an estimated 40–60% of trivial inputs.

### Two-tier architecture

**Tier 1 — Deterministic regex (<1 ms)**

Matches known noise patterns without any scoring:
- Single characters, `k`/`y`/`n` variants
- Confirmations: `ok`, `sure`, `got it`, `yep`, …
- Greetings: `hi`, `hey`, `hello`, …
- Reactions: `lol`, `thanks`, `cool`, …
- Emoji-only strings
- Pure punctuation or whitespace

**Tier 2 — Signal weight threshold**

When a `signal_weight` (0.0–1.0) is provided by a classifier:

| Range | Verdict |
|-------|---------|
| 0.00–0.15 | Definitely noise → filter with ack |
| 0.15–0.35 | Likely noise → filter with ack |
| 0.35–0.65 | Uncertain → return `{:clarify, prompt}` |
| 0.65–1.00 | Signal → `:pass` |

Thresholds are runtime-configurable:

```elixir
config :optimal_system_agent,
  noise_filter_thresholds: %{
    definitely_noise: 0.15,
    likely_noise: 0.35,
    uncertain: 0.65
  }
```

`calibrate_weights/2` adjusts thresholds automatically given bucket statistics; requires at least 50 samples before taking effect.

### Return values

| Value | Meaning |
|-------|---------|
| `:pass` | Message is substantive — route to LLM |
| `{:filtered, ack}` | Noise — return short acknowledgment |
| `{:clarify, prompt}` | Low signal — ask user to elaborate |

The convenience wrapper `filter_and_reply/3` takes a `reply_fn` and returns a boolean: `true` means the message was consumed by the filter.

---

## Signal Routing

The full inbound path for any channel:

```
Platform webhook / poll
  -> Channel adapter (GenServer)
     -> Channels.Session.ensure_loop/3
        -> Agent.Loop.process_message/2
           -> (LLM, tools, orchestration)
        <- {:ok, response} | {:plan, text} | {:filtered, signal} | {:error, reason}
     -> channel.send_message(chat_id, response)
  -> Platform API
```

The NoiseFilter sits between the channel adapter and `Loop.process_message/2`. CLI channels apply it in `process_input/2`; messaging adapters apply it in their `process_update/handle_message` functions.

---

## See Also

- [cli.md](cli.md) — CLI channel detail
- [http.md](http.md) — HTTP channel and all route modules
- [messaging.md](messaging.md) — Telegram, Discord, Slack, and all messaging adapters
