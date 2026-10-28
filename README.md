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

This section covers the candidate only. [INSTALL.md](INSTALL.md) is the full
install guide, written for the final `release-v0.0.1`. Everything it describes
applies to rc3 except how you get the two files: a candidate has no GitHub
release, so the steps below fetch them another way.

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

### Requirements

- An Apple Silicon Mac running macOS 26 or later, with 16 GB of memory and 25 GB free.
- Docker Desktop running, with at least 8 GB of memory allotted (Settings → Resources).
- These, installed and running on the Mac itself, as
  [INSTALL.md, Preparing a clean Mac](INSTALL.md#preparing-a-clean-mac) describes:
  - Ollama, its current release (v0.40.5 or later), with both models pulled:
    `ollama pull nemotron-3-nano:4b-mlx` and `ollama pull embeddinggemma-2:270m`.
  - Node, exactly 26.12.1.
  - OpenClaw, its current release (`npm install -g openclaw@latest`; rc3 was
    certified on 2026.10.8).

You don't need a source checkout, a compiler or a Docker login, because the
images are public. The installer runs on the stock macOS `/bin/bash`.

On a Mac that is also used for development, stop the native universe
(`./stopUniverse.sh`) and any other stack holding the release's ports first.
`install` lists the ports it finds taken.

### 1. Get the installer

Take the installer from the commit rc3 was built from, so it matches the images:

```bash
cd ~
curl -fsSL -o realityengine \
  https://raw.githubusercontent.com/jateeter/RealityEngine_CI/fc60831f9123fc6328a34ec6b0e648f10c7b3f4e/release/realityengine
chmod +x realityengine
```

### 2. Get the images file

`images.json` pins each of the 12 images by digest. It is published as the
artifact `release-images-release-v0.0.1-rc3` of run 40605186263, which expires
on 2027-01-25. Get it either way:

```bash
# From GitHub. This needs the GitHub CLI and a login, because artifacts are never anonymous.
brew install gh && gh auth login
gh run download 40605186263 -R jateeter/RealityEngine_CI \
  -n release-images-release-v0.0.1-rc3 -D ~

# Or copy it from a developer Mac, where the regression lane keeps it at
#   RealityEngine_CI/.regression-tests/candidates/release-v0.0.1-rc3.images.json
# Save it on this Mac as ~/images.json.
```

Then check the file. A different hash means it isn't rc3's, so don't install:

```bash
shasum -a 256 ~/images.json
# 1b78605b856feb6a7ee3e889f61d3418c8b0eb4ad1f1c07eb5cc03ae7af5f327
```

### 3. Install

```bash
./realityengine install --version release-v0.0.1-rc3 --images images.json
```

This starts the default engine set: one C++, one Common Lisp and one Scala
instance. For another set, add `--engines`, for example
`--engines cpp:2,lsp:1,scala:1`.

What `install` does:
1. Checks the Mac, including Ollama, Node and OpenClaw.
2. Writes its configuration under `~/.realityengine`, which you can change
   with `--dir`. This covers the instance UUIDs, the instance registry, a
   local CA, the secrets and OpenClaw's agents.
3. Pulls about 12 GB of images: the 12 rc3 images and the third-party ones
   they run with.
4. Starts the OpenClaw gateway on the Mac, waits until every service is ready,
   then prints the addresses.

A first install takes 10–20 minutes, mostly downloading. When it finishes,
trust the local CA so the browser accepts Manager's certificate:

```bash
./realityengine trust-ca
```

### 4. Run and check it

Paste this into the terminal. It runs under the stock `/bin/bash`, and every
line should report `200`:

```bash
./realityengine status
for p in 6100 6101 6300 6301 6600 6601; do        # Scala, C++, Lisp: PE then RE
  printf 'engine :%s ' "$p"; curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 5 "http://localhost:$p/api/health" || echo FAIL
done
curl -fsS  -o /dev/null -w 'instance registry %{http_code}\n' http://localhost:5999/re-registry.json
curl -fsSk -o /dev/null -w 'manager %{http_code}\n'           https://localhost:5173
curl -fsS  -o /dev/null -w 'localai %{http_code}\n'           http://localhost:4000/health
curl -fsS  -o /dev/null -w 'openclaw %{http_code}\n'          http://localhost:18789/healthz
```

The ports above are for the default engine set. With another `--engines`,
`http://localhost:5999/re-registry.json` lists each instance's `re_url` and
`pe_url`.

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

The engines boot with the regression corpus. To load more machines:

```bash
./realityengine machines list
./realityengine machines load --domain agriculture   # loads into every engine instance, keeping them in parity
```

Day-to-day commands:

```bash
./realityengine logs [service]
./realityengine down          # stop; data is kept
./realityengine up            # start again
./realityengine uninstall     # add --purge to delete the data as well
```

Troubleshooting is covered in [INSTALL.md](INSTALL.md#troubleshooting).

### Re-running the regression lane on rc3 (developer Mac)

To repeat E1 on a Mac with the sibling repos checked out at the rc3 commits
above, run this from this repository:

```bash
./scripts/regression-test.sh --execute --profile local-containerized \
  --images .regression-tests/candidates/release-v0.0.1-rc3.images.json \
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
- the output of the check in step 4;
- anything you had to do that this section doesn't describe.

E3 has to pass before the candidate can be promoted to `release-v0.0.1` by
digest (`docs/ReleaseRoadmap.md` F4), and the remaining release gates still apply after it.
