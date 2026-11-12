# RealityEngine_CI release/ Guidance

This directory is the **release bundle**: what turns a certified set of commits
into images that a Mac with Apple Silicon on macOS 26 or later installs and runs
with no checkout (`docs/ReleaseRoadmap.md`, decisions A1–A11; `RELEASE.md`;
`INSTALL.md` for users).

| File | What it is |
|---|---|
| `images.json` | The image catalog: every first-party image, its repo, build context and Dockerfile (B1). `scripts/check-release-images.py` validates it |
| `build-images.py` | Builds the catalog natively for linux/arm64, labels each image with its commit, and writes an images file of digests (B4, B5) |
| `candidates/` | Each published candidate's images file (`<tag>.images.json`), committed unchanged from the release run's artifact, so a candidate installs without a GitHub login (the artifact needs one). A release's promotion run's file is committed the same way (`release-v0.0.1.images.json`); `install.sh`'s `IMAGES_SHA256` is the sha256 of the one it installs |
| `promote-images.py` | Retags certified candidates as a release, by digest, never moving a release tag |
| `compose.yml` | The fixed services of an install. Third-party images pinned by tag and digest; first-party by `${RE_IMAGE_*}` |
| `init/` | `re-init`: configures an install (engine services per instance spec, instance UUIDs, both instance-registry views, config, certificates, secrets, OpenClaw), serves the instance registry, and loads machines (C1, C2, C6) |
| `corpus/` | `re-corpus`: the regression corpus the engines boot with, the Load Machines catalog, localAI's machines (A8) |
| `config/` | Release-only config: Prometheus (file_sd per instance, and the `bridge-metrics` service running `scripts/bridge-metrics-exporter.mjs`), Promtail (Docker API, streams labelled `source=compose`; the dashboards select `source=~"host|compose"`), the TLS proxy |
| `host-requirements.json` | What the Mac's own Ollama, OpenClaw and Node must be (#592). The CLI carries the same constants; `scripts/tests/test-host-preflight.sh` keeps them equal |
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
- **Each role's default model runs on MLX** (owner rule, #593): `nemotron-3-nano:4b-mlx`
  and the embedder `embeddinggemma-2:270m`. The embedder is written in
  `compose.yml` (localAI and Open WebUI) and the CLI's model check, and
  `scripts/tests/test-release-embed-default.sh` keeps them equal to localAIStack's
  registry default. Vectors from two embedders do not mix, so `up` and `upgrade`
  run `realityengine reembed` when the collections were filled by another model
  (`reembed_if_needed`); it execs `python -m reembed_cli` in the localAI image,
  which keeps the old collection until `reembed drop-old`.
- **Host services are kept current, never pinned** (#592, #663). `realityengine
  host-check` (also run by `install`, `up`, `upgrade`, `startUniverse.sh` and
  every regression run) finds Ollama, OpenClaw and the Node OpenClaw runs on,
  compares them with `host-requirements.json` and the current public releases,
  and records `state/host-services.json` (with `updated`, what it changed),
  which `configure` copies into `release.json` and every regression manifest
  embeds as `hostServices`: that record, not a pin, is what certification reads.
  `install`, `up`, `upgrade` and `host-check --update` update a service behind
  current or below the minimum, the way it was installed (Ollama.app from the
  signed release zip, checked against GitHub's digest and Ollama's Developer ID
  team; Homebrew; `npm install -g openclaw@<current> --allow-scripts=openclaw`),
  with the gateway stopped first. A plain `host-check` never changes the host.
  A failed update below the minimum fails; above it, the version is kept and
  one `host-update` issue is filed per service and version (or
  `state/host-updates.md` written where `gh` cannot file); a failed lookup says
  so, keeps what is installed, and is never read as current. `RE_HOST_UPDATE=0`
  turns updating off. `openclaw.required` is `true`: the gateway
  runs natively, so a missing OpenClaw, or a Node other than `node.exact`,
  fails install. The probe resolves the `openclaw` the LaunchAgent runs
  (`RE_OPENCLAW_BIN`/`OPENCLAW_BIN`, Homebrew's prefix, then PATH).
- **The OpenClaw gateway is the Mac's own `openclaw`, not an image** (#592).
  `re-init configure` (and `machines-load`) generate its home in
  `<install>/openclaw` with localOpenClawStack's scripts, in the `entries`
  format with the Mac's paths (`HOST_INSTALL_DIR`, recorded in
  `state/host-install.json`), loopback bind, Ollama on 127.0.0.1 and the
  browser sidecar's CDP (`RE_PORT_BROWSER_CDP`, default 9222, published on
  127.0.0.1 only). It copies those scripts and the sandbox Dockerfile to
  `<install>/ocs`, with the token in a private `.env`. `realityengine up` then
  runs `ocs/scripts/native-gateway.sh up --no-generate`: the LaunchAgent
  `org.realityengine.openclaw-gateway` on `127.0.0.1:${RE_PORT_OPENCLAW}`;
  `down`, `upgrade` and `uninstall` stop it first. Containers reach it at
  `host.docker.internal`. The images are 12.

## Testing

- `scripts/tests/test-host-preflight.sh`: the host preflight against stubbed
  curl/ollama/openclaw/node/gh, under `/bin/bash`.
- `scripts/tests/test-release-init.sh`: `configure` against a scratch install;
  no Docker.
- `scripts/tests/test-release-images.sh`: the catalog check's refusals.
- A live install builds the images locally and runs
  `release/realityengine install --local --dir <scratch>`. It starts the whole
  suite, so it needs the owner's go-ahead; it collides with the development
  stacks' ports (4000, 8080, 18789) and memory.

## Local exception: the installer runs on bash 3.2

The contract's bash rule does not apply to the installer CLI
(`realityengine`, `install.sh`, `uninstall.sh`): they ship to clean Macs
and must run on macOS `/bin/bash` 3.2.

## Standing rules

The standing rules are in
`../docs/ENGINEERING_CONTRACT.md`, which is
authoritative. They are not listed or summarised here, so this file never
falls behind the contract. Read it before changing anything here.
