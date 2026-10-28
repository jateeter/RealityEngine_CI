#!/bin/bash
# install.sh — install RealityEngine on a Mac, start to finish.
#
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/install.sh
#   bash install.sh
#
# One command for a fresh Mac. It does what INSTALL.md describes step by step:
# Docker Desktop, Ollama and its two models, Node, OpenClaw, then the release
# itself, checked against the digests it was certified with. Each step is
# skipped when the Mac already satisfies it, so running it again is safe: it
# brings an existing install up, or upgrades it to this release.
#
# The details go to ~/RealityEngine/install.log; the terminal shows one line per
# step. macOS asks for your password when something is installed system-wide
# (Docker Desktop, Node) and when the local certificate is trusted.
#
#   bash install.sh [--engines SPEC] [--dir DIR] [--check]
#     --engines SPEC  engine instances, default cpp:1,lsp:1,scala:1
#     --dir DIR       install directory, default ~/.realityengine
#     --check         report what would be done, change nothing
#
# Runs on the stock macOS /bin/bash (3.2): a fresh Mac has nothing else.

set -euo pipefail

# ── The release this script installs ──────────────────────────────────────────
# Moving to the next candidate changes these five lines and nothing else
# (RELEASE.md §2). Each value is the certified one: the installer at the commit
# the images were built from, and the images file committed under
# release/candidates/, both checked by sha256 before they are used.
RELEASE_TAG="release-v0.0.1-rc3"
INSTALLER_COMMIT="fc60831f9123fc6328a34ec6b0e648f10c7b3f4e"
INSTALLER_SHA256="406963c0dcd62603fc920b655de835cee698cb924becc611380282c6e27ae26c"
IMAGES_COMMIT="e9352074c66d59551c3dd10726a61232a398c8b9"
IMAGES_SHA256="1b78605b856feb6a7ee3e889f61d3418c8b0eb4ad1f1c07eb5cc03ae7af5f327"

# Host requirements (release/host-requirements.json for this release).
NODE_VERSION="26.12.1"
NODE_PKG_SHA256="eb21cdde0d65277d388ddd4eca6a155bd0082d764372bb98334a470a290d6231"
OLLAMA_MIN="0.40.5"
MODELS="nemotron-3-nano:4b-mlx embeddinggemma-2:270m"
MACOS_MIN=26
DISK_MIN_GB=30
DOCKER_MEM_MIN_GB=8

REPO_RAW="https://raw.githubusercontent.com/jateeter/RealityEngine_CI"
WORK="$HOME/RealityEngine"
LOG="$WORK/install.log"

ENGINES=""
INSTALL_DIR=""
CHECK=false
while [ $# -gt 0 ]; do
  case "$1" in
    --engines) ENGINES="${2:?--engines needs a value}"; shift 2 ;;
    --engines=*) ENGINES="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --check) CHECK=true; shift ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see: bash install.sh --help)" >&2; exit 2 ;;
  esac
done
RE_DIR="${INSTALL_DIR:-$HOME/.realityengine}"

# ── Output ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step()  { printf '%s▸ %s%s\n' "$B" "$*" "$N"; echo "== $* ($(date -u +%FT%TZ))" >> "$LOG"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; echo "ok: $*" >> "$LOG"; }
todo()  { printf '  %s→%s %s\n' "$Y" "$N" "$*"; echo "would: $*" >> "$LOG"; }
fail()  {
  printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2
  printf '  The full log is %s. Its last lines:\n' "$LOG" >&2
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2
  exit 1
}
# A requirement this Mac does not meet: fatal, except under --check, which
# reports every unmet requirement and carries on.
UNMET=0
require() {  # condition-already-tested-false message
  if $CHECK; then printf '  %s✗%s %s\n' "$R" "$N" "$1"; echo "unmet: $1" >> "$LOG"; UNMET=$((UNMET + 1))
  else fail "$1"; fi
}
# Run a command with its output in the log only.
quiet() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }
# Run a long command with its output in the log, showing elapsed time.
long() {
  local label="$1"; shift
  echo "+ $*" >> "$LOG"
  "$@" >> "$LOG" 2>&1 &
  local pid=$! start; start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    [ -t 1 ] && printf '\r  … %s (%dm%02ds)' "$label" $(( ($(date +%s) - start) / 60 )) $(( ($(date +%s) - start) % 60 ))
    sleep 2
  done
  [ -t 1 ] && printf '\r\033[K'
  wait "$pid"
}

