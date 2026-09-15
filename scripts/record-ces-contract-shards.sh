#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  RETIRED 2026-09-14, with scripts/regression-ces-contracts.py, which it drives.
#
#  KEPT for the same reason: it is the record of how the sharded sweep was
#  sequenced — scopes cheapest first, resume by consulting the versioned cesgen
#  registry, journalled failures, residency refused before recording rather than
#  after. That sequencing logic is sound and independent of the defect.
#
#  It selects *scopes* for a recorder that drove one chain at a time through a
#  source it registered itself. The replacement arms the corpus's own interned
#  sources and drives the whole resident corpus once, so there is no per-chain
#  scope to select — a domain is a projection of that single run:
#
#      scripts/record-ces-contracts.py --only <domain> --write
#
#  scripts/bring-up-corpus-incrementally.py now calls that directly.
# ─────────────────────────────────────────────────────────────────────────────
# Record the CES output-stream contract shards — one per corpus domain, one per
# configured test-environment corpus.
#
# The recorder (regression-ces-contracts.py) records one scope per invocation.
# This drives it across every scope the registry knows about, in ascending cost
# order, writing each shard as it completes.
#
# WHY ONE SHARD PER SCOPE, and not one artifact:
#
#   A contract shard is only true of the machines it was recorded from. The
#   corpus grows a domain at a time, so a monolith makes every arrival a
#   whole-corpus re-record against a live three-runtime quorum and a diff nobody
#   can read. Sharded, a machine added to `energy` invalidates `domain:energy`
#   and nothing else, and the diff is the size of the change.
#
# RESUMABLE, AND WHY THAT MATTERS HERE:
#
#   The full sweep is thousands of chains against three live runtimes. By
#   default a scope whose shard is already `recorded` against the current corpus
#   is skipped, so an interrupted run resumes rather than restarts, and a
#   re-run after adding one domain's machines re-records that domain alone.
#   --force overrides.
#
# PRECONDITION — the machines must be resident:
#
#   The recorder drives chains through the live PE and reads what comes back.
#   A machine the engines never loaded emits nothing, and the recorder correctly
#   classifies that as `no-runtime-emits` — a true observation, and a useless
#   shard. So the universe must be booted on a corpus that CONTAINS the scope
#   being recorded. This script checks residency per scope and refuses rather
#   than recording a shard full of silence, because a shard of silence is
#   indistinguishable from a shard of a domain that genuinely does nothing.
#
#   For the domain scopes that means --machine-corpus=full.
set -uo pipefail

if [ "${CES_ALLOW_RETIRED_RECORDER:-}" != "1" ]; then
  echo "record-ces-contract-shards.sh is RETIRED (see the banner above)." >&2
  echo "  record with:  scripts/record-ces-contracts.py --only <domain> --write" >&2
  exit 2
fi

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINES_DIR="$CI_DIR/../RealityEngine_Machines"
SHARD_DIR="$CI_DIR/config/ces-contracts"
REGISTRY_JSON="$MACHINES_DIR/domains/ces-contract-registry.json"
BUILDER="$MACHINES_DIR/scripts/build-ces-contract-registry.py"
RECORDER="$CI_DIR/scripts/regression-ces-contracts.py"
REGISTRY_URL="${RE_REGISTRY_URL:-http://127.0.0.1:5999/re-registry.json}"
INSTANCE_REGISTRY="${RE_INSTANCE_REGISTRY:-/tmp/re-registry/re-registry.json}"

FORCE=false
ONLY=""
DRY_RUN=false
SKIP_RESIDENCY=false
SHOW_STATUS=false
FORGET_FAILURES=false
FAILED_MODE="retry"          # retry | skip | only
MAX_CONSECUTIVE=3            # 0 disables the guard
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$CI_DIR/.ces-contracts/runs/$RUN_ID"
# Outside the run directory on purpose: it is the state that must survive runs.
JOURNAL="$CI_DIR/.ces-contracts/journal.json"

