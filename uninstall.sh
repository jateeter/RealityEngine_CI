#!/bin/bash
# uninstall.sh — remove RealityEngine from a Mac: a complete install, or what is
# left of one that stopped partway.
#
#   curl -fsSL -o uninstall.sh https://raw.githubusercontent.com/jateeter/RealityEngine_CI/main/uninstall.sh
#   bash uninstall.sh
#
# The companion of install.sh. It does not need the install to be whole: it
# finds what an install leaves by the names Docker and macOS give it, not by
# asking the installer, so it also clears an install whose directory was deleted
# by hand or whose first start failed. What it removes:
#   - the containers, volumes and network of the compose project (realityengine),
#     including the data in them, and the agents' OpenClaw sandbox containers;
#   - the OpenClaw gateway LaunchAgent, when it is the install's;
#   - the install directory (~/.realityengine), only what the installer wrote;
#   - the "RealityEngine Local CA" certificate from the login keychain;
#   - the installer files in ~/RealityEngine (the logs are kept);
#   - with --images, the release's images (about 12 GB; a reinstall pulls them).
# Docker Desktop, Ollama and its models, Node and OpenClaw stay: install.sh keeps
# them, and other software may use them.
#
#   bash uninstall.sh [--dir DIR] [--images] [--yes] [--check]
#     --dir DIR   install directory, default ~/.realityengine
#     --images    also remove the release images
#     --yes       do not ask before removing
#     --check     report what would be removed, change nothing
#
# Runs on the stock macOS /bin/bash (3.2), like install.sh.

set -euo pipefail

PROJECT_DEFAULT="realityengine"
GATEWAY_LABEL="org.realityengine.openclaw-gateway"
CA_NAME="RealityEngine Local CA"
IMAGE_REGISTRY="ghcr.io/jateeter"
WORK="$HOME/RealityEngine"
LOG="$WORK/uninstall.log"
# What the installer writes into the install directory (release/realityengine,
# re-init). Anything else found there is reported and left.
INSTALL_ENTRIES=".env certs cli.conf compose.yml compose.engines.yml config engines
images.json ocs openclaw openclaw-agents.json registry release.json state"

INSTALL_DIR=""
IMAGES=false
YES=false
CHECK=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --images) IMAGES=true; shift ;;
    --yes|-y) YES=true; shift ;;
    --check) CHECK=true; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see: bash uninstall.sh --help)" >&2; exit 2 ;;
  esac
done
RE_DIR="${INSTALL_DIR:-$HOME/.realityengine}"
RE_DIR="${RE_DIR%/}"

# ── Output ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
mkdir -p "$WORK"
: >> "$LOG"
echo "" >> "$LOG"
echo "######## uninstall.sh $(date -u +%FT%TZ) dir=$RE_DIR check=$CHECK images=$IMAGES" >> "$LOG"
step()  { printf '%s▸ %s%s\n' "$B" "$*" "$N"; echo "== $*" >> "$LOG"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; echo "ok: $*" >> "$LOG"; }
item()  { printf '  %s→%s %s\n' "$Y" "$N" "$*"; echo "found: $*" >> "$LOG"; }
note()  { printf '  %s!%s %s\n' "$Y" "$N" "$*"; echo "note: $*" >> "$LOG"; }
FAILED=0
bad()   { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; echo "failed: $*" >> "$LOG"; FAILED=$((FAILED + 1)); }
quiet() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }

[ "$(uname -s)" = Darwin ] || { echo "This uninstaller is for macOS." >&2; exit 1; }

printf '%sRealityEngine uninstall%s\n' "$B" "$N"
$CHECK && printf 'Check only: nothing on this Mac is changed.\n'
printf 'Details are logged to %s\n\n' "$LOG"

# ── What is there ─────────────────────────────────────────────────────────────
step "Looking for the install"

# The compose project: the install's own .env names it; otherwise the default.
PROJECT="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$RE_DIR/.env" 2>/dev/null | head -1 || true)"
PROJECT="${PROJECT:-$PROJECT_DEFAULT}"

# Is the install directory the installer's? Any of these says so. Without one,
# nothing in it is touched: ~/.realityengine is also a development universe's
# OpenClaw home.
dir_is_install=false
for f in .env cli.conf release.json compose.yml; do
  [ -e "$RE_DIR/$f" ] && dir_is_install=true
done
dir_entries=""
if $dir_is_install; then
  for e in $INSTALL_ENTRIES; do
    [ -e "$RE_DIR/$e" ] && dir_entries="$dir_entries $e"
  done