# version_ge A B: true when version A >= version B (numeric, dot-separated).
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".");
    for (i = 1; i <= (n > m ? n : m); i++) {
      if ((x[i] + 0) > (y[i] + 0)) exit 0;
      if ((x[i] + 0) < (y[i] + 0)) exit 1;
    }
    exit 0 }'
}
# json_get FILE KEYPATH: a value from a JSON file, with macOS's own plutil (a
# fresh Mac has no python3 until the Command Line Tools are installed).
json_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
sha256_is() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
need_sudo() {
  $CHECK && return 0
  if ! sudo -n true 2>/dev/null; then
    printf '  macOS will ask for your password: %s\n' "$1"
    sudo -v || fail "Administrator access is needed to $1."
  fi
}

mkdir -p "$WORK"
: >> "$LOG"
echo "" >> "$LOG"
echo "######## install.sh $RELEASE_TAG $(date -u +%FT%TZ) check=$CHECK" >> "$LOG"

printf '%sRealityEngine %s%s\n' "$B" "$RELEASE_TAG" "$N"
$CHECK && printf 'Check only: nothing on this Mac is changed.\n'
printf 'Details are logged to %s\n\n' "$LOG"

# ── 1. This Mac ───────────────────────────────────────────────────────────────
step "Checking this Mac"
[ "$(uname -s)" = Darwin ] || fail "This installer is for macOS."
[ "$(uname -m)" = arm64 ] || fail "An Apple Silicon Mac (M1 or later) is required; the images are arm64 only."
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge "$MACOS_MIN" ] || require "macOS $MACOS_MIN or later is required; this Mac runs $macos."
free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
[ "${free_gb:-0}" -ge "$DISK_MIN_GB" ] || require "At least $DISK_MIN_GB GB of free disk is needed; $free_gb GB is free."
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$mem_gb" -ge 16 ] || printf '  %s!%s %s GB of memory; 16 GB is recommended.\n' "$Y" "$N" "$mem_gb"
ok "macOS $macos, Apple Silicon, $mem_gb GB memory, $free_gb GB free"

# ── 2. Docker Desktop ─────────────────────────────────────────────────────────
step "Docker Desktop"
if [ ! -d /Applications/Docker.app ]; then
  if $CHECK; then todo "install Docker Desktop"; else
    long "downloading Docker Desktop" curl -fL -o "$WORK/Docker.dmg" https://desktop.docker.com/mac/main/arm64/Docker.dmg \
      || fail "Docker Desktop could not be downloaded."
    need_sudo "install Docker Desktop"
    quiet sudo hdiutil attach "$WORK/Docker.dmg" -nobrowse || fail "The Docker Desktop disk image could not be opened."
    long "installing Docker Desktop" sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license \
      || { quiet sudo hdiutil detach /Volumes/Docker || true; fail "Docker Desktop did not install."; }
    quiet sudo hdiutil detach /Volumes/Docker || true
    rm -f "$WORK/Docker.dmg"
    ok "Docker Desktop installed"
  fi
fi
export PATH="/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
if ! $CHECK; then
  if ! docker info >/dev/null 2>&1; then
    quiet open -a Docker || true
    printf '  Starting Docker Desktop. If it opens a window, accept or skip it.\n'
    n=0
    until docker info >/dev/null 2>&1; do
      n=$((n + 1)); [ "$n" -le 150 ] || fail "Docker Desktop did not start within 5 minutes. Start it, then run this again."
      sleep 2
    done
  fi
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  docker_gb=$(( (mem_bytes + 536870912) / 1073741824 ))
  [ "$docker_gb" -ge "$DOCKER_MEM_MIN_GB" ] || fail "Docker Desktop has ${docker_gb} GB of memory; it needs at least $DOCKER_MEM_MIN_GB GB.
  Open Docker Desktop → Settings → Resources, set Memory to $DOCKER_MEM_MIN_GB GB or more, Apply & restart, then run this again."
  ok "Docker Desktop $(docker version --format '{{.Server.Version}}' 2>/dev/null) running, ${docker_gb} GB memory"