usage() {
  cat <<'USAGE'
record-ces-contract-shards.sh [options]

  --only SCOPE[,SCOPE...]  Record only these scopes (e.g. domain:energy,corpus:regression)
  --force                  Re-record scopes already current against the corpus
  --dry-run                Print the plan and exit; drive nothing
  --skip-residency-check   Record even where the scope's machines are not resident.
                           Produces shards of silence. Only for diagnosing the check itself.

 Restarting after failures — the sweep marks what failed and moves on, and the
 marking survives the run, so restarting is just the same command again:
  --skip-failed            Step past scopes the journal already records as failed,
                           so a restart makes progress on the rest first.
  --retry-failed-only      Come back for exactly those, and nothing else.
  --forget-failures        Clear non-recorded journal entries before planning.
  --max-consecutive N      Halt after N failures in a row (default 3; 0 disables).
                           Consecutive failures are one systemic fault, not N.
  --status                 Print the journal and the registry status; drive nothing.
  --help

 Exit status is 1 when any scope failed or the sweep halted, 0 otherwise.

Scopes come from the registry builder, so they need no restating here:
  python3 ../RealityEngine_Machines/scripts/build-ces-contract-registry.py --status
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --only=*) ONLY="${arg#*=}" ;;
    --only)   echo "--only needs =SCOPE,..." >&2; exit 2 ;;
    --force)  FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    --skip-residency-check) SKIP_RESIDENCY=true ;;
    --skip-failed) FAILED_MODE="skip" ;;
    --retry-failed-only) FAILED_MODE="only" ;;
    --forget-failures) FORGET_FAILURES=true ;;
    --max-consecutive=*) MAX_CONSECUTIVE="${arg#*=}" ;;
    --status) SHOW_STATUS=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Quorum is 3-of-3 — cpp, lsp and scala, never a majority. Asked again before
# every scope, because an engine that dies mid-sweep is one universe-level fault
# and must not be reported as a scope-level failure once per remaining domain.
quorum_runtimes() {
  python3 - "$INSTANCE_REGISTRY" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(" ".join(sorted({i.get("runtime") for i in d.get("instances", [])
                       if i.get("status", "running") == "running" and i.get("runtime")})))
PY
}
quorum_present() { [ "$(quorum_runtimes)" = "cpp lsp scala" ]; }
quorum_missing() {
  present="$(quorum_runtimes)"
  for r in cpp lsp scala; do case " $present " in *" $r "*) ;; *) printf '%s ' "$r" ;; esac; done
}

show_status() {
  python3 - "$JOURNAL" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("journal: none yet"); raise SystemExit(0)
scopes = doc.get("scopes", {})
if not scopes:
    print("journal: empty"); raise SystemExit(0)
print(f"journal ({doc.get('updatedAt', '?')}):")
order = {"failed": 0, "interrupted": 1, "not-resident": 2, "recorded": 3}
for scope, e in sorted(scopes.items(), key=lambda kv: (order.get(kv[1].get("outcome"), 9), kv[0])):
    line = f"  {scope:<38} {e.get('outcome','?'):<13} {e.get('attempts',0)} attempt(s)  {e.get('lastAttemptAt','')}"
    print(line)
    if e.get("lastError"):
        print(f"      {e['lastError'][:150]}")
PY
}

if [ "$SHOW_STATUS" = true ]; then
  show_status; echo; python3 "$BUILDER" --status; exit 0
fi

[ -f "$BUILDER" ]  || die "registry builder not found: $BUILDER"
[ -f "$RECORDER" ] || die "recorder not found: $RECORDER"

# A formed quorum is checked here as well as in the recorder, so a sweep of
# sixteen scopes fails at the start instead of sixteen times.
curl -sf --max-time 5 "$REGISTRY_URL" >/dev/null 2>&1 \
  || die "instance registry not reachable at $REGISTRY_URL — start the universe first"

python3 "$BUILDER" --write >/dev/null || die "could not build the registry"

# Which machine basenames the engines actually hold. Read once from one RE; the
# residency question is "did the boot corpus include this", and the boot corpus
# is the same for every instance in a universe. A per-instance disagreement
# about the resident corpus is a real finding, but it belongs to the load-parity
# gate, not here.
RE_URL="$(python3 -c "
import json,sys
try: d=json.load(open('$INSTANCE_REGISTRY'))
except Exception: sys.exit(1)
for i in d.get('instances',[]):
    if i.get('status','running')=='running' and i.get('re_url'):
        print(i['re_url'].rstrip('/')); break
" 2>/dev/null)"
[ -n "$RE_URL" ] || die "no running RE instance in $INSTANCE_REGISTRY"

# `GET /api/machines` — the IN-MEMORY registry — not `/api/machines/json/list`,
# which catalogs the corpus files on disk. A machine imported into a running
# engine never appears in json/list, so a residency check reading it would call
# every incrementally-loaded domain absent and refuse to record the very shards
# this sweep exists to produce.
#
# Keyed by machine NAME, because every runtime mints its own id for the same
# logical machine and ids are therefore not comparable across the quorum.
RESIDENT="$(mktemp -t re-resident.XXXXXX)"
trap 'rm -f "$RESIDENT"' EXIT
curl -sf --max-time 30 "$RE_URL/api/machines" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ms=d.get('machines',d) if isinstance(d,dict) else d
for m in ms:
    if isinstance(m,dict) and m.get('name'):
        print(m['name'])
" >"$RESIDENT" || die "could not read the resident registry from $RE_URL"
info "resident corpus: $(wc -l <"$RESIDENT" | tr -d ' ') machines at $RE_URL"

