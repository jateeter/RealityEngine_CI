#!/usr/bin/env bash
# The release CLI's host preflight (RealityEngine_CI#592, slice a): Ollama,
# OpenClaw and the Node it runs on are checked against release/host-requirements.json
# and the current public release. Everything external is stubbed: curl, ollama,
# openclaw, node and gh, so the result does not depend on this Mac or the network.
#
# Runs the CLI under /bin/bash (3.2 on macOS) because that is what ships.
set -euo pipefail
[ -z "${TRACE:-}" ] || set -x

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$CI_DIR/release/realityengine"
REQ="$CI_DIR/release/host-requirements.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; [ -z "${2:-}" ] || echo "       $2"; fails=$((fails + 1)); }
expect() { # name condition-exit-status [detail]
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

echo "host preflight"

# ── the CLI's constants are the requirements file ────────────────────────────
want="$(python3 -I - "$REQ" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"HOST_REQ_NODE={r['node']['exact']}")
print(f"HOST_REQ_OLLAMA_MIN={r['ollama']['min']}")
print(f"HOST_REQ_OPENCLAW_MIN={r['openclaw']['min']}")
print(f"HOST_REQ_OPENCLAW_REQUIRED={str(r['openclaw']['required']).lower()}")
print(f"HOST_MILESTONE={r['milestone']}")
PY
)"
got="$(grep -E '^HOST_(REQ_[A-Z_]+|MILESTONE)=' "$CLI" | sort)"
[ "$(printf '%s\n' "$want" | sort)" == "$got" ]; expect "constants equal release/host-requirements.json" $? "want: $want / got: $got"

# ── stubs ────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *11434/api/version*) [ -n "${FAKE_OLLAMA_API:-}" ] && { printf '{"version":"%s"}' "$FAKE_OLLAMA_API"; exit 0; }; exit 7 ;;
  *11434/api/tags*) printf '%s' "${FAKE_TAGS:-{\"models\":[]\}}"; exit 0 ;;
  *) exit 7 ;;