elif docker info >/dev/null 2>&1; then
  ok "Docker Desktop running"
else
  todo "start Docker Desktop and check it has at least $DOCKER_MEM_MIN_GB GB of memory"
fi

# ── 3. Ollama and its models ──────────────────────────────────────────────────
step "Ollama and its models"
OLLAMA_CLI="ollama"
command -v ollama >/dev/null 2>&1 || OLLAMA_CLI="/Applications/Ollama.app/Contents/Resources/ollama"
ollama_have=""
[ -x "$(command -v "$OLLAMA_CLI" 2>/dev/null || true)" ] && ollama_have="$("$OLLAMA_CLI" --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')"
# Read the whole response before parsing it: an awk that exits at its match
# makes curl fail on SIGPIPE, which pipefail turns into the script's exit.
ollama_release="$(curl -fsS --max-time 10 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null || true)"
ollama_latest="$(printf '%s\n' "$ollama_release" | awk -F'"' '/"tag_name"/ {print $4}' | sed 's/^v//' | sed -n 1p)"
[ -n "$ollama_latest" ] || ollama_latest="$OLLAMA_MIN"
if [ -n "$ollama_have" ] && version_ge "$ollama_have" "$ollama_latest"; then
  ok "Ollama $ollama_have (current)"
elif $CHECK; then
  todo "install Ollama $ollama_latest${ollama_have:+ (installed: $ollama_have)}"
else
  quiet osascript -e 'quit app "Ollama"' || true
  long "downloading Ollama $ollama_latest" curl -fL -o "$WORK/Ollama.dmg" \
    https://github.com/ollama/ollama/releases/latest/download/Ollama.dmg || fail "Ollama could not be downloaded."
  mnt="$(hdiutil attach -nobrowse -readonly "$WORK/Ollama.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}')"
  [ -n "$mnt" ] || fail "The Ollama disk image could not be opened."
  rm -rf /Applications/Ollama.app && cp -R "$mnt/Ollama.app" /Applications/ || fail "Ollama could not be copied to /Applications."
  quiet hdiutil detach "$mnt" || true
  rm -f "$WORK/Ollama.dmg"
  OLLAMA_CLI="/Applications/Ollama.app/Contents/Resources/ollama"
  ollama_have="$("$OLLAMA_CLI" --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')"
  ok "Ollama $ollama_have installed"
fi
if ! $CHECK; then
  if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    quiet open -a Ollama || true
    n=0
    until curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; do
      n=$((n + 1)); [ "$n" -le 60 ] || fail "Ollama did not start. Open the Ollama app, then run this again."
      sleep 2
    done
  fi
  version_ge "$("$OLLAMA_CLI" --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')" "$OLLAMA_MIN" \
    || fail "Ollama $OLLAMA_MIN or later is required."
fi
for m in $MODELS; do
  if "$OLLAMA_CLI" list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "$m"; then
    ok "model $m"
  elif $CHECK; then
    todo "pull model $m"
  else
    long "downloading model $m" "$OLLAMA_CLI" pull "$m" || fail "The model $m could not be pulled."
    ok "model $m"
  fi
done

# ── 4. Node ───────────────────────────────────────────────────────────────────
step "Node $NODE_VERSION"
NODE_BIN=""
for cand in "$(command -v node 2>/dev/null || true)" /usr/local/bin/node /opt/homebrew/bin/node; do
  [ -n "$cand" ] && [ -x "$cand" ] && [ "$("$cand" --version 2>/dev/null)" = "v$NODE_VERSION" ] && { NODE_BIN="$cand"; break; }
done
if [ -n "$NODE_BIN" ]; then
  ok "Node $NODE_VERSION ($NODE_BIN)"
elif $CHECK; then
  todo "install Node $NODE_VERSION (the official installer, checked by sha256)"
else
  long "downloading Node $NODE_VERSION" curl -fL -o "$WORK/node-v$NODE_VERSION.pkg" \
    "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION.pkg" || fail "Node could not be downloaded."
  sha256_is "$WORK/node-v$NODE_VERSION.pkg" "$NODE_PKG_SHA256" \
    || fail "The Node installer does not match its published sha256; it was not run."
  need_sudo "install Node $NODE_VERSION"
  long "installing Node $NODE_VERSION" sudo installer -pkg "$WORK/node-v$NODE_VERSION.pkg" -target / \
    || fail "Node did not install."
  rm -f "$WORK/node-v$NODE_VERSION.pkg"
  NODE_BIN=/usr/local/bin/node
  ok "Node $NODE_VERSION installed"
