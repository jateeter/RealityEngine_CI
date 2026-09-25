# RealityEngine_CI Config Guidance

This directory holds generated and shared runtime configuration for the integrated universe.

- Keep `integrations.json` compatible with every PE implementation that consumes `INTEGRATIONS_CONFIG`.
- Keep instance registry and config defaults aligned with `/Users/johnt/workspace/GitHub/CLAUDE.md`.
- Treat generated runtime manifests as operational state unless the user explicitly asks to commit them.
- Use JSON schema-aware editing where available.
- `ces-contracts/` holds the CES output-stream contract shards, derived from 3-of-3 runtime agreement (`docs/QUORUM_CONTRACT.md`) and named `domain-<name>.json` or `corpus-<name>.json`. They are authoritative git files, not runtime state: review them as diffs. The drift gate in `scripts/run-all-tests.sh` runs `scripts/record-ces-contracts.py --check` against them.
- Record them with `scripts/record-ces-contracts.py --only <domain> --write` (or `--corpus <name> --write`), never by hand. Which shards exist and whether they are current is tracked in the cesgen registry, `RealityEngine_Machines/domains/ces-contract-registry.json`.
- There is no single-file `ces-contracts.json` any more. It, `scripts/regression-ces-contracts.py` and `scripts/record-ces-contract-shards.sh` were retired on 2026-09-14 (#376) because they measured a synthetic stimulus. Both scripts refuse to run unless `CES_ALLOW_RETIRED_RECORDER=1`, which exists only to reproduce the old behaviour.

## Standing rules — authoritative in `../docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. The table is an index
to the contract, not a copy of it: it names every rule so you know what to look
up, and the contract's wording governs wherever the two differ.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Regenerate a stale `<name>` registry, don't fail it | Each `<name>` registry is a view of the running system. A gate regenerates it and fails only on a disagreement that survives regeneration. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| _CI is the authority | Peripheral repos keep minimal CI that forces local validation; RealityEngine_CI verifies fixes against a live universe. Check its `docs/` before adding CI anywhere else. |
| Name it `CLAUDE.md` | Uppercase, always. On a case-insensitive filesystem `claude.md` is the same inode; dedupe on `st_ino`, never on a resolved path. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |
| Use bash, not zsh | Shell work runs in `/opt/homebrew/bin/bash` (5.x), not zsh or macOS `/bin/bash` 3.2: any loop, unquoted variable, glob or `set --` goes through it with `set -euo pipefail`, and you check the command's exit status, not the pipeline tail. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
