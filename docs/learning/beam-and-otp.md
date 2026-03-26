# What is the BEAM VM and OTP?

This guide explains the runtime that powers Daemon. If you have only ever written
Python, JavaScript, or Go, several things about Daemon's architecture will seem
strange until you understand the BEAM and OTP.

---

## Erlang and Elixir

**Erlang** is a programming language created at Ericsson in the 1980s to power
telephone switches. The core requirement was uncompromising: the system had to
handle millions of simultaneous calls, never go down, and survive hardware
failures without losing a single conversation. Erlang was built to meet that
requirement and it has been in production at telecoms companies ever since.

**Elixir** is a modern language that runs on the same virtual machine as Erlang.
It was created in 2011 and offers a friendlier syntax, better tooling, and a
larger ecosystem while keeping everything that makes Erlang reliable. Daemon is
written in Elixir.

The relationship is like this: Elixir is to Erlang what Kotlin is to Java, or
TypeScript is to JavaScript. Different surface, same runtime.

That runtime is called the **BEAM**.

---

## The BEAM Virtual Machine

BEAM stands for Bogdan/Bjorn's Erlang Abstract Machine. The name is historical;
what matters is what the BEAM does.

The BEAM is a virtual machine with unusual design goals. Most virtual machines
(the JVM, CPython, V8) were designed for speed on a single thread. The BEAM was
designed for massive concurrency, fault tolerance, and predictable latency. Those
goals led to very different tradeoffs.

### What makes the BEAM special

**1. Lightweight processes**

The BEAM has its own concept of a "process" that is completely separate from an
operating system process. A BEAM process is tiny — about 2KB of memory at
startup. You can run hundreds of thousands of them on a single machine without
breaking a sweat.

This is different from OS threads (which cost megabytes each) or OS processes
(which cost even more). Think of BEAM processes as extremely cheap actors that
the runtime schedules for you.

In Daemon, each chat session runs in its own process. Crashes are isolated. One
broken session cannot affect another.

**2. Isolated memory**

BEAM processes do not share memory. Each process has its own heap. When one
process wants to communicate with another, it sends a message. The message is
copied between heaps.

This sounds inefficient, but it has a critical property: you can never have a
data race. There is no shared mutable state to corrupt. The garbage collector
runs per-process, so it never stops the entire application.

**3. Preemptive scheduling**

The BEAM scheduler is preemptive. It gives each process a limited number of
"reductions" (roughly equivalent to function calls) before switching to another
process. No process can monopolize the CPU by running an infinite loop.

This is why Daemon stays responsive even when the agent loop is deep in a reasoning
cycle. The scheduler keeps all processes moving.

**4. Fault tolerance**

The BEAM was built on the assumption that things will go wrong. Rather than
trying to prevent all failures (impossible), it provides tools to recover from
them gracefully. We cover this below under OTP.

**5. Hot code reload**

You can upgrade running Elixir code without stopping the system. The BEAM
supports two versions of a module in memory simultaneously during an upgrade.
Daemon uses a related technique with goldrush: compiled routing modules are
replaced at boot and when new tools are registered.

---

## OTP: Not Just a Library

OTP stands for Open Telecom Platform. When people say "OTP", they usually mean
two things at once:

1. A set of Elixir/Erlang modules (GenServer, Supervisor, Application, etc.)
2. A design philosophy for building fault-tolerant concurrent systems

The second part is more important than the first. OTP is a way of thinking about
how to structure programs that need to stay running under pressure.

The core idea is that a running system is a tree of processes, and each process
has a parent responsible for it. If a process crashes, its parent decides what
to do: restart it, restart related processes, or let the crash propagate up.

This is called a supervision tree.

---

## Processes and Message Passing

A BEAM process is created with `spawn` or through supervision. It runs a
function. When the function returns (or crashes), the process ends.

Processes communicate by sending messages to each other's mailbox:

