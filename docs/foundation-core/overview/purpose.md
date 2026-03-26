# Purpose — Why Daemon Exists

**Audience:** Engineers evaluating Daemon, contributors understanding design intent,
researchers studying applied Signal Theory.

---

## The Problem

Every major AI agent framework today has the same architectural defect: it
processes every message identically. A user asking "What time is it?" and a user
saying "Refactor this 3,000-line module, add tests, and document the API" travel
through the same pipeline. Same model tier. Same context assembly. Same strategy
selection overhead. Same latency. Same cost.

This is not an implementation shortcoming — it is a category error in design.
These are not the same kind of input. They carry different amounts of information.
They require different amounts of compute. They need different reasoning strategies.
Processing them identically is wasteful in the trivial case and under-powered in
the complex case.

The root cause is that most systems skip the classification step. They take raw
text and immediately ask the LLM to reason about it, which means the LLM is doing
two things at once: figuring out what kind of thing this is, and then doing the
thing. Mixing those concerns makes both worse.

---

## The Solution: Classify Before You Route

Daemon separates classification from execution. Every input passes through a Signal
Theory classifier that produces a structured 5-tuple before anything else happens:

```
S = (Mode, Genre, Type, Format, Weight)
```

This tuple is cheap to compute (LLM-primary with a deterministic regex fallback
that runs in under 1ms), cached in ETS with a SHA256 key and 10-minute TTL, and
used to drive every downstream routing decision: which model tier, which reasoning
strategy, whether to invoke the orchestrator, how much context to assemble.

The classifier runs before the agent loop. The agent loop never has to guess what
kind of task it is handling.

---

## Signal Theory: The Five Dimensions

Signal Theory is the governing framework, formalized in:

> Luna, R. (2026). *Signal Theory: The Architecture of Optimal Intent Encoding
> in Communication Systems.* Zenodo. https://zenodo.org/records/18774174

Each input is classified across five orthogonal dimensions:

### Mode — What operational action is required?

| Mode | Meaning | Examples |
|---|---|---|
| BUILD | Create something new | "Generate a REST API", "scaffold this module", "write tests" |
| EXECUTE | Perform an action now | "Run the test suite", "deploy to staging", "send this email" |
| ANALYZE | Produce insight | "What caused this crash?", "show Q3 revenue trend" |
| MAINTAIN | Fix or update something | "Fix the login bug", "migrate this schema", "update dependencies" |
| ASSIST | Provide guidance | "Explain how OTP works", "what does this error mean?" |

Mode determines reasoning strategy and orchestration depth. BUILD and EXECUTE
tasks with high weight are candidates for multi-agent decomposition. ASSIST tasks
almost never are.

### Genre — What is the communicative act?

| Genre | Meaning |
|---|---|
| DIRECT | A command or instruction — do something |
| INFORM | Sharing information — here are facts |
| COMMIT | Making a promise — "I will handle it" |
| DECIDE | Approving, rejecting, or choosing |
| EXPRESS | Emotional expression — gratitude, frustration |

Genre drives response style and follow-up behavior. A COMMIT genre signals the
agent should track what was promised. An EXPRESS genre shifts tone.

### Type — What is the domain category?

```
question   — asking for information (contains ?, who/what/when/where/why/how)
request    — asking for an action to be performed
issue      — reporting a problem (error, bug, broken, crash, fail)
scheduling — time-related (remind, schedule, later, tomorrow)
summary    — asking for condensed information
report     — providing status or results
general    — none of the above
```

### Format — What container is this message in?

```
message      — conversational input
command      — slash command or structured directive
document     — long-form content (uploaded file, paste)
notification — system-generated alert
```

### Weight — How much information does this carry?

Weight is a continuous value in [0.0, 1.0] that encodes informational density
and task complexity:

```
0.0 – 0.2   Noise: greetings, filler, single words ("ok", "thanks", "hi")
0.2 – 0.35  Low: simple acknowledgments, trivial questions
0.35 – 0.65 Medium: standard questions, single-step requests
0.65 – 0.9  High: complex tasks, multi-part requests, technical content
0.9 – 1.0   Critical: production incidents, emergencies, urgent multi-step work
```

Weight directly determines which tier of model handles the request:

