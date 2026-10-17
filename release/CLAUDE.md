# RealityEngine_CI release/ Guidance

This directory is the **release bundle**: what turns a certified set of commits
into images that a Mac with Apple Silicon on macOS 26 or later installs and runs
with no checkout (`docs/ReleaseRoadmap.md`, decisions A1–A11; `RELEASE.md`;
`INSTALL.md` for users).

| File | What it is |
|---|---|
| `images.json` | The image catalog: every first-party image, its repo, build context and Dockerfile (B1). `scripts/check-release-images.py` validates it |
| `build-images.py` | Builds the catalog natively for linux/arm64, labels each image with its commit, and writes an images file of digests (B4, B5) |
| `promote-images.py` | Retags certified candidates as a release, by digest, never moving a release tag |
| `compose.yml` | The fixed services of an install. Third-party images pinned by tag and digest; first-party by `${RE_IMAGE_*}` |
| `init/` | `re-init`: configures an install (engine services per instance spec, instance UUIDs, both instance-registry views, config, certificates, secrets, OpenClaw), serves the instance registry, and loads machines (C1, C2, C6) |
| `corpus/` | `re-corpus`: the regression corpus the engines boot with, the Load Machines catalog, localAI's machines (A8) |
| `config/` | Release-only config: Prometheus (file_sd per instance), Promtail (Docker API), the TLS proxy |
| `realityengine` | The installer CLI. **Runs on the stock macOS `/bin/bash` 3.2**: no arrays of arrays, no `${v,,}`, no `mapfile`. All logic beyond checking the Mac and driving compose lives in `re-init` |

## Invariants

- **Nothing builds and nothing mounts a checkout** at install time. Host paths are
  the install directory's generated files; data is in named volumes.
- **Engine services are generated, never hand-written** (`reinit.py
  engine_services`), from the operator's spec (A7). Ports: a band per engine
  type (scala 6100, cpp 6300, lsp 6600), stride 10, PE then RE.
- **Instance UUIDs come from `scripts/lib/instance_uuids.py`, unchanged**, in lane
  `release`, kept in the install's `state/` (#296). Never mint one elsewhere.
- **Two views of one instance registry**: host addresses for tools on the Mac,
  container addresses for Manager, localAI and MCP.
- **A service that registers with the engines at start must restart when the
  spec changes.** localAI carries `RE_ENGINES` and PIM `HEALTHKIT_PE_SCOPE_URLS`
  in their environment for exactly that.
- **Machines load into every instance through Manager's own
  `POST /api/corpus/load`**, so the modal and the CLI share one path.

## Testing

- `scripts/tests/test-release-init.sh`: `configure` against a scratch install;
  no Docker.
- `scripts/tests/test-release-images.sh`: the catalog check's refusals.
- A live install builds the images locally and runs
  `release/realityengine install --local --dir <scratch>`. It starts the whole
  suite, so it needs the owner's go-ahead; it collides with the development
  stacks' ports (4000, 8080, 18789) and memory.

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
| Use bash, not zsh | Shell work runs in `/opt/homebrew/bin/bash` (5.x), not zsh or macOS `/bin/bash` 3.2: any loop, unquoted variable, glob or `set --` goes through it with `set -euo pipefail`, and you check the command's exit status, not the pipeline tail. The installer CLI is the one deliberate exception: it is shipped to clean Macs and must run on 3.2. |
