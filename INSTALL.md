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
  Engines, as many instances of each as you choose.
- **Manager:** the Visualizer.
- **The instance registry:** which engines are running and where.
- **localAIStack:** local AI and RAG, with Qdrant and Redis.
- **Open WebUI**, and OpenClaw's browser sidecar.
- **PIM and a Solid server:** the authoritative store of your health data.
- **MCP.**
- **Monitoring:** Prometheus, Loki and Grafana.

The engines boot with the regression corpus, and you can load further machines
from `RealityEngine_Machines` at any time.

**Ollama and the OpenClaw gateway run natively on your Mac**, outside Docker,
from your own installation of each, so that models run on Apple Silicon's MLX
runtime. Ollama has used MLX by default since v0.40.0. Each `realityengine up`
starts both services and loads the suite's configuration and agents into them.
This is new in `release-v0.0.1-rc3` (#592). Through rc2, the gateway ran in a
container.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or later). Intel Macs are not supported |
| macOS | 26 or later |
| Memory | 16 GB. Give Docker Desktop at least **8 GB** (Settings → Resources). The default `cpp:1,lsp:1,scala:1` uses about 4 GB when idle, and more under load. Ollama needs about 4 GB of its own for `nemotron-3-nano:4b-mlx` (2.9 GB) |
| Disk | 30 GB free: the images (about 15 GB), the models (about 4 GB), and the data |
| Docker | [Docker Desktop](https://www.docker.com/products/docker-desktop/), current release, running. Other container runtimes are not tested |
| Ollama | The **current public release**, v0.40.5 or later (the MLX build of the model needs it), installed on the Mac and running, with both models pulled: `nemotron-3-nano:4b-mlx`, and localAI's embedding model `embeddinggemma-2:270m`. Both run on MLX |
| Node | **Exactly 26.12.1**, the version this release pins for OpenClaw (`release/host-requirements.json`) |
| OpenClaw | The **current public release**, npm `latest`, installed globally for your user |

Nothing else is needed: no Homebrew, no Xcode, no source checkout. If Ollama
or OpenClaw falls behind its current public release, `install` and `up` warn
you, print the upgrade command, and keep going. On a Mac where the GitHub CLI
is signed in to this repository, they also open an issue for the update. A
Node version other than the pinned one is an error.

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
curl -fsSL -o realityengine \
  https://github.com/jateeter/RealityEngine_CI/releases/download/release-v0.0.1/realityengine
curl -fsSL -o images.json \
  https://github.com/jateeter/RealityEngine_CI/releases/download/release-v0.0.1/images.json
chmod +x realityengine
./realityengine install --version release-v0.0.1 --images images.json
```

`images.json` pins every image of the release by digest, so what you run is
exactly what was certified.

`install` does the following:
1. Checks the Mac: macOS version, Apple Silicon, Docker Desktop and its memory,
   disk space, Ollama and the model, and free ports.
2. Configures the install in `~/.realityengine` (override with `--dir`):
   - an instance UUID for each engine instance, kept for good;
   - the instance registry;
   - a local certificate authority and server certificate;
   - generated passwords and tokens;
   - OpenClaw's configuration and agents.
3. Pulls the images (about 15 GB the first time) and starts everything.
4. Waits until every service is ready, then prints the addresses.

A first install takes 10–20 minutes, most of it downloading. The install
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

| | |
|---|---|
| Manager (Visualizer) | https://localhost:5173 |
| Instance registry | http://localhost:5999/re-registry.json |
| localAI API | http://localhost:4000 |
| Open WebUI | http://localhost:8080 |
| OpenClaw gateway | http://localhost:18789 |
| PIM | http://localhost:8090 |
| Grafana | http://localhost:3002 (user `admin`) |
| Prometheus | http://localhost:9090 |
| Qdrant | http://localhost:4333 |
| MCP | http://localhost:7331 |

The generated passwords (Open WebUI admin, Grafana admin, the Solid account) and
tokens are in `~/.realityengine/state/secrets.json`.

Manager uses HTTPS with a certificate from the install's own CA. To have your
browser trust it:

```bash
./realityengine trust-ca     # adds the CA to your login keychain; macOS asks for your password
```

Tools that use the instance registry find the engines with
`RE_REGISTRY_URL=http://localhost:5999/re-registry.json`.

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

## Upgrading and rolling back

```bash
./realityengine upgrade --to release-v0.0.2 --images images-v0.0.2.json
./realityengine upgrade --to release-v0.0.1 --images images.json   # roll back
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
bash uninstall.sh [--images] [--yes] # remove; --images also removes the release images
```

## The HealthKit bridge (iPhone)

The HealthKit bridge is an iOS app that sends your Health data to a Perception
Engine and mirrors it into PIM. In `release-v0.0.1` it is a **development
deployment: untested, and built and installed with Xcode.** It is not part of
the images.

1. Install Xcode, clone `localHealthkitBridge`, and open it as `README.md` there
   describes. Signing needs an Apple developer team.
2. Point the app at a PE by your Mac's **LAN address**, not `localhost`. The
   instance registry records that address as `host` in
   `http://localhost:5999/re-registry.json`. The bridge speaks plain HTTP on the
   local network (the app allows it with `NSAllowsLocalNetworking`), for example
   `http://<that address>:6300` for `cpp-1`. The engine ports are published on
   every interface for this reason; the instance registry and the other
   services are on `localhost` only.
3. Use the HealthKit ingest token, `HEALTHKIT_BRIDGE_TOKEN` in
   `~/.realityengine/state/secrets.json`.
4. The iPhone and the Mac must be on the same network, and macOS may ask once
   to allow incoming connections for Docker.

The bridge's **mirror to PIM** does not work from the phone in this release.
PIM is published on `localhost` only: of its API, only the HealthKit routes
authenticate the caller, so the rest must not face the network
(`localHealthkitBridge/docs/MIRROR_CONTRACT.md` §5). The mirror itself (bridge →
PIM → Solid pod) is tested from the Mac.

## Troubleshooting

**A port is in use.** `install` names the ports it needs that something else
holds. Stop that program, or move a port by setting it before `install` or
`up`, for example `RE_PORT_WEBUI=18080 ./realityengine up`. The names are
`MANAGER_UI`, `MANAGER_API`, `LOCALAI`, `OPENCLAW`, `WEBUI`, `PIM`, `CSS`,
`MCP`, `REGISTRY`, `GRAFANA`, `PROMETHEUS` and `QDRANT`. macOS's AirPlay Receiver holds
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

## Known limitations of release-v0.0.1

- Apple Silicon Macs on macOS 26 or later only.
- Docker Desktop is the only tested container runtime.
- Ollama must be installed and running natively.
- The HealthKit bridge is an untested development deployment.
- MQTT ingest from the Yuma broker depends on that external broker. This
  release makes no MQTT-parity claim.
- LLM drift between engines is recorded but not evaluated.
