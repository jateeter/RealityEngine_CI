# Installing RealityEngine

How to install and run the RealityEngine suite on a Mac from its release images.
No source checkout, compiler or build toolchain is needed.

**The quickest way is [`install.sh`](install.sh)**, which does every step below:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/install.sh
bash install.sh
```

This guide describes the same steps by hand. To build and run
from source instead, see `QUICKSTART.md` and `DOCKER_QUICKSTART.md`.

## What you get

One command starts the whole suite. Most of it runs in Docker:

- **Engines:** C++, Common Lisp and Scala Reality Engines and Perception
  Engines, as many instances of each as you choose, and the Rust engine
  (`rust-1`), a conformance follower: it runs beside the others and never
  votes. Leave it out with `--engines cpp:1,lsp:1,scala:1`.
- **Manager:** the Visualizer.
- **The instance registry:** which engines are running and where.
- **localAIStack:** local AI and RAG, with Qdrant and Redis.
- **Open WebUI**, and OpenClaw's browser sidecar.
- **PIM and a Solid server:** the authoritative store of your health data.
- **Asset storage:** dokieli for authoring and annotating documents
  (https://assets-dokieli.localhost:13444/), their Solid pods
  (https://assets-css.localhost:13443/) and the lifecycle API that runs their
  approval workflows with Manager. Two accounts are made at install,
  `author` and `reviewer` (set `ASSETS_PEOPLE` to choose others); their
  passwords are in `~/.realityengine/assets/.secrets/accounts.json`. Ports
  13443 and 13444 are fixed: a pod's address includes its port.
- **MCP.**
- **Monitoring:** Prometheus, Loki and Grafana, with an exporter for the OpenClaw gateway, localAI, Qdrant and Ollama health.

The engines boot with the regression corpus, and you can load further machines
from `RealityEngine_Machines` at any time.

**Ollama and the OpenClaw gateway run natively on your Mac**, outside Docker,
from your own installation of each, so that models run on Apple Silicon's MLX
runtime. Ollama has used MLX by default since v0.40.0. Each `realityengine up`
starts both services and loads the suite's configuration and agents into them
(#592).

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or later). Intel Macs are not supported |
| macOS | 26 or later |
| Memory | 16 GB. Give Docker Desktop at least **8 GB** (Settings → Resources). The default `cpp:1,lsp:1,scala:1` uses about 4 GB when idle, and more under load. Ollama needs about 4 GB of its own for `nemotron-3-nano:4b-mlx` (2.9 GB) |
| Disk | 30 GB free: the images (about 15 GB), the models (about 4 GB), and the data |
| Docker | [Docker Desktop](https://www.docker.com/products/docker-desktop/), current release, running. Other container runtimes are not tested |
| Ollama | The **current public release**, v0.40.13 or later (the minimum the stack needs), installed on the Mac and running, with both models pulled: `nemotron-3-nano:4b-mlx`, and localAI's embedding model `embeddinggemma-2:270m`. Both run on MLX |
| Node | **Exactly 26.12.1**, the version this release pins for OpenClaw (`release/host-requirements.json`) |
| OpenClaw | The **current public release**, npm `latest`, installed globally for your user |

Nothing else is needed: no Homebrew, no Xcode, no source checkout. **Ollama and
OpenClaw are kept current; the release requires at least Ollama 0.40.13 and
OpenClaw 2026.10.5.** When either is behind its current public release (or below
that minimum), `install.sh`, `realityengine install`, `up` and `upgrade` update
it the way it was installed: Ollama.app from its signed GitHub release, a
Homebrew Ollama with Homebrew, OpenClaw with `npm install -g openclaw@latest`.
They say in one line what changed. If the current release can't be looked up,
the installed version is kept and that is said; if an update fails above the
minimum, the version is kept, noted, and on a Mac where the GitHub CLI is signed
in to this repository an issue is opened. Below the minimum, a failed update is
an error. `realityengine host-check` only reports; `host-check --update` updates.
A Node version other than the pinned one is an error (Node stays exact).

## Preparing a clean Mac

Run these in Terminal, in order. Each download comes from the vendor and is
always its current release, apart from Node, which is pinned and checked
against its published sha256. Commands marked `sudo` ask for your password.

**1. Docker Desktop.** Use Docker's command-line install:

```bash
curl -fL -o ~/Downloads/Docker.dmg https://desktop.docker.com/mac/main/arm64/Docker.dmg
sudo hdiutil attach ~/Downloads/Docker.dmg -nobrowse
sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license
sudo hdiutil detach /Volumes/Docker
open -a Docker
```

Then set Settings → Resources → Memory to at least 8 GB, and wait until
`docker info` answers.

**2. Ollama**, from its latest GitHub release. The Homebrew cask can lag
behind it.

```bash
osascript -e 'quit app "Ollama"' 2>/dev/null || true     # if an older one is running
curl -fL -o ~/Downloads/Ollama.dmg https://github.com/ollama/ollama/releases/latest/download/Ollama.dmg
MNT="$(hdiutil attach -nobrowse -readonly ~/Downloads/Ollama.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')"
rm -rf /Applications/Ollama.app && cp -R "$MNT/Ollama.app" /Applications/
hdiutil detach "$MNT"
open -a Ollama          # on first launch it offers to install the `ollama` command; accept
ollama --version
ollama pull nemotron-3-nano:4b-mlx
ollama pull embeddinggemma-2:270m
```

**3. Node 26.12.1**, the official installer, checked before it runs:

```bash
curl -fL -o ~/Downloads/node-v26.12.1.pkg https://nodejs.org/dist/v26.12.1/node-v26.12.1.pkg
echo "eb21cdde0d65277d388ddd4eca6a155bd0082d764372bb98334a470a290d6231  $HOME/Downloads/node-v26.12.1.pkg" \
  | shasum -a 256 -c -
