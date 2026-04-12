# PLAN

**Canonical plan**: [docs/operations/roberto-content/Plan.md](docs/operations/roberto-content/Plan.md)

## Current Milestone

Re-run the representative Roberto content check now that both transient verifier runtime failures and malformed non-classification replies are excluded from the stable citation cache.

## Active Issue

`vas-swarm-jji.19` — Re-run representative Roberto content check after verifier malformed-reply cache hardening.
`vas-swarm-dy1` remains open as inherited repo debt. For this Roberto program, it is non-blocking unless a failing test touches `investigate` or its directly coupled planning/verification path.
Current state: `vas-swarm-jji.1` through `vas-swarm-jji.18` are complete and closed. The exact representative content-check artifact [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json) exposed the last first-order integrity bug when the observational lane returned `belief_consensus_for` despite `grounded_for_count = 0`, `grounded_against_count = 0`, and `runtime_failures.count = 5`. That seam is closed: the runtime-equivalent replay artifact [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json) downgrades the exact bad trace to `runtime_failure`, the cooldown-safe fallback live artifact [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json) shows the representative lanes now end either grounded or explicit partial/runtime-honest under provider noise, the runtime artifact [vaos-jji17-verifier-cache-recovery-1776006215.json](/tmp/vaos-jji17-verifier-cache-recovery-1776006215.json) proves transient verifier failures no longer poison reruns, and the runtime artifact [vaos-jji18-verifier-malformed-recovery-1776007114.json](/tmp/vaos-jji18-verifier-malformed-recovery-1776007114.json) proves malformed non-empty replies now degrade to `unexpected_response` and recover cleanly on rerun while legitimate negative reasoning still caches. The next active issue is therefore the representative content recheck rather than another citation-cache integrity seam.

## Strategic Queue

The next long-horizon tasks for the durable epistemic engine are:
- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add non-paper evidence operations to the planner
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — completed: prevent retrieval-ops-only `artifact_reference` plans from launching external paper search
- `vas-swarm-jji.7` — completed: prevent retrieval-ops-only local artifact preparations from triggering alphaXiv auth/startup during preflight
- `vas-swarm-jji.8` — completed: the content check proved representative routing still works, reactivated the live earth-shape grounding boundary, and filed the remaining observational follow-ups
- `vas-swarm-jji.9` — completed: demote historical or debate-only support fragments in observational traces
- `vas-swarm-jji.10` — completed: harden observational contradiction grounding under paraphrase and provider-noise drift
- `vas-swarm-jji.11` — completed: rerun the representative content check after the observational paraphrase hardening
- `vas-swarm-jji.12` — completed: harden empirical grounding when extracted cited claims lose topic anchors
- `vas-swarm-jji.13` — completed: surface live verifier/provider failures when randomized support stays belief-only
- `vas-swarm-jji.14` — completed: audit randomized_intervention support balance after runtime-honesty fix
- `vas-swarm-jji.15` — completed: demote co-formulated randomized contradictions from direct grounding
- `vas-swarm-jji.16` — completed: rerun the final Roberto content check and close the belief-only verdict seam exposed by verifier runtime failure
- `vas-swarm-jji.17` — completed: transient verifier runtime failures no longer poison investigate citation-verification cache across reruns
- `vas-swarm-jji.18` — completed: harden investigate against malformed non-empty verifier replies poisoning the citation cache
- `vas-swarm-jji.19` — active: rerun the representative Roberto content check after verifier malformed-reply cache hardening

Sequence:
- keep `vas-swarm-9m7` closed unless a new live measurement trace regresses
- use the `jji.16` exact content-check artifact, the exact observational replay artifact, and the fallback live artifact as the new representative audit baseline
- treat first-order integrity as closed unless a new live representative trace regresses into directional belief-only output without grounded evidence
- do not add more family-specific `planetary_shape` salvage unless it is temporary debt
- continue the durable-epistemic-engine path by proving the representative lanes still hold after the final verifier-cache hardening

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
- `vas-swarm-jji.12` is complete:
  - empty extracted claims no longer ground through paper-only topic fallback
  - direct observational studies can satisfy topic alignment from split claim-plus-paper anchors when the extracted claim still retains one topic anchor
  - cross-supplement interaction reviews now classify as indirect combination evidence before synthesis, which blocks the live-shaped beetroot/caffeine caveat leak
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `147 tests, 0 failures`
  - replay artifact [vaos-jji12-grounding-replay-1775956794.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-jji12-grounding-replay-1775956794.json) proves the representative grounding boundary moved
  - live observational fallback [vaos-investigate-trace-f503fd8c4bf2184c-jji12-live-observational-fallback-port0-1775957319684.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-f503fd8c4bf2184c-jji12-live-observational-fallback-port0-1775957319684.json) grounded direct and synthesis contradictory evidence again
- `vas-swarm-jji.15` is complete:
  - co-formulated randomized contradiction claims now classify as indirect / belief when the cited wording shows mixed-agent or attribution-confound intervention evidence
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `152 tests, 0 failures`
  - replay artifact [vaos-jji15-grounding-replay-1775979139.json](/tmp/vaos-jji15-grounding-replay-1775979139.json) keeps standalone caffeine support `direct/grounded` while demoting the nitric-oxide-plus-caffeine contradiction to `indirect/belief`
- `vas-swarm-jji.16` is complete:
  - `direction_summary/4` now downgrades belief-only directional verdicts to `runtime_failure` when citation verification/runtime failures occur and no grounded evidence survives
  - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `154 tests, 0 failures`
  - exact representative content-check artifact [vaos-jji16-content-check-1775980701.json](/tmp/vaos-jji16-content-check-1775980701.json) exposed the seam, runtime-equivalent replay [vaos-jji16-observational-runtime-replay-1775982675.json](/tmp/vaos-jji16-observational-runtime-replay-1775982675.json) proves the exact bad observational trace now returns `runtime_failure`, and fallback live validation [vaos-jji16-content-check-fallback-1775981910.json](/tmp/vaos-jji16-content-check-fallback-1775981910.json) shows representative lanes are now grounded or explicit partial/runtime-honest under provider instability
- Next Roberto step:
- `vas-swarm-jji.19`: rerun the representative measurement / observational / randomized_intervention content checks now that both timeout noise and malformed verifier replies are kept out of the stable citation cache
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
