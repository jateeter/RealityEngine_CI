#!/usr/bin/env bash
# Unit tests for scripts/install-deploy-validate-agent.sh and the Node prelude of
# scripts/deploy-validate-scheduled.sh. Changes nothing: the installer runs
# without --execute (it only prints), under a scratch HOME, and the scheduled
# script runs only its prelude (DEPLOY_VALIDATE_PRELUDE_ONLY=1), which exits
# before it touches Docker or the deploy agent.
#
# What it guards: the hand-written plist launched `/bin/bash -lc`, so macOS
# bash 3.2 ran the login profile (sdkman's `bad substitution` on every run), and
# pinned nvm's v26.8.2 on PATH long after the lockstep minor moved to 26.12.
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$CI_DIR/scripts/install-deploy-validate-agent.sh"
SCHEDULED="$CI_DIR/scripts/deploy-validate-scheduled.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/home"

render() { HOME="$SCRATCH/home" DEPLOY_VALIDATE_BASH=/opt/homebrew/bin/bash bash "$INSTALLER" "$@" 2>"$SCRATCH/stderr"; }

# Read one field from a rendered plist. plistlib is in the standard library on
# every runner, so this does not need macOS's plutil.
field() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys, json
d = plistlib.load(open(sys.argv[1], "rb"))
v = d
for k in sys.argv[2].split("."):
    v = v[int(k)] if isinstance(v, list) else v.get(k)
print(json.dumps(v) if isinstance(v, (list, dict, bool)) or v is None else v)
PY
}

echo "install-deploy-validate-agent.sh"

if render > "$SCRATCH/default.plist"; then ok "dry run exits 0"; else bad "dry run exits 0"; fi
grep -q 'dry run, nothing changed' "$SCRATCH/stderr" && ok "dry run says it changed nothing" || bad "dry run says it changed nothing"
[ ! -e "$SCRATCH/home/Library/LaunchAgents" ] && ok "dry run writes no plist" || bad "dry run writes no plist"
python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$SCRATCH/default.plist" 2>/dev/null \
  && ok "output is a valid plist" || bad "output is a valid plist"

P="$SCRATCH/default.plist"
[ "$(field "$P" Label)" = org.energyos.realityengine.deploy-validate ] && ok "label" || bad "label: $(field "$P" Label)"
[ "$(field "$P" ProgramArguments.0)" = /opt/homebrew/bin/bash ] && ok "runs bash 5 directly" || bad "argv[0]: $(field "$P" ProgramArguments.0)"
[ "$(field "$P" ProgramArguments.1)" = "$CI_DIR/scripts/deploy-validate-scheduled.sh" ] \
  && ok "argv[1] is the scheduled script" || bad "argv[1]: $(field "$P" ProgramArguments.1)"
args="$(field "$P" ProgramArguments)"
case "$args" in *'"-l'*) bad "no login shell: $args" ;; *) ok "no login shell" ;; esac
[ "$(field "$P" ProgramArguments.0)" != /bin/bash ] && ok "not macOS bash 3.2" || bad "argv[0] is /bin/bash"
path="$(field "$P" EnvironmentVariables.PATH)"
case "$path" in *nvm*|*node*) bad "PATH names no Node: $path" ;; *) ok "PATH names no Node" ;; esac
case ":$path:" in *:/opt/homebrew/bin:*) ok "PATH has Homebrew" ;; *) bad "PATH has Homebrew: $path" ;; esac
[ "$(field "$P" StartInterval)" = 604800 ] && ok "default interval is weekly" || bad "interval: $(field "$P" StartInterval)"
[ "$(field "$P" RunAtLoad)" = false ] && ok "does not run at load" || bad "RunAtLoad: $(field "$P" RunAtLoad)"
[ "$(field "$P" StandardErrorPath)" = "$CI_DIR/.deploy-validate/scheduled/launchd.err.log" ] \
  && ok "logs under .deploy-validate/scheduled" || bad "stderr path: $(field "$P" StandardErrorPath)"

render --interval 21600 > "$SCRATCH/6h.plist" && [ "$(field "$SCRATCH/6h.plist" StartInterval)" = 21600 ] \
  && ok "--interval is honoured" || bad "--interval is honoured"
if render --interval 60 >/dev/null; then bad "refuses an interval under an hour"; else ok "refuses an interval under an hour"; fi
if render --interval weekly >/dev/null; then bad "refuses a non-numeric interval"; else ok "refuses a non-numeric interval"; fi
if render --bogus >/dev/null; then bad "refuses an unknown argument"; else ok "refuses an unknown argument"; fi

echo "deploy-validate-scheduled.sh prelude"

if grep -q 'nvm use "\$NODE_MAJOR"' "$SCHEDULED"; then bad "no bare-major nvm use"; else ok "no bare-major nvm use"; fi
grep -q '^\. "\$CI_DIR/scripts/lib/node-env.sh"' "$SCHEDULED" && ok "sources node-env.sh" || bad "sources node-env.sh"
if grep -q '\$(establish_node' "$SCHEDULED"; then bad "establish_node not called in a subshell"; else ok "establish_node not called in a subshell"; fi

# Live prelude, where nvm and the .nvmrc minor are installed (developer Macs);
# a runner without them skips it rather than failing on the host.
want="$(tr -d '[:space:]' < "$CI_DIR/.nvmrc")"
if [ -s "$HOME/.nvm/nvm.sh" ] && [ -d "$HOME/.nvm/versions/node" ] && ls -d "$HOME/.nvm/versions/node/v$want."* >/dev/null 2>&1; then
  # The PATH a launchd run starts with: no Node on it.
  out="$(env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/bin:/bin DEPLOY_VALIDATE_PRELUDE_ONLY=1 /opt/homebrew/bin/bash "$SCHEDULED" 2>&1)"
  case "$out" in
    *"node=v$want."*) ok "prelude selects Node $want from a Node-less PATH ($out)" ;;
    *) bad "prelude selects Node $want from a Node-less PATH: $out" ;;
  esac
else
  echo "  skip live prelude: no nvm with Node $want here"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
