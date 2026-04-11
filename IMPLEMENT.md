# IMPLEMENT

**Canonical runbook**: [docs/operations/roberto-content/Implement.md](docs/operations/roberto-content/Implement.md)

## Execution Contract

- Read `SPEC.md`, `PLAN.md`, and `STATUS.md` first.
- Work the first real bottleneck from the latest live trace.
- Fix the narrowest generic layer that explains the failure.
- Validate with tests and a live rerun.
- Update status and Beads before stopping.

## Resume Command

```bash
scripts/roberto-loop
```

Summary-only fallback:

```bash
mix osa.roberto.resume
```
