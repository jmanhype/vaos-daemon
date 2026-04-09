# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `scripts/bd-safe onboard` to get started from Codex or any Git worktree shell.

## Beads Wrapper

Use `scripts/bd-safe` for Beads commands in this repo instead of raw `bd`.

- Codex worktree shells can leak `GIT_INDEX_FILE=.git/index` into the Beads daemon environment.
- That inherited Git env breaks sync-worktree pulls with `fatal: .git/index: index file open failed: Not a directory`.
- `scripts/bd-safe` clears the Git worktree env before launching `bd`, which prevents the daemon from reusing the broken index path.

## Quick Reference

```bash
scripts/bd-safe ready              # Find available work
scripts/bd-safe show <id>          # View issue details
scripts/bd-safe update <id> --status in_progress  # Claim work
scripts/bd-safe close <id>         # Complete work
scripts/bd-safe sync               # Sync with git
```

## Beads Drift Recovery

If Beads reports `DB (...) has more issues than JSONL (...) after pull`, treat it as a sync-drift incident first, not a deletion prompt.

```bash
scripts/bd-safe sync --status      # Check main vs sync-branch drift
scripts/bd-safe sync               # Re-export/push/pull/import the current issue set
```

- Do not run `bd import --delete-missing` unless you have confirmed the main worktree JSONL and the sync worktree JSONL already agree on issue IDs.
- A stale Beads sync worktree can lag behind `main` and temporarily make legitimate issues look DB-only.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   scripts/bd-safe sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