mkdir -p "$SHARD_DIR" "$LOG_DIR" "$(dirname "$JOURNAL")"

# ── The journal ──────────────────────────────────────────────────────────────
#
# A sweep of a dozen domains against three live runtimes is long enough that
# something will go wrong partway through, and the useful behaviour is to mark
# what failed and keep going rather than abandon the run. That only helps if the
# marking OUTLIVES the run, so it is a file, written after every scope, not a
# shell variable that dies with the process.
#
# Restarting is then the same command again: scopes already recorded and current
# are skipped by the registry, and previously-failed scopes are retried unless
# --skip-failed says to step past them. Nothing needs a resume token, because
# the durable state is the shards and the journal, not a cursor.
#
# A failed scope leaves NO shard behind. The recorder writes its artifact once,
# at the end, so a scope that dies partway simply has no file and reads as
# unrecorded — never as a partial contract that looks complete.

journal_set() {  # scope outcome error log
  python3 - "$JOURNAL" "$1" "$2" "$3" "$4" "$RUN_ID" <<'PY'
import json, os, sys, tempfile, time
path, scope, outcome, err, log, run_id = sys.argv[1:7]
try:
    doc = json.load(open(path))
except Exception:
    doc = {"version": "1.0.0", "scopes": {}}
entry = doc["scopes"].get(scope, {})
# Attempts accumulate across runs. A scope that has failed four times over four
# sweeps is a different fact from one that failed once, and the difference is
# what tells an operator to stop retrying and go look.
entry["attempts"] = entry.get("attempts", 0) + 1
entry.update({"outcome": outcome, "lastAttemptAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "lastRunId": run_id})
if err:
    entry["lastError"] = err[:500]
else:
    entry.pop("lastError", None)
if log:
    entry["log"] = log
if outcome == "recorded":
    entry["lastRecordedAt"] = entry["lastAttemptAt"]
doc["scopes"][scope] = entry
doc["updatedAt"] = entry["lastAttemptAt"]
# Written through a temp file: a sweep killed mid-write must not leave the
# journal unparseable, because an unreadable journal is one that silently
# reverts every failure marking it held.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
PY
}

if [ "$FORGET_FAILURES" = true ] && [ -f "$JOURNAL" ]; then
  python3 - "$JOURNAL" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
dropped = [s for s, e in doc["scopes"].items() if e.get("outcome") != "recorded"]
for s in dropped:
    del doc["scopes"][s]
json.dump(doc, open(path, "w"), indent=2, sort_keys=True)
open(path, "a").write("\n")
print(f"forgot {len(dropped)} non-recorded journal entries")
PY
fi

# ── The plan ─────────────────────────────────────────────────────────────────
#
# Ascending chain count: the cheap scopes finish first, so an interrupted sweep
# leaves the most shards behind rather than the fewest.
PLAN="$(python3 - "$REGISTRY_JSON" "$RESIDENT" "$FORCE" "$ONLY" "$JOURNAL" "$FAILED_MODE" \
        "$MACHINES_DIR/machines" "$CI_DIR/../localAIStack/data/machines" <<'PY'
import json, os, sys
from pathlib import Path
registry, resident_file, force, only, journal_path, failed_mode = sys.argv[1:7]
MACHINES_ROOT = Path(sys.argv[7])
LOCAL_AI_ROOT = Path(sys.argv[8])
force = force == "true"
doc = json.load(open(registry))
resident = {l.strip() for l in open(resident_file) if l.strip()}
wanted = {s.strip() for s in only.split(",") if s.strip()} if only else None
try:
    journal = json.load(open(journal_path))["scopes"]
except Exception:
    journal = {}

for scope, e in sorted(doc["scopes"].items(), key=lambda kv: kv[1]["chainCount"]):
    if wanted is not None and scope not in wanted:
        continue
    if not force and e["status"] == "recorded":
        continue
    failed_before = journal.get(scope, {}).get("outcome") in ("failed", "interrupted")
    # --skip-failed steps past what is already known broken, so a restart makes
    # progress on the rest instead of re-hitting the same wall first.
    if failed_mode == "skip" and failed_before:
        continue
    # --retry-failed-only is the other half: come back for exactly those.
    if failed_mode == "only" and not failed_before:
        continue
    # Scope members are relFile paths; residency is by machine name. Resolve
    # each file to the name it declares so the two are comparable at all.
    members, absent = [], []
    for rel in e["corpus"]["members"]:
        path = MACHINES_ROOT / rel
        if not path.exists():
            path = next(iter(LOCAL_AI_ROOT.rglob(rel.split("/")[-1])), path)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            name = (raw.get("machine", raw) or {}).get("name")
        except Exception:
            name = None
        members.append(name or rel)
        if not name or name not in resident:
            absent.append(name or rel)
    prior = journal.get(scope, {})
    print("\t".join([scope, str(e["chainCount"]), str(len(absent)), str(len(members)),
                     prior.get("outcome", "-"), str(prior.get("attempts", 0))]))
PY
)"

if [ -z "$PLAN" ]; then
  info "nothing to record — every selected scope is current or filtered out"
  python3 "$BUILDER" --status
  exit 0
fi

info "plan:"
printf '%s\n' "$PLAN" | while IFS=$'\t' read -r scope chains absent total prior attempts; do
  note=""
  [ "$absent" -gt 0 ] && note="  [$absent/$total NOT RESIDENT]"
  [ "$prior" != "-" ] && note="$note  [prior: $prior after $attempts attempt(s)]"
  printf '  %-38s %6s chains%s\n' "$scope" "$chains" "$note"
done

if [ "$DRY_RUN" = true ]; then
  info "dry run — nothing driven"
  exit 0
fi

# An interrupted sweep marks the scope it was on, so a restart can tell "we
# never got to this" from "this was in flight when the run died".
CURRENT_SCOPE=""
on_interrupt() {
  [ -n "$CURRENT_SCOPE" ] && journal_set "$CURRENT_SCOPE" "interrupted" "run interrupted" ""
  info "interrupted — journal at $JOURNAL; re-run to resume"
  exit 130
}
trap on_interrupt INT TERM

recorded=0; skipped=0; failed=0; consecutive=0; halted=""
while IFS=$'\t' read -r scope chains absent total prior attempts; do
  [ -n "$scope" ] || continue
  kind="${scope%%:*}"; name="${scope#*:}"
  out="$SHARD_DIR/${kind}-${name}.json"
  # The regression shard is already authoritative at its own path (the CI drift
  # gate reads it there); recording it anywhere else would make two files one
  # contract.
  [ "$scope" = "corpus:regression" ] && out="$CI_DIR/config/ces-contracts.json"
  log="$LOG_DIR/${kind}-${name}.log"

  # Quorum is re-checked per scope, not once at the top. An engine that dies at
  # hour three of an eight-hour sweep would otherwise mark every remaining
  # domain as failed — nine scope-level defects reported for one universe-level
  # one, and nine shards that would have to be re-recorded to find out.
  if ! quorum_present; then
    halted="quorum lost — $(quorum_missing) not answering"
    info "HALT: $halted"
    info "  remaining scopes left unattempted rather than marked failed"
    break
  fi

  if [ "$absent" -gt 0 ] && [ "$SKIP_RESIDENCY" != true ]; then
    info "SKIP $scope — $absent of $total machines are not resident"
    journal_set "$scope" "not-resident" "$absent of $total machines not resident" ""
    skipped=$((skipped+1))
    continue
  fi

  CURRENT_SCOPE="$scope"
  info "recording $scope ($chains chains) → $(basename "$out")"
  # --machine-corpus takes `domain:<name>` verbatim and a corpus list by bare
  # name, which is the recorder's vocabulary, not this script's to reinterpret.
  selector="$scope"
  [ "$kind" = "corpus" ] && selector="$name"
  if python3 "$RECORDER" --record --machine-corpus "$selector" --out "$out" >"$log" 2>&1; then
    info "  ok — $(grep -m1 'ces-contracts:' "$log" | sed 's/.*ces-contracts: //; s/ →.*//')"
    journal_set "$scope" "recorded" "" "$log"
    recorded=$((recorded+1)); consecutive=0
  else
    reason="$(tail -3 "$log" | tr '\n' ' ' | sed 's/  */ /g')"
    info "  FAILED — $reason"
    info "  (full log: $log)"
    journal_set "$scope" "failed" "$reason" "$log"
    failed=$((failed+1)); consecutive=$((consecutive+1))
    # Consecutive failures are evidence of one systemic problem, not of N
    # independent ones. Burning the rest of an eight-hour sweep against it
    # produces a dozen identical log files and no more information than three.
    if [ "$MAX_CONSECUTIVE" -gt 0 ] && [ "$consecutive" -ge "$MAX_CONSECUTIVE" ]; then
      halted="$consecutive consecutive failures — stopping rather than repeating one fault across every remaining scope"
      info "HALT: $halted"
      break
    fi
  fi
  CURRENT_SCOPE=""
done <<<"$PLAN"

trap - INT TERM
info "recorded=$recorded skipped=$skipped failed=$failed  logs: $LOG_DIR"
[ -n "$halted" ] && info "halted: $halted"
python3 "$BUILDER" --write >/dev/null && python3 "$BUILDER" --status

if [ "$failed" -gt 0 ] || [ -n "$halted" ]; then
  echo
  info "journal: $JOURNAL"
  info "  re-run to retry the failures, --skip-failed to move past them,"
  info "  or --retry-failed-only to come back for just those."
  exit 1
fi
exit 0
