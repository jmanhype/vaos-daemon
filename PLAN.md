# PLAN

**Canonical plan**: [docs/operations/roberto-content/Plan.md](docs/operations/roberto-content/Plan.md)

## Current Milestone

Demote historical or debate-only support fragments in the live `observational` grounding path now that the `vas-swarm-9m7` measurement verifier boundary is closed again.

## Active Issue

`vas-swarm-jji.9` — Demote historical or debate-only support fragments in observational investigate traces.
`vas-swarm-dy1` remains open as inherited repo debt. For this Roberto program, it is non-blocking unless a failing test touches `investigate` or its directly coupled planning/verification path.
Current state: `vas-swarm-jji.1` through `vas-swarm-jji.8` are complete and closed. The live investigate core no longer switches on family/profile-conditioned planner, retrieval, grounding, or wrapper normalization behavior, and retrieval-ops-only local artifact plans no longer bleed into external paper search or alphaXiv preflight auth/startup. On `2026-04-11`, `vas-swarm-9m7` closed after the verifier stopped treating every separable multi-ref sourced summary as `multiple_refs`: replaying the exact `jji8-measurement` blocker trace now resolves recurring refs `3`, `8`, `14`, `2`, and `7` back to primary verification targets, and the semantically equivalent fallback live trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) again selected `measurement` and completed with grounded evidence on both sides (`3/1`) and no timeout. That removes the first-order measurement collapse. The next active bottleneck is therefore `vas-swarm-jji.9`, filed from the same `vas-swarm-jji.8` audit because the fresh observational trace still grounded historical / debate-only fragments as support for `vaccines cause autism`.

## Strategic Queue

The next long-horizon tasks for the durable epistemic engine are:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add non-paper evidence operations to the planner
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: prevent retrieval-ops-only `artifact_reference` plans from launching external paper search
- `vas-swarm-jji.7` — completed: prevent retrieval-ops-only local artifact preparations from triggering alphaXiv auth/startup during preflight
- `vas-swarm-jji.8` — completed: the content check proved representative routing still works, reactivated the live earth-shape grounding boundary, and filed `vas-swarm-jji.9` for the observational follow-up
- `vas-swarm-jji.9` — active: demote historical or debate-only support fragments in observational traces

Sequence:
- keep `vas-swarm-9m7` closed unless a new live measurement trace regresses
- use `vas-swarm-jji.8` as the completed audit that now leaves `vas-swarm-jji.9` as the next first-order bottleneck
- do not add more family-specific `planetary_shape` salvage unless it is temporary debt
- continue the durable-epistemic-engine path through the observational claim-alignment boundary

## Verification Status

- `vas-swarm-942` is complete:
  - `mix test test/tools/investigate_test.exs` -> `100 tests, 0 failures`
  - `mix test test/investigation/evidence_planner_test.exs` -> `8 tests, 0 failures`
  - live validation carries 1 probe paper into the selected `randomized_intervention` run and produces `grounded_for_count = 1`
- `vas-swarm-tgf` is complete:
  - runtime decision telemetry is isolated off `:investigate_ledger`
  - `mix test test/intelligence/decision_ledger_test.exs test/intelligence/decision_journal_persistence_test.exs test/intelligence/runtime_ledger_isolation_test.exs test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs` -> `154 tests, 0 failures`
  - four traced earth-shape wrapper runs completed without the old ledger timeout
- `vas-swarm-jji.1` is complete:
  - planner selection no longer uses `ClaimFamily`
  - `EvidencePlanner` now derives generic evidence signatures from the claim text itself
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `114 tests, 0 failures`
  - live validation trace [vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json) selected `measurement` with generic `planning.signatures` and no family-conditioned planning metadata
- `vas-swarm-jji.2` is complete:
  - retrieval no longer uses `ClaimFamily.evidence_profile/3` in the investigate core
  - `EvidencePlanner` now builds generic retrieval profiles from operation signatures for query generation, rerank/directness scoring, and relevant-paper filtering
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `114 tests, 0 failures`
  - live validation trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-2-live-curvature-1775881600133.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-2-live-curvature-1775881600133.json) selected `measurement` with generic `planning.signatures`; later citation verification degraded under provider timeout / HTTP 429 noise
- `vas-swarm-jji.3` is complete:
  - sourced-evidence grounding no longer branches on `profile` inside `investigate`
  - `grounding_role_for/3` now derives direct/synthesis/contextual/indirect roles from extracted cited claims plus evidence-profile anchors and paper context
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `127 tests, 0 failures`
  - live validation trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-3-live-curvature-1-1775939217052.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-3-live-curvature-1-1775939217052.json) completed with `direction=asymmetric_evidence_for`, `grounded_for_count=3`, and recurring direct refs `14`, `3`, and `5` grounded without family/profile salvage
- `vas-swarm-jji.5` is complete:
  - production investigate no longer depends on `ClaimFamily.normalize_topic/1`
  - generic wrapper stripping now lives in `Daemon.Tools.Builtins.Investigate.normalized_search_topic/1`
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `131 tests, 0 failures`
  - live validation trace [vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json) selected `artifact_reference` from a wrapped docs/code claim and normalized its `local_artifact_search` query to `the repository documentation says Documentation.md is the canonical Roberto status file`
