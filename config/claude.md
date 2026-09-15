# RealityEngine_CI Config Guidance

This directory holds generated and shared runtime configuration for the integrated universe.

- Keep `integrations.json` compatible with every PE implementation that consumes `INTEGRATIONS_CONFIG`.
- Keep registry/config defaults aligned with `/Users/johnt/workspace/GitHub/claude.md`.
- Treat generated runtime manifests as operational state unless the user explicitly asks to commit them.
- Use JSON schema-aware editing where available.
- `ces-contracts.json` and `ces-contracts/` hold CES output-stream contract shards derived from 3-of-3 runtime agreement (`docs/QUORUM_CONTRACT.md`). They are authoritative git files, not runtime state: review them as diffs. `ces-contracts.json` is the regression scope and stays at that path because the drift gate in `scripts/run-all-tests.sh` reads it there; every other scope is a shard in `ces-contracts/`, named `domain-<name>.json` or `corpus-<name>.json`.
- Record them with `scripts/record-ces-contract-shards.sh`, never by hand. Which shards exist and whether they are current is tracked in `../RealityEngine_Machines/domains/ces-contract-registry.json`.

## Standing rules — authoritative in `../docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. They were previously
copied into eighteen `claude.md` files across six repositories, which is the
duplication problem the rules themselves warn about: copies drift, a rule added
to one applies only where someone looked, and with no authority a reader cannot
tell which copy is current.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
