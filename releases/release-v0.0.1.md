# RealityEngine release-v0.0.1 (Release 0.01)

The first release of the integrated RealityEngine application: the ten
repositories at the commits below, and the twelve images built from exactly
those commits, pinned by digest in [`release-v0.0.1.json`](release-v0.0.1.json).
It is candidate `release-v0.0.1-rc6`, promoted by digest without rebuilding.

## Install

On an Apple Silicon Mac with macOS 26 or later, 16 GB of memory and 30 GB free:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/install.sh
bash install.sh
```

`INSTALL.md` covers prerequisites, first run, upgrade and uninstall.

## What is in it

| Repository | Commit |
|---|---|
| RealityEngine_CI | `5213088` |
| RealityEngine_CPP | `1a66823` |
| RealityEngine_LSP | `de28483` |
| RealityEngine_Scala | `e5d1745` |
| RealityEngine_Machines | `7d9bf07` |
| RealityEngine_Manager | `c134d78` |
| localAIStack | `f894e0f` |
| localOpenClawStack | `ef036c9` |
| OpenCommons-Health---Personal-Information-Management | `521e1d9` |
| localHealthkitBridge | `3d3f5a7` (source only, A10) |

Images (`ghcr.io/jateeter/<name>:release-v0.0.1`, linux/arm64): `re-cpp`,
`re-lsp`, `re-scala`, `re-scala-pe`, `re-visualizer-backend`,
`re-visualizer-frontend`, `re-localai-api`, `re-mcp`, `re-init`, `re-pim`,
`re-css`, `re-corpus`. Digests are in the manifest.

Every repository carries the tag `release-v0.0.1` at its commit above.

## How it was certified

| Check | Run | Result |
|---|---|---|
| Containerized lane on the published rc6 images (E1, the certifying run) | `e1-rc6-cert-20261029a` | completed, 0 new failures, no change from rc5; 44 machines per engine |
| Native local lane at the same commits (F1) | `f1-native-rc6-20261029a` | completed, 0 new failures, no change from the E1 run |
| Native vs containerized measurements (E2) | the two runs above | 53 of 57 reports identical; the 4 that differ are explained below |
| Clean-Mac install (E3) | owner, second Mac (Mac Studio M1 Max, macOS 27.0.1, Docker Desktop 29.9.2) | upgrade rc5 → rc6, uninstall, fresh install, domain load, spec change and uninstall all succeeded |

Both lanes ran `cpp:1,lsp:1,scala:1` on the regression corpus, with localAI,
Ollama (`nemotron-3-nano:4b-mlx`), the native OpenClaw gateway, the PIM mirror
and the live Yuma MQTT broker. Every required stage passed on both:
service inventory, ISRE/OSRE trajectory parity, universal vectors,
machine-set, export and engine-process parity, the PE step contract, MCP,
OpenClaw on every engine, localAI and the PIM mirror.

The native lane ran `RealityEngine_CI` at `2d0f5ac`, not the pinned `5213088`.
Between the two are the e2e spec update for Manager's navigation (#659), the
rc6 images file and README (#658), `install.sh` and `host-requirements.json`'s
release field (#660), and the roadmap (#662); no runtime source.

The four reports that differ between the lanes:
- `local-ai`: the length of an LLM answer (drift is recorded, not evaluated),
  and which engine localAI's bridge targeted (the instance registry's order
  differs by lane);
- `openclaw-integration-cpp-1` and `-scala-1`: whether the
  `localai/agent/tools` source had activated when it was read (it differs
  between engines within the E1 run too);
- `service-inventory`: the native universe serves the OpenAPI Swagger UI and
  its six per-engine proxies, which the release images do not include, and
  answers the optional bridge-metrics probe on the host's port 7342. The
  release runs bridge-metrics inside compose, where Prometheus scrapes it,
  without publishing that port.

None is an engine difference.

## Not certified by this release

These were skipped or not run, by decision, and must not be read as passing:
- **The HealthKit bridge** (A10): an untested development deployment built with
  Xcode. No iPhone was connected to the Mac that ran the lanes.
- **The arbiter sweep**, which compares the engines under every arbiter rule:
  off unless requested. The arbiter conformance stage passed.
- **The deployment suite**, which neither lane runs; D7's live suites ran on
  the install.
- **A from-scratch install of the host tools.** E3 ran on a Mac that already
  had Docker Desktop, Ollama, Node and OpenClaw, so their installation was
  exercised only in its keep-what-is-there form.

## Known limitations

- Apple Silicon Macs on macOS 26 or later only; no Intel or Linux images (A4).
- Docker Desktop is the only tested container runtime (A5).
- Ollama runs natively on the host and must be installed first (A6).
- Hosted checks don't cover Ollama, OpenClaw, the PIM mirror or the iPhone.
  Certification comes from the local and containerized lanes.
- MQTT Yuma availability is external (D5); no MQTT-parity claim (A11).
- LLM drift is recorded but not evaluated (A11).
- Ollama and OpenClaw are kept at whatever the Mac has, with a warning when
  behind the current release; from the next release they are updated (#663).
- Manager e2e: `openclaw-portal.spec.ts:174` (machine-corpus agents not loaded
  in OpenClaw) and `tree-to-pe-manager-equivalence.spec.ts` (API response
  bytes differ across engines) fail, as they did before rc6.
- The native PEs intern every RE machine lacking a source on a bootstrap and
  ignore `machineIds` (noted on Manager#304).
- **Data in motion is not fully encrypted.** Manager is served over HTTPS
  through its TLS proxy. Most other traffic between the system's parts is
  plain HTTP: the engines' RE and PE APIs, the instance registry, localAI,
  MCP, Ollama, the OpenClaw gateway on loopback, and the services on the
  compose network. Every link must be encrypted to the current highest
  standard (TLS 1.3, loopback included, outside parties held strictly) as a
  gate for `release-v0.0.2` (#668).
