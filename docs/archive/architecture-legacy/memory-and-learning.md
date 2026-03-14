# Memory & Learning Systems

> How OSA remembers, learns, and improves over time

## Overview

OSA has four memory layers and a self-learning engine. Memory persists across sessions. The learning engine identifies patterns from errors and successes, consolidating them into reusable knowledge.

## Memory Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Memory System                        │
│                                                           │
│  ┌─────────────┐  ┌──────────┐  ┌─────────┐  ┌───────┐ │
│  │   Session    │  │ Long-term │  │ Episodic│  │ Vault │ │
│  │   (JSONL)    │  │(MEMORY.md)│  │  (ETS)  │  │       │ │
│  │             │  │           │  │         │  │ 8 cats│ │
│  │ Per-session  │  │ Across    │  │ Keyword │  │ Facts │ │
│  │ conversation │  │ all       │  │ inverted│  │ Obs.  │ │
│  │ history     │  │ sessions  │  │ index   │  │ Decay │ │
│  └─────────────┘  └──────────┘  └─────────┘  └───────┘ │
│         │               │             │            │      │
│         └───────────────┼─────────────┼────────────┘      │
│                         │             │                    │
│                   ┌─────┴─────┐ ┌─────┴──────┐           │
│                   │  Cortex   │ │   Vault    │           │
│                   │ Synthesis │ │ FactStore  │           │
│                   │           │ │ (ETS+JSONL)│           │
│                   │ Topics    │ │ Observer   │           │
│                   │ Bulletins │ │ Lifecycle  │           │
│                   │ Patterns  │ │ Handoffs   │           │
│                   └───────────┘ └────────────┘           │
└──────────────────────────────────────────────────────────┘
```

## Four Memory Layers

### 1. Session Memory (JSONL)

**Location**: `~/.osa/sessions/{session_id}/messages.jsonl`

Append-only conversation history for the current session. Each line is a JSON object:

```json
{"role": "user", "content": "Fix the auth bug", "timestamp": "2026-02-27T10:00:00Z"}
{"role": "assistant", "content": "Looking at the auth module...", "timestamp": "2026-02-27T10:00:05Z"}
```

**Commands:**
```
/sessions          # List all stored sessions
/resume <id>       # Resume a previous session
/new               # Start fresh session
/history           # View current session history
/history search <q># Search across session history
```

### 2. Long-term Memory (MEMORY.md)

**Location**: `~/.osa/MEMORY.md`

Persistent Markdown file updated by the agent after significant events. Categories:

- **Decisions** — Architecture and design choices
- **Patterns** — Recurring code/workflow patterns
- **Solutions** — Proven fixes for known problems
- **Context** — User preferences, project structure
- **Facts** — Important information learned

**Commands:**
```
/memory            # Show memory stats
/mem-save <type>   # Save to memory (decision|pattern|solution|context)
/mem-search <q>    # Search memory
/mem-recall <topic># Recall specific topic
/mem-list          # List entries by collection
/mem-stats         # Memory statistics
/mem-export        # Export memory to file
/mem-delete <id>   # Delete an entry
/mem-context       # Save current conversation context
```

### 3. Episodic Index (ETS)

In-memory inverted keyword index for fast retrieval. Indexes both session and long-term memory. Enables sub-millisecond lookups by keyword.

Built at startup from MEMORY.md and session files. Rebuilt on memory writes.

### 4. Vault — Structured Memory

**Module**: `Vault` (facade) + `Vault.Supervisor` (FactStore + Observer)

**Location**: `~/.osa/vault/`

The Vault is a structured memory system that augments the three stores above with typed categories, rule-based fact extraction, scored observations, and session lifecycle management.

```
~/.osa/vault/
├── facts/          # Verified facts with confidence scores
├── decisions/      # Architecture and design choices
├── lessons/        # Learned insights from errors/successes
├── preferences/    # User/project preferences
├── commitments/    # Promises and deadlines
├── relationships/  # People, roles, entities
├── projects/       # Project metadata and status
├── observations/   # Scored observations with time decay
├── handoffs/       # Session handoff documents
└── .vault/
    ├── facts.jsonl       # Temporal fact store (append-only, versioned)
    ├── checkpoints/      # Mid-session save points
    └── dirty/            # Dirty-death detection flags
