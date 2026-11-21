# RealityEngine release-v0.0.2 (Release 0.02)

The second release of the integrated RealityEngine application: the twelve
repositories at the commits below, and the sixteen images built from exactly
those commits, pinned by digest in [`release-v0.0.2.json`](release-v0.0.2.json).
It is candidate `release-v0.0.2-rc5`, promoted by digest without rebuilding
(promotion run 44847165944).

New since `release-v0.0.1`:
- **Data in motion is encrypted** (#668): every link between the system's
  parts runs TLS 1.3 under transport profile `re-transport-2026.11`, mTLS
  between services and TLS for user-facing links. The remaining exceptions are
  listed below as accepted deficiencies.
- **The asset storage stack** (`localAssetStorageStack`, #706): Solid PODs,
  the dokieli authoring UI and the document lifecycle API, with the IFRS chain
  run on three engines and compared 3-of-3.
- **The Rust engine** (`re-rust`) and Manager's TypeScript PE (`re-ts-pe`), as
  non-voting conformance followers. Quorum stays C++, LSP and Scala.
- **The HealthKit bridge is certified on the release install** (#808),
  including the phone → PIM mirror through PIM's token-gated device listener.

## Install

On an Apple Silicon Mac with macOS 26 or later, 16 GB of memory and 30 GB free:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/install.sh
bash install.sh
```

`INSTALL.md` covers prerequisites, first run, upgrade and uninstall. Each
install generates its own CA, service secrets and asset-storage accounts. An
iPhone running the bridge has to trust the new install's CA and be given its
new bridge token.

## What is in it

| Repository | Commit |
|---|---|
| RealityEngine_CI | `a3acd7e` |
| RealityEngine_CPP | `423ae03` |
| RealityEngine_LSP | `b0d2143` |
| RealityEngine_Scala | `e3f6d5f` |
| RealityEngine_Rust | `43ad6c0` (follower) |
| RealityEngine_Machines | `ad26c0b` |
| RealityEngine_Manager | `24cec08` |
| localAIStack | `edcb3f5` |
| localOpenClawStack | `aadb899` |
| localAssetStorageStack | `cb2c4bb` |
| OpenCommons-Health---Personal-Information-Management | `4ed20c4` |
| localHealthkitBridge | `2c04343` (iOS app, built with Xcode; no image) |

Images (`ghcr.io/jateeter/<name>:release-v0.0.2`, linux/arm64): `re-cpp`,
`re-lsp`, `re-scala`, `re-scala-pe`, `re-rust`, `re-ts-pe`,
`re-visualizer-backend`, `re-visualizer-frontend`, `re-localai-api`, `re-mcp`,
`re-init`, `re-pim`, `re-css`, `re-corpus`, `re-dokieli`, `re-lifecycle`.
Digests are in the manifest and in
[`release-v0.0.2.images.json`](../release/candidates/release-v0.0.2.images.json).

Every repository carries the tag `release-v0.0.2` at its commit above.
`release-manifest.py published --expect equal` confirmed all 28 repository
tags and images resolve to the manifest.

`RealityEngine_CI`'s main had moved past `a3acd7e` when the manifest was
generated, by release data only: `install.sh`, `release/host-requirements.json`,
the rc5 images file and the rc5 native manifest (`releaseDataAhead` in the
manifest; #813). No runtime source.

## How it was certified

| Check | Run | Result |
|---|---|---|
| Containerized lane on the published rc5 images (E1, the certifying run) | `e1-rc5-cert-20261120b` | completed, 0 new failures against the native run, 0 changed measures |
| Native local lane at the same commits | `rc5-native-20261120` | completed, every stage passed, arbiter sweep included |
| Native vs containerized measurements | the two runs above | 53 of 62 reports identical; the 9 that differ are explained below |

Both lanes ran `cpp:1,lsp:1,scala:1` on the regression corpus with TLS on,
with localAI, Ollama (`nemotron-3-nano:4b-mlx`), the native OpenClaw gateway,
the asset storage stack, the PIM mirror, the iPhone running the HealthKit
bridge, and the live Yuma MQTT broker. The native lane also ran the Rust
follower, shown and not counted. Every required stage passed on both lanes:
build, service inventory, ISRE/OSRE trajectory parity, universal vectors,
machine-set, export and engine-process parity, the PE step contract,
escalation dispatch, arbitration retention, the reset contract, MCP, arbiter
conformance, OpenClaw on every engine, localAI and its machines, MQTT Yuma,
the transport probe, the asset workflow (smoke 10/10, IFRS chain 22/22), the
PIM mirror and the HealthKit bridge.

This is the first release in which the asset workflow ran against the release
install itself (#814).

The nine reports that differ between the lanes:
- `asset-smoke`: the receipt signing key id. Each stack has its own key.
- `local-ai`: the length of an LLM answer (drift is recorded, not evaluated),
  which engine localAI's bridge targeted (the instance registry's order
  differs by lane), and the health and CareKit state each lane's engines
  had reached when it was read.
- `mcp-smoke`: the release's TLS front adds `no-transform` and
  `x-accel-buffering` to MCP's streaming headers.
- `mqtt-yuma-cpp-1`, `mqtt-yuma-lsp-1`: byte, ping and push counts from the
  live external broker.
- `service-inventory`: the native universe serves the OpenAPI portal and its
  per-engine proxies and answers the host bridge-metrics probe; the release
  runs bridge-metrics inside compose without publishing it.
- `transport-probe`, `transport-probe-grafana`, `transport-probe-loki`: the
  links each lane deploys differ (the release adds the Manager TLS proxy to
  Grafana and the Ollama and Open WebUI links listed below; the native lane
  has bridge-metrics and the portal), endpoint names differ (`*.localhost`
  against `127.0.0.1`), and Loki's front answered 503 while Loki was still
  becoming ready.

None is an engine difference. The parity reports are identical.

## Transport profile

Certified under `re-transport-2026.11` (TLS 1.3 only, the profile's cipher
suites, one CA per install, mTLS between services, TLS without client
certificates on user-facing links). The manifest records the release as
compliant with no unrecorded gaps. The accepted transport deficiencies, each
an owner decision recorded in `config/transport-inventory.json`:

- **Ollama in a release install** (#729): plain HTTP on the host's loopback.
  The dev lanes put a TLS front before it, which a release Mac cannot be
  assumed to run.
- **Ollama's TLS front to Ollama** (localAIStack#172): loopback only on the dev
  lanes.
- **Open WebUI** (localOpenClawStack#92): plain HTTP, shipped as such in this
  release; the browser sidecar's CDP proxy to Chromium is plaintext inside its
  own container.
- **The Yuma MQTT broker** (#730): an external party with no TLS.
- **The Solid Community Servers** (PIM's and the asset store's): TLS 1.3
  without client-certificate verification.
- **Loki, Prometheus and Grafana** (#729): Go cannot restrict a server's TLS
  1.3 suites, so each listens on its container's loopback behind a front that
  serves the profile.
- **The npm registry**, read for OpenClaw's current version (#663), offers TLS
  1.2 only.
- **Epic** (PIM#86): an external party, off by default, held to TLS 1.3 against
  the system store, with no lane certificate.
- **Qdrant** (localAIStack#172): its own TLS with client-certificate
  verification, verified by hand rather than by the lane probe.
- **OpenClaw's MCP servers are gateway-wide** (#714), not scoped to a frame.
  Accepted for this release; clone agents have no MCP tools yet.

## Not certified by this release

These were skipped or not run, by decision, and must not be read as passing:
- **The arbiter sweep on the release install.** The containerized lane cannot
  run it (it restarts a native universe per arbiter rule). It passed on the
  native lane, `rc5-native-20261120`.
- **The deployment suite**, which neither lane runs yet; it is not wired into
  `regression-test.sh` (owner accepted, 2026-11-20).

## Clean install

Run 2026-11-20 (times UTC, 2026-11-21) on the owner's Mac with `install.sh`
from `main`. It was a MacBook with Apple Silicon, macOS 27.0.1, 32 GB of memory,
Docker Desktop 29.9.2 with 16 GB, and Wi-Fi at about 1.2–1.3 MB/s. It
succeeded: every service was ready, the native OpenClaw gateway answered with
the profile's 20 agents, and the local CA was trusted.

| Phase | Start | Took |
|---|---|---|
| First run, stopped at OpenClaw (EACCES, #823) | 04:58:20 | 1 min |
| Host checks: Mac, Docker, Ollama 0.40.16, Node, OpenClaw 2026.11.6 | 05:17:20 | 28 s |
| `realityengine install`: host check, `re-init` configure, PKI, accounts | 05:17:48 | about 10 min |
| Pulling the release images | about 05:28 | about 64 min |
| Start, readiness, OpenClaw gateway (sandbox image built) | 06:32:36 | about 3 min |
| `trust-ca` (waiting for the owner's keychain password) | 06:35:17 | 10 min |
| Service check | 06:45:08 | under 1 min |

From the second `install.sh` to the running install took **78 minutes**,
and 64 of them were the image download. The download speed decides how
long it takes.

**How clean it was.** Before the install, the RC4 install was removed with
`uninstall.sh --images --yes`, and Docker's images and build cache were pruned.
`~/.realityengine` was deleted, so the CA, secrets and instance UUIDs are new.
Some state was kept:
- the Ollama models were already pulled;
- two data volumes, `realityengine_localai-machines` and
  `realityengine_corpus-catalog`, survived the uninstall, because it does not
  pass `--purge`;
- Node 26.12.1 (the official `.pkg`) and nvm's OpenClaw were already
  installed.

So this run did not exercise installing Ollama, Node or OpenClaw from nothing,
or pulling the models.

**Findings.**
- The in-place OpenClaw update used the root-owned `/usr/local` npm, which
  failed with EACCES (#823). The workaround was to update OpenClaw with nvm's
  npm and rerun.
- `docker compose pull --quiet` prints nothing for the whole download, so a
  slow pull looks like a hang.
- `INSTALL.md` still showed the v0.0.1 manual install (#824).
- Ollama 0.40.17 was released during the install; the installer filed a
  `host-update` issue and kept 0.40.16, which is above the 0.40.13 minimum.

## Known limitations

- Apple Silicon Macs on macOS 26 or later only; no Intel or Linux images.
- Docker Desktop is the only tested container runtime.
- Ollama runs natively on the host and must be installed first; Ollama and
  OpenClaw are updated to their current releases (#663).
- Hosted checks don't cover Ollama, OpenClaw, the PIM mirror, the asset
  workflow or the iPhone. Certification comes from the local lanes.
- MQTT Yuma availability is external; no MQTT-parity claim.
- LLM drift is recorded but not evaluated.
- The Rust engine and the TypeScript PE are followers: their results are shown
  and never fail a run or count toward parity.
- The containerized lane does not stop a native universe still holding the
  release ports, and checks them only after building (#819). Stop it with
  `stopUniverse.sh` first.
- `startUniverse.sh` can trust a stale engine pid file whose pid was reused
  (RealityEngine_CPP#203).
- The bridge app's POD defaults still name `http://css.localhost`
  (localHealthkitBridge#61), and its CA profiles are not named by lane and
  fingerprint (localHealthkitBridge#62).
- OpenClaw sandbox workspace containers accumulate across runs
  (localOpenClawStack#104).
- A run trace printed the HealthKit bridge token (#810); rotate it on any
  install that ran that trace.
