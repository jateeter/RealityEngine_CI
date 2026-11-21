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

- [Example Machine Compendium](https://github.com/jateeter/RealityEngine_CI/wiki/Example-Machine-Compendium) — searchable index of
  all active domains, machines, AI triggers, agents, vector mappings, and
  interconnections generated from `RealityEngine_Machines/machines/`.
- [Machine Interconnection Index](https://github.com/jateeter/RealityEngine_CI/wiki/Machine-Interconnection-Index) — searchable
  output-to-input overlap index for domain-local and cross-domain machine
  interconnections.
- [Life Balance Machines](https://github.com/jateeter/RealityEngine_CI/wiki/Life-Balance-Machines) — `100` lifestyle-psychiatry
  tracking, automation, projection, and e2e validation machines.

The corpus at `release-v0.0.1` (`RealityEngine_Machines` `7d9bf07`,
[`docs/EXAMPLE_DOMAIN_COMPENDIUM.md`](docs/EXAMPLE_DOMAIN_COMPENDIUM.md)):

- `1327` machines
- `14` active domains
- `9486` used perceptual positions
- `1427` machine-level interconnections
- `95` cross-domain interconnections

## Running from source

Clone these twelve repositories side by side in one workspace directory:

- RealityEngine_CI
- RealityEngine_Machines
- RealityEngine_Manager
- RealityEngine_CPP
- RealityEngine_LSP
- RealityEngine_Scala
- RealityEngine_Rust (a non-voting conformance follower)
- localAIStack
- localOpenClawStack
- localHealthkitBridge
- OpenCommons-Health---Personal-Information-Management
- localAssetStorageStack (from release-v0.0.2)

Then, from `RealityEngine_CI`:

```bash
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1
```

## Release: release-v0.0.2 (closed)

`release-v0.0.2` (Release 0.02) is the second release of the integrated
RealityEngine application: the twelve repositories at the commits below, each
tagged `release-v0.0.2`, and 16 linux/arm64 images on `ghcr.io/jateeter`,
tagged `release-v0.0.2` and pinned by digest in
[`releases/release-v0.0.2.json`](releases/release-v0.0.2.json). It is
candidate `release-v0.0.2-rc5`, promoted by digest without rebuilding
(`release-images.yml` run
[44847165944](https://github.com/jateeter/RealityEngine_CI/actions/runs/44847165944)).
New in it are TLS 1.3 on every link, the asset storage stack, the Rust engine
and the TypeScript PE as followers, and the HealthKit bridge certified on the
release install. The release notes are
[`releases/release-v0.0.2.md`](releases/release-v0.0.2.md).

**Status: closed on 2026-11-21.** release-v0.0.2 is supported for bug
collection and avoidance directives only. Defects found in it are filed on the
[`release-v0.0.3`](https://github.com/jateeter/RealityEngine_CI/milestone) milestone,
and the release notes' **Deficiencies found after release** table says how to
avoid each one on a v0.0.2 install. `release-v0.0.3` is the next release.

**To install it on a Mac, run [`install.sh`](install.sh)** (see
[Install on a fresh Mac](#install-on-a-fresh-mac) below). It does everything,
from Docker Desktop to a running suite, and needs no GitHub account.
[INSTALL.md](INSTALL.md) describes the same steps by hand.

### What certifies it

| Check | Run | Result |
|---|---|---|
| Containerized lane on the rc5 images (E1, the certifying run) | `e1-rc5-cert-20261120b` | completed, 0 new failures against the native run |
| Native lane at the same commits | `rc5-native-20261120` | completed, every stage passed, arbiter sweep included |
| Native vs containerized measurements | the two runs above | 53 of 62 reports identical, 9 explained, none an engine difference |
| Clean-Mac install (E3) | owner, second Mac, 2026-11-20 and 21 | install, asset smoke and IFRS chain, HealthKit on the new CA, machine load, spec change, upgrade and uninstall passed; the documented rollback to v0.0.1 failed (#830) and has an avoidance |

| Repository | Commit |
|---|---|
| OpenCommons-Health---Personal-Information-Management | `4ed20c4` |
| RealityEngine_CI | `a3acd7e` |
| RealityEngine_CPP | `423ae03` |
| RealityEngine_LSP | `b0d2143` |
| RealityEngine_Machines | `ad26c0b` |
| RealityEngine_Manager | `24cec08` |
| RealityEngine_Rust | `43ad6c0` |
| RealityEngine_Scala | `e3f6d5f` |
| localAIStack | `edcb3f5` |
| localAssetStorageStack | `cb2c4bb` |
| localHealthkitBridge | `2c04343` |
| localOpenClawStack | `aadb899` |

**Not certified by this release**, and not to be read as passing: the arbiter
sweep on the release install (it passed on the native lane), the deployment
suite (neither lane runs it), and a from-scratch install of the host tools.

The previous release, `release-v0.0.1`, is described in
[`releases/release-v0.0.1.md`](releases/release-v0.0.1.md).

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
A first run is mostly downloading: the v0.0.2 clean install took 78 minutes,
64 of them pulling images at about 1.3 MB/s. The pull prints nothing until each
image finishes (#825); `tail -f ~/RealityEngine/install.log` shows it moving. It:
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
7. Installs the suite, downloading about 4.5 GB of images (about 15 GB on
   disk), and starts it.
8. Trusts the suite's local certificate, so the browser accepts Manager.
9. Checks every service and prints the addresses.

macOS asks for your password when Docker Desktop or Node is installed system-wide,
and when the certificate is trusted.

Each step is skipped when the Mac already satisfies it, so `install.sh` is safe
to run again. On a Mac where release-v0.0.2 is already installed, it starts it.
On an older install, a release candidate included, it upgrades it to
release-v0.0.2, keeping its data.

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
./realityengine up            # after a machines load, restores the OpenClaw gateway's TLS (#829)
```

To remove it, run [`uninstall.sh`](uninstall.sh). It also clears an install that
stopped partway, or one whose `~/.realityengine` was deleted by hand. It lists
what it found, asks before removing anything, and keeps Docker Desktop, Ollama
and its models, Node and OpenClaw:

```bash
curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/uninstall.sh
bash uninstall.sh --check     # what it would remove
bash uninstall.sh             # add --images to also remove the 16 re-* release images
```

On a v0.0.2 install it leaves `~/.realityengine/pki` (the install CA's private
key), `~/.realityengine/assets` and the trusted install CA in the keychain
(#831). Remove that directory and the "RealityEngine Install CA" certificate by
hand afterwards, and the profile from any iPhone that trusted it.

Run it before installing again over a failed attempt. Data left from an earlier
install that doesn't match the new install's passwords is what stops the
`pim-bootstrap` step with exit 1.

Troubleshooting is covered in [INSTALL.md](INSTALL.md#troubleshooting).

### Re-running the regression lane on the release (developer Mac)

To repeat E1 on a Mac with the sibling repos checked out at the release's
commits (`scripts/release-manifest.py verify --manifest releases/release-v0.0.2.json`),
run this from this repository:

```bash
./scripts/regression-test.sh --execute --profile local-containerized \
  --images release/candidates/release-v0.0.2.images.json \
  --run-id e1-release-<yyyymmdd><letter>
```

The lane installs the release as the compose project `re-regression` and runs
the regression stages against it. It also checks each image's revision label
against the run's repo pins, so the local repos must match those commits.

### Reporting an install problem

Open an issue in this repository with:
- the Mac model and macOS version;
- the Ollama, Node and OpenClaw versions;
- how long the install took;
- `~/RealityEngine/install.log`, and the service checks `install.sh` printed at the end;
- anything you had to do that this section doesn't describe.
