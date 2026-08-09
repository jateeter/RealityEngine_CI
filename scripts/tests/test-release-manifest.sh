#!/usr/bin/env bash
# Unit tests for scripts/release-manifest.py — no engines, no network.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/release-manifest.py"

PASS=0; FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"; PASS=$((PASS+1))
  else
    echo "  FAIL: $label"
    echo "        expected: $(echo "$expected" | head -c 200)"
    echo "        actual:   $(echo "$actual"   | head -c 200)"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) echo "  PASS: $label"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL: $label"
       echo "        expected to contain: $needle"
       echo "        actual: $(echo "$haystack" | head -c 300)"
       FAIL=$((FAIL+1)) ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fixtures ────────────────────────────────────────────────────────────────
# Shaped as scripts/regression-test.sh records provenance. The terminal status
# vocabulary is that harness's: "completed" on success, "failed" otherwise
# (regression-test.sh:817-819). It is deliberately not "passed" — that is the
# per-command vocabulary, and an earlier draft of this tool assumed it, which
# meant it refused every green run.

make_run() {                 # $1=dir  $2=status  $3=worktreeSha  $4=originMainSha
  mkdir -p "$1/reports"
  cat > "$1/manifest.json" <<EOF
{
  "runId": "test-run-1",
  "status": "$2",
  "profile": "hosted",
  "engineSpec": "cpp:1,lsp:1,scala:1",
  "serviceInventoryStatus": "passed",
  "coverage": { "localAI": false, "openclaw": false, "machineCorpus": "standard-deployment" },
  "repos": [
    { "name": "RepoA", "remoteUrl": "https://example.org/RepoA",
      "worktreeSha": "$3", "originMainSha": "$4", "buildStatus": "passed" },
    { "name": "RepoB", "remoteUrl": "https://example.org/RepoB",
      "worktreeSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "originMainSha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "buildStatus": "passed" }
  ]
}
EOF
  printf '{"status":"passed"}\n'  > "$1/reports/mqtt-yuma-cpp-1.json"
  printf '{"failures":["boom"]}\n' > "$1/reports/mcp-smoke.json"
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

echo "release-manifest generate"

# A green run pins cleanly.
make_run "$TMP/green" "completed" "$SHA_A" "$SHA_A"
OUT="$(python3 "$TOOL" generate --run-dir "$TMP/green" --version v9.9.9 --out "$TMP/green.json" 2>&1)"
assert_contains "$OUT" "2 repos pinned" "green run pins every repo"
assert_eq "$(python3 -c "import json;print(json.load(open('$TMP/green.json'))['repos'][0]['sha'])")" \
          "$SHA_A" "pins the commit the build used"
assert_eq "$(python3 -c "import json;print(json.load(open('$TMP/green.json'))['version'])")" \
          "v9.9.9" "records the release version"
assert_eq "$(python3 -c "import json;print('provisional' in json.load(open('$TMP/green.json')))")" \
          "False" "a green manifest is not marked provisional"

# Stage results are read from the run's reports, including a failing one.
assert_eq "$(python3 -c "import json;print(json.load(open('$TMP/green.json'))['certifiedBy']['stages']['mcp-smoke'])")" \
          "failed" "reads per-stage status from the reports"

# A failed run is refused rather than pinned silently.
make_run "$TMP/red" "failed" "$SHA_A" "$SHA_A"
set +e
OUT="$(python3 "$TOOL" generate --run-dir "$TMP/red" --version v9.9.9 --out "$TMP/red.json" 2>&1)"
CODE=$?
set -e
assert_eq "$CODE" "2" "refuses to pin from a failed run"
assert_contains "$OUT" "refusing to pin" "says why it refused"
assert_eq "$([ -f "$TMP/red.json" ] && echo exists || echo absent)" "absent" \
          "writes nothing when it refuses"

# The override is explicit and self-documenting.
OUT="$(python3 "$TOOL" generate --run-dir "$TMP/red" --version v9.9.9 --out "$TMP/red.json" --allow-unverified 2>&1)"
assert_contains "$OUT" "provisional" "override announces the manifest is provisional"
assert_contains "$(cat "$TMP/red.json")" "\"provisional\"" "records the override in the manifest"

# Building something other than the branch tip must be visible, not averaged away.
make_run "$TMP/drifted" "completed" "$SHA_A" "cccccccccccccccccccccccccccccccccccccccc"
set +e
OUT="$(python3 "$TOOL" generate --run-dir "$TMP/drifted" --version v9.9.9 --out "$TMP/d.json" 2>&1)"
CODE=$?
set -e
assert_eq "$CODE" "2" "refuses when the build and the branch tip disagree"
assert_contains "$OUT" "but origin/main was" "names the disagreement"

# A status the harness never emits is uncertified, not assumed good.
make_run "$TMP/odd" "passed" "$SHA_A" "$SHA_A"
set +e
OUT="$(python3 "$TOOL" generate --run-dir "$TMP/odd" --version v9.9.9 --out "$TMP/odd.json" 2>&1)"
CODE=$?
set -e
assert_eq "$CODE" "2" "an unrecognised run status is refused, not guessed"
assert_contains "$OUT" "certified runs report 'completed'" "names the status it expects"

echo "release-manifest verify"

# A real workspace: two git repos, one at the pinned commit and one moved on.
WS="$TMP/ws"
mkdir -p "$WS/RepoA" "$WS/RepoB"
for r in RepoA RepoB; do
  git -C "$WS/$r" init -q
  git -C "$WS/$r" config user.email t@example.org
  git -C "$WS/$r" config user.name Test
  echo one > "$WS/$r/f"; git -C "$WS/$r" add f; git -C "$WS/$r" commit -qm one
done
A_SHA="$(git -C "$WS/RepoA" rev-parse HEAD)"
B_SHA="$(git -C "$WS/RepoB" rev-parse HEAD)"

cat > "$TMP/pin.json" <<EOF
{ "schemaVersion": 1, "version": "v1.0.0",
  "certifiedBy": { "runId": "test-run-1", "status": "passed" },
  "repos": [
    { "name": "RepoA", "sha": "$A_SHA" },
    { "name": "RepoB", "sha": "$B_SHA" }
  ] }
EOF

OUT="$(python3 "$TOOL" verify --manifest "$TMP/pin.json" --workspace "$WS" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "clean workspace verifies"
assert_contains "$OUT" "matching: 2/2" "reports every repo matching"

# Move one repo on.
echo two > "$WS/RepoB/f"; git -C "$WS/RepoB" commit -qam two
set +e
OUT="$(python3 "$TOOL" verify --manifest "$TMP/pin.json" --workspace "$WS" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "drifted workspace fails"
assert_contains "$OUT" "RepoB: HEAD" "names the drifted repo"
assert_contains "$OUT" "matching: 1/2" "still counts the matching repo"

# Uncommitted changes at the right commit are drift too — the tree is not the commit.
git -C "$WS/RepoB" reset -q --hard "$B_SHA"
echo dirty > "$WS/RepoB/f"
set +e
OUT="$(python3 "$TOOL" verify --manifest "$TMP/pin.json" --workspace "$WS" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "uncommitted changes count as drift"
assert_contains "$OUT" "modified tracked file" "explains the dirty tree"

OUT="$(python3 "$TOOL" verify --manifest "$TMP/pin.json" --workspace "$WS" --allow-dirty 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "--allow-dirty tolerates it"

# Untracked files are build output, not divergence from the commit.
git -C "$WS/RepoB" checkout -q -- f
touch "$WS/RepoB/compile_commands.json" "$WS/RepoB/.DS_Store"
OUT="$(python3 "$TOOL" verify --manifest "$TMP/pin.json" --workspace "$WS" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "untracked files are not drift"
assert_contains "$OUT" "matching: 2/2" "untracked files leave the repo matching"
rm -f "$WS/RepoB/compile_commands.json" "$WS/RepoB/.DS_Store"

# A pinned commit absent from the checkout must not read as clean.
git -C "$WS/RepoB" checkout -q -- f
cat > "$TMP/absent.json" <<EOF
{ "schemaVersion": 1, "version": "v1.0.0",
  "certifiedBy": { "runId": "r", "status": "passed" },
  "repos": [ { "name": "RepoA", "sha": "dddddddddddddddddddddddddddddddddddddddd" } ] }
EOF
set +e
OUT="$(python3 "$TOOL" verify --manifest "$TMP/absent.json" --workspace "$WS" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "a commit missing from the checkout is drift"
assert_contains "$OUT" "is not in this checkout" "says the commit is absent"

# A repo that is not checked out at all.
cat > "$TMP/missing.json" <<EOF
{ "schemaVersion": 1, "version": "v1.0.0",
  "certifiedBy": { "runId": "r", "status": "passed" },
  "repos": [ { "name": "RepoZ", "sha": "$A_SHA" } ] }
EOF
set +e
OUT="$(python3 "$TOOL" verify --manifest "$TMP/missing.json" --workspace "$WS" 2>&1)"; CODE=$?
set -e
assert_eq "$CODE" "1" "a missing repo fails verification"
assert_contains "$OUT" "not checked out" "names the missing repo"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