sudo installer -pkg ~/Downloads/node-v26.12.1.pkg -target /
node --version          # v26.12.1
```

**4. OpenClaw**, the latest release, installed into a user-owned npm prefix so
that it needs no `sudo`:

```bash
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.zprofile
export PATH="$HOME/.npm-global/bin:$PATH"
npm install -g openclaw@latest
openclaw --version
```

Don't run `openclaw onboard --install-daemon`. It installs OpenClaw's own
gateway service on port 18789 using `~/.openclaw`, and that would collide with
the gateway `realityengine` runs. `realityengine` keeps its gateway's state in
`~/.realityengine/openclaw`, and leaves your `~/.openclaw` alone.

**5. Check the footprint.** Each installed version should match the current one:

```bash
echo "Docker   $(docker version --format '{{.Server.Version}}')"
echo "Ollama   $(ollama --version | awk '{print $NF}')   current: $(curl -fsS https://api.github.com/repos/ollama/ollama/releases/latest | awk -F'"' '/"tag_name"/{print $4}')"
echo "Node     $(node --version)   required: v26.12.1"
echo "OpenClaw $(openclaw --version | awk '{print $2}')   current: $(npm view openclaw@latest version)"
ollama list | grep -E 'nemotron-3-nano:4b-mlx|embeddinggemma-2:270m'
```

On a Mac that already has older copies, the same commands upgrade them in
place. If Node is managed by nvm, `nvm install 26.12.1` is also fine, as long as
`openclaw` runs on that Node.

## Install

```bash
curl -fsSL -O https://github.com/jateeter/RealityEngine_CI/releases/download/release-v0.0.2/realityengine
curl -fsSL -O https://github.com/jateeter/RealityEngine_CI/releases/download/release-v0.0.2/release-v0.0.2.images.json
shasum -a 256 -c - <<'SUMS'
e0963eace3e9c710e366a0a90d80de6676f10da805b963af92b0f5f17108ddb4  realityengine
11623b7ecee1f6c262d4c6ed08d521285d2a13a739712d9116ed1171d7840712  release-v0.0.2.images.json
SUMS
chmod +x realityengine
./realityengine install --version release-v0.0.2 --images release-v0.0.2.images.json
```

The two hashes are the ones the release was certified with, and the ones
`install.sh` checks. `release-v0.0.2.images.json` pins every image of the
release by digest, so what you run is exactly what was certified.

`install` does the following:
1. Checks the Mac: macOS version, Apple Silicon, Docker Desktop and its memory,
   disk space, Ollama and the model, and free ports.
2. Configures the install in `~/.realityengine` (override with `--dir`):
   - an instance UUID for each engine instance, kept for good;
   - the instance registry;
   - a local certificate authority and server certificate;
   - generated passwords and tokens;
   - OpenClaw's configuration and agents.
3. Pulls the images (about 4.5 GB to download the first time, about 15 GB on
   disk) and starts everything.
4. Waits until every service is ready, then prints the addresses.

A first install takes about 15 minutes plus the image download. The
download is most of it: release-v0.0.2's clean install took 78 minutes in all,
64 of them pulling over Wi-Fi at about 1.2 MB/s
([`releases/release-v0.0.2.md`](releases/release-v0.0.2.md), "Clean
install"). The pull prints nothing until each image finishes. The install
directory holds generated configuration only. Your data lives in Docker
volumes and survives restarts, upgrades and `uninstall` without `--purge`.

### Choosing the engines

Pass `--engines` to `install` or `up`. The default is one instance of each:

```bash
./realityengine up --engines cpp:2,lsp:1,scala:1
```

Each instance gets its own UUID, kept across restarts and spec changes. An
instance you remove keeps its UUID for when it comes back. Each engine type has
its own port band:

| Engine | PE port, RE port (instance 1) | Then |
|---|---|---|
| Scala | 6100, 6101 | +10 per instance |
| C++ | 6300, 6301 | +10 per instance |
| Common Lisp | 6600, 6601 | +10 per instance |

Up to 20 instances of each type. Scala instances need the most memory: the RE
has a 3 GB heap and the PE a 2 GB heap.

## Using it

| Service | Address | Client certificate |
|---|---|---|
| Manager (Visualizer) | https://localhost:5173 | no |
| Instance registry | https://localhost:5999/re-registry.json | required |
| localAI API | https://localhost:4000 | required |
| Open WebUI | http://localhost:8080 | no (plain HTTP, see below) |
| OpenClaw gateway | https://localhost:18789 | no (its token instead) |
| PIM | https://localhost:8090 | no |
| Grafana | https://localhost:3002 (user `admin`) | no |
| Prometheus | https://localhost:9090 | required |
| Qdrant | https://localhost:4333 | required |
| MCP | https://localhost:7331 | required |
| Asset storage (dokieli) | https://assets-dokieli.localhost:13444/ | no |
| Asset storage (pods) | https://assets-css.localhost:13443/ | no |

These are the addresses with TLS on, the release's default. `./realityengine
urls` prints the install's own; with `RE_TLS=off` every one is `http://`.
- **Browsers:** run `./realityengine trust-ca` once (next section), and the
  services marked "no" open without a warning.
