# New to OSA's Tech Stack? Start Here.

OSA is built on a stack of technologies that are powerful but unfamiliar to most
developers coming from Python, JavaScript, or other mainstream ecosystems. This
section exists to change that.

You do not need to be an Elixir expert to use OSA. But understanding the
fundamentals of how OSA works will help you configure it correctly, debug it
when something goes wrong, and extend it when you need to.

These guides are written for people who have never used Elixir, OTP, or the BEAM
virtual machine. If you already know these technologies, the reference docs in
`/docs/reference/` will serve you better.

---

## Reading Order

Work through these in order if you are starting from zero. Each guide builds on
the previous one.

### 1. The Runtime

- **[beam-and-otp.md](./beam-and-otp.md)** — What is the BEAM VM and OTP?

  Start here. Explains Erlang, Elixir, the BEAM virtual machine, OTP processes,
  GenServer, and the "let it crash" philosophy. This is the foundation everything
  else builds on.

- **[supervision-trees.md](./supervision-trees.md)** — Understanding Supervision Trees

  How OSA organizes its processes into a hierarchy that self-heals. Covers
  restart strategies and walks through OSA's actual four-subsystem tree.

### 2. Storage and Speed

- **[ets-and-persistent-term.md](./ets-and-persistent-term.md)** — Understanding ETS and persistent_term

  How OSA stores and retrieves data at microsecond speed without a database.
  Explains ETS tables, persistent_term, and when OSA uses each.

### 3. Event Routing

- **[goldrush-events.md](./goldrush-events.md)** — What is goldrush and Why OSA Uses It

  How OSA routes events, tool calls, and provider requests at BEAM instruction
  speed using a compiled event dispatch library.

### 4. Intelligence Layer

- **[signal-theory-explained.md](./signal-theory-explained.md)** — Understanding Signal Theory

  OSA classifies every incoming message into a 5-tuple before deciding how to
  handle it. This guide explains why, and what each dimension means.

- **[react-pattern.md](./react-pattern.md)** — The ReAct Pattern: How AI Agents Reason

  The core loop that drives OSA's intelligence: Observe, Think, Act, repeat.
  Explains how the agent decides what to do and when to stop.

### 5. Providers and Models

- **[llm-providers.md](./llm-providers.md)** — How OSA Talks to AI Models

  The 18 LLM providers OSA supports, how provider abstraction works, fallback
  chains, local models with Ollama, and how tool calling and streaming work.

### 6. The Desktop App

- **[tauri-sveltekit.md](./tauri-sveltekit.md)** — Understanding the Desktop App Stack

  How OSA's desktop application works: Tauri (Rust shell), SvelteKit (web UI),
  and the Elixir backend running as a sidecar process.

---

## Quick Reference

| Technology | What it is | Guide |
|---|---|---|
| BEAM / OTP | Elixir's runtime and process model | [beam-and-otp.md](./beam-and-otp.md) |
| Supervision trees | Process hierarchy and fault recovery | [supervision-trees.md](./supervision-trees.md) |
| ETS | In-memory key-value store | [ets-and-persistent-term.md](./ets-and-persistent-term.md) |
| persistent_term | Global immutable cache | [ets-and-persistent-term.md](./ets-and-persistent-term.md) |
| goldrush | Compiled event routing | [goldrush-events.md](./goldrush-events.md) |
| Signal Theory | Message classification system | [signal-theory-explained.md](./signal-theory-explained.md) |
| ReAct | Reason-and-act agent loop | [react-pattern.md](./react-pattern.md) |
| LLM providers | AI model APIs | [llm-providers.md](./llm-providers.md) |
| Tauri + SvelteKit | Desktop app framework | [tauri-sveltekit.md](./tauri-sveltekit.md) |

---

## Still Have Questions?

- Check the [reference docs](../reference/) for API details.
- Check [operations docs](../operations/) for deployment and configuration.
- Check [KNOWN_ISSUES.md](../KNOWN_ISSUES.md) if something is broken.