```elixir
# Send a message to a process identified by its PID
send(pid, {:hello, "world"})

# Receive messages in a process
receive do
  {:hello, content} -> IO.puts("Got: #{content}")
end
```

Daemon's event bus, session loops, and tool calls all work through this mechanism.
When the agent loop needs an LLM response, it sends a message to the provider
process and waits for a reply.

---

## GenServer: The Workhorse Pattern

Writing raw `send` and `receive` gets messy. OTP provides **GenServer** (Generic
Server) as a standard pattern for processes that need to:

- Hold state between messages
- Handle synchronous calls (caller waits for response)
- Handle asynchronous casts (fire and forget)
- Handle timeouts and system messages

A GenServer looks like this:

```elixir
defmodule Counter do
  use GenServer

  # Start the server, initial state is 0
  def start_link(_opts), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

  # Public API: synchronous call, waits for a response
  def get_count, do: GenServer.call(__MODULE__, :get)

  # Public API: asynchronous cast, fire and forget
  def increment, do: GenServer.cast(__MODULE__, :increment)

  # Callback: initialize state
  def init(initial), do: {:ok, initial}

  # Callback: handle a synchronous call
  def handle_call(:get, _from, state), do: {:reply, state, state}

  # Callback: handle an asynchronous cast
  def handle_cast(:increment, state), do: {:noreply, state + 1}
end
```

Daemon uses GenServer extensively: the event bus, tool registry, provider registry,
memory, orchestrator, scheduler, and more are all GenServers.

---

## Supervisors and "Let It Crash"

The "let it crash" philosophy sounds reckless but is the opposite. It means:

- Do not write defensive code that tries to handle every possible error.
- Instead, let the process crash cleanly and rely on the supervisor to restart it.
- The restarted process starts fresh, with clean state, and continues working.

This is why airplane pilots are trained to handle emergencies rather than
pretending emergencies cannot happen. A system designed to recover from failures
is more reliable than a system that tries to prevent them all.

A **Supervisor** is a special process whose only job is to watch other processes
and restart them when they crash. Supervisors form the backbone of OTP
applications.

### Restart strategies

Supervisors support three restart strategies:

**`:one_for_one`** — If one child crashes, restart only that child. Other
children continue running. Use this when children are independent.

```
Supervisor
├── Worker A  (crashes → restarts A only)
├── Worker B  (unaffected)
└── Worker C  (unaffected)
```

**`:one_for_all`** — If one child crashes, restart all children. Use this when
children are tightly coupled and cannot function without each other.

```
Supervisor
├── Worker A  (crashes → restarts A, B, C)
├── Worker B  (restarts)
└── Worker C  (restarts)
```

**`:rest_for_one`** — If one child crashes, restart it and all children that
were started after it. Use this when children have a startup dependency order.

```
Supervisor
├── Worker A  (crashes → restarts A, B, C)
├── Worker B  (restarts — depends on A)
└── Worker C  (restarts — depends on A)
```

---

## Why Daemon Chose Elixir and OTP

Daemon's requirements map directly onto what Elixir and OTP were built for:

| Daemon requirement | OTP solution |
|---|---|
| Each chat session is isolated | Each session is a separate process |
| Sessions can crash without affecting others | Process isolation + supervision |
| Multiple sessions run concurrently | BEAM scheduler handles thousands of processes |
| Agent loop must stay responsive during tool execution | Preemptive scheduler prevents starvation |
| Event routing must not block callers | Async message passing via supervised tasks |
| System must restart after crashes | Supervision trees with configured restart strategies |
| Tool registry needs hot updates | GenServer manages state; goldrush recompiles at write time |

The alternative — Python threads, Node.js event loop, Go goroutines — would
require significantly more effort to achieve the same reliability guarantees that
OTP gives you by default.

---

## Next Steps

Now that you understand processes, GenServer, and supervisors, read
[supervision-trees.md](./supervision-trees.md) to see how Daemon organizes all of
its processes into a four-subsystem hierarchy and why each subsystem uses the
restart strategy it does.