- `vas-swarm-jji.6` is complete:
  - `search_all_papers/4` now exits through a local-only retrieval path before external paper fanout when the selected plan is retrieval-ops-only
  - `finalize_search_results/3` now keeps local-only and mixed-source retrieval finalization on the same executor seam
  - `Investigate.external_paper_search_enabled?/1` exposes the retrieval gate for deterministic coverage
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `132 tests, 0 failures`
  - runtime artifact [vaos-jji6-local-artifact-validation-XXXX.txt](/tmp/vaos-jji6-local-artifact-validation-XXXX.txt) confirms the representative docs/code claim stays on `artifact_reference`, records `probe_reason = "retrieval_ops_only"`, and returns `source_counts = %{local_repo: 5}` with only `local_repo` consulted sources
- `vas-swarm-jji.7` is complete:
  - `Investigate.preflight_runtime/2` now derives alphaXiv preflight eligibility from the topic's evidence plan before auth/startup
  - retrieval-ops-only docs/code plans skip alphaXiv auth/startup entirely, while mixed-source plans still check auth/start as needed
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs test/tools/alphaxiv_client_test.exs` -> `136 tests, 0 failures`
  - runtime artifact [vaos-jji7-local-artifact-validation-1775946503.txt](/tmp/vaos-jji7-local-artifact-validation-1775946503.txt) confirms the representative docs/code claim stays `local_repo`-only through preflight and retrieval with no alphaXiv auth/startup warnings
- `vas-swarm-jji.8` is complete:
  - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `124 tests, 0 failures`
  - planner spot checks still selected the intended generic lanes for:
    - `measurement` (`examine claims that the earth is flat`)
    - `observational` (`vaccines cause autism`)
    - `randomized_intervention` (`acute caffeine intake enhances endurance time-trial performance in trained cyclists and triathletes`)
  - runtime audit artifact [vaos-jji8-content-check-1775947922.json](/tmp/vaos-jji8-content-check-1775947922.json) captured the representative content check and the three trace paths
  - measurement trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json) selected `measurement` with a direct geodesy corpus, but ended `direction=insufficient_evidence`, `grounded_for_count=0`, and `grounded_against_count=0` with all five opposing sourced items belief-only; that reactivates `vas-swarm-9m7`
  - observational trace [vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-6288e6adc2dfd5a5-jji8-observational-1775947776135.json) selected `observational` and grounded both sides (`2/4`), but it grounded history/debate fragments as support for `vaccines cause autism`; that is now tracked in `vas-swarm-jji.9`
  - randomized-intervention trace [vaos-investigate-trace-5c090736ecfc44a0-jji8-randomized-intervention-1775947922324.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-5c090736ecfc44a0-jji8-randomized-intervention-1775947922324.json) selected `randomized_intervention` and completed with `direction=asymmetric_evidence_for`, `grounded_for_count=2`, and `grounded_against_count=0`
- `vas-swarm-9m7` is complete:
  - `verification_ref_status/2` now allows multi-ref sourced summaries through verification when the existing claim-shaping pipeline isolates one substantive primary cited claim; inseparable multi-ref claims still remain `multiple_refs`
  - `mix test test/investigation/claim_family_test.exs test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `136 tests, 0 failures`
  - replaying the exact blocker trace [vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-9cee767146dfb20d-jji8-measurement-1775947626820.json) now maps recurring opposing refs `3`, `8`, `14`, `2`, and `7` back to primary verification targets instead of the old `multiple_refs` dead-end
  - the exact prompt was under a DecisionJournal cooldown on `2026-04-11`, so live validation used semantically equivalent fallback `determine whether the earth has measurable curvature`
  - fallback live trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-9m7-live-curvature-1775949543170.json) selected `measurement`, completed with `direction=supporting`, `grounded_for_count=3`, `grounded_against_count=1`, `verified_for=5`, `verified_against=1`, and `timeout=nil`
- Harness audit (2026-04-11):
  - `mix test test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs test/tools/investigate_test.exs` -> `126 tests, 0 failures`
  - `ClaimFamily.normalize_topic/1` no longer appears on the production investigate path
  - `ClaimFamily.normalize_verification_claim/1` does not appear on the production investigate path
  - the `profile`-conditioned grounding branch has been removed from the live investigate path, leaving the Roberto content check as the next concern
- Next Roberto step:
  - `vas-swarm-jji.9`: demote historical or debate-only support fragments in the observational lane without regressing the now-closed measurement verifier fix
- Repo-wide inherited full-suite failures remain background debt unless the failing test intersects `investigate`, `evidence_planner`, or directly coupled verification/retrieval code

## Operating Rule

After each slice:
1. run targeted tests
2. run a live validation
3. update Beads and status docs
4. ask what Roberto would do next
5. continue if the next bottleneck is already clear
6. if three live attempts fail to verify the current milestone, mark the blocker clearly and pause instead of advancing
7. do not extend `ClaimFamily` or family-like `profile` contracts as core abstractions; either delete that logic or isolate it as explicit temporary debt
