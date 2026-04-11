# STATUS

**Canonical status**: [docs/operations/roberto-content/Documentation.md](docs/operations/roberto-content/Documentation.md)
**Epic**: `vas-swarm-jji`
**Current active issue**: `vas-swarm-jji.6`
**Latest trace**: [vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json)
**Next Roberto step**: Keep `retrieval_ops`-only `artifact_reference` investigate runs local by skipping external paper search unless mixed-source retrieval is explicit, while keeping `vas-swarm-9m7` recorded only as blocker evidence.

## Verification Status

- `vas-swarm-942` closed:
  - carryover fix landed: selected probe papers now seed the merged retrieval corpus
  - targeted tests passed:
    - `mix test test/tools/investigate_test.exs` -> `100 tests, 0 failures`
    - `mix test test/investigation/evidence_planner_test.exs` -> `8 tests, 0 failures`
  - live validation improved:
    - `direction = asymmetric_evidence_for`
    - `grounded_for_count = 1`
    - `planning.selected.probe.carried_papers = 1`
- `vas-swarm-tgf` closed:
  - decision telemetry now writes to a dedicated runtime ledger instead of sharing `:investigate_ledger`
  - `DecisionLedger` now starts its own runtime ledger instead of piggybacking on investigate ledger lifecycle
  - regression coverage added for runtime-ledger isolation
  - targeted investigate-path verification passed:
    - `mix test test/intelligence/decision_ledger_test.exs test/intelligence/decision_journal_persistence_test.exs test/intelligence/runtime_ledger_isolation_test.exs test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs` -> `154 tests, 0 failures`
  - live repeated-run validation passed:
    - four traced earth-shape wrapper runs completed without `GenServer.call(:investigate_ledger, {:add_evidence, ...}, 5000)` timing out
    - traces:
      - [vaos-investigate-trace-933bc72a8e647f60-vas-swarm-tgf-live-batch-1-1775864497841.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-933bc72a8e647f60-vas-swarm-tgf-live-batch-1-1775864497841.json)
      - [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-tgf-live-batch-2-1775864610783.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-tgf-live-batch-2-1775864610783.json)
      - [vaos-investigate-trace-ae47836c2550010b-vas-swarm-tgf-live-batch-3-1775864721930.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-ae47836c2550010b-vas-swarm-tgf-live-batch-3-1775864721930.json)
      - [vaos-investigate-trace-ced8169044ad7a49-vas-swarm-tgf-live-batch-4-1775864863691.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-ced8169044ad7a49-vas-swarm-tgf-live-batch-4-1775864863691.json)
- `vas-swarm-jji.1` closed:
  - `EvidencePlanner` now infers generic evidence signatures from topic terms instead of using `ClaimFamily` to steer mode choice
  - planner scoring no longer applies `family_bias`
  - `search_query_plan/2` no longer records planner `claim_family` or `family_profile`; it now exposes `evidence_signatures`
  - targeted investigate-path verification passed:
    - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `114 tests, 0 failures`
  - live validation passed:
    - trace [vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-783ba4fc4a18e58d-vas-swarm-jji-1-live-measurement-1775880477523.json) selected `measurement`
    - the planning block contains generic `signatures`
    - the planning block no longer exposes family-conditioned metadata keys
- `vas-swarm-jji.2` closed:
  - retrieval no longer depends on `ClaimFamily.evidence_profile/3` in the investigate core
  - `EvidencePlanner` now builds generic operation-shaped `evidence_profile` maps for query generation, rerank/directness scoring, and relevant-paper filtering
  - `planetary_shape` retrieval hints are no longer used by the core measurement path
  - targeted investigate-path verification passed:
    - `mix test test/investigation/evidence_planner_test.exs test/tools/investigate_test.exs` -> `114 tests, 0 failures`
  - live validation completed:
    - trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-2-live-curvature-1775881600133.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-2-live-curvature-1775881600133.json) selected `measurement`
    - the planning block again exposed generic `signatures`
    - the run completed through retrieval and both LLM passes, then degraded during citation verification under provider timeout / HTTP 429 noise
