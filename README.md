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

  

## Release candidate: release-v0.0.1-rc2

`release-v0.0.1-rc2` is the current candidate for the MVP release. It is 13
linux/arm64 images on `ghcr.io/jateeter`, built by `release-images.yml`
run [39315175811](https://github.com/jateeter/RealityEngine_CI/actions/runs/39315175811)
from this repository at `a260777`. It passed the containerized regression lane (E1,
run `e1-rc2-20261019a`). The clean-Mac install (E3) is the next check
(`docs/ReleaseRoadmap.md`).

This section covers the candidate only. [INSTALL.md](INSTALL.md) is the full
install guide, written for the final `release-v0.0.1`. Everything it describes
applies to rc2 except how you get the two files: a candidate has no GitHub
release, so the steps below fetch them another way.

### Requirements

- An Apple Silicon Mac running macOS 26 or later, with 16 GB of memory and 25 GB free.
- Docker Desktop running, with at least 8 GB of memory allotted (Settings → Resources).
- Ollama running natively, with both models pulled:
  `ollama pull llama3.1:8b` and `ollama pull nomic-embed-text`.

You don't need a source checkout, a compiler or a Docker login, because the
images are public. The installer runs on the stock macOS `/bin/bash`.

On a Mac that is also used for development, stop the native universe
(`./stopUniverse.sh`) and any other stack holding the release's ports first.
`install` lists the ports it finds taken.

### 1. Get the installer

Take the installer from the commit rc2 was built from, so it matches the images:

```bash
cd ~
curl -fsSL -o realityengine \
  https://raw.githubusercontent.com/jateeter/RealityEngine_CI/a260777e1b9e4132d928326e59cc21e09d904237/release/realityengine
chmod +x realityengine
```

### 2. Get the images file

`images.json` pins each of the 13 images by digest. It is published as the
artifact `release-images-release-v0.0.1-rc2` of run 39315175811, which expires
on 2027-01-17. Get it either way:

```bash
# From GitHub. This needs the GitHub CLI and a login, because artifacts are never anonymous.
brew install gh && gh auth login
gh run download 39315175811 -R jateeter/RealityEngine_CI \
  -n release-images-release-v0.0.1-rc2 -D ~

# Or copy it from a developer Mac, where the regression lane keeps it at
#   RealityEngine_CI/.regression-tests/candidates/release-v0.0.1-rc2.images.json
# Save it on this Mac as ~/images.json.
```

Then check the file. A different hash means it isn't rc2's, so don't install:

```bash
shasum -a 256 ~/images.json
# 8adfb5863b2ce0d2707b31075b06eaef1b26ee2443eed251e5471123b5504e30
```

### 3. Install

```bash
./realityengine install --version release-v0.0.1-rc2 --images images.json
```

This starts the default engine set: one C++, one Common Lisp and one Scala
instance. For another set, add `--engines`, for example
`--engines cpp:2,lsp:1,scala:1`.

What `install` does:
1. Checks the Mac.
2. Writes its configuration under `~/.realityengine`, which you can change
   with `--dir`. This covers the instance UUIDs, the instance registry, a
   local CA, the secrets and OpenClaw's agents.
3. Pulls about 15 GB of images.
4. Waits until every service is ready, then prints the addresses.

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
| OpenClaw gateway | http://localhost:18789 |
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

### Re-running the regression lane on rc2 (developer Mac)

To repeat E1 on a Mac with the sibling repos checked out at the rc2 pins, run
this from this repository:

```bash
./scripts/regression-test.sh --execute --profile local-containerized \
  --images .regression-tests/candidates/release-v0.0.1-rc2.images.json \
  --run-id e1-rc2-<yyyymmdd><letter>
```

The lane installs rc2 as the compose project `re-regression` and runs the
regression stages against it. It also checks each image's revision label
against the run's repo pins, so the local repos must match those pins.

### Reporting the clean-Mac result (E3)

Record the outcome in `docs/ReleaseRoadmap.md` under E3. Include:
- the Mac model and macOS version;
- how long the install took;
- the output of the check in step 4;
- anything you had to do that this section doesn't describe.

E3 has to pass before the candidate can be promoted to `release-v0.0.1` by
digest (`docs/ReleaseRoadmap.md` F4), and the remaining release gates still apply after it.
