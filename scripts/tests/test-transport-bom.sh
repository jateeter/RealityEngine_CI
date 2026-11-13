#!/usr/bin/env bash
# Tests for scripts/transport-bom.py (owner, 2026-11-12).
#
# Offline: runs the generator against copies of the component map and the
# inventory in a temp directory (the generator's CI_DIR is a copy of this
# checkout's scripts/, config/, release/ and docs/), so the committed BOM is
# never written. Breaks one thing per case and expects the generator to fail
# naming it.
#
# Usage: bash scripts/tests/test-transport-bom.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# A copy of the checkout. Its siblings are absent, so sibling compose files are
# reported unresolved; the cases below do not depend on them.
copy() {
  local d="$TMP/ws/$1"
  mkdir -p "$d/docs"
  cp -R "$CI_DIR/scripts" "$CI_DIR/config" "$CI_DIR/release" "$d/"
  for f in docker-compose.yml docker-compose.observability-tls.yml; do cp "$CI_DIR/$f" "$d/"; done
  printf '%s' "$d"
}

echo "transport BOM"
if python3 "$CI_DIR/scripts/transport-bom.py" --check >/dev/null 2>&1; then ok "the committed BOM is current"; else bad "the committed BOM is stale"; fi

d="$(copy dropped)"
python3 - "$d/config/transport-bom-components.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for c in s["components"]:
    c["links"] = [l for l in c["links"] if l != "pim-to-epic"]
json.dump(s, open(sys.argv[1], "w"))
PY
out=$(python3 "$d/scripts/transport-bom.py" 2>&1)
if [[ $? -ne 0 && "$out" == *"link pim-to-epic: no component serves it"* ]]; then ok "a link no component serves fails"; else bad "dropped: $out"; fi

d="$(copy unknown)"
python3 - "$d/config/transport-bom-components.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["components"][0]["links"].append("no-such-link")
json.dump(s, open(sys.argv[1], "w"))
PY
out=$(python3 "$d/scripts/transport-bom.py" 2>&1)
if [[ $? -ne 0 && "$out" == *"no-such-link"*"not in the inventory"* ]]; then ok "a component naming an unknown link fails"; else bad "unknown: $out"; fi

d="$(copy stale)"
python3 "$d/scripts/transport-bom.py" >/dev/null 2>&1; printf 'edited\n' >> "$d/docs/TRANSPORT_BOM.md"
out=$(python3 "$d/scripts/transport-bom.py" --check 2>&1)
if [[ $? -ne 0 && "$out" == *"stale"* ]]; then ok "--check fails a stale BOM"; else bad "stale: $out"; fi

echo "transport BOM: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
