#!/usr/bin/env bash
# Unit tests for scripts/lib/stack-owner.sh and the startUniverse.sh /
# stopUniverse.sh code that uses it (RealityEngine_CI#479). No Docker: `docker`,
# `launchctl` and `lsof` are stubbed and every call is logged.
#
# A universe started from worktrees with --no-openclaw removed the operator's
# OpenClaw stack and recreated localAI from the worktree, because a worktree is
# the same compose project as the main checkout.
#
# The extracted script segments call stubs that static analysis cannot see.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

MAIN="$TMP/ws/localAIStack";      mkdir -p "$MAIN"
WT="$TMP/wt/localAIStack";        mkdir -p "$WT"
OCS_MAIN="$TMP/ws/localOpenClawStack"; mkdir -p "$OCS_MAIN"; touch "$OCS_MAIN/docker-compose.yml"
ln -s "$TMP/ws" "$TMP/ws-link"

# Stub docker. $STUB_DIR/running lists "name<TAB>working_dir" per container.
STUB_DIR="$TMP/stub"; mkdir -p "$STUB_DIR/bin"; : > "$STUB_DIR/running"; : > "$STUB_DIR/calls"
cat > "$STUB_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_DIR/calls"
case "$1" in
  ps)      cut -f1 "$STUB_DIR/running" ;;
  inspect) name="${*: -1}"; awk -F'\t' -v n="$name" '$1==n{print $2}' "$STUB_DIR/running" ;;