- `vas-swarm-jji.3` closed:
  - sourced evidence no longer switches on `profile` to decide grounding behavior inside `investigate`
  - `grounding_role_for/3` now routes all sourced evidence through one generic cited-claim grounding path based on extracted claim text, evidence-profile anchors, and paper-context fallback
  - generic `verification_claim_text/1` remains the single verifier-shaping layer; recurring earth-shape wrappers and a non-earth `subject as "quote"` case are covered without family-specific normalization
  - targeted investigate-path verification passed:
    - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `127 tests, 0 failures`
  - live validation completed:
    - trace [vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-3-live-curvature-1-1775939217052.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-a7be5c1d943e2844-vas-swarm-jji-3-live-curvature-1-1775939217052.json) completed in `101699ms`
    - `direction = asymmetric_evidence_for`
    - `grounded_for_count = 3`
    - recurring direct refs `paper_ref=14`, `paper_ref=3`, and `paper_ref=5` stayed grounded without family/profile salvage
    - contextual sourced ref `paper_ref=6` was demoted to belief with `grounding_role=contextual`, showing the generic grounding path is separating contextual support from direct evidence
- `vas-swarm-jji.4` closed:
  - `EvidencePlanner` can now choose a generic non-paper `artifact_reference` mode via `artifact_reference_signature`
  - the selected plan now carries explicit `retrieval_ops`, and `investigate` executes `local_artifact_search` against `local_repo` docs/code artifacts before paper retrieval
  - non-paper sources now preserve explicit provenance in runtime traces via `trace.sources[*].source_kind` and `trace.sources[*].provenance`
  - no new topic-family routing was introduced; `vas-swarm-9m7` remains blocker evidence only
  - targeted investigate-path verification passed:
    - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `131 tests, 0 failures`
  - live validation passed on both required claim classes:
    - docs/code trace [vaos-investigate-trace-d3720298d454cb3c-vas-swarm-jji-4-docs-testenv-1775942835911.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-d3720298d454cb3c-vas-swarm-jji-4-docs-testenv-1775942835911.json) completed end to end under `MIX_ENV=test` to avoid a local `8089` port collision, selected `artifact_reference`, emitted `retrieval_ops = [%{operation: :local_artifact_search, source: :local_repo, scope: ["docs"]}]`, and finished with `direction = asymmetric_evidence_for`, `grounded_for_count = 1`, `grounded_against_count = 0`
    - the docs/code trace records explicit non-paper provenance, including `source = local_repo`, `source_kind = artifact_doc`, and `provenance = %{operation: "local_artifact_search", path: "docs/operations/roberto-content/Documentation.md", scope: ["docs"]}`
    - empirical trace [vaos-investigate-trace-e5e4f891f0c3d92b-vas-swarm-jji-4-empirical-1775942606636.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-e5e4f891f0c3d92b-vas-swarm-jji-4-empirical-1775942606636.json) still selected `measurement` and completed with `direction = supporting`, `grounded_for_count = 1`, and `grounded_against_count = 1`
- `vas-swarm-jji.5` closed:
  - production `investigate` no longer depends on `ClaimFamily.normalize_topic/1`
  - generic wrapper stripping now lives in `Daemon.Tools.Builtins.Investigate.normalized_search_topic/1`, and `ClaimFamily` no longer owns the search-topic seam
  - targeted investigate-path verification passed:
    - `mix test test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs` -> `131 tests, 0 failures`
  - live wrapped docs/code validation completed:
    - trace [vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-aec23c8ca5850790-vas-swarm-jji-5-docs-wrapper-1775943904289.json) completed end to end under `MIX_ENV=test`
    - the selected plan stayed on `artifact_reference`
    - `planning.selected.retrieval_ops = [%{operation: :local_artifact_search, source: :local_repo, scope: ["docs", "code"], query: "the repository documentation says Documentation.md is the canonical Roberto status file"}]`, proving the wrapped claim normalized onto the generic local-artifact query
    - the trace again recorded explicit local provenance for `STATUS.md`, `docs/operations/roberto-content/Documentation.md`, and `lib/daemon/operations/roberto_loop.ex`
    - the same trace exposed the next bottleneck: even `retrieval_ops`-only `artifact_reference` runs still consulted HuggingFace/external sources, which is now tracked as `vas-swarm-jji.6`