esac
EOF
cat > "$BIN/node" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "v${FAKE_NODE:-26.12.1}"; exit 0; fi
[ -f "${1:-}" ] && { echo "OpenClaw ${FAKE_OC:-2026.10.7} (abc1234)"; exit 0; }
exit 0
EOF
printf '#!/bin/bash\necho "ollama version is ${FAKE_OLLAMA_CLI:-0.0.0}"\n' > "$BIN/ollama"
# macOS cannot chain interpreters, so the stub is run by env -> the stub node.
printf '#!/usr/bin/env node\n' > "$BIN/openclaw"
chmod +x "$BIN/curl" "$BIN/node" "$BIN/ollama" "$BIN/openclaw"
# gh records its calls; it is a writer, and has no open host-update issues unless told.
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo "${GH_PERM:-WRITE}" ;;
  "issue list") [ -z "${GH_EXISTING:-}" ] || echo "$GH_EXISTING" ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# run <dir> [args...]: the CLI on a PATH of stubs plus the system's tools.
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
run() { local d="$1"; shift; REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" "$@"; }

# The openclaw stub is only present when a case asks for it.
with_openclaw() { mv "$T/openclaw.off" "$BIN/openclaw" 2>/dev/null || true; }
without_openclaw() { [ -f "$BIN/openclaw" ] && mv "$BIN/openclaw" "$T/openclaw.off" || true; }

# ── 1. Ollama below the MLX floor fails and names the fix ────────────────────
without_openclaw
d="$T/c1"; out="$T/c1.out"
set +e
FAKE_OLLAMA_API=0.35.0 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 run "$d" host-check >"$out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ]; expect "Ollama 0.35.0 fails the check" $? "exit $rc"
grep -q "Ollama.app" "$out"; expect "...and names the upgrade" $?
grep -q '"status": "below-min"' "$d/state/host-services.json"; expect "...and records below-min" $?

# ── 2. current Ollama and OpenClaw on the pinned Node: passes ────────────────
with_openclaw
d="$T/c2"
FAKE_OLLAMA_API=0.40.8 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 run "$d" host-check >"$T/c2.out" 2>&1
expect "current Ollama and OpenClaw on Node 26.12.1 pass" $?
grep -q '"installed": "0.40.8"' "$d/state/host-services.json"; expect "...and records the version" $?
[ ! -f "$d/state/host-updates.md" ]; expect "...and writes no update note" $?

# ── 3. behind the release: warn, write the note, and never duplicate ─────────
with_openclaw
d="$T/c3"
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.6 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >"$T/c3.out" 2>&1
expect "behind the release still passes (warn, not fail)" $?
grep -q "Host update: Ollama 0.40.8 available (installed 0.40.6)" "$d/state/host-updates.md"; expect "note names Ollama" $?
grep -q "Host update: OpenClaw 2026.10.7 available (installed 2026.10.6)" "$d/state/host-updates.md"; expect "note names OpenClaw" $?
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.6 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >/dev/null 2>&1
[ "$(grep -c '^- Host update' "$d/state/host-updates.md")" -eq 2 ]; expect "a second run does not duplicate it" $?
env FAKE_OLLAMA_API=0.40.8 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >/dev/null 2>&1
[ ! -f "$d/state/host-updates.md" ]; expect "the note is removed once current" $?

# ── 4. a failed lookup is reported, never read as current ────────────────────
d="$T/c4"
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.6 RE_LATEST_OLLAMA= RE_LATEST_OPENCLAW= RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >"$T/c4.out" 2>&1
expect "an unreachable release lookup does not fail" $?
grep -q "NOT checked" "$T/c4.out"; expect "...and says currency was not checked" $?
grep -q '"lookups_skipped": true' "$d/state/host-services.json"; expect "...and records that" $?

# ── 5. issues: filed once, refreshed (not duplicated) on the next run ────────
d="$T/c5"; export GH_LOG="$T/gh.log"; : > "$GH_LOG"
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_GH="$BIN/gh" \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >"$T/c5.out" 2>&1
grep -q "issue create .*--label host-update .*--milestone release-v0.0.1-rc3" "$GH_LOG"; expect "files a labelled, milestoned issue" $?
[ ! -f "$d/state/host-updates.md" ]; expect "...and then needs no note" $?
: > "$GH_LOG"
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_GH="$BIN/gh" \
  GH_EXISTING=77 REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >/dev/null 2>&1
{ grep -q "issue edit 77" "$GH_LOG" && ! grep -q "issue create" "$GH_LOG"; }; expect "an open issue is refreshed, not duplicated" $?
env FAKE_OLLAMA_API=0.40.6 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_GH="$BIN/gh" \
  GH_PERM=READ REALITYENGINE_DIR="$T/c5b" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >/dev/null 2>&1
[ -f "$T/c5b/state/host-updates.md" ]; expect "without write access it falls back to the note" $?

# ── 6. Node and OpenClaw are required: the gateway runs natively (#592) ──────
d="$T/c6"
set +e
env FAKE_OLLAMA_API=0.40.8 FAKE_OC=2026.10.7 FAKE_NODE=25.6.1 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$d" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >"$T/c6.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ]; expect "OpenClaw on Node 25.6.1 fails" $?
grep -q "26.12.1" "$T/c6.out"; expect "...and names the pinned version" $?
without_openclaw
set +e
env FAKE_OLLAMA_API=0.40.8 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$T/c6c" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check >"$T/c6c.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q "npm install -g openclaw@latest" "$T/c6c.out"; expect "a missing OpenClaw fails, naming the install" $?
# The requirement is one switch in the requirements file; off, both only warn.
sed 's/^HOST_REQ_OPENCLAW_REQUIRED=true/HOST_REQ_OPENCLAW_REQUIRED=false/' "$CLI" > "$T/cli-optional"
env FAKE_OLLAMA_API=0.40.8 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
  REALITYENGINE_DIR="$T/c6d" PATH="$BIN:$SYS" /bin/bash "$T/cli-optional" host-check >/dev/null 2>&1
expect "...unless OpenClaw is optional" $?
with_openclaw

# ── 7. --json is what the regression manifest embeds ─────────────────────────
js="$(FAKE_OLLAMA_API=0.40.8 FAKE_OC=2026.10.7 RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 REALITYENGINE_DIR="$T/c7" PATH="$BIN:$SYS" /bin/bash "$CLI" host-check --json 2>/dev/null)"
printf '%s' "$js" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["ollama"]["installed"]=="0.40.8" and d["node"]["required"]=="26.12.1"'
expect "host-check --json is valid and carries the versions" $?

[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; }
echo "$fails failure(s)"; exit 1
