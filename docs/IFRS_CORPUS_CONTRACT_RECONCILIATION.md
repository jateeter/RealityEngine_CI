# Corpus growth reconciliation in domain approval

Corpus growth is expected during admission. The gate verifies the published baseline plus the exact declared domain delta. This applies to additions, updates and removals.

Machines owns `scripts/corpus_contract.py`, the current transition at `domains/corpus-contract.json`, and immutable predecessor snapshots under `domains/corpus-contracts/`. The Bash approval entrypoint exposes `reconcile-counts` (dry run by default, `--write` to stage). Production `prepare` executes reconciliation before generators, binds its hash in the Git ledger, and runs the dependent corpus-count gate with current-digest verification.

The CI count gate validates complete transition history, declared changes, current file hashes and manifest counts before accepting resulting totals. Without a transition it retains the published baseline. Agent joins, fixture exclusions, axes, egress-only bindings and provenance checks remain enabled. Counts do not refresh CES or semantic shards, close accounting findings, or approve domains.

| Measure | Verified baseline | IFRS delta | Result |
| --- | ---: | ---: | ---: |
| Machines | 1,327 | +225 | 1,552 |
| Domains | 12 | +1 | 13 |
| Agent specs | 1,322 | +225 | 1,547 |
| Native agent bindings | 1,058 | 0 | 1,058 |
| OpenClaw projections | 1,184 | 0 | 1,184 |

The baseline is Machines commit `1baddcbaa1a52c6abca884ac4cdbf26dfe85f90a`. All 1,327 baseline file hashes remain unchanged; the transition contains exactly 225 added IFRS files. It retains TEST_ONLY and productionApproval=false. Existing dependent agent provenance already names the current corpus digest and is reverified without artificial churn.

The complete sequence for affected machine registries, semantic shards, review, tags, Git ledger and Manager loading is in `RealityEngine_Machines/docs/DOMAIN_APPROVAL_WORKFLOW.md`. Machines PR #234 supplies the companion helper/artifacts; CI PR #690 consumes them. The first hosted failure in run `41347964828` is retained as historical evidence. The reconciled gate passes locally; hosted verification requires the companion Machines changes.