fi

DOCKER=false
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1 && ! $CHECK; then
    printf '  Starting Docker Desktop to find the install'"'"'s containers…\n'
    quiet open -a Docker || true
    n=0
    until docker info >/dev/null 2>&1 || [ "$n" -ge 60 ]; do sleep 2; n=$((n + 1)); done
  fi
  docker info >/dev/null 2>&1 && DOCKER=true
fi
containers=""; volumes=""; networks=""; sandboxes=""; images=""
if $DOCKER; then
  containers="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true)"
  # By name and label: <project>_* whose compose project is this one, or which
  # has none (the installer also makes volumes with `docker run -v`). A name
  # alone is not enough: the development stack's realityengine_ci_* volumes
  # share the prefix and belong to the compose project realityengine_ci.
  volumes=""
  for v in $(docker volume ls -q 2>/dev/null | grep "^${PROJECT}_" || true); do
    case "$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$v" 2>/dev/null)" in
      "$PROJECT"|"") volumes="$volumes $v" ;;
    esac
  done
  networks=""
  # The release names its network after the project itself.
  for v in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -e "^${PROJECT}\$" -e "^${PROJECT}_" || true); do
    case "$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$v" 2>/dev/null)" in
      "$PROJECT"|"") networks="$networks $v" ;;
    esac
  done
  # The agents' sandboxes, by the install's OpenClaw home among their mounts.
  for c in $(docker ps -aq --filter name=openclaw-sbx 2>/dev/null); do
    if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" 2>/dev/null | grep -qF "$RE_DIR/openclaw/"; then
      sandboxes="$sandboxes $c"
    fi
  done
  if $IMAGES; then
    # By reference, not id: a release pulls by digest, so most have no tag, and
    # removing a reference never forces out an image a container still uses.
    images="$(docker images --digests --format '{{.Repository}} {{.Tag}} {{.Digest}}' 2>/dev/null \
      | awk -v r="$IMAGE_REGISTRY/re-" 'index($1, r) == 1 {
          if ($2 != "<none>") print $1 ":" $2; else if ($3 != "<none>") print $1 "@" $3 }' | sort -u || true)"
  fi
fi

