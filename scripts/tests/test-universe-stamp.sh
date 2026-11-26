#!/usr/bin/env bash
# scripts/lib/universe-stamp.sh: a refused start keeps the running universe's
# stamp, and stopUniverse.sh trusts the universe manifest over a stamp that
# says OpenClaw was not started (e1-dev-20261126b, 2026-11-26).
#
# Pure: it sources the library and works on files in a scratch directory. It
# starts nothing and reads no stamp or manifest outside that directory.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/universe-stamp.sh
source "$CI_DIR/scripts/lib/universe-stamp.sh"

PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }

S="$TMP/.universe-engine-selection"

echo "1. a refused start puts the running universe's stamp back"
printf 'OPENCLAW=yes\n' > "$S"
universe_stamp_stage "$S"; printf 'OPENCLAW=no\n' > "$S"; universe_stamp_abandon "$S"
check "$(cat "$S")" "OPENCLAW=yes" "stamp restored"
check "$([ -e "$S.prev" ] && echo kept || echo gone)" "gone" "no .prev left behind"

echo "2. a refused start with no universe running leaves no stamp"
rm -f "$S"
universe_stamp_stage "$S"; printf 'OPENCLAW=no\n' > "$S"; universe_stamp_abandon "$S"
check "$([ -e "$S" ] && echo present || echo absent)" "absent" "new stamp removed"

echo "3. a start that passed its preflight keeps its own stamp"
printf 'OPENCLAW=yes\n' > "$S"
universe_stamp_stage "$S"; printf 'OPENCLAW=no\n' > "$S"; universe_stamp_commit "$S"
universe_stamp_abandon "$S"   # a later failure must not roll back
check "$(cat "$S")" "OPENCLAW=no" "committed stamp stands"
check "$([ -e "$S.prev" ] && echo kept || echo gone)" "gone" "no .prev after commit"

echo "4. the manifest overrides a stamp of no"
M="$TMP/universe-manifest.json"
printf '{"openclaw_started": true}\n' > "$M"
check "$(universe_openclaw_stamp no "$M")" "yes" "no + started manifest -> yes"
printf '{"openclaw_started": false}\n' > "$M"
check "$(universe_openclaw_stamp no "$M")" "no" "no + not-started manifest -> no"
check "$(universe_openclaw_stamp no "$TMP/missing.json")" "no" "no + no manifest -> no"
printf '{"openclaw_started": true}\n' > "$M"
check "$(universe_openclaw_stamp auto "$M")" "auto" "auto is left alone"
check "$(universe_openclaw_stamp yes "$M")" "yes" "yes is left alone"
printf 'not json\n' > "$M"
check "$(universe_openclaw_stamp no "$M")" "no" "unreadable manifest -> stamp"

echo
echo "universe-stamp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