```

**Key capabilities:**

| Feature | Implementation |
|---------|---------------|
| **Typed categories** | 8 categories, each with YAML frontmatter template and dedicated directory |
| **Fact extraction** | ~15 regex patterns extract decisions, preferences, versions, ports, URLs, lessons, etc. |
| **Temporal versioning** | Facts are never deleted — superseded facts get `valid_until` timestamp |
| **Scored observations** | `score * e^(-decay_rate * hours)` — stale observations naturally fall out |
| **Session lifecycle** | Wake (dirty-death detection) → Checkpoint (periodic) → Sleep (handoff doc) |
| **Context profiles** | 4 profiles control vault → prompt injection (default/planning/incident/handoff) |
| **Auto-checkpoint** | Hook on `:post_tool_use` (priority 80) checkpoints every 10 tool calls |

**Architecture:** ETS for hot reads (`:osa_vault_facts`), GenServer for serialized writes, JSONL for persistence — same pattern as Hooks/Tools.

**Tools:**
```
vault_remember     — Store memory with automatic fact extraction
vault_context      — Build profiled context from vault
vault_wake         — Start session (detect dirty deaths)
vault_sleep        — End session (create handoff document)
vault_checkpoint   — Mid-session save point
vault_inject       — Query-matched prompt injection
```

**Commands:**
```
/mem-save          # Still works — Vault augments, doesn't replace existing memory
```

---

## Cortex Knowledge Synthesis

**Module**: `Agent.Cortex`

The Cortex tracks active topics across sessions and generates targeted bulletins when relevant topics resurface.

```
/cortex            # Show active topics and latest bulletin
```

**How it works:**
1. Every conversation updates the topic tracker
2. When a topic reaches enough references, Cortex generates a synthesis
3. Synthesis is injected into context when the topic is relevant
4. Cross-session patterns are detected and highlighted

---

## Learning Engine (SICA)

**Module**: `Agent.Learning`

The SICA (Self-Improving Cognitive Architecture) engine learns from every interaction:

### Learning Cycle

```
OBSERVE  →  Detect events (errors, patterns, successes)
    │
REFLECT  →  Analyze significance and root cause
    │
PROPOSE  →  Generate improvement hypothesis
    │
TEST     →  Validate hypothesis against history
    │
INTEGRATE →  Merge validated learning into knowledge base
```

### What Gets Learned

| Event Type | What Happens |
|-----------|--------------|
| **Error** | VIGIL taxonomy classifies the error, suggests recovery, stores solution |
| **Success** | Pattern extracted, stored for future reference |
| **Correction** | User feedback captured, anti-pattern flagged |
| **Tool failure** | Failure mode cataloged, alternative approach stored |

### VIGIL Error Taxonomy

Errors are classified into categories with auto-recovery suggestions:

| Category | Examples | Recovery Strategy |
|----------|---------|-------------------|
| **Parse** | JSON decode, regex failure | Re-format input, try alternative parser |
| **Network** | Timeout, connection refused | Retry with backoff, try fallback provider |
| **Permission** | File access, API auth | Check credentials, escalate |
| **Logic** | Wrong output, failed assertion | Review approach, try alternative |
| **Resource** | OOM, token limit exceeded | Compact context, reduce scope |

### Consolidation Schedule

| Trigger | Type | What Happens |
|---------|------|--------------|
| Every 5 interactions | Incremental | Recent patterns merged into knowledge base |
| Every 50 interactions | Full | Complete knowledge base audit and deduplication |
| Session end | Flush | All pending learnings persisted to disk |

### Skill Generation

When a pattern is detected 5+ times, the learning engine flags it as a skill generation candidate:

```
Pattern detected 5x: "parse JSON response and extract field"
  → Candidate for new skill: json_extract
  → Agent can create it via create_skill tool
```

### Storage

**Location**: `~/.osa/learning/`
- `patterns.json` — Recurring patterns with frequency counts
- `solutions.json` — Proven solutions indexed by problem type

**Commands:**
```
/learning          # Learning engine metrics and recent patterns
```

---

## Context Management

### 4-Tier Priority Assembly

Context is assembled with a token budget, prioritized in 4 tiers:

| Tier | Priority | Budget | Contents |
|------|----------|--------|----------|
| **Critical** | Always included | Fixed | System prompt, identity, current task |
| **High** | 40% of remaining | Variable | Recent messages, active memory |
| **Medium** | 30% of remaining | Variable | Relevant memory, topic bulletins |
| **Low** | Remaining | Variable | Background context, history |

### 3-Zone Progressive Compaction

When context approaches token limits, compaction triggers:

| Zone | Messages | Treatment |
|------|----------|-----------|
| **Hot** | Last 10 | Full fidelity — no compression |
| **Warm** | 11-30 | Summarized with importance weighting |
| **Cold** | 31+ | Aggressive compression to key points |

**Thresholds:**
- 80% of budget → Warning (more aggressive context selection)
- 85% of budget → Aggressive compaction (warm zone compressed)
- 95% of budget → Emergency (cold zone discarded, warm heavily compressed)

**Commands:**
```
/compact           # Show compaction stats
/usage             # Token usage breakdown
```

---

## Best Practices

1. **Use `/mem-save` actively** — Save important decisions, patterns, and context
2. **Search before solving** — `/mem-search` before attacking a problem fresh
3. **Let the learning engine work** — Don't fight it; correct errors and let SICA learn
4. **Monitor context usage** — `/usage` to track token consumption
5. **Resume sessions** — `/resume` picks up where you left off with full context