- Harness audit (2026-04-11):
  - targeted audit verification passed:
    - `mix test test/investigation/evidence_planner_test.exs test/investigation/claim_family_test.exs test/tools/investigate_test.exs` -> `126 tests, 0 failures`
  - current runtime picture:
    - `ClaimFamily.normalize_topic/1` no longer appears on the production investigate path
    - `ClaimFamily.normalize_verification_claim/1` does not appear on the production investigate path
    - the `profile`-conditioned grounding branch in `investigate` remains absent from the live path
  - implication after `vas-swarm-jji.5`:
    - wrapper cleanup debt has been retired from the live path
    - the next long-horizon step is keeping `retrieval_ops`-only `artifact_reference` runs local without adding new family/profile salvage
- Recorded blocker context:
  - `vas-swarm-9m7` remains blocked after three live validation attempts
  - its role is now evidentiary, not active implementation scope
  - what landed before the pause:
    - `verification_claim_text` / claim-family compaction now has focused regressions for:
      - quoted Earth-center reference-frame fragments
      - quoted relation fragments after reporting verbs
      - `subject as "quote"` shape wrappers
      - `connecting it to "quote"` shape wrappers
      - Earth-center clauses with later quoted distractors
      - split spheroid quotes like `"an oblate spheroid"` + `"axis of figure coincident ..."`
    - targeted investigate-path verification passed:
      - `mix test test/intelligence/decision_ledger_test.exs test/intelligence/decision_journal_persistence_test.exs test/intelligence/runtime_ledger_isolation_test.exs test/tools/investigate_test.exs test/investigation/evidence_planner_test.exs --seed 0` -> `160 tests, 0 failures`
  - why it is still recorded:
    - live trace [vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-26a15ca058e69445-vas-swarm-9m7-live-3-1775866106501.json) shows one recurring opposing ref grounded (`paper_ref=8`) but `paper_ref=2` still belief-only
    - live trace [vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-65d0265bdc0cbfe6-vas-swarm-9m7-live-4-1775866396092.json) drifted onto unrelated black-hole horizon literature
    - live trace [vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json](/var/folders/7q/tx7m0tg12m5cgq7k8z8q2dzw0000gn/T/vaos-investigate-trace-b3f6795f46baf623-vas-swarm-9m7-live-5-1775866601837.json) hit verifier timeouts/rate limits and ended with no recurring opposing refs grounded
- Repo-history audit:
  - the remaining full-suite failures are in pre-takeover Roberto/PAMF2-era surfaces
  - they do not intersect `investigate` or the completed `vas-swarm-942` retrieval carryover path
- Policy update:
  - repo-wide inherited full-suite failures are recorded as background debt in `vas-swarm-dy1`
  - they do not block Roberto `investigate` milestones unless they touch `investigate`, `evidence_planner`, or directly coupled verification/retrieval code, or are introduced by the current work

## Long-Horizon Queue

- `vas-swarm-jji.1` — completed: remove `ClaimFamily` from planner selection path
- `vas-swarm-jji.2` — completed: replace family-shaped retrieval hints with generic evidence signatures
- `vas-swarm-jji.3` — completed: replace profile-conditioned verifier / grounding behavior with generic capability-driven cited-claim extraction
- `vas-swarm-jji.4` — completed: add a generic non-paper artifact/reference evidence operation with explicit provenance
- `vas-swarm-jji.5` — completed: retire the surviving `ClaimFamily.normalize_topic/1` wrapper-normalization seam from the production investigate path
- `vas-swarm-jji.6` — active: keep `retrieval_ops`-only `artifact_reference` investigate runs local by suppressing external paper search bleed

The queue order is intentional:
- planner agnosticism first
- retrieval/verifier generalization second
- source broadening after the family-conditioned path is no longer steering the engine

## Resume

1. Read `STATUS.md`.
2. Run `scripts/roberto-loop`.
3. Open `vas-swarm-9m7` for blocker context only.
4. Resume implementation from `vas-swarm-jji.6`.
5. Use the `vas-swarm-jji.5` wrapped docs/code trace plus the `vas-swarm-jji.4` docs/code and empirical traces as evidence for why the next cut is external-search containment on retrieval-ops-only artifact plans rather than more source-family salvage.
6. Record any unrelated inherited suite failures under `vas-swarm-dy1` without blocking `investigate` work.
7. Update status docs, Beads, commit, and push.

If you only need the summary snapshot without launching a Codex slice, run `mix osa.roberto.resume`.
