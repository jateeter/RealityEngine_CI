# RealityEngine_CI Config Guidance

This directory holds generated and shared runtime configuration for the integrated universe.

- Keep `integrations.json` compatible with every PE implementation that consumes `INTEGRATIONS_CONFIG`.
- Keep instance registry and config defaults aligned with `/Users/johnt/workspace/GitHub/CLAUDE.md`.
- Treat generated runtime manifests as operational state unless the user explicitly asks to commit them.
- `ces-contracts/` holds the CES output-stream contract shards, derived from 3-of-3 runtime agreement (`docs/QUORUM_CONTRACT.md`) and named `domain-<name>.json` or `corpus-<name>.json`. They are authoritative git files, not runtime state: review them as diffs. The drift gate in `scripts/run-all-tests.sh` runs `scripts/record-ces-contracts.py --check` against them, with `--corpus <name>` when the universe booted a `config/<name>-corpus.txt` manifest.
- Record them with `scripts/record-ces-contracts.py --only <domain> --write` (or `--corpus <name> --write`, checked with `--corpus <name> --check`), never by hand. Which shards exist and whether they are current is tracked in the cesgen registry, `RealityEngine_Machines/domains/ces-contract-registry.json`.
- `ces-contracts/` shards are the only CES contract record. `scripts/regression-ces-contracts.py` and `scripts/record-ces-contract-shards.sh` measured a synthetic stimulus and are retired: they refuse to run unless `CES_ALLOW_RETIRED_RECORDER=1`, which exists only to reproduce their output.
- `extension-corpus.txt` is generated: the regression corpus plus the machine-factory candidates above the corpus vector budget, composed by `scripts/write-extension-corpus.py` from `extension-corpus.json`. Never edit it by hand. Boot it with `--machine-corpus=extension`; the materializer finds candidates under `RealityEngine_Machines/machine_factory/domains`.
- **Machine-factory work in progress never fails a gate** (owner, 2026-11-27). The harness composes the extension manifest at boot (`--out`) from each package's `machines/*.json` as it stands; `--check` gates only the regression half, and a stale candidate snapshot is a note. In `ces-contracts/corpus-*.json` candidates sit in `candidates`, outside `corpusFingerprint` and `counts`, and `record-ces-contracts.py --check` compares them non-gating. RealityEngine_Machines' cesgen registry leaves candidates out of every scope (`candidatePolicy`). At admission a machine moves to `machines/domains/<slug>/` and gates. Any change that adds a `config/*-corpus.txt` regenerates that registry in the same change set: CI#877 did not, and every regression run stopped in `validate-machines` until RealityEngine_Machines#315.

## Standing rules

The standing rules are in
`../docs/ENGINEERING_CONTRACT.md`, which is
authoritative. They are not listed or summarised here, so this file never
falls behind the contract. Read it before changing anything here.
