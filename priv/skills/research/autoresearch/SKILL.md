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
1. **Edit** — Modify `train.py` with one focused change (hyperparameter, architecture, optimizer tweak)
2. **Run** — Execute training for exactly 5 minutes (wall clock) inside a Firecracker VM
3. **Measure** — Read `val_bpb` (validation bits-per-byte) from training output
4. **Keep or Revert** — If `val_bpb` improved → commit the change. If not → restore previous `train.py`.
5. **Repeat**

## Setup Phase

Before the experiment loop, use `compute_vm` to:

1. **Create a VM** from the `python-ml` template (size: medium — 2vCPU, 2GB RAM)
2. **Upload the three fixed files** to `/workspace/`:
   - `prepare.py` — data preparation (run once, never touch again)
   - `train.py` — the file you will iteratively edit
   - `program.md` — human instructions describing the research goal
3. **Run prepare.py once**: `cd /workspace && python prepare.py`
4. **Record the baseline** by running train.py once for 5 minutes and noting the starting `val_bpb`

## Experiment Loop

```
FOR experiment 1 to N:
  1. Read current train.py content
  2. Read program.md for guidance
  3. Think: propose ONE specific, measurable change to train.py
     - Examples: change learning rate, add dropout, change batch size,
       modify optimizer, adjust warmup steps, tweak weight decay
     - Each change must have a clear hypothesis: "I expect this to lower val_bpb because..."
  4. Write the modified train.py to VM
  5. Run: timeout 300 python train.py 2>&1
     (300 seconds = 5 min wall clock — matches Karpathy's protocol)
  6. Parse val_bpb from output (look for "val loss" or "val_bpb" in logs)
  7. Compare to best_val_bpb so far:
     - If improved (lower is better): update best_val_bpb, keep train.py
     - If not improved: restore previous train.py from saved content
  8. Log: experiment number, change made, val_bpb, kept/reverted
END
```

## Parsing val_bpb

The training output will contain lines like:
```
step 100: train loss 3.4521, val loss 3.2891
```

`val_bpb = val_loss / ln(2)` — or the script may output it directly.
Parse the **last** val loss/val_bpb line before the script exits.

## Saving State Between Experiments

Use `memory_save` after each kept experiment to record:
- Experiment number
- Change made
- val_bpb achieved
- Full modified train.py content (or the diff)

Use `memory_recall` at the start to restore best train.py if resuming.

## Cleanup

After all experiments (or if interrupted), `compute_vm(operation: destroy)` to release the VM.

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
- Always restore train.py on regression, never accumulate bad changes
- Stop if val_bpb stops improving for 10 consecutive experiments
- Log every experiment — even failed ones teach something
- Never modify prepare.py or program.md — only train.py
