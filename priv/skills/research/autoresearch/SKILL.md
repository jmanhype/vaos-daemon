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

Then poll until status = `running` (VM takes 10–30s to boot):
```
compute_vm(operation: status, vm_id: <id>)
# Repeat every 5s until you see "status=running"
```

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

Note this as `best_val_bpb` (your starting point). Save it with `memory_save`.

## Experiment Loop

```
FOR experiment 1 to N:

  1. Read current train.py:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/train.py)

  2. Read program.md for guidance:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/program.md)

  3. Think: propose ONE change with a hypothesis
     Examples:
       - "increase learning_rate from 3e-4 to 1e-3 — hypothesis: LR too low for this model size"
       - "increase n_embd from 128 to 256 — hypothesis: more capacity needed"
       - "set dropout=0.0 — hypothesis: small model should not regularize this aggressively"

  4. Write modified train.py:
     compute_vm(operation: write_file, vm_id: <id>,
                path: /workspace/train.py, content: <new_train_py>)

  5. Run experiment (run_experiment.sh auto-backs up train.py → train.py.prev):
     compute_vm(operation: exec, vm_id: <id>,
                command: "bash /workspace/run_experiment.sh",
                timeout: 360)

  6. Read result:
     compute_vm(operation: read_file, vm_id: <id>, path: /workspace/val_bpb.txt)
     → single float, e.g. "1.342871"

  7. Compare to best_val_bpb:
     IMPROVED (lower) → keep train.py, update best_val_bpb
     NOT IMPROVED     → revert:
       compute_vm(operation: exec, vm_id: <id>,
                  command: "cp /workspace/train.py.prev /workspace/train.py",
                  timeout: 10)

  8. Log experiment result (see Output Format below)

END
```

## Saving State Between Experiments

Use `memory_save` after each kept experiment to record:
- Experiment number, change made, val_bpb achieved
- Full modified train.py content (so you can resume if the session is interrupted)

Use `memory_recall` at the start to check for a previous session's best train.py.

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
