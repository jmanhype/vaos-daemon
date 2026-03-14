# ADR-NNN: Title

## Status

One of: `Proposed` | `Accepted` | `Rejected` | `Deprecated` | `Superseded by ADR-NNN`

## Date

YYYY-MM-DD

---

## Context

Describe the situation that makes a decision necessary. Include:

- The problem or requirement this decision addresses
- The constraints and forces at play (technical, organizational, timeline)
- Any prior decisions or context the reader needs to understand this one
- What the system looked like before this decision, if it is changing something existing

This section should be objective — describe the situation, not the solution.

---

## Considered Alternatives

For each alternative that was seriously considered:

### Alternative A: [Name]

What it is, how it would work, and why it was considered.

**Pros:**
- ...

**Cons:**
- ...

### Alternative B: [Name]

What it is, how it would work, and why it was considered.

**Pros:**
- ...

**Cons:**
- ...

---

## Decision

State the decision clearly and concisely. Explain the reasoning — why this alternative
over the others. Reference specific constraints from the Context section.

Be specific about what was decided:
- Which modules are affected
- Which supervision strategy was chosen
- Which external library was selected
- What the API contract is

---

## Consequences

### Benefits

List what becomes better as a result of this decision. Be specific and honest —
avoid generic statements like "improved performance".

### Costs and Trade-offs

List what becomes harder, slower, or more complex as a result. Every architectural
decision has costs. If you cannot identify any, the decision record is incomplete.

### Compliance Requirements

If the decision establishes rules that contributors must follow, list them here
as actionable requirements:

- New X must be implemented as Y
- Z is not permitted in production code paths
- All changes to module W require review from the MIOSA team

---

## Open Questions

Questions that were not resolved at decision time and may affect future decisions.
Delete this section if there are none.

---

## References

- Related ADRs: ADR-NNN, ADR-NNN
- External resources: URLs, papers, documentation
- Related GitHub issues or PRs: #NNN

---

## Numbering

ADR numbers are assigned sequentially. When writing a new ADR:

1. Check the highest existing number in `docs/foundation-core/governance/architectural-decisions/`.
2. Use the next number.
3. File as `adr-NNN-short-title.md` where `short-title` is kebab-case, 2–5 words.

Current ADRs:
- ADR-001: OTP Supervision Tree as Core Architecture
- ADR-002: Miosa Package Extraction and Shim Layer
- ADR-003: goldrush Event Bus and Signal Theory Integration
- ADR-004: Signal Theory for Message Classification
- ADR-005: Local-First Architecture

The next ADR should be ADR-006.
