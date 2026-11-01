#!/usr/bin/env bash
# Unit tests for conformance followers (docs/QUORUM_CONTRACT.md section 1,
# RealityEngine_CI#607): scripts/lib/followers.py, the follower filter in the
# parity stages and quorum_composition(), and the follower lane's
# unavailable exits (scripts/rust-conformance.sh).
#
# The rule under test is that a follower never votes: a 2-1 split among the
# voters stays a disagreement whatever the follower says, and a follower that
# differs cannot turn the voters' agreement into a failure. Each case asserts an
# exit status against stub engines, so green here means something.
#
# Usage: bash scripts/tests/test-followers.sh
set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$CI_DIR/scripts/lib/followers.py"
STAGE="$CI_DIR/scripts/regression-machine-set-parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $(jobs -p) 2>/dev/null' EXIT

PASS=0
FAIL=0
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }
expect() {  # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

# A stub engine: GET /api/machines serves fixed names; GET /api/arbitration
# answers per <mode>: `declared` is the ruled 501 unsupported, `bare501` a 501
# without the declaration, `absent` a 404 with the error envelope.
start_stub() {  # start_stub <port> <names> <mode>
  python3 - "$1" "$2" "$3" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, names, mode = int(sys.argv[1]), sys.argv[2], sys.argv[3]
machines = [{"id": f"m-{port}-{i}", "name": n} for i, n in enumerate(names.split(",")) if n]
class H(BaseHTTPRequestHandler):
    def reply(self, code, payload):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/api/machines":
            return self.reply(200, {"machines": machines})
        if mode == "declared":
            return self.reply(501, {"error": f"GET {self.path} is not implemented by this runtime",
                                    "participation": "unsupported", "surface": f"GET {self.path}"})
        if mode == "bare501":
            return self.reply(501, None)
        return self.reply(404, {"error": "absent"})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  for _ in $(seq 1 50); do
    curl -sf --max-time 1 "http://127.0.0.1:$1/api/machines" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

registry() {  # registry <cpp port> <lsp port> <scala port> [<follower port>]
  python3 - "$@" > "$TMP/registry.json" <<'PY'
import json, sys
ports = sys.argv[1:]
instances = [{"id": rid, "runtime": rid.split("-")[0], "re_url": f"http://127.0.0.1:{p}",
              "pe_url": f"http://127.0.0.1:{p}"}
             for rid, p in zip(("cpp-1", "lsp-1", "scala-1"), ports[:3])]
if len(ports) > 3:
    instances.append({"id": "rust-1", "runtime": "rust", "role": "follower",
                      "re_url": f"http://127.0.0.1:{ports[3]}", "pe_url": ""})
print(json.dumps({"instances": instances}))
PY
}

stage_exit() {  # stage_exit <registry>
  python3 "$STAGE" --registry "$1" >"$TMP/out" 2>&1
  echo $?
}

echo "conformance followers"

start_stub 5871 "Alpha,Beta,Gamma" absent || { echo "stub 5871 failed"; exit 1; }
start_stub 5872 "Alpha,Beta,Gamma" absent || { echo "stub 5872 failed"; exit 1; }
start_stub 5873 "Alpha,Beta,Gamma" absent || { echo "stub 5873 failed"; exit 1; }
start_stub 5874 "Alpha,Beta,Omega" absent || { echo "stub 5874 failed"; exit 1; }
start_stub 5875 "Alpha,Beta,Omega" declared || { echo "stub 5875 failed"; exit 1; }
start_stub 5876 "Alpha,Beta,Gamma" bare501 || { echo "stub 5876 failed"; exit 1; }

# ── a stage never counts a follower ──────────────────────────────────────────
registry 5871 5872 5873 5874
expect "the voters agree; a differing follower in the instance data is not a vote" \
  0 "$(stage_exit "$TMP/registry.json")"
if grep -q "rust-1" "$TMP/out"; then
  bad "the stage named the follower in its quorum composition"
else
  ok "the quorum composition lists the voters only"
fi

# ── a 2-1 split stays a disagreement whatever the follower says ──────────────
# scala-1 holds Omega; the follower sides with it, then with the other two.
registry 5871 5872 5874 5874
expect "a 2-1 split with the follower siding with the one is still a disagreement" \
  1 "$(stage_exit "$TMP/registry.json")"
registry 5871 5872 5874 5871
expect "a 2-1 split with the follower siding with the two is still a disagreement" \
  1 "$(stage_exit "$TMP/registry.json")"

# ── split: the voters' run and the joint run ─────────────────────────────────
registry 5871 5872 5873 5874
ids="$(python3 "$LIB" split "$TMP/registry.json" "$TMP/voters.json" "$TMP/joint.json")"
expect "split names the follower" "rust-1" "$ids"
expect "the voters' registry holds the three voters" 3 \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["instances"]))' "$TMP/voters.json")"
expect "the joint registry presents the follower as an ordinary instance" "4 0" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["instances"]; print(len(d), sum("role" in i for i in d))' "$TMP/joint.json")"
expect "the voters' run passes" 0 "$(stage_exit "$TMP/voters.json")"
expect "the joint run fails on the differing follower" 1 "$(stage_exit "$TMP/joint.json")"

