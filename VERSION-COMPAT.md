# RealityEngine Universe — Version Compatibility Matrix

This file is read by `scripts/validate-versions.sh` to confirm that each
sibling repo is on a compatible ref before `startUniverse.sh` proceeds.

The table format is `| Repo | Version/Tag | Branch |`.
Use `any` for Version to pin only the branch; leave Branch blank to pin only the tag.

## Current Pinned Versions

| Repo | Version/Tag | Branch |
|---|---|---|
| RealityEngine_CPP      | any | main |
| RealityEngine_LSP      | any | main |
| RealityEngine_Scala    | any | main |
| RealityEngine_Manager  | any | main |
| RealityEngine_Machines | any | main |
| localAIStack           | any | main |
| localOpenClawStack     | any | main |

`RealityEngine_CPP` and `RealityEngine_LSP` were absent from this table until
2026-08-09. Only repos listed here are checked, so the gate reported
"All sibling repos on compatible refs" while never looking at two of the three
runtimes — the two that cross-runtime parity is measured against. A gate that
silently covers less than it appears to is the failure mode this whole
verification posture exists to avoid.

Every repo the release manifest pins is now listed, except `RealityEngine_CI`
itself, which is the repo running the check.

## Usage

```bash
# Check all repos before starting
bash scripts/validate-versions.sh

# Warn only (don't block startup on mismatch)
bash scripts/validate-versions.sh --warn-only
```

To pin a specific release tag once repos are tagged, change the version
field from `any` to the tag name (e.g. `v2.1.0`).

## Changelog

- 2026-05-24: CI v1.0.0 — all repos on main
