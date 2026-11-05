# RealityEngine_CI Config Guidance

This directory holds generated and shared runtime configuration for the integrated universe.

- Keep `integrations.json` compatible with every PE implementation that consumes `INTEGRATIONS_CONFIG`.
- Keep instance registry and config defaults aligned with `/Users/johnt/workspace/GitHub/CLAUDE.md`.
- Treat generated runtime manifests as operational state unless the user explicitly asks to commit them.
- `ces-contracts/` holds the CES output-stream contract shards, derived from 3-of-3 runtime agreement (`docs/QUORUM_CONTRACT.md`) and named `domain-<name>.json` or `corpus-<name>.json`. They are authoritative git files, not runtime state: review them as diffs. The drift gate in `scripts/run-all-tests.sh` runs `scripts/record-ces-contracts.py --check` against them, with `--corpus <name>` when the universe booted a `config/<name>-corpus.txt` manifest.
- Record them with `scripts/record-ces-contracts.py --only <domain> --write` (or `--corpus <name> --write`, checked with `--corpus <name> --check`), never by hand. Which shards exist and whether they are current is tracked in the cesgen registry, `RealityEngine_Machines/domains/ces-contract-registry.json`.
- `ces-contracts/` shards are the only CES contract record. `scripts/regression-ces-contracts.py` and `scripts/record-ces-contract-shards.sh` measured a synthetic stimulus and are retired: they refuse to run unless `CES_ALLOW_RETIRED_RECORDER=1`, which exists only to reproduce their output.

## Standing rules

The standing rules are in
`../docs/ENGINEERING_CONTRACT.md`, which is
authoritative. They are not listed or summarised here, so this file never
falls behind the contract. Read it before changing anything here.
