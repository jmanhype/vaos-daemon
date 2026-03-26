# Understanding Signal Theory

Signal Theory is Daemon's approach to classifying messages before deciding how to
handle them. It is one of the ideas that makes Daemon different from a simple
LLM wrapper.

---

## The Problem: Every Message Treated the Same

Most AI agents operate on a simple loop: receive message, call LLM, return
response. Every message gets the same treatment. "Hello" gets an LLM call.
"Deploy to production immediately" gets an LLM call. A 500-word technical
specification gets an LLM call.

This approach wastes tokens and misses opportunities. A greeting does not need
tool access. A status report does not need reasoning. A simple acknowledgment
("ok", "sounds good") does not need the agent to do anything except acknowledge
it was received.

Beyond token cost, treating every message the same leads to routing mistakes.
A message that is clearly a command ("run the tests") should not go through
the same reasoning path as a conceptual question ("explain how the test runner
works"). They require different handling.

Signal Theory says: **classify the message first, then route it**.

---

## The 5-Tuple: S = (Mode, Genre, Type, Weight, Format)

Every incoming message in Daemon is classified into five dimensions. Together they
form a signal:

```
S = (Mode, Genre, Type, Weight, Format)
```

Think of this as a diagnostic label that tells Daemon what to do with a message
before any LLM reasoning begins.

---

## Mode: What the User Wants Done

Mode answers: "What operational action does this message require?"

| Mode | Meaning | Examples |
|---|---|---|
| `EXECUTE` | Do something NOW | "run the tests", "deploy", "send the email" |
| `BUILD` | Create something new | "write a script", "generate a report", "scaffold a service" |
| `ANALYZE` | Provide insight | "what is the error rate?", "compare these metrics", "summarize the logs" |
| `MAINTAIN` | Fix or update something existing | "fix the bug", "update the config", "patch this dependency" |
| `ASSIST` | Explain or guide | "how do I do X?", "what does this mean?", "help me understand" |

Mode is the coarsest routing dimension. An `EXECUTE` message routes differently
from an `ASSIST` message. Execute might invoke tools immediately. Assist might
skip tools entirely and go straight to generation.

Important: mode is classified by primary intent, not individual words. "Help me
build a rocket" is `BUILD` (the goal is to build something), not `ASSIST`. "Can
you run the tests?" is `EXECUTE` (the goal is to run something), not a question.

---

## Genre: The Intent of the Communication

Genre answers: "What is the communicative purpose of this message?"

This comes from linguistics — specifically speech act theory. Every utterance
does something beyond its literal meaning.

| Genre | Meaning | Examples |
|---|---|---|
| `DIRECT` | Command or instruction — telling the agent to do something | "deploy now", "stop the job" |
| `INFORM` | Sharing information or status | "the build failed", "I've updated the config" |
| `COMMIT` | Making a promise or declaration of intent | "I'll handle the database migration" |
| `DECIDE` | Making or requesting a decision | "approve this PR", "should I use Redis or Postgres?" |
| `EXPRESS` | Emotional expression | "this is great!", "I'm frustrated with this error" |

Genre enables intelligent shortcuts. A message classified as `EXPRESS` genre
almost certainly does not need tool calls — it needs a brief empathetic response.
A message classified as `DIRECT` genre needs action, not explanation.

---

## Type: The Domain Category

Type is a more specific classification within genre and mode:

| Type | Description |
|---|---|
| `question` | Asking for information (contains ?, starts with who/what/when/where/why/how) |
| `request` | Asking for an action to be performed |
| `issue` | Reporting a problem (error, bug, broken, crash) |
| `scheduling` | Time-related (remind, schedule, tomorrow, next week) |
| `summary` | Asking for condensed information (summarize, recap, overview) |
| `report` | Providing status or results |
| `general` | None of the above |

Type helps Daemon select the right response style and tools. An `issue` type message
might trigger the debugging reasoning strategy. A `scheduling` type message routes
to the scheduler subsystem.

---

## Weight: How Important and Complex

Weight is a float from 0.0 to 1.0 representing the informational density and
urgency of the message.

| Range | Meaning | Examples |
|---|---|---|
| 0.0–0.2 | Noise | "ok", "sure", "yes", single-word acknowledgments |
| 0.3–0.5 | Low information | "thanks", "got it", "sounds good" |
| 0.5–0.7 | Medium | Standard questions, simple single-step requests |
| 0.7–0.9 | High | Complex tasks, multi-part requests, technical content |
| 0.9–1.0 | Critical | Urgent issues, emergencies, production problems |

Weight is the most operationally significant dimension. Daemon uses it to:

- **Skip tool loading** for low-weight messages (weight < 0.3 means the message
  is probably noise; loading all available tools for a greeting wastes tokens).
- **Select reasoning strategy** — high-weight messages might use a more thorough
  reasoning strategy like Tree of Thoughts rather than simple ReAct.
- **Prioritize** — in a multi-session swarm, high-weight events can preempt
  lower-priority work.

---

## Format: How the Message is Structured

Format describes the structural presentation of the message based on the channel
it arrived from:

| Format | Channel |
|---|---|
| `command` | CLI — messages from the terminal |
| `message` | Chat channels (Telegram, Discord, Slack, WhatsApp) |
| `notification` | Webhook — programmatic triggers |
| `document` | Filesystem — file-based input |

Format helps Daemon adapt its response style to the communication medium. A CLI
command gets a precise, structured response. A chat message gets a conversational
reply. A document gets a document back.

---

## How Classification Works

Daemon classifies messages using two approaches in sequence:

**1. Fast deterministic classification** (always runs, < 1ms, `confidence: :low`)

Pattern matching on the message text. Checks for question words, command verbs,
exclamation marks, URLs, and other surface features. Produces a rough
classification instantly.

**2. LLM enrichment** (runs asynchronously when enabled, `confidence: :high`)

Sends the message to the configured LLM with a classification prompt. The LLM
returns a JSON object like:

```json
{"mode": "EXECUTE", "genre": "DIRECT", "type": "request", "weight": 0.75}
```

This is fire-and-forget: the LLM enrichment runs in a supervised background
task. The initial fast classification is used immediately; the LLM result updates
the signal when it arrives and is emitted as a `signal_classified` event.

---

## Real Examples with Weight Scores

These are examples of how Daemon classifies actual messages:

```
"ok"
→ Mode: ASSIST, Genre: EXPRESS, Type: general, Weight: 0.05
→ Result: Simple acknowledgment, no tools loaded, minimal response

"what time is it?"
→ Mode: ASSIST, Genre: DIRECT, Type: question, Weight: 0.3
→ Result: Quick response, maybe one time-lookup tool

"run all the tests and fix any failures you find"
→ Mode: EXECUTE, Genre: DIRECT, Type: request, Weight: 0.85
→ Result: ReAct loop, shell_execute tool, file_read, file_edit

"the production database is down and customers cannot log in"
→ Mode: MAINTAIN, Genre: INFORM, Type: issue, Weight: 0.97
→ Result: High priority, immediate tool access, escalation path

"explain how the authentication flow works"
→ Mode: ASSIST, Genre: DIRECT, Type: question, Weight: 0.6
→ Result: Analysis mode, file_read tools to inspect code, no writes

"I'll handle the deployment tonight"
→ Mode: EXECUTE, Genre: COMMIT, Type: general, Weight: 0.4
→ Result: Acknowledgment, possibly schedule a follow-up check

"generate a weekly summary of all agent activities"
→ Mode: BUILD, Genre: DIRECT, Type: summary, Weight: 0.72
→ Result: Analysis tools, memory recall, structured report generation
```

---

## How It Saves Tokens and Improves Accuracy

Token savings come from two places:

1. **Low-weight messages skip tool loading**: The LLM call to handle "ok" does
   not need to know about the 40 available tools. Excluding the tool definitions
   from the context saves hundreds of tokens per message.

2. **Genre routing can skip the LLM entirely**: An `EXPRESS` genre message with
   weight < 0.2 is noise. Daemon can respond with a canned acknowledgment without
   an LLM call at all.

Accuracy improves because the reasoning strategy matches the message type. A
`BUILD`-mode message triggers a creation-oriented reasoning path. An `ANALYZE`-
mode message triggers ChainOfThought rather than ReAct. Getting the strategy
right before reasoning begins produces better results than using the same strategy
for everything.

---

## The Research Foundation

Signal Theory is formally defined in:

> Luna, R. (2026). *Signal Theory: The Architecture of Optimal Intent Encoding
> in Communication Systems*. Zenodo. https://zenodo.org/records/18774174

Daemon's implementation lives in `MiosaSignal` (the canonical library) and
`Daemon.Signal.Classifier` (the Daemon-wired wrapper that injects the
event bus and LLM provider into the classification pipeline).

---

## Next Steps

Read [react-pattern.md](./react-pattern.md) to see how Daemon uses the signal
classification to select a reasoning strategy and drive the agent loop.