# ── the verdict table ────────────────────────────────────────────────────────
verdict() { python3 "$LIB" verdict "$@"; }
expect "voters agree, joint passes: agrees" agrees "$(verdict 0 0)"
expect "voters agree, joint fails: differs" differs "$(verdict 0 1)"
expect "voters agree, surface declared unsupported: unsupported" unsupported "$(verdict 0 0 'GET /api/x')"
expect "voters disagree: not-compared, whatever the joint run did" not-compared "$(verdict 1 0)"
expect "voters disagree: not-compared, even when the follower declares unsupported" \
  not-compared "$(verdict 1 1 'GET /api/x')"

# ── the probe reads only the ruled declaration ───────────────────────────────
probe() { python3 "$LIB" probe "http://127.0.0.1:$1" GET /api/arbitration; }
expect "501 with participation unsupported is unsupported" unsupported "$(probe 5875)"
expect "a bare 501 is not a declaration" supported "$(probe 5876)"
expect "a 404 is not a declaration" supported "$(probe 5874)"

# ── quorum_composition() ignores a follower ──────────────────────────────────
composition() {
  python3 - "$CI_DIR/scripts/$1" <<'PY'
import importlib.util, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent / "lib"))
spec = importlib.util.spec_from_file_location("stage", sys.argv[1])
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
q = stage.quorum_composition([{"runtime": "cpp"}, {"runtime": "lsp"},
                              {"runtime": "rust", "role": "follower"}])
print(q["formed"], ",".join(q["present"]))
PY
}
for stage in regression-universal-vectors.py regression-ces-contracts.py; do
  expect "$stage: a follower neither forms a quorum nor appears in it" "False cpp,lsp" \
    "$(composition "$stage")"
done

# ── a declared-unsupported PE is not a failed reset ──────────────────────────
resets() {
  python3 - "$CI_DIR/scripts/lib" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from reset_contract import reset_instances
instance = {"id": "rust-1", "re": "http://re", "pe": ""}
if sys.argv[2]:
    instance["pe_participation"] = sys.argv[2]
print(len(reset_instances(lambda url, body: (200, {}), [instance])))
PY
}
expect "a follower declaring its PE unsupported resets cleanly" 0 "$(resets unsupported)"
expect "an instance missing its PE without declaring it is still a failed reset" 1 "$(resets '')"

# regression-arbitration-retention.py resets each instance itself, through
# reset_pair, so it carries the declaration from the instance data too.
retention_resets() {
  python3 - "$CI_DIR/scripts/regression-arbitration-retention.py" "$1" "$TMP/retention.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("stage", sys.argv[1])
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
entry = {"id": "rust-1", "runtime": "rust", "re_url": "http://re"}
if sys.argv[2]:
    entry["pe_participation"] = sys.argv[2]
open(sys.argv[3], "w").write(json.dumps({"instances": [entry]}))
stage.http = lambda method, url, payload=None: (200, {})
rt = stage.Runtime(stage.load_instances(stage.Path(sys.argv[3]))[0], 1000)
rt.reset()
print(len(rt.failures))
PY
}
expect "arbitration-retention resets a follower declaring its PE unsupported cleanly" 0 \
  "$(retention_resets unsupported | tail -1)"
expect "arbitration-retention still fails an undeclared missing PE" 1 "$(retention_resets '' | tail -1)"
retention_voters() {
  python3 - "$CI_DIR/scripts/regression-arbitration-retention.py" "$TMP/retention-voters.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("stage", sys.argv[1])
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
open(sys.argv[2], "w").write(json.dumps({"instances": [
    {"id": "cpp-1", "runtime": "cpp", "re_url": "http://cpp", "pe_url": "http://cpp-pe"},
    {"id": "rust-1", "runtime": "rust", "re_url": "http://rust", "role": "follower"}]}))
print(",".join(i["id"] for i in stage.load_instances(stage.Path(sys.argv[2]))))
PY
}
expect "arbitration-retention: a follower does not vote" "cpp-1" "$(retention_voters)"

# Recording one runtime's legacy baseline keeps every other runtime's bodies.
record_merge() {
  python3 - <<'PY'
current = {"fixture": {"cpp": "c", "lsp": "l"}, "empty": {"cpp": "e"}}
recorded = {"fixture": {"rust": "r"}, "empty": {"rust": "re"}}
for label, bodies in recorded.items():
    current.setdefault(label, {}).update(bodies)
print(",".join(sorted(current["fixture"])), ",".join(sorted(current["empty"])))
PY
}
expect "a per-runtime baseline merge keeps the others" "cpp,lsp,rust cpp,rust" "$(record_merge)"
grep -q 'current.setdefault(label, {}).update(bodies)' "$CI_DIR/scripts/regression-arbitration-retention.py" \
  && ok "regression-arbitration-retention.py records per runtime" \
  || bad "regression-arbitration-retention.py replaces each label's whole map when recording"

# ── the lane: unavailable is exit 3, never a pass ────────────────────────────
lane() { "$CI_DIR/scripts/rust-conformance.sh" --out "$TMP/lane" --no-build "$@" >"$TMP/lane.out" 2>&1; echo $?; }
expect "the lane with no universe is unavailable" 3 \
  "$(lane --registry "$TMP/none.json")"
registry 5871 5872 5873
expect "the lane without a corpus it can name is unavailable" 3 \
  "$(RE_UNIVERSE_REGISTRY_URL_FILE=/dev/null lane --registry "$TMP/registry.json" --corpus "$TMP/no-such-corpus")"

echo
echo "followers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
