# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

## Start Here

- [Why this system exists](https://github.com/jateeter/RealityEngine_CI/wiki/Why-This-System-Exists) states the system's purpose,
  its design commitments, and what it declines to be.
- [System document index](https://github.com/jateeter/RealityEngine_CI/wiki/System-Document-Index) maps the documentation across
  all ten repositories and opens with a reading order for a new reader.

## Authoritative Specifications

- [Deployable system](DEPLOYMENT_CONTRACT.md) is the
  primary authoritative documentation surface for the deployable system.
- [Integrated specification](INTEGRATED_SPECIFICATION.md) is the cross-repo
  documentation index, audit summary, deployment gate list, and roadmap to full
  integrated specifications.

The CI repository owns the executable deployment contract and tracks the wiki
gitlink used for published system documentation. Runtime-local docs must link
back to these files rather than redefining ports or environment names.

## Example Machine Corpus

- [Example Machine Compendium](Example-Machine-Compendium) — searchable index of
  all active domains, machines, AI triggers, agents, vector mappings, and
  interconnections generated from `examples/machines/*.json`.
- [Machine Interconnection Index](Machine-Interconnection-Index) — searchable
  output-to-input overlap index for domain-local and cross-domain machine
  interconnections.
- [Life Balance Machines](Life-Balance-Machines) — `100` lifestyle-psychiatry
  tracking, automation, projection, and e2e validation machines.

Current generated corpus:

- `1006` machines
- `11` active domains
- `4109` used perceptual positions
- `1361` machine-level interconnections
- `135` cross-domain interconnections

- ## System Depoloyment
  Clone the following github repos into your local workspace:
  RealityEngine_CI
  RealityEngine_Machines
  RealityEngine_Manager
  RealityEngine_CPP
  RealityEngine_LSP
  RealityEngine_Scala
  localAIStack
  localOpenclawStack
  localHealthkitBridge

  from within the RealityEngine_CI repository, enter:
  ./startUniverse.sh --engines=cpp:1,lsp:1,scala:1

  

## Release candidate: release-v0.0.1-rc3

`release-v0.0.1-rc3` is the current candidate for the MVP release. It is 12
linux/arm64 images on `ghcr.io/jateeter`, built by `release-images.yml`
run [40605186263](https://github.com/jateeter/RealityEngine_CI/actions/runs/40605186263)
from this repository at `fc60831`. It replaces rc2: Ollama and the OpenClaw
gateway now run natively on the Mac, outside Docker (#592), so the
`re-openclaw-gateway` image is gone. The clean-Mac install (E3) is the next
check (`docs/ReleaseRoadmap.md`).

**To install rc3 on a Mac, run [`install.sh`](install.sh)** (see
[Install on a fresh Mac](#install-on-a-fresh-mac) below). It does everything,
from Docker Desktop to a running suite, and needs no GitHub account.
[INSTALL.md](INSTALL.md) describes the same steps by hand.

### What rc3 certifies

| Check | Run | Result |
|---|---|---|
| Containerized lane on the published images (E1, certifying form) | `e1-rc3-cert-20261028a` | completed, 0 new failures, 44 machines on each engine |
| Containerized lane built from the same commits (E1, development form) | `e1-rc3-20261027b` | completed, 0 new failures |
| Native lane, compared with E1 (E2) | `e2-native-rc3-20261027b` | completed, 0 new failures; 52 of 57 reports identical, 5 explained |

The images were built from these commits, the ones both lanes ran:

| Repository | Commit |
|---|---|
| RealityEngine_CI | `fc60831` |
| RealityEngine_CPP | `1a66823` |
| RealityEngine_LSP | `de28483` |
| RealityEngine_Scala | `e5d1745` |
| RealityEngine_Machines | `7d9bf07` |
| RealityEngine_Manager | `af99f99` |
| localAIStack | `f894e0f` |
| localOpenClawStack | `ef036c9` |
| OpenCommons-Health---Personal-Information-Management | `521e1d9` |

The five reports that differ between the lanes are:
- the length of an LLM answer and which engine localAI's bridge targeted;
- when the live Yuma MQTT stream delivered;
- whether one agent-tools source had activated when it was read;
- an envelope id the comparison does not mask;
- the Swagger portal and the bridge-metrics exporter, which the release does
  not run.

None is an engine difference.

These are **not certified by rc3**, and must not be read as passing:
- **The HealthKit bridge.** No iPhone was connected to the Mac that ran the
  lanes, so the `healthkit-bridge` stage was skipped. The device test of
  `localHealthkitBridge` is being run separately on an iPhone, and its result
  is recorded in #592.
- **The arbiter sweep**, which compares the engines under every arbiter rule.
  It is off unless asked for, so it did not run.
- **The deployment suite**, which neither lane runs.

### Install on a fresh Mac

You need an Apple Silicon Mac on macOS 26 or later, with 16 GB of memory,
30 GB of free disk, an internet connection and your administrator password.
Nothing else: no GitHub account, Homebrew, Xcode or source checkout.

Open Terminal and run:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/install.sh
bash install.sh
```

It shows one line per step and logs the details to `~/RealityEngine/install.log`.
A first run takes 20–40 minutes, mostly downloading. It:
1. Checks the Mac: Apple Silicon, macOS version, memory and disk.
2. Installs Docker Desktop if it is missing, starts it, and checks it has at
   least 8 GB of memory. If it has less, it says how to raise it in Docker
   Desktop's settings and stops; raise it and run `install.sh` again.
3. Looks for Ollama first, from the app or Homebrew. One at v0.40.5 or later is
   kept as it is; a newer release is only mentioned. Otherwise it installs the
   current release. Then it pulls whichever of the two models,
   `nemotron-3-nano:4b-mlx` and `embeddinggemma-2:270m`, Ollama doesn't
   already have.
4. Installs Node 26.12.1 from nodejs.org, after checking the installer's
   published sha256.
5. Looks for OpenClaw first, wherever npm installed it. One at 2026.10.5 or
   later is kept, and a newer release is only mentioned. Otherwise it installs
   the current release into a user-owned npm prefix, with no `sudo`.
6. Downloads the release installer and the images file, and checks both
   against the sha256 they were certified with.
7. Installs the suite, about 12 GB of images, and starts it.
8. Trusts the suite's local certificate, so the browser accepts Manager.
9. Checks every service and prints the addresses.

macOS asks for your password when Docker Desktop or Node is installed system-wide,
and when the certificate is trusted.

Each step is skipped when the Mac already satisfies it, so `install.sh` is safe
to run again. On a Mac where rc3 is already installed, it starts it. On an older
install, it upgrades it to rc3, keeping its data.

Options:
- `bash install.sh --check` reports what it would do, and every requirement
  the Mac does not meet, without changing anything.
- `--engines cpp:2,lsp:1,scala:1` chooses the engine instances. The default
  is one of each.
- `--dir DIR` installs somewhere other than `~/.realityengine`.

### Using it

| Service | Address |
|---|---|
| Manager (Visualizer) | https://localhost:5173 |
| Instance registry | http://localhost:5999/re-registry.json |
| localAI API | http://localhost:4000 |
| Open WebUI | http://localhost:8080 |
| OpenClaw gateway (on the Mac, not in Docker) | http://localhost:18789 |
| PIM | http://localhost:8090 |
| Grafana | http://localhost:3002 (user `admin`) |

The generated passwords and tokens are in `~/.realityengine/state/secrets.json`.
The instance registry lists each engine instance's `re_url` and `pe_url`.

`install.sh` leaves the release's own command at `~/RealityEngine/realityengine`:

```bash
cd ~/RealityEngine
./realityengine status
./realityengine logs [service]
./realityengine down          # stop; data is kept
./realityengine up            # start again
./realityengine machines list
./realityengine machines load --domain agriculture   # loads into every engine instance, keeping them in parity
```

To remove it, run [`uninstall.sh`](uninstall.sh). It also clears an install that
stopped partway, or one whose `~/.realityengine` was deleted by hand. It lists
what it found, asks before removing anything, and keeps Docker Desktop, Ollama
and its models, Node and OpenClaw:

```bash
curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/uninstall.sh
bash uninstall.sh --check     # what it would remove
bash uninstall.sh             # add --images to also remove the 12 GB of release images
```

Run it before installing again over a failed attempt. Data left from an earlier
install that doesn't match the new install's passwords is what stops the
`pim-bootstrap` step with exit 1.

Troubleshooting is covered in [INSTALL.md](INSTALL.md#troubleshooting).

### Re-running the regression lane on rc3 (developer Mac)

To repeat E1 on a Mac with the sibling repos checked out at the rc3 commits
above, run this from this repository:

```bash
./scripts/regression-test.sh --execute --profile local-containerized \
  --images release/candidates/release-v0.0.1-rc3.images.json \
  --run-id e1-rc3-<yyyymmdd><letter>
```

The lane installs rc3 as the compose project `re-regression` and runs the
regression stages against it. It also checks each image's revision label
against the run's repo pins, so the local repos must match those commits.

### Reporting the clean-Mac result (E3)

Record the outcome in `docs/ReleaseRoadmap.md` under E3. Include:
- the Mac model and macOS version;
- the Ollama, Node and OpenClaw versions;
- how long the install took;
- `~/RealityEngine/install.log`, and the service checks `install.sh` printed at the end;
- anything you had to do that this section doesn't describe.

E3 has to pass before the candidate can be promoted to `release-v0.0.1` by
digest (`docs/ReleaseRoadmap.md` F4), and the remaining release gates still apply after it.