fi
NODE_DIR="$(dirname "${NODE_BIN:-/usr/local/bin/node}")"
export PATH="$NODE_DIR:$PATH"

# ── 5. OpenClaw ───────────────────────────────────────────────────────────────
step "OpenClaw"
NPM="$NODE_DIR/npm"
oc_latest="$("$NPM" view openclaw@latest version 2>/dev/null || true)"
# A user-owned global prefix, so OpenClaw installs without sudo, unless the
# current one is already writable (Homebrew's is).
npm_prefix="$("$NPM" prefix -g 2>/dev/null || true)"
if [ -z "$npm_prefix" ] || { [ ! -w "$npm_prefix/lib" ] && [ ! -w "$npm_prefix" ]; }; then
  npm_prefix="$HOME/.npm-global"
fi
export PATH="$npm_prefix/bin:$PATH"
OC_BIN="$(command -v openclaw 2>/dev/null || true)"
oc_have=""
[ -n "$OC_BIN" ] && oc_have="$("$OC_BIN" --version 2>/dev/null | awk '{print $2}')"
if [ -n "$oc_have" ] && [ -n "$oc_latest" ] && [ "$oc_have" = "$oc_latest" ]; then
  ok "OpenClaw $oc_have (current)"
elif $CHECK; then
  todo "install OpenClaw ${oc_latest:-latest}${oc_have:+ (installed: $oc_have)} into $npm_prefix"
else
  if [ "$npm_prefix" = "$HOME/.npm-global" ]; then
    mkdir -p "$npm_prefix"
    quiet "$NPM" config set prefix "$npm_prefix"
    grep -qs 'npm-global/bin' "$HOME/.zprofile" \
      || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.zprofile"
  fi
  long "installing OpenClaw ${oc_latest:-latest}" "$NPM" install -g "openclaw@${oc_latest:-latest}" \
    || fail "OpenClaw did not install."
  hash -r
  OC_BIN="$(command -v openclaw 2>/dev/null || true)"
  [ -n "$OC_BIN" ] || fail "OpenClaw installed, but the openclaw command is not on PATH."
  oc_have="$("$OC_BIN" --version 2>/dev/null | awk '{print $2}')"
  ok "OpenClaw $oc_have installed"
fi
export OPENCLAW_BIN="${OC_BIN:-}" OPENCLAW_NODE="$NODE_DIR/node"

# ── 6. The release files ──────────────────────────────────────────────────────
step "Release $RELEASE_TAG"
if $CHECK; then
  # Fetched to a scratch directory and checked, so --check proves both are
  # reachable and certified without touching the install.
  tmp="$(mktemp -d)"
  if curl -fsSL -o "$tmp/re" "$REPO_RAW/$INSTALLER_COMMIT/release/realityengine" 2>>"$LOG" \
      && sha256_is "$tmp/re" "$INSTALLER_SHA256"; then ok "installer reachable, sha256 matches"
  else require "The release installer is unreachable or does not match its sha256."; fi
  if curl -fsSL -o "$tmp/im" "$REPO_RAW/$IMAGES_COMMIT/release/candidates/$RELEASE_TAG.images.json" 2>>"$LOG" \
      && sha256_is "$tmp/im" "$IMAGES_SHA256"; then ok "images file reachable, sha256 matches"
  else require "The images file is unreachable or does not match its sha256."; fi
  rm -rf "$tmp"
else
  quiet curl -fsSL -o "$WORK/realityengine.new" \
    "$REPO_RAW/$INSTALLER_COMMIT/release/realityengine" || fail "The release installer could not be downloaded."
  sha256_is "$WORK/realityengine.new" "$INSTALLER_SHA256" \
    || fail "The release installer does not match its certified sha256; it was not used."
  mv "$WORK/realityengine.new" "$WORK/realityengine" && chmod +x "$WORK/realityengine"
  quiet curl -fsSL -o "$WORK/images.json.new" \
    "$REPO_RAW/$IMAGES_COMMIT/release/candidates/$RELEASE_TAG.images.json" || fail "The images file could not be downloaded."
  sha256_is "$WORK/images.json.new" "$IMAGES_SHA256" \
    || fail "The images file does not match its certified sha256; it was not used."
  mv "$WORK/images.json.new" "$WORK/images.json"
  ok "installer and images file match their certified sha256"