```elixir
# From Daemon.Agent.Tier
def tier_for_complexity(complexity) when complexity <= 3, do: :utility
def tier_for_complexity(complexity) when complexity <= 6, do: :specialist
def tier_for_complexity(_complexity),                     do: :elite
```

| Weight | Tier | Model Class | Token Budget |
|---|---|---|---|
| 0.00 – 0.35 | Utility | 8B models, Haiku, GPT-3.5 | 100K tokens |
| 0.35 – 0.65 | Specialist | 70B models, Sonnet, GPT-4o-mini | 200K tokens |
| 0.65 – 1.00 | Elite | Frontier models, Opus, GPT-4o | 250K tokens |

---

## Theoretical Grounding

Daemon's architecture is grounded in four principles from communication and systems
theory. These are not decorative citations — they directly shaped design decisions.

### Shannon — Channel Capacity

Shannon's theorem establishes that every communication channel has finite
information-carrying capacity. Exceeding that capacity degrades signal quality.

**Applied to Daemon:** Every LLM call has a token budget. Filling that budget with
low-relevance context degrades response quality. The two-tier context assembly
system (static cached base + dynamic budgeted context) and the three-zone
compactor (HOT / WARM / COLD) are direct applications of Shannon's insight: match
information density to channel capacity. Do not waste bits on noise.

### Ashby — Requisite Variety

Ashby's Law states that a controller must possess at least as much variety as the
system it controls. A controller with insufficient variety cannot maintain
stability across all system states.

**Applied to Daemon:** A single model at a single tier cannot adequately handle the
full variety of inputs an agent receives — from trivial greetings to multi-week
engineering projects. Daemon's variety-matching response: 18 providers, 3 tiers per
provider, 12 channel adapters, 5 reasoning strategies (CoT, Reflection, MCTS,
Tree of Thoughts, ReAct), 4 swarm collaboration patterns, 34 tools, and unlimited
custom skills. The system's variety matches its input space.

### Beer — Viable System Model

Beer's Viable System Model (VSM) identifies five subsystems that any viable
autonomous system must possess: operations, coordination, control, intelligence,
and policy. Each mode in Signal Theory maps to one of these subsystems:

| VSM Subsystem | Daemon Mode |
|---|---|
| System 1 — Operations | EXECUTE |
| System 2 — Coordination | MAINTAIN |
| System 3 — Control | ANALYZE |
| System 4 — Intelligence | BUILD |
| System 5 — Policy | ASSIST |

This is not coincidental. The five modes were derived from the VSM to ensure that
Daemon can function as a genuinely viable autonomous system — not just a chatbot with
tool access.

### Wiener — Feedback Loops

Wiener established that stable systems require negative feedback loops: the
output of a system is measured and fed back as input to correct future behavior.

**Applied to Daemon:** Every agent action produces feedback that updates system
state. Tool execution results are fed back into the agent loop. Learning patterns
are captured by the episodic memory system and scored by the knowledge graph.
Vault observations decay exponentially over time (temporal scoring) — the system
literally forgets what is no longer relevant. Hook middleware measures execution
quality and blocks unsafe actions before they propagate. The PACT framework
(Planning → Action → Coordination → Testing) is a formalized feedback loop at
the orchestration level.

---

## What Daemon Is Not Trying to Do

Understanding scope is as important as understanding purpose.

Daemon is not trying to be the fastest possible inference layer. Inference speed is
a provider concern — Daemon's job is to send the right request to the right provider
with the right context.

Daemon is not trying to replace existing chat interfaces. It sits behind them. The
12 channel adapters translate between platform-specific formats and Daemon's internal
signal representation.

Daemon is not trying to be a general-purpose web framework. Bandit and Plug are
present for the HTTP API surface and webhook reception only. There is no routing
DSL, no template engine, no session middleware.

Daemon is not trying to prevent all failure. OTP's "let it crash" philosophy means
the system is designed to recover from failure automatically, not to avoid it at
all costs. See [Architecture Principles](architecture-principles.md) for how this
shapes every supervision decision.

---

## Next

- [Architecture Principles](architecture-principles.md) — The design rules that
  follow from this purpose
- [System Boundaries](system-boundaries.md) — Concrete scope: what Daemon owns,
  what it delegates
- [Glossary](glossary.md) — Canonical definitions for all terms used above