esac
exit 0
STUB
for t in launchctl lsof; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_DIR/calls"\n' "$t" > "$STUB_DIR/bin/$t"; done
chmod +x "$STUB_DIR"/bin/*
export STUB_DIR PATH="$STUB_DIR/bin:$PATH"
running() { printf '%s\n' "$@" > "$STUB_DIR/running"; }

# shellcheck source=../lib/stack-owner.sh
source "$CI_DIR/scripts/lib/stack-owner.sh"

echo "stack_foreign_owner"
running ""
check "$(stack_foreign_owner "$WT" "$STACK_OWNER_LOCALAI_PATTERN")" "" "nothing running: no owner"
running "localai_api	$MAIN" "localai_qdrant	$MAIN"
check "$(stack_foreign_owner "$MAIN" "$STACK_OWNER_LOCALAI_PATTERN")" "" "running from this checkout: not foreign"
check "$(stack_foreign_owner "$WT" "$STACK_OWNER_LOCALAI_PATTERN")" "$(cd "$MAIN" && pwd -P)" \
  "the #479 case: running from main, asked from a worktree, names main"
check "$(stack_foreign_owner "$TMP/ws-link/localAIStack" "$STACK_OWNER_LOCALAI_PATTERN")" "" \
  "a symlinked path to the same checkout is not foreign"
running "localai_api	"
check "$(stack_foreign_owner "$WT" "$STACK_OWNER_LOCALAI_PATTERN")" "" "no compose label: not attributed"
running "open-webui	$MAIN" "openclaw-gateway	$OCS_MAIN"
check "$(stack_foreign_owner "$WT" "$STACK_OWNER_LOCALAI_PATTERN")" "" "OpenClaw containers do not match the localAI pattern"
check "$(stack_foreign_owner "$OCS_MAIN" "$STACK_OWNER_OPENCLAW_PATTERN")" "$(cd "$MAIN" && pwd -P)" \
  "OpenClaw pattern covers open-webui"

# ── startUniverse.sh: the guard, extracted and run ───────────────────────────
GUARD=$(sed -n '/^source "\$CI_DIR\/scripts\/lib\/stack-owner.sh"$/,/_refuse_foreign_stack "localOpenClawStack"/p' "$CI_DIR/startUniverse.sh")
run_guard() {  # <OPENCLAW> <DRY_RUN> [env...]
  local oc="$1" dry="$2"; shift 2
  env "$@" CI_DIR="$CI_DIR" LAS_DIR="$WT" OCS_DIR="$TMP/wt/localOpenClawStack" OPENCLAW="$oc" DRY_RUN="$dry" \
    bash -c 'WARNS=(); die(){ echo "DIE: $*"; exit 1; }; warn(){ echo "WARN: $*"; }; add_warn(){ echo "ADDWARN: $*"; }
             '"$GUARD"'
             echo "CONTINUED"' 2>&1 || true
}

echo "startUniverse.sh guard"
check "$([ -n "$GUARD" ] && echo found)" found "guard block extracted"
running "localai_api	$MAIN"
out=$(run_guard auto false)
check "$(grep -c '^DIE: localAIStack is running from a different checkout' <<<"$out")" 1 "foreign localAI: refuses"
check "$(grep -c "$(cd "$MAIN" && pwd -P)" <<<"$out")" 1 "and names the running checkout"
check "$(grep -c '^CONTINUED' <<<"$out")" 0 "and stops before the cleanup"
out=$(run_guard auto false RE_TAKE_OVER_STACKS=1)
check "$(grep -c '^CONTINUED' <<<"$out")" 1 "RE_TAKE_OVER_STACKS=1 proceeds"
check "$(grep -c '^WARN: localAIStack is running from' <<<"$out")" 1 "and says what it is taking over"
out=$(run_guard auto true)
check "$(grep -c '^ADDWARN: Dry-run: localAIStack' <<<"$out")$(grep -c '^CONTINUED' <<<"$out")" 11 "dry-run warns and continues"
running "openclaw-gateway	$OCS_MAIN"
check "$(grep -c '^DIE: localOpenClawStack' <<<"$(run_guard auto false)")" 1 "foreign OpenClaw: refuses when OpenClaw will start"
check "$(grep -c '^CONTINUED' <<<"$(run_guard no false)")" 1 "foreign OpenClaw with --no-openclaw: not our business, continues"

# ── startUniverse.sh: --no-openclaw leaves OpenClaw alone ────────────────────
CLEAN=$(sed -n '/^# OpenClaw cleanup\./,/^fi  # OPENCLAW != no$/p' "$CI_DIR/startUniverse.sh")
run_clean() {
  : > "$STUB_DIR/calls"
  CI_DIR="$TMP" OCS_DIR="$OCS_MAIN" OPENCLAW="$1" HOME="$TMP" \
    bash -c 'info(){ :; }; ok(){ :; }; '"$CLEAN" >/dev/null 2>&1 || true
}
echo "startUniverse.sh OpenClaw cleanup"
check "$([ -n "$CLEAN" ] && echo found)" found "cleanup block extracted"
run_clean no
check "$(grep -cE 'compose down|rm -f|launchctl unload|lsof' "$STUB_DIR/calls" || true)" 0 "--no-openclaw: no compose down, rm, unload or port kill"
run_clean auto
check "$(grep -c 'docker compose down' "$STUB_DIR/calls")" 1 "default: still tears down before starting"

# ── stopUniverse.sh ──────────────────────────────────────────────────────────
FOREIGN=$(sed -n '/^foreign_stack() {/,/^}/p' "$CI_DIR/stopUniverse.sh")
run_foreign() {
  env "$@" bash -c 'source "'"$CI_DIR"'/scripts/lib/stack-owner.sh"; warn(){ echo "WARN: $*"; }
                    '"$FOREIGN"'
                    foreign_stack localAIStack "'"$WT"'" "$STACK_OWNER_LOCALAI_PATTERN" && echo SKIP || echo STOP'
}
echo "stopUniverse.sh"
check "$(grep -c '^source "\$CI_DIR/scripts/lib/stack-owner.sh"' "$CI_DIR/stopUniverse.sh")" 1 "sources the library"
running "localai_api	$MAIN"
check "$(run_foreign | tail -1)" SKIP "foreign localAI is left running"
check "$(run_foreign RE_TAKE_OVER_STACKS=1 | tail -1)" STOP "RE_TAKE_OVER_STACKS=1 stops it"
running "localai_api	$WT"
check "$(run_foreign | tail -1)" STOP "own localAI is stopped"

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