fi

# ── 7. Install, start or upgrade ──────────────────────────────────────────────
RE="$WORK/realityengine"
args=(--images "$WORK/images.json")
[ -n "$INSTALL_DIR" ] && args+=(--dir "$INSTALL_DIR")
[ -n "$ENGINES" ] && args+=(--engines "$ENGINES")
installed=""
[ -f "$RE_DIR/release.json" ] && installed="$(json_get "$RE_DIR/release.json" version)"
if [ -z "$installed" ]; then
  action="install"; cmd=(install --version "$RELEASE_TAG" "${args[@]}")
elif [ "$installed" = "$RELEASE_TAG" ]; then
  action="start"; cmd=(up "${args[@]}")
else
  action="upgrade from $installed"; cmd=(upgrade --to "$RELEASE_TAG" "${args[@]}")
fi
step "RealityEngine: $action"
if $CHECK; then
  todo "realityengine ${cmd[*]}"
  if [ "$UNMET" -gt 0 ]; then
    printf '\nCheck complete: %d requirement(s) above are not met; fix them, then run without --check.\n' "$UNMET"
    exit 1
  fi
  printf '\nCheck complete. Run without --check to install.\n'
  exit 0
fi
[ "$action" = install ] && printf '  The first install downloads about 12 GB and takes 10–20 minutes.\n'
long "$action" "$RE" "${cmd[@]}" || fail "realityengine ${cmd[0]} did not finish."
ok "RealityEngine $RELEASE_TAG is running"

if [ "$action" = install ]; then
  step "Trusting the local certificate"
  printf '  macOS asks for your password so the browser accepts Manager'"'"'s certificate.\n'
  "$RE" trust-ca ${INSTALL_DIR:+--dir "$INSTALL_DIR"} >> "$LOG" 2>&1 \
    && ok "local certificate trusted" \
    || printf '  %s!%s Not trusted; run later: %s trust-ca\n' "$Y" "$N" "$RE"
fi

# ── 8. Check it ───────────────────────────────────────────────────────────────
step "Checking the services"
bad=0
check() {  # name url [-k]
  if curl -fsS ${3:-} -o /dev/null --max-time 10 "$2" 2>/dev/null; then ok "$1"
  else printf '  %s✗%s %s (%s)\n' "$R" "$N" "$1" "$2"; bad=$((bad + 1)); fi
}
check "instance registry" http://localhost:5999/re-registry.json
reg="$WORK/re-registry.json"
if curl -fsS --max-time 10 -o "$reg" http://localhost:5999/re-registry.json 2>/dev/null; then
  i=0
  while id="$(json_get "$reg" "instances.$i.id")" && [ -n "$id" ]; do
    for kind in re pe; do
      url="$(json_get "$reg" "instances.$i.${kind}_url")"
      [ -n "$url" ] && check "$id $(echo "$kind" | tr a-z A-Z)" "$url/api/health"
    done
    i=$((i + 1))
  done
fi
check "Manager" https://localhost:5173 -k
check "localAI" http://localhost:4000/health
check "OpenClaw gateway" http://localhost:18789/healthz

cat <<EOF

${B}RealityEngine $RELEASE_TAG is installed.${N}

  Manager (Visualizer)   https://localhost:5173
  Instance registry      http://localhost:5999/re-registry.json
  localAI API            http://localhost:4000
  Open WebUI             http://localhost:8080
  OpenClaw gateway       http://localhost:18789
  PIM                    http://localhost:8090
  Grafana                http://localhost:3002   (user admin)

  Passwords and tokens:  $RE_DIR/state/secrets.json
  Day to day:            $RE status | logs | down | up | uninstall
  Install log:           $LOG
EOF
[ "$bad" -eq 0 ] || { printf '\n%s%d service(s) did not answer.%s Give them a minute, then: %s status\n' "$Y" "$bad" "$N" "$RE"; exit 1; }
