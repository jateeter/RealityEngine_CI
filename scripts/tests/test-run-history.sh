#!/usr/bin/env bash
# Unit tests for scripts/lib/run_history.py — run retention and the comparison
# baseline order runs by time and keep the newest certifying run.
#
# The fixtures replay 2026-10-08: build-only run build-1008, keeping two runs,
# sorted run ids by name, kept pr544-1639 (10-05) and deleted main-1007 (10-07),
# the release candidate.
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/lib/run_history.py"
PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run <dir> <id> <status> <finishedAt> <live: yes|no|legacy-yes|legacy-no>
run() {
  local d="$1/$2" status="$3" fin="$4" live="$5"
  mkdir -p "$d/reports"
  case "$live" in
    yes|no)
      local lt=false; [ "$live" = yes ] && lt=true
      printf '{"runId":"%s","status":"%s","finishedAt":"%s","phases":{"build":true,"start":%s,"liveTests":%s}}\n' \
        "$2" "$status" "$fin" "$lt" "$lt" > "$d/manifest.json" ;;
    legacy-yes)
      printf '{"runId":"%s","status":"%s","finishedAt":"%s"}\n' "$2" "$status" "$fin" > "$d/manifest.json"
      echo '{}' > "$d/reports/service-inventory.json" ;;
    legacy-no)
      printf '{"runId":"%s","status":"%s","finishedAt":"%s"}\n' "$2" "$status" "$fin" > "$d/manifest.json" ;;
  esac
}
lines() { tr '\n' ' ' | sed 's/ $//'; }

echo "run history"

# ── The 2026-10-08 incident (legacy manifests, as they were) ──────────────────
R="$TMP/incident"; mkdir -p "$R"
run "$R" pr544-1639 completed 2026-10-05T23:52:07Z legacy-yes
run "$R" main-1006  failed    2026-10-06T22:37:16Z legacy-yes
run "$R" main-1007  completed 2026-10-07T21:48:10Z legacy-yes
run "$R" build-1008 completed 2026-10-08T15:31:39Z legacy-no

assert_eq "$(python3 "$TOOL" order "$R" | lines)" "build-1008 main-1007 main-1006 pr544-1639" \
  "orders by finishedAt, not by run id"
# What build-1008 did, rerun: it is the run in progress, keeping two.
assert_eq "$(python3 "$TOOL" prune "$R" --keep 2 --exclude build-1008 | lines)" "main-1006 pr544-1639" \
  "keeps main-1007, the newest run, and removes the older ones"
assert_eq "$(python3 "$TOOL" baseline "$R" --exclude build-1008)" "main-1007" \
  "the baseline is the newest certifying run"
assert_eq "$(python3 "$TOOL" baseline "$R")" "main-1007" \
  "a newer build-only run is never the baseline"

# ── A certifying run survives build-only runs that outnumber it ───────────────
R="$TMP/protect"; mkdir -p "$R"
run "$R" main-1007  completed 2026-10-07T21:48:10Z yes
run "$R" build-a    completed 2026-10-08T10:00:00Z no
run "$R" build-b    completed 2026-10-08T11:00:00Z no
assert_eq "$(python3 "$TOOL" prune "$R" --keep 2 --exclude build-c | lines)" "build-a" \
  "keeps the newest build-only run and the older certifying run; removes the other"
assert_eq "$(python3 "$TOOL" prune "$R" --keep 1 --exclude build-c | lines)" "build-b build-a" \
  "keeps the certifying run even when --keep leaves no room for it"

# ── Certifying means completed AND the live stages ran ────────────────────────
R="$TMP/certify"; mkdir -p "$R"
run "$R" live-failed   failed    2026-10-08T12:00:00Z yes
run "$R" live-ok       completed 2026-10-07T12:00:00Z yes
run "$R" phases-no     completed 2026-10-09T12:00:00Z no
echo '{}' > "$R/phases-no/reports/service-inventory.json"   # phases win over the legacy marker
assert_eq "$(python3 "$TOOL" baseline "$R")" "live-ok" \
  "a failed run and a run whose phases say no live tests are not certifying"

# ── Without finishedAt, startedAt then directory mtime ────────────────────────
R="$TMP/fallback"; mkdir -p "$R/a" "$R/b" "$R/c"
printf '{"status":"planned","startedAt":"2026-10-08T09:00:00Z"}\n' > "$R/a/manifest.json"
printf '{"status":"completed","finishedAt":"2026-10-08T08:00:00Z"}\n' > "$R/b/manifest.json"
touch -t 202610010000 "$R/c"
assert_eq "$(python3 "$TOOL" order "$R" | lines)" "a b c" \
  "a run in progress orders by startedAt, a run without a manifest by mtime"

# ── retain mode: no run in progress excluded, keep counts every run ───────────
R="$TMP/retain"; mkdir -p "$R"
for i in 1 2 3 4; do run "$R" "r$i" completed "2026-10-0${i}T00:00:00Z" no; done
assert_eq "$(python3 "$TOOL" prune "$R" --keep 2 | lines)" "r2 r1" "retain keeps the newest N"
assert_eq "$(python3 "$TOOL" prune "$R" --keep 0 | lines)" "" "--keep 0 removes nothing"

# ── regression-report.py uses the same baseline ───────────────────────────────
R="$TMP/report/runs"; mkdir -p "$R"
run "$R" pr544-1639 completed 2026-10-05T23:52:07Z legacy-yes
run "$R" main-1006  completed 2026-10-06T22:37:16Z legacy-yes
run "$R" main-1007  completed 2026-10-07T21:48:10Z legacy-yes
got="$(cd "$CI_DIR/scripts" && python3 -c "
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('rr', 'regression-report.py')
rr = importlib.util.module_from_spec(spec); spec.loader.exec_module(rr)
p = rr.find_compare_run(Path('$TMP/report'), 'main-1007', '')
print(p.name if p else '')
")"
assert_eq "$got" "main-1006" "regression-report compares main-1007 against main-1006, not pr544-1639"

# ── regression-test.sh's own prune_run_history, extracted and run ─────────────
# The harness cannot be run here: its Docker preflight tears down local stacks.
# The function itself is exercised against the incident instead.
H="$TMP/harness"; R="$H/runs"; mkdir -p "$R"
run "$R" pr544-1639 completed 2026-10-05T23:52:07Z legacy-yes
run "$R" main-1006  failed    2026-10-06T22:37:16Z legacy-yes
run "$R" main-1007  completed 2026-10-07T21:48:10Z legacy-yes
mkdir -p "$R/build-1008"   # the run in progress: its directory exists, manifest not yet final
FN="$TMP/prune_fn.sh"
awk '/^prune_run_history\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$CI_DIR/scripts/regression-test.sh" > "$FN"
# The extracted function reads log, HISTORY_DIR, RUN_ID and KEEP_RUNS; the
# linter cannot see those uses through `source`.
# shellcheck disable=SC2034,SC2329
out="$(
  log() { echo "$*"; }
  HISTORY_DIR="$H" RUN_ID="build-1008" KEEP_RUNS=2
  # shellcheck source=/dev/null
  source "$FN"
  prune_run_history
)"
assert_eq "$(find "$R" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | lines)" "build-1008 main-1007" \
  "the harness's prune keeps main-1007 and the run in progress"
assert_eq "$(echo "$out" | grep -c 'removed 2')" "1" "the harness logs what it removed"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
