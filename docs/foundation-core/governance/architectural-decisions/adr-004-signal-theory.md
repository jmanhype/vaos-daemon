# ADR-004: Signal Theory for Message Classification

## Status

Accepted

## Date

2025-01-01

---

## Context

Every AI agent framework faces the same problem: all messages are treated as equal.
A user typing "ok" is sent through the same pipeline — including LLM inference — as
a user asking "Refactor this 3,000-line module and add comprehensive tests." The
compute cost, latency, and model tier required are vastly different.

Before Signal Theory was adopted, Daemon's message processing was undifferentiated:

- Every message triggered a full ReAct loop
- No pre-LLM filtering existed
- Low-signal messages ("lol", "ok", greetings) consumed the same resources as
  complex multi-step requests
- Tool lists were passed to the LLM regardless of message complexity, causing
  hallucinated tool sequences for trivial inputs
- There was no structured way to express the *intent type* of a message — only
  the raw text was available to downstream routing logic

The need was for a classification system that could:
1. Run synchronously before any LLM call (sub-millisecond)
2. Produce structured, multi-dimensional output suitable for routing decisions
3. Optionally use LLM enrichment for higher accuracy without blocking the hot path
4. Be grounded in a coherent theoretical framework, not ad-hoc heuristics

### Why Not Simpler Approaches

**Intent classification with an LLM prompt**: Every classification call costs an LLM
round-trip. For a busy installation handling hundreds of messages per hour, this is
prohibitive. It also creates a bootstrapping problem: the LLM must be available to
classify messages before the LLM is called.

**Keyword matching only**: Simple keyword lists produce too many false positives and
cannot capture the communicative purpose of a message (asking for help vs. issuing a
command vs. expressing frustration all use different downstream strategies).

**A fixed taxonomy (intent categories)**: Existing intent classification taxonomies
(e.g., from dialogue systems) are designed for narrow domains. Daemon serves an open-ended
general-purpose agent and needs a domain-agnostic structure.

---

## Considered Alternatives

### Alternative A: Keyword-based Routing Only

Route messages based on keyword lists per action type. No LLM needed.

**Pros:**
- Zero latency
- Simple to implement and audit
- No external dependencies

**Cons:**
- Cannot capture communicative purpose ("help me build X" vs. "run X" vs. "why did X fail")
- No numeric signal weight for tier routing
- Brittle for paraphrases and non-English inputs
- No structured output to drive downstream logic

### Alternative B: Single-dimension Intent Classification

Classify messages into a flat list of intents (question, command, report, etc.) and
route accordingly.

**Pros:**
- Simpler than a multi-dimensional tuple
- Well-studied in dialogue systems literature

**Cons:**
- A single dimension loses information: "help me fix this bug" is simultaneously a
  question, a command, and an issue report
- No weight dimension means no basis for tier selection
- Does not distinguish operational mode (build vs. execute vs. analyze)

### Alternative C: Signal Theory 5-Tuple (chosen)

Classify each message into a 5-tuple `(Mode, Genre, Type, Format, Weight)` based on
Signal Theory (Luna, 2026). Run synchronously via pattern matching; optionally enrich
asynchronously via LLM.

**Pros:**
- Multi-dimensional: captures operational mode, communicative purpose, domain type, format, and information density simultaneously
- Weight is a continuous scalar — directly usable for tier selection without a separate mapping step
- Deterministic fallback is always available (no LLM dependency in the hot path)
- Theoretically grounded in communication science, not ad-hoc
- Extensible: new dimensions or modes can be added without restructuring call sites

**Cons:**
- More complex than a flat taxonomy — contributors must understand 5 orthogonal dimensions
- LLM prompt for classification must be tuned carefully to avoid misclassification
- The weight calibration (which weight maps to which tier) requires empirical tuning

---

## Decision

Adopt Signal Theory (Luna, 2026) as the classification framework for all incoming
messages. Implement a two-level classifier in `Daemon.Signal.Classifier`:

**Level 1 (synchronous, <1ms):** `classify_fast/2` runs regex and keyword patterns to
produce a signal with `confidence: :low`. This is always available.

**Level 2 (async, LLM-enriched):** `classify_async/3` spawns a supervised Task that
calls the configured LLM with a structured prompt. On completion, it emits a
`:signal_classified` event via `Events.Bus`. The main loop uses the Level 1 result
and is not blocked by Level 2.

The signal 5-tuple fields and their routing consequences:

| Field | Values | Routing Use |
|---|---|---|
| Mode | EXECUTE, BUILD, ANALYZE, MAINTAIN, ASSIST | Determines which agent strategies are offered (tools vs. plan vs. reflection) |
| Genre | DIRECT, INFORM, COMMIT, DECIDE, EXPRESS | `GenreRouter` can short-circuit the LLM for some genres (INFORM, EXPRESS) |
| Type | question, request, issue, scheduling, summary, report, general | Contextual label for memory and hook payloads |
| Format | message, command, document, notification | Channel-derived, affects context assembly |
| Weight | 0.0 – 1.0 | Drives tier selection: <0.35 → utility, 0.35–0.65 → specialist, 0.65+ → elite |

The weight also controls the `@tool_weight_threshold` (0.20) in `Agent.Loop` — messages
below this threshold receive no tool list, preventing hallucinated tool sequences for
low-signal inputs.

The canonical implementation lives in `MiosaSignal.MessageClassifier` (shim) with the
Daemon-wired integration in `Daemon.Signal.Classifier`.

Reference: Luna, R. (2026). *Signal Theory: The Architecture of Optimal Intent Encoding
in Communication Systems*. https://zenodo.org/records/18774174

---

## Consequences

### Benefits

- Sub-millisecond synchronous classification means the LLM is never invoked on
  low-signal messages like "ok", "lol", or greetings — significant cost savings at scale
- Tier routing is deterministic from weight rather than requiring a separate heuristic
- Genre-based short-circuiting (INFORM → skip tools, EXPRESS → empathy response) allows
  the agent to handle common non-action messages without any LLM call
- The signal struct is propagated through the event system, giving all subscribers
  (telemetry, memory, hooks) structured signal metadata

### Costs and Trade-offs

- The LLM prompt for classification (`@classification_prompt_fallback` in `Classifier`)
  must be kept in sync with Signal Theory dimension definitions — it is documentation-sensitive
- Weight calibration thresholds (0.20 tool threshold, 0.35/0.65 tier boundaries) were
  chosen empirically and may need tuning for specific deployment contexts
- The 5-tuple adds conceptual complexity compared to a flat routing scheme;
  contributors must read the Signal Theory paper or documentation to understand the dimensions

### Compliance Requirements

- All new channel adapters must classify incoming messages through `Signal.Classifier`
  before passing them to `Agent.Loop`
- The weight field must not be hard-coded; it must come from the classifier
- New routing logic that depends on message content must use signal dimensions rather
  than pattern-matching raw message text

---

## References

- Luna, R. (2026). Signal Theory: The Architecture of Optimal Intent Encoding in Communication Systems. https://zenodo.org/records/18774174
- `lib/daemon/signal/classifier.ex`
- `lib/daemon/agent/loop/genre_router.ex`
- `lib/daemon/channels/noise_filter.ex`
- ADR-003: goldrush Event Bus (Signal Theory events propagate through it)
