---
name: autoresearch
description: Karpathy AutoResearcher — closed-loop ML experiment agent that edits train.py, runs 5-minute training jobs inside a Firecracker VM, tracks val_bpb improvements, and runs ~100 experiments overnight.
triggers:
  - autoresearch
  - ml experiment
  - train experiment
  - neural network experiment
  - run experiments
  - improve training
  - hyperparameter search
  - nanoGPT experiment
priority: 2
---

# AutoResearcher Skill

You are running Karpathy's AutoResearcher pattern: a closed-loop ML experiment agent.

## Core Loop

For each experiment:
1. **Edit** — Modify `train.py` with one focused change
2. **Run** — `bash /workspace/run_experiment.sh` (hard 5-min wall clock)
3. **Measure** — Read `val_bpb.txt` (single float, written by train.py)
4. **Keep or Revert** — lower val_bpb = better. Revert = `cp /workspace/train.py.prev /workspace/train.py`
5. **Repeat**

## Setup Phase

### 1. Create VM and wait until running

```
compute_vm(operation: create, template_id: autoresearch, size: medium)
→ note the vm_id
```

Then wait until running (replaces manual polling):
```
compute_vm(operation: wait, vm_id: <id>)
→ returns "VM <id> is running" once boot completes
```

The `wait` operation polls every 3 seconds and times out after 120 seconds by default. If the VM reaches a terminal state (stopped, destroyed, error) it fails immediately.

### 2. Run prepare.py once

```
compute_vm(operation: exec, vm_id: <id>,
           command: "cd /workspace && python prepare.py",
           timeout: 120)
```

Data files already exist in the template — this downloads Shakespeare and tokenises it.

### 3. Record baseline

```
compute_vm(operation: exec, vm_id: <id>,
           command: "bash /workspace/run_experiment.sh",
           timeout: 360)

compute_vm(operation: read_file, vm_id: <id>, path: /workspace/val_bpb.txt)
```

Note this as `best_val_bpb` (your starting point). Save it with `memory_save`. This is also the starting row in your Research Log.

## Research Log

Maintain a running experiment table in working memory. Print the full table after each experiment.

```
| # | param | old → new | val_bpb | delta | kept |
|---|-------|-----------|---------|-------|------|
| 0 | baseline | — | 1.34 | — | ✓ |
| 1 | learning_rate | 3e-4 → 1e-3 | 1.31 | -0.03 | ✓ |
| 2 | dropout | 0.1 → 0.0 | 1.33 | +0.02 | ✗ |
```

Before proposing each new experiment, review the Research Log and apply these rules:

- **No repeats.** Never retry a (param, direction) pair that already appears in the log.
- **Exhaustion check.** A param axis is exhausted when both directions have been tried and neither helped. Move on.
- **Plateau detection.** If the last 5 experiments all appear in the log with `kept = ✗`, trigger the Convergence Rule below.

## Experiment Loop

```
FOR experiment 1 to N:

  1. Review Research Log — identify which params and directions are exhausted.

  2. Read current train.py:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/train.py)

  3. Read program.md for guidance:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/program.md)

  4. Think: propose ONE change with a hypothesis, avoiding exhausted axes.
     Examples:
       - "increase learning_rate from 3e-4 to 1e-3 — hypothesis: LR too low for this model size"
       - "increase n_embd from 128 to 256 — hypothesis: more capacity needed"
       - "set dropout=0.0 — hypothesis: small model should not regularize this aggressively"

  5. Write modified train.py:
     compute_vm(operation: write_file, vm_id: <id>,
                path: /workspace/train.py, content: <new_train_py>)

  6. Run experiment (run_experiment.sh auto-backs up train.py → train.py.prev):
     compute_vm(operation: exec, vm_id: <id>,
                command: "bash /workspace/run_experiment.sh",
                timeout: 360)

  7. Read result:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/val_bpb.txt)
     → single float, e.g. "1.342871"

  8. Compare to best_val_bpb:
     IMPROVED (lower) → keep train.py, update best_val_bpb
     NOT IMPROVED     → revert:
       compute_vm(operation: exec, vm_id: <id>,
                  command: "cp /workspace/train.py.prev /workspace/train.py",
                  timeout: 10)

  9. Update Research Log and print the full table.

 10. Log experiment result (see Output Format below).

END
```

## Convergence Rule

If the same hyperparameter space has been explored in all directions with no improvement in the last 5 consecutive experiments, switch axes:

- Move to **architectural changes**: `n_layer`, `n_head`, `n_embd`
- Announce the switch explicitly: "Hyperparameter search exhausted — switching to architecture exploration."
- Reset the plateau counter when an architectural change produces an improvement.

If architectural changes are also exhausted after 5 non-improvements, stop early and summarize findings.

## Saving State Between Experiments

Use `memory_save` after each kept experiment to record:
- Experiment number, change made, val_bpb achieved
- Full modified train.py content (so you can resume if the session is interrupted)
- Current Research Log table

Use `memory_recall` at the start to check for a previous session's best train.py and Research Log.

## Cleanup

After all experiments (or if interrupted):
```
compute_vm(operation: destroy, vm_id: <id>)
```

## Output Format

After each experiment, report:
```
[Exp #N] Change: <what you changed>
         Hypothesis: <why you expected improvement>
         val_bpb: <value> (best: <best_so_far>)
         Result: KEPT ✓ | REVERTED ✗
```

Then print the current Research Log table.

Final summary:
```
## AutoResearch Complete
- Experiments run: N
- Best val_bpb: X.XXXX (experiment #K)
- Total improvement: X% over baseline
- Key findings: [list of changes that helped]
```

## Rules

- Never run two changes at once — one hypothesis per experiment
- The revert command is always: `cp /workspace/train.py.prev /workspace/train.py`
  (run_experiment.sh writes this backup automatically before each run)
- Stop if val_bpb stops improving for 10 consecutive experiments
- Never modify prepare.py, program.md, or run_experiment.sh — only train.py
- If exec returns an error, read `/workspace/out/last_run.log` to diagnose
- Always consult the Research Log before proposing a change — never retry a failed direction