# The gateway LaunchAgent is shared with the development universe; it is the
# install's when its OpenClaw home is under the install directory.
PLIST="$HOME/Library/LaunchAgents/$GATEWAY_LABEL.plist"
gateway=false
if [ -f "$PLIST" ]; then
  state="$(plutil -extract EnvironmentVariables.OPENCLAW_STATE_DIR raw -o - "$PLIST" 2>/dev/null || true)"
  case "$state" in "$RE_DIR"/*) gateway=true ;; esac
fi

# The CA: matched by name, which only re-init gives a certificate.
cas="$(security find-certificate -a -c "$CA_NAME" -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
  | awk '/^SHA-1 hash:/ {print $3}' || true)"

work_files=""
for f in "$WORK"/*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in install.log|uninstall.log) ;; *) work_files="$work_files $(basename "$f")" ;; esac
done

count() { printf '%s\n' "$1" | grep -c . || true; }
found=0
[ -n "$containers" ] && { item "$(count "$containers") container(s) of the compose project $PROJECT"; found=1; }
[ -n "$volumes" ]    && { item "$(count "$(printf '%s\n' $volumes)") volume(s), with the install's data: $(printf '%s ' $volumes)"; found=1; }
[ -n "$networks" ]   && { item "network(s): $(printf '%s ' $networks)"; found=1; }
[ -n "$sandboxes" ]  && { item "$(count "$(printf '%s\n' $sandboxes)") OpenClaw sandbox container(s)"; found=1; }
$gateway             && { item "the OpenClaw gateway LaunchAgent ($GATEWAY_LABEL)"; found=1; }
[ -n "$dir_entries" ] && { item "the install directory $RE_DIR:$dir_entries"; found=1; }
[ -n "$cas" ]        && { item "$(count "$cas") \"$CA_NAME\" certificate(s) in the login keychain"; found=1; }
[ -n "$work_files" ] && { item "installer files in $WORK:$work_files"; found=1; }
[ -n "$images" ]     && { item "$(count "$images") release image(s) ($IMAGE_REGISTRY/re-*)"; found=1; }
if ! $DOCKER; then
  note "Docker is not running, so the install's containers and volumes could not be looked for."
fi
if [ -d "$RE_DIR" ] && ! $dir_is_install; then
  note "$RE_DIR is not an install directory (no .env, cli.conf, release.json or compose.yml); it is left as it is."
fi

if [ "$found" -eq 0 ]; then
  echo ""
  if $DOCKER; then ok "Nothing of a RealityEngine install is on this Mac."; exit 0; fi
  echo "Start Docker Desktop and run this again to check for containers and volumes." >&2
  exit 1
fi

if $CHECK; then
  echo ""
  echo "Run without --check to remove these."
  exit 0
fi

if ! $YES; then
  echo ""
  printf 'Remove these? The install'"'"'s data goes with them. [y/N] '
  answer=""
  read -r answer < /dev/tty || true
  case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing was removed."; exit 1 ;; esac
fi
echo ""

# ── Remove ────────────────────────────────────────────────────────────────────
if $gateway; then
  step "OpenClaw gateway"
  launchctl bootout "gui/$(id -u)/$GATEWAY_LABEL" >> "$LOG" 2>&1 || true
  n=0
  while launchctl print "gui/$(id -u)/$GATEWAY_LABEL" >/dev/null 2>&1 && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
  rm -f "$PLIST"
  if launchctl print "gui/$(id -u)/$GATEWAY_LABEL" >/dev/null 2>&1; then bad "the gateway LaunchAgent is still loaded"
  else ok "gateway stopped and its LaunchAgent removed"; fi
fi

if $DOCKER && [ -n "$containers$volumes$networks$sandboxes" ]; then
  step "Containers and data ($PROJECT)"
  # shellcheck disable=SC2086  # the ids and names, split on purpose
  {
    [ -n "$sandboxes" ]  && quiet docker rm -f $sandboxes
    [ -n "$containers" ] && quiet docker rm -f $containers
    [ -n "$networks" ]   && quiet docker network rm $networks
    [ -n "$volumes" ]    && quiet docker volume rm $volumes
  } || true
  left="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true)"
  [ -z "$left" ] || bad "$(count "$left") container(s) of $PROJECT are still there"
  left=""
  for v in $volumes; do docker volume inspect "$v" >/dev/null 2>&1 && left="$left $v"; done
  [ -z "$left" ] || bad "volume(s) still there:$left"
  [ "$FAILED" -eq 0 ] && ok "containers, network and volumes removed"
fi

if [ -n "$dir_entries" ]; then
  step "Install directory"
  for e in $dir_entries; do
    rm -rf "${RE_DIR:?}/$e" || bad "could not remove $RE_DIR/$e"
  done
  rest="$(ls -A "$RE_DIR" 2>/dev/null || true)"
  if [ -z "$rest" ]; then
    rmdir "$RE_DIR" 2>/dev/null || true
    ok "$RE_DIR removed"
  else
    ok "the installer's files removed from $RE_DIR"
    note "left there, not written by the installer: $(printf '%s ' $rest)"
  fi
fi

if [ -n "$cas" ]; then
  step "Local certificate"
  printf '  macOS may ask for your password to remove the certificate'"'"'s trust setting.\n'
  for h in $cas; do
    security delete-certificate -Z "$h" -t "$HOME/Library/Keychains/login.keychain-db" >> "$LOG" 2>&1 \
      || bad "could not remove the certificate $h from the login keychain"
  done
  [ -z "$(security find-certificate -a -c "$CA_NAME" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null)" ] \
    && ok "\"$CA_NAME\" removed from the login keychain"
fi

if [ -n "$work_files" ]; then
  step "Installer files"
  for f in $work_files; do rm -rf "${WORK:?}/$f"; done
  ok "removed from $WORK (install.log and uninstall.log are kept)"
fi

if [ -n "$images" ]; then
  step "Release images"
  for i in $images; do quiet docker rmi "$i" || true; done
  left="$(docker images --format '{{.Repository}}' 2>/dev/null | grep -c "^$IMAGE_REGISTRY/re-" || true)"
  if [ "${left:-0}" -eq 0 ]; then ok "release images removed"
  else note "$left release image(s) are still used by other containers (the regression lane's re-regression?) and were kept"; fi
fi

echo ""
if [ "$FAILED" -gt 0 ]; then
  printf '%s✗ %d step(s) did not finish.%s The log is %s.\n' "$R" "$FAILED" "$N" "$LOG" >&2
  exit 1
fi
printf '%sRealityEngine is removed.%s\n' "$B" "$N"
echo "Docker Desktop, Ollama and its models, Node and OpenClaw are still installed."
echo "To install again: bash install.sh"
