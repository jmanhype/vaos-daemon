# Roberto Compatibility Constitution

This file is a compatibility bridge for generic Codex skills that expect
`.specify/memory/constitution.md` to exist.

It is not the primary standards source for this repository.

Canonical standards sources:
- `AGENTS.md`
- `SPEC.md`
- `PLAN.md`
- `IMPLEMENT.md`
- `STATUS.md`
- `docs/operations/roberto-content/`

Working rules for autonomous Codex slices in this repo:
- Use `scripts/bd-safe` for Beads commands, not raw `bd`.
- Respect unrelated dirty worktree changes and never revert them unless asked.
- Work the first real bottleneck from the latest Roberto trace and current Beads issue.
- Prefer the narrowest generic fix over topic-specific salvage.
- Run targeted tests for the changed path before stopping.
- Update Beads and status docs when the slice lands.
- Finish with `git pull --rebase`, `scripts/bd-safe sync`, `git push`, and `git status`.

Quality expectations:
- Follow small, reviewable changes.
- Add or update focused tests for behavior you change.
- Prefer existing repo patterns over introducing new architecture.