- **Tools:** for a service marked "required", trust the install CA and present a
  client certificate. The CLI uses `~/.realityengine/pki/issued/harness`. For
  example:

  ```bash
  P=~/.realityengine/pki
  curl --cacert $P/ca/ca.crt --cert $P/issued/harness/cert.pem --key $P/issued/harness/key.pem \
    https://localhost:5999/re-registry.json
  ```

The generated passwords (Open WebUI admin, Grafana admin, the Solid account) and
tokens are in `~/.realityengine/state/secrets.json`.

### Certificates and encryption

**Every service talks over TLS 1.3**, with each service presenting a
certificate to the others (mutual TLS), under the suite's transport profile
(`config/transport-profile.json`, recorded in `release.json`). Two exceptions,
accepted for release-v0.0.2:
- Open WebUI serves plain HTTP on `127.0.0.1:8080`, behind its own login;
- Ollama is reached over plain HTTP on the Mac (it serves no TLS).

**The install's own certificate authority** lives in `~/.realityengine/pki`,
made on the first `install` and never shared with another Mac. Every service's
certificate comes from it: one per engine instance (naming the instance's
UUID), and one each for the instance registry, Manager, localAI, Qdrant, Redis,
MCP, PIM and its Solid server, the monitoring stack, and the OpenClaw gateway
and its browser. Private keys stay in that directory and are mounted read-only
into the one container that uses each; the CA's key is mounted nowhere.

**Trust the CA in your browser** (your step; nothing changes a trust store
without you):

```bash
./realityengine trust-ca     # adds ~/.realityengine/pki/ca/ca.crt to your login keychain; macOS asks for your password
```

**Rotation.** Service certificates are valid for 90 days. Every `up` and
`upgrade` renews any that is within 30 days of expiry, and the services pick up
the new certificate when they restart. The CA is valid for 5 years.

**Revocation.** `re_pki.py revoke NAME` (with `RE_PKI_DIR=~/.realityengine/pki`)
revokes a certificate and regenerates the CA's revocation list, which every
service checks; recreate the services (`./realityengine up`) to load it.

**Turning it off** (for troubleshooting only): `RE_TLS=off ./realityengine up`
reconfigures the install without TLS; `RE_TLS=on ./realityengine up` turns it
back on. An install keeps its setting across `up` and `upgrade`.

Tools that use the instance registry find the engines with
`RE_REGISTRY_URL=https://localhost:5999/re-registry.json`, trusting the CA
above and presenting a client certificate (the CLI's own is
`~/.realityengine/pki/issued/harness`).

