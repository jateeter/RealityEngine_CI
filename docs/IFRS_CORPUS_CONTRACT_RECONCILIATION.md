# IFRS extension versus the published corpus exit contract

The native-observation integration passes local measured testing, but its
hosted corpus-exit job is blocked by a published-contract mismatch. This is
not a native parity failure or an accounting acceptance decision.

`RealityEngine_Machines/docs/CORPUS_EXIT_CRITERIA.md` pins its settled numbers
to `corpus-exit-v2.0` and requires a new major revision for settled changes.
`scripts/check-corpus-exit-criteria.py` enforces those numbers. The hosted job
checks current Machines and OpenClaw main, which already include the IFRS
extension, against that older published baseline.

| Check | Published v2.0 | Current measured corpus | Difference |
| --- | ---: | ---: | ---: |
| Machines | 1,327 | 1,552 | +225 IFRS machines |
| Domains | 12 | 13 | +1 experimental IFRS domain |
| Agent specs | 1,322 | 1,547 | +225 IFRS agent specs |
| Native agent bindings | 1,058 | 1,058 | 0 |
| OpenClaw projections | 1,184 | 1,184 | 0 |
| Intentionally agent-free arbitration fixtures | 5 | 5 | 0 |

The same job confirms unique machine names, zero orphan agents, exact
arbitration-fixture exclusions, zero axis mismatches, and egress-only observe
bindings. These checks remain enabled. The three count assertions remain
failing rather than silently accepting larger limits.

Before merge, reconcile the published contract and the gate's input scope in
a reviewed change: either publish a new corpus contract with remeasured settled
criteria and regenerate dependent provenance against its pinned ref, or define
and test an explicit experimental-domain overlay while retaining every v2.0
baseline assertion. Neither approach should mark IFRS production-accepted or
treat its test-only signoff waiver as a production release decision.

Evidence: RealityEngine_CI workflow run `41347964828`, PR #690. The independent
native/connected evidence is recorded in Machines PR #234. The legacy-key
census failure from that run was separately corrected: factory-schema names
used exclusively in exact `not/required` prohibitions are rejection guards,
not active legacy keys. Positive legacy properties in the same schema still
fail the census, verified by regression tests.
