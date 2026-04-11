# Implement: Roberto Loop Runbook

**Source of truth order**
1. `docs/operations/roberto-content/Prompt.md`
2. `docs/operations/roberto-content/Documentation.md`
3. Current Beads issue
4. `docs/operations/roberto-content/Plan.md`

## Operating Loop

This program runs on a strict loop:

1. Read the current active issue from Beads.
2. Open the exact live trace or artifact that exposed it.
3. Identify the first real failure boundary.
4. Fix the narrowest generic layer that explains that failure.
5. Run targeted tests.
6. Run a live validation on the same or semantically equivalent claim.
7. Update `Documentation.md`.
8. Close the resolved issue and open the next first-order bottleneck if one appears.
9. Commit, sync, push.
10. Ask: `What would Roberto do next?`

If the answer is obvious from the evidence, continue. Do not stop merely because one local fix landed.

## Anti-Drift Rules

- Do not add topic-specific logic unless it is clearly temporary and tracked as debt.
- Do not switch to a different problem class while the current first-order bottleneck is unresolved.
- Do not treat stress-probe results as product verdicts.
- Do not confuse “planner picked the right lane” with “the run is trustworthy.”
- Do not let reasoning-only claims consume sourced-evidence budget unless they are explicitly being handled as belief.

## Preferred Fix Order

When multiple layers look suspicious, prefer this order:

1. Routing / evidence mode
2. Retrieval / rerank
3. Verification-claim shaping
4. Verification transport / timeout / retry behavior
5. Evidence-store classification
6. Model/provider changes

Provider or model changes should happen only when the boundary is clearly a provider/model problem.

## Validation Rules

Every slice must have:
- one targeted test run
- one live validation or equivalent runtime artifact
- one Beads state transition
- one push to `origin/main`

If a live run is blocked by cooldown, use a semantically equivalent query and record that explicitly.

## Session Close

Before ending a session:

1. `git pull --rebase`
2. `scripts/bd-safe sync`
3. `git push`
4. `git status`
5. update `Documentation.md` with:
   - latest commit
   - current issue
   - latest trace
   - next Roberto step

## Current Rule

Until Roberto is content, the program continues from the next first-order bottleneck. No celebratory stopping points.

## Entry Points

Repo-root control files mirror this stack for long-running Codex sessions:
- [SPEC.md](/Users/speed/vaos-daemon/SPEC.md)
- [PLAN.md](/Users/speed/vaos-daemon/PLAN.md)
- [IMPLEMENT.md](/Users/speed/vaos-daemon/IMPLEMENT.md)
- [STATUS.md](/Users/speed/vaos-daemon/STATUS.md)

Primary launch command:

```bash
scripts/roberto-loop
```

Summary-only fallback:

```bash
mix osa.roberto.resume
```