## Loading machines

The engines boot with the regression corpus. Manager's **Load Machines** modal
offers the whole of `RealityEngine_Machines`, every domain. To load from the
command line instead:

```bash
./realityengine machines list                      # the catalog, by domain
./realityengine machines load --domain agriculture # into every engine instance
./realityengine machines load --machine <id>       # one machine
./realityengine machines load --all                # the whole corpus
```

A load goes into **every** instance, so the engines stay in parity. Each PE then
refreshes its sources. Machines you load are reloaded automatically after every
restart.

`RealityEngine_Machines` keeps growing after a release. To get its newest
machines without upgrading:

```bash
./realityengine machines sync              # its main branch
./realityengine machines sync --ref <tag>  # or any branch, tag or commit
```

`sync` downloads the corpus from GitHub and checks it: every file must be valid
JSON, and no filename may repeat. Only then does it replace the catalog. A
failed sync leaves the catalog as it was.

## Day to day

```bash
./realityengine status      # what is installed, and every service's state
./realityengine logs [svc]  # recent logs, of everything or one service
./realityengine down        # stop; data is kept
./realityengine up          # start again (re-applies the configuration)
```

## Experimenting with near-misses (sandbox replicas)

With K-line capture on, an engine keeps its **near-misses**: paths that got
partway through a machine's sequence and then failed at one step. A **sandbox
replica** is a copy of one engine instance where those near-misses can be put
back, replayed and varied. Nothing a replica does reaches the install.

```bash
./realityengine sandbox export --from cpp-1 --out near.jsonl   # cpp-1's near-misses
./realityengine sandbox up --from cpp-1 --bundle near.jsonl    # prints the replica's name
./realityengine sandbox replay --name <name>                   # 8 near-misses, as recorded, then varied
./realityengine sandbox replay --name <name> --kline <id> --vary 928=0.4
./realityengine sandbox list
./realityengine sandbox down --name <name>                     # results are kept
```

- **The replica** runs from the instance's own image, on a network of its own.
  - It has a UUID and a certificate of its own, issued by the install's CA.
  - It holds no provider settings (no localAI, OpenClaw, Ollama, MQTT or
    HealthKit).
  - It boots the install's corpus, and is refused if that is not the corpus
    the bundle was captured on.
- **Results** are kept in `<install>/state/sandbox/<name>/`: the replica's
  K-lines, the bundle (read-only), and `experiments.jsonl`, one line per replay.
- **Requirements:** the install must have TLS on. `uninstall` removes every
  replica.

How to read the results: `docs/SANDBOX_EXPERIMENTS.md`.

## Upgrading and rolling back

```bash
./realityengine upgrade --to release-v0.0.2 --images release-v0.0.2.images.json
./realityengine upgrade --to release-v0.0.1 --images release-v0.0.1.images.json   # roll back
```

An upgrade changes the images and keeps everything else: the instance UUIDs and
their clocks, localAI's state, Qdrant, the Solid pod, the machine catalog and
the machines you loaded.

## Uninstalling

```bash
./realityengine uninstall            # remove the containers; data and configuration are kept
./realityengine uninstall --purge    # remove everything, including all data
```

[`uninstall.sh`](uninstall.sh) removes everything as well, and also works when
the install is incomplete: when the first start failed, or when
`~/.realityengine` is gone but its Docker volumes are not. It finds what an
install left by the names Docker and macOS give it: the compose project's
containers, volumes and network, the OpenClaw gateway's LaunchAgent, the
installer's files in `~/.realityengine` and `~/RealityEngine`, and the local CA
in the login keychain. It keeps Docker Desktop, Ollama and its models, Node and
OpenClaw.

```bash
curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/uninstall.sh
bash uninstall.sh --check            # list what it would remove
bash uninstall.sh [--images] [--yes] # remove; --images also removes the 12 re-* release images
```

## The HealthKit bridge (iPhone)

The HealthKit bridge is an iOS app that sends your Health data to a Perception
Engine and mirrors it into PIM, your health record on your own Solid pod. It is
built and installed with Xcode; it is not part of the images. From
`release-v0.0.2` it is certified on the release install, on an iPhone, mirror
included (RealityEngine_CI#808).

1. Install Xcode, clone `localHealthkitBridge`, and open it as `README.md` there
   describes. Signing needs an Apple developer team.
2. **Trust the install's CA on the iPhone.** Every link the phone uses is
   TLS 1.3, under certificates from the install's own CA. Write the CA as an
   iOS profile with `localHealthkitBridge/scripts/ca_profile.sh --ca
   ~/.realityengine/pki/ca/ca.crt`, install it on the phone, and turn on full
   trust for it (the script prints the steps). Nothing reaches the phone's
   connections before that.
3. **Point the app at the install by your Mac's LAN address**, never
   `localhost`. `./realityengine install` and `up` print the addresses under
   *iPhone HealthKit bridge*:
   - a Perception Engine: `https://<LAN address>:<PE port>` (the PE ports are in
     `./realityengine status`; the engines publish them on every interface);
   - PIM's device listener: `https://<LAN address>:8091` (`RE_PORT_PIM_DEVICE`).
     It serves only what the phone calls: the mirror and the app's view of your
     records. The rest of PIM stays on `localhost`.
4. Use the install's HealthKit token, `HEALTHKIT_BRIDGE_TOKEN` in
   `~/.realityengine/state/secrets.json`, for the PE (Settings → *Bridge token*)
   and for PIM (Settings → *PIM bridge token*).
5. The iPhone and the Mac must be on the same network, and macOS may ask once
   to allow incoming connections for Docker.

**The mirror** (Settings → *Mirror to PIM*): declare the Health metrics to PIM,
approve the ones you want in PIM, then *Preview from Apple Health* and *Approve
and apply*. Only metrics you approved are read, and nothing is written to your
pod until you approve that batch's preview
(`localHealthkitBridge/docs/MIRROR_CONTRACT.md` §7).

## Troubleshooting

**A port is in use.** `install` names the ports it needs that something else
holds. Stop that program, or move a port by setting it before `install` or
`up`, for example `RE_PORT_WEBUI=18080 ./realityengine up`. The names are
`MANAGER_UI`, `MANAGER_API`, `LOCALAI`, `OPENCLAW`, `WEBUI`, `PIM`, `CSS`,
`MCP`, `REGISTRY`, `GRAFANA`, `PROMETHEUS`, `QDRANT` and `BROWSER_CDP`
(OpenClaw's browser sidecar, 9222). macOS's AirPlay Receiver holds
5000 and 7000, which the release does not use.

**`pim-bootstrap` didn't complete successfully: exit 1.** `docker logs
realityengine-pim-bootstrap-1` shows why. `403 … Invalid email/password
combination` means the Solid server's data is from an earlier install, whose
password this install doesn't have. That happens when `~/.realityengine` was
deleted but its Docker volumes were not. If nothing in the old install needs
keeping, run `bash uninstall.sh`, then `bash install.sh` again.

**Something stays "not ready".** Check `./realityengine status` and
`./realityengine logs <service>`. Most often Docker Desktop has too little
memory: raise it in Settings → Resources and run `./realityengine up`.

**Local AI reports Ollama unreachable.** Start Ollama (`ollama serve`, or the
Ollama app) and check `curl http://127.0.0.1:11434/api/version` answers.

**The browser warns about the certificate.** Run `./realityengine trust-ca`
and restart the browser.

## Known limitations of release-v0.0.2

- Apple Silicon Macs on macOS 26 or later only; no Intel or Linux images.
- Docker Desktop is the only tested container runtime.
- Ollama runs natively on the Mac and must be installed first. Ollama and
  OpenClaw are updated to their current releases (#663).
- The HealthKit bridge is built and installed with Xcode (no App Store or
  TestFlight build). Its POD defaults still name `http://css.localhost`
  (localHealthkitBridge#61), and its CA profiles are not named by lane and
  fingerprint (localHealthkitBridge#62).
- MQTT ingest from the Yuma broker depends on that external broker. This
  release makes no MQTT-parity claim.
- LLM drift between engines is recorded but not evaluated.
- The Rust engine and the TypeScript PE are followers: their results are shown
  and never fail a run or count toward parity.
- Ollama and Open WebUI are plain HTTP, accepted transport deficiencies of
  this release; the others are listed in the release notes.
- OpenClaw sandbox workspace containers accumulate across runs
  (localOpenClawStack#104).
- A run trace printed the HealthKit bridge token (#810); rotate it on any
  install that ran that trace.

The release notes, [`releases/release-v0.0.2.md`](releases/release-v0.0.2.md),
list every limitation and what the release's certification does not cover.

release-v0.0.2 is closed and supported for bug collection and avoidance
directives only; `release-v0.0.3` is the next release. Defects found since it
shipped, among them a Scala engine memory leak under autopush, are in the release
notes under "Deficiencies found after release", each with how to avoid it.
