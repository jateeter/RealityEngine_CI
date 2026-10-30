#!/usr/bin/env bash
# Unit tests for scripts/release-manifest.py — no engines, no network: remotes
# are local bare repos and the registry is a stub (RE_IMAGETOOLS).
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
#
# A run here is a certifying one unless told otherwise: the local-containerized
# lane (E1), every required stage passed in reports/regression-status.json (the
# structured record), and reports/images.json naming the image it ran.

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
REQUIRED=(service-inventory trajectory-parity universal-vectors machine-set-parity export-parity pe-step-contract engine-process-parity mcp openclaw local-ai pim-mirror)

# $1=dir $2=status $3=worktreeSha $4=originMainSha [$5=profile] [$6=RepoB worktreeSha]
make_run() {
  local profile="${5:-local-containerized}" b_sha="${6:-$SHA_B}"
  mkdir -p "$1/reports"
  cat > "$1/manifest.json" <<EOF
{
  "runId": "$(basename "$1")",
  "status": "$2",
  "profile": "$profile",
  "engineSpec": "cpp:1,lsp:1,scala:1",
  "serviceInventoryStatus": "passed",
  "coverage": { "localAI": true, "openclaw": true, "machineCorpus": "regression" },
  "repos": [
    { "name": "RepoA", "remoteUrl": "https://example.org/RepoA",
      "worktreeSha": "$3", "originMainSha": "$4", "buildStatus": "passed" },
    { "name": "RepoB", "remoteUrl": "https://example.org/RepoB",
      "worktreeSha": "$b_sha", "originMainSha": "$b_sha", "buildStatus": "passed" }
  ]
}
EOF
  python3 - "$1/reports/regression-status.json" "${REQUIRED[@]}" <<'EOF'
import json, sys
stages = {name: {"exit": 0, "status": "passed"} for name in sys.argv[2:]}
stages["healthkit-bridge"] = {"exit": 0, "status": "skipped", "reason": "no connected iPhone"}
json.dump({"stages": stages, "build": {"status": "passed"}, "deployment": {"status": "passed"}},
          open(sys.argv[1], "w"))
EOF
  printf '{"status":"passed"}\n' > "$1/reports/mqtt-yuma-cpp-1.json"
  printf '{"images":[{"name":"re-a","repo":"RepoA","revision":"%s","ref":"ghcr.io/x/re-a","digest":"%s"}]}\n' \
    "$3" "$DIGEST" > "$1/reports/images.json"
}

# Edit a run's structured stage results: $1=dir $2=python statement on `stages`/`doc`.
edit_status() {
  python3 - "$1/reports/regression-status.json" "$2" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1])); stages = doc["stages"]
exec(sys.argv[2])
json.dump(doc, open(sys.argv[1], "w"))
EOF
}

# The candidate images file: $1=path [$2=revision] [$3=digest] [$4=pushed]
make_images() {
  printf '{"tag":"release-v9.9.9-rc1","registry":"ghcr.io/x","platform":"linux/arm64","pushed":%s,"images":[{"name":"re-a","repo":"RepoA","revision":"%s","ref":"ghcr.io/x/re-a","digest":"%s"}]}\n' \
    "${4:-true}" "${2:-$SHA_A}" "${3-$DIGEST}" > "$1"
}

field() { python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$1" "$2"; }

# generate, keeping its exit code: $@ = generate arguments
gen() { set +e; OUT="$(python3 "$TOOL" generate "$@" 2>&1)"; CODE=$?; set -e; }

HK=(--omission "healthkit-bridge=A10: no iPhone")

echo "release-manifest generate"

make_run "$TMP/green" "completed" "$SHA_A" "$SHA_A"
make_images "$TMP/images.json"

# A green certifying run pins cleanly.
gen --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1 --out "$TMP/green.json"
assert_eq "$CODE" "0" "a certifying run on its candidate images generates"
assert_contains "$OUT" "2 repos pinned" "green run pins every repo"
assert_eq "$(field "$TMP/green.json" "m['repos'][0]['sha']")" "$SHA_A" "pins the commit the build used"
assert_eq "$(field "$TMP/green.json" "m['version']")" "release-v9.9.9-rc1" "records the release version"
assert_eq "$(field "$TMP/green.json" "'provisional' in m")" "False" "a green manifest is not marked provisional"
assert_eq "$(field "$TMP/green.json" "m['images'][0]['digest']")" "$DIGEST" "records every image digest (F2)"
assert_eq "$(field "$TMP/green.json" "len(m['imagesFile']['sha256'])")" "64" "records the images file's sha256"
assert_eq "$(field "$TMP/green.json" "m['certifiedBy']['stageResults']['pim-mirror']['status']")" "passed" \
          "records the structured stage results"
assert_eq "$(field "$TMP/green.json" "m['certifiedBy']['omissions']['healthkit-bridge']")" "A10: no iPhone" \
          "records each omission's reason"
OUT="$(python3 "$TOOL" check --manifest "$TMP/green.json" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "check accepts an eligible candidate manifest"
assert_contains "$OUT" "is eligible" "check says so"

# D1: application releases are tagged release-vN.M.Z. A component-style vN.M.Z
# (localHealthkitBridge carries its own v0.1.0) is refused at generation, and
# `untagged`, the placeholder every regression run uses, is accepted with no
# evidence at all.
gen --run-dir "$TMP/green" --version v9.9.9 --out "$TMP/semver.json"
assert_eq "$CODE" "2" "refuses a component-style vN.M.Z version"
assert_contains "$OUT" "release-vN.M.Z" "names the required form"
assert_eq "$([ -f "$TMP/semver.json" ] && echo exists || echo absent)" "absent" \
          "writes nothing for a refused version"
make_run "$TMP/hosted" "completed" "$SHA_A" "$SHA_A" hosted
printf '{"failures":["boom"]}\n' > "$TMP/hosted/reports/mcp-smoke.json"
gen --run-dir "$TMP/hosted" --version untagged --out "$TMP/untagged.json"
assert_contains "$OUT" "repos pinned" "accepts 'untagged', the regression run's placeholder"
assert_eq "$(field "$TMP/untagged.json" "m['certifiedBy']['stages']['mcp-smoke']")" "failed" \
          "reads per-stage status from the reports"

# ...and cut-release.sh refuses a manifest whose version is not an application
# tag before it looks at, let alone tags, any repository.
set +e
OUT="$(bash "$CI_DIR/scripts/cut-release.sh" --manifest "$TMP/untagged.json" 2>&1)"
CODE=$?
set -e
assert_eq "$([ "$CODE" -ne 0 ] && echo refused || echo accepted)" "refused" \
          "cut-release refuses an untagged manifest"
assert_contains "$OUT" "not an application release tag" "cut-release says why"

# A failed run is refused rather than pinned silently.
make_run "$TMP/red" "failed" "$SHA_A" "$SHA_A"
gen --run-dir "$TMP/red" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1 --out "$TMP/red.json"
assert_eq "$CODE" "2" "refuses to pin from a failed run"
assert_contains "$OUT" "refusing to pin" "says why it refused"
assert_eq "$([ -f "$TMP/red.json" ] && echo exists || echo absent)" "absent" \
          "writes nothing when it refuses"

# The override is explicit and self-documenting, and check refuses its result.
gen --run-dir "$TMP/red" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1 --out "$TMP/red.json" --allow-unverified
assert_contains "$OUT" "provisional" "override announces the manifest is provisional"
assert_contains "$(cat "$TMP/red.json")" "\"provisional\"" "records the override in the manifest"
set +e; OUT="$(python3 "$TOOL" check --manifest "$TMP/red.json" 2>&1)"; CODE=$?; set -e
assert_eq "$CODE" "1" "check refuses a provisional manifest"
assert_contains "$OUT" "provisional manifest" "names the provisional marker"

# Building something other than the branch tip must be visible, not averaged away.
make_run "$TMP/drifted" "completed" "$SHA_A" "cccccccccccccccccccccccccccccccccccccccc"
gen --run-dir "$TMP/drifted" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1 --out "$TMP/d.json"
assert_eq "$CODE" "2" "refuses when the build and the branch tip disagree"
assert_contains "$OUT" "but origin/main was" "names the disagreement"

# A status the harness never emits is uncertified, not assumed good.
make_run "$TMP/odd" "passed" "$SHA_A" "$SHA_A"
gen --run-dir "$TMP/odd" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1 --out "$TMP/odd.json"
assert_eq "$CODE" "2" "an unrecognised run status is refused, not guessed"
assert_contains "$OUT" "certified runs report 'completed'" "names the status it expects"

echo "release eligibility (E4)"

# Each refusal: $1=label $2=expected text, then the generate arguments.
refuses() {
  local label="$1" expect="$2"; shift 2
  gen "$@" --out "$TMP/refused.json"
  assert_eq "$CODE" "2" "refuses: $label"
  assert_contains "$OUT" "$expect" "names it: $label"
}

refuses "no images" "a release includes its images" \
  --run-dir "$TMP/green" "${HK[@]}" --version release-v9.9.9-rc1

make_images "$TMP/nodigest.json" "$SHA_A" ""
refuses "an image with no digest" "image re-a: no digest" \
  --run-dir "$TMP/green" --images "$TMP/nodigest.json" "${HK[@]}" --version release-v9.9.9-rc1

make_images "$TMP/otherrev.json" "dddddddddddddddddddddddddddddddddddddddd"
refuses "an image revision that differs from its pin" "differs from RepoA's pin" \
  --run-dir "$TMP/green" --images "$TMP/otherrev.json" "${HK[@]}" --version release-v9.9.9-rc1

make_images "$TMP/otherdigest.json" "$SHA_A" "sha256:2222222222222222222222222222222222222222222222222222222222222222"
refuses "images the certifying run did not run" "ran sha256:1111" \
  --run-dir "$TMP/green" --images "$TMP/otherdigest.json" "${HK[@]}" --version release-v9.9.9-rc1

make_images "$TMP/unpushed.json" "$SHA_A" "$DIGEST" false
refuses "an images file never pushed" "was not pushed" \
  --run-dir "$TMP/green" --images "$TMP/unpushed.json" "${HK[@]}" --version release-v9.9.9-rc1

make_run "$TMP/native-only" "completed" "$SHA_A" "$SHA_A" local
refuses "the E1 lane missing (a native run as the certifying run)" "not 'local-containerized'" \
  --run-dir "$TMP/native-only" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1

make_run "$TMP/pimskip" "completed" "$SHA_A" "$SHA_A"
edit_status "$TMP/pimskip" "stages['pim-mirror'] = {'status': 'skipped', 'reason': 'no POD'}"
refuses "pim-mirror skipped, even with an omission" "pim-mirror is skipped (required; D2)" \
  --run-dir "$TMP/pimskip" --images "$TMP/images.json" "${HK[@]}" --omission "pim-mirror=no POD" --version release-v9.9.9-rc1

make_run "$TMP/pimfail" "completed" "$SHA_A" "$SHA_A"
edit_status "$TMP/pimfail" "stages['pim-mirror']['status'] = 'failed'"
refuses "pim-mirror failed" "pim-mirror is failed" \
  --run-dir "$TMP/pimfail" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1

make_run "$TMP/noparity" "completed" "$SHA_A" "$SHA_A"
edit_status "$TMP/noparity" "del stages['export-parity']"
refuses "a required stage missing" "required stage export-parity is missing" \
  --run-dir "$TMP/noparity" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1

make_run "$TMP/newparity" "completed" "$SHA_A" "$SHA_A"
edit_status "$TMP/newparity" "stages['widget-parity'] = {'status': 'skipped', 'reason': 'x'}"
refuses "any parity stage not passed, required list or not" "widget-parity is skipped (required)" \
  --run-dir "$TMP/newparity" --images "$TMP/images.json" "${HK[@]}" --omission "widget-parity=x" --version release-v9.9.9-rc1

refuses "a skipped stage with no recorded decision" "healthkit-bridge is skipped with no recorded decision" \
  --run-dir "$TMP/green" --images "$TMP/images.json" --version release-v9.9.9-rc1

make_run "$TMP/nostatus" "completed" "$SHA_A" "$SHA_A"
rm "$TMP/nostatus/reports/regression-status.json"
refuses "no structured stage results (never stage-results.tsv)" "the E1 lane is missing" \
  --run-dir "$TMP/nostatus" --images "$TMP/images.json" --version release-v9.9.9-rc1

make_run "$TMP/badreport" "completed" "$SHA_A" "$SHA_A"
printf '{"failures":["boom"]}\n' > "$TMP/badreport/reports/mcp-smoke.json"
refuses "a failed stage report" "report mcp-smoke is failed" \
  --run-dir "$TMP/badreport" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9-rc1

# A release, not a candidate, needs the native lane at the same commits (F1).
refuses "a release without the native lane" "the native lane is missing" \
  --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --version release-v9.9.9

make_run "$TMP/native" "completed" "$SHA_A" "$SHA_A" local
gen --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --native-run-dir "$TMP/native" \
  --version release-v9.9.9 --out "$TMP/release.json"
assert_eq "$CODE" "0" "a release with both lanes generates"
assert_eq "$(field "$TMP/release.json" "m['certifiedBy']['native']['runId']")" "native" "records the native run"
OUT="$(python3 "$TOOL" check --manifest "$TMP/release.json" 2>&1)"; CODE=$?
assert_eq "$CODE" "0" "check accepts the release"
assert_contains "$OUT" "native run native" "check names both lanes"

make_run "$TMP/native-red" "failed" "$SHA_A" "$SHA_A" local
refuses "a native lane that did not complete" "native: run native-red status is 'failed'" \
  --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --native-run-dir "$TMP/native-red" --version release-v9.9.9

make_run "$TMP/native-drift" "completed" "$SHA_A" "$SHA_A" local "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
refuses "a native lane at other commits, undecided" "RepoB ran at eeeeeeeeeeee, not the pin" \
  --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --native-run-dir "$TMP/native-drift" --version release-v9.9.9
gen --run-dir "$TMP/green" --images "$TMP/images.json" "${HK[@]}" --native-run-dir "$TMP/native-drift" \
  --native-drift "RepoB=docs only" --version release-v9.9.9 --out "$TMP/drift.json"
assert_eq "$CODE" "0" "a decided native drift generates"
assert_eq "$(field "$TMP/drift.json" "m['certifiedBy']['native']['drift']['RepoB']['reason']")" "docs only" \
          "records the drift and its reason"

# check re-derives eligibility from the manifest alone: an edited manifest is refused.
python3 - "$TMP/release.json" "$TMP/edited.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["images"][0]["revision"] = "f" * 40
json.dump(m, open(sys.argv[2], "w"))
EOF
set +e; OUT="$(python3 "$TOOL" check --manifest "$TMP/edited.json" 2>&1)"; CODE=$?; set -e
assert_eq "$CODE" "1" "check refuses a manifest edited after generation"
assert_contains "$OUT" "differs from RepoA's pin" "names the edit"

echo "release-manifest published"

# Remote tags: a bare origin per repo. Registry tags: a stub imagetools that
# answers from a file of "ref digest" lines.
PUBWS="$TMP/pubws"
mkdir -p "$PUBWS"
for r in RepoA RepoB; do
  git init -q --bare "$PUBWS/$r.git"
  git -C "$PUBWS" clone -q "$PUBWS/$r.git" "$r" 2>/dev/null
  git -C "$PUBWS/$r" config user.email t@example.org
  git -C "$PUBWS/$r" config user.name Test
  echo one > "$PUBWS/$r/f"; git -C "$PUBWS/$r" add f; git -C "$PUBWS/$r" commit -qm one
  git -C "$PUBWS/$r" push -q origin HEAD:main
done
PA="$(git -C "$PUBWS/RepoA" rev-parse HEAD)"; PB="$(git -C "$PUBWS/RepoB" rev-parse HEAD)"
python3 - "$TMP/release.json" "$TMP/pub.json" "$PA" "$PB" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
m["repos"] = [{"name": "RepoA", "sha": sys.argv[3]}, {"name": "RepoB", "sha": sys.argv[4]}]
m["images"][0]["revision"] = sys.argv[3]
json.dump(m, open(sys.argv[2], "w"))
EOF
REG="$TMP/registry.txt"
cat > "$TMP/imagetools" <<'EOF'
#!/usr/bin/env bash
ref="${!#}"
hit="$(awk -v r="$ref" '$1 == r { print $2 }' "$STUB_REGISTRY")"
[ -n "$hit" ] && { echo "$hit"; exit 0; }
echo "ERROR: $ref: not found" >&2; exit 1
EOF
chmod +x "$TMP/imagetools"
export RE_IMAGETOOLS="$TMP/imagetools" STUB_REGISTRY="$REG"
pub() { set +e; OUT="$(python3 "$TOOL" published --manifest "$TMP/pub.json" --workspace "$PUBWS" "$@" 2>&1)"; CODE=$?; set -e; }

echo "ghcr.io/x/re-a@$DIGEST $DIGEST" > "$REG"
pub --expect absent-or-equal
assert_eq "$CODE" "0" "nothing tagged yet: clear to cut"
pub --expect equal
assert_eq "$CODE" "1" "nothing tagged yet: not published"
assert_contains "$OUT" "origin has no release-v9.9.9" "names the missing remote tag"
assert_contains "$OUT" "ghcr.io/x/re-a:release-v9.9.9 does not exist" "names the missing image tag"

: > "$REG"
pub --expect absent-or-equal
assert_eq "$CODE" "1" "refuses when the candidate digest is gone from the registry"
assert_contains "$OUT" "is not in ghcr.io/x/re-a" "names the missing candidate"

git -C "$PUBWS/RepoB" commit -q --allow-empty -m two
git -C "$PUBWS/RepoB" tag -a release-v9.9.9 -m x HEAD
git -C "$PUBWS/RepoB" push -q origin refs/tags/release-v9.9.9
printf 'ghcr.io/x/re-a@%s %s\nghcr.io/x/re-a:release-v9.9.9 sha256:%s\n' "$DIGEST" "$DIGEST" "$(printf '3%.0s' {1..64})" > "$REG"
pub --expect absent-or-equal
assert_eq "$CODE" "1" "refuses a remote tag at another commit, and an image tag at another digest"
assert_contains "$OUT" "RepoB: origin has release-v9.9.9 at" "names the remote tag collision"
assert_contains "$OUT" "re-a: ghcr.io/x/re-a:release-v9.9.9 is sha256:3333" "names the image tag collision"

git -C "$PUBWS/RepoB" push -q --delete origin release-v9.9.9
git -C "$PUBWS/RepoB" tag -d release-v9.9.9 >/dev/null
for r in RepoA RepoB; do
  git -C "$PUBWS/$r" tag -a release-v9.9.9 -m x "$(field "$TMP/pub.json" "[x['sha'] for x in m['repos'] if x['name']=='$r'][0]")"
  git -C "$PUBWS/$r" push -q origin refs/tags/release-v9.9.9
done
printf 'ghcr.io/x/re-a@%s %s\nghcr.io/x/re-a:release-v9.9.9 %s\n' "$DIGEST" "$DIGEST" "$DIGEST" > "$REG"
pub --expect equal
assert_eq "$CODE" "0" "published: every tag and image resolves to the manifest"
assert_contains "$OUT" "3/3" "counts every repo tag and image"

printf '#!/usr/bin/env bash\necho "ERROR: unauthorized" >&2; exit 1\n' > "$TMP/imagetools"
pub --expect absent-or-equal
assert_eq "$CODE" "1" "a registry that cannot be read fails, it is not read as absent"
assert_contains "$OUT" "cannot inspect" "says the registry could not be checked"
unset RE_IMAGETOOLS STUB_REGISTRY

echo "cut-release.sh"

CUT="$CI_DIR/scripts/cut-release.sh"
cut() { set +e; OUT="$(bash "$CUT" --manifest "$@" 2>&1)"; CODE=$?; set -e; }
export RE_IMAGETOOLS="$TMP/imagetools" STUB_REGISTRY="$REG"
cat > "$TMP/imagetools" <<'EOF'
#!/usr/bin/env bash
ref="${!#}"
hit="$(awk -v r="$ref" '$1 == r { print $2 }' "$STUB_REGISTRY")"
[ -n "$hit" ] && { echo "$hit"; exit 0; }
echo "ERROR: $ref: not found" >&2; exit 1
EOF
echo "ghcr.io/x/re-a@$DIGEST $DIGEST" > "$REG"

# A fresh version, with RepoB back at its pin.
git -C "$PUBWS/RepoB" reset -q --hard "$PB"
python3 - "$TMP/pub.json" "$TMP/cut.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["version"] = "release-v9.9.8"
json.dump(m, open(sys.argv[2], "w"))
EOF

cut "$TMP/edited.json" --workspace "$PUBWS"
assert_eq "$CODE" "1" "refuses an ineligible manifest"
assert_contains "$OUT" "the manifest is not eligible" "says the manifest is not eligible"

cut "$TMP/cut.json" --workspace "$PUBWS"
assert_eq "$CODE" "0" "an eligible manifest rehearses cleanly"
assert_contains "$OUT" "would tag RepoA" "the dry run names what it would tag"
assert_eq "$(git -C "$PUBWS/RepoA" tag -l release-v9.9.8)" "" "the dry run tags nothing"

# A repo whose main moved on is cut from a git worktree at its pin, where .git
# is a file, not a directory.
WTWS="$TMP/wtws"
mkdir -p "$WTWS"
ln -s "$PUBWS/RepoA" "$WTWS/RepoA"
git -C "$PUBWS/RepoB" worktree add -q --detach "$WTWS/RepoB" "$PB"
cut "$TMP/cut.json" --workspace "$WTWS"
assert_eq "$CODE" "0" "a repo checked out as a git worktree is cut like any other"
assert_contains "$OUT" "would tag RepoB" "the worktree repo is tagged, not skipped"
git -C "$PUBWS/RepoB" worktree remove "$WTWS/RepoB"

# A collision on a remote stops the cut before any local tag.
git -C "$PUBWS/RepoA" tag -a release-v9.9.8 -m x "$PA"
git -C "$PUBWS/RepoA" push -q origin refs/tags/release-v9.9.8
git -C "$PUBWS/RepoA" tag -d release-v9.9.8 >/dev/null
git -C "$PUBWS/RepoB" commit -q --allow-empty -m three
git -C "$PUBWS/RepoB" tag -a release-v9.9.8 -m x HEAD
git -C "$PUBWS/RepoB" push -q origin refs/tags/release-v9.9.8
git -C "$PUBWS/RepoB" tag -d release-v9.9.8 >/dev/null
git -C "$PUBWS/RepoB" reset -q --hard "$PB"
cut "$TMP/cut.json" --workspace "$PUBWS" --execute
assert_eq "$CODE" "1" "refuses a tag already on a remote at another commit"
assert_contains "$OUT" "RepoB: origin has release-v9.9.8 at" "names the remote collision"
assert_eq "$(git -C "$PUBWS/RepoA" tag -l release-v9.9.8)" "" "creates no local tag when it refuses"
git -C "$PUBWS/RepoA" push -q --delete origin release-v9.9.8
git -C "$PUBWS/RepoB" push -q --delete origin release-v9.9.8

# A push the remote rejects is a failed publication, not a warning.
printf '#!/bin/sh\necho "tags are frozen" >&2\nexit 1\n' > "$PUBWS/RepoB.git/hooks/pre-receive"
chmod +x "$PUBWS/RepoB.git/hooks/pre-receive"
cut "$TMP/cut.json" --workspace "$PUBWS" --execute --push
assert_eq "$CODE" "1" "a rejected push fails the cut"
assert_contains "$OUT" "not pushed to 1 repo(s): RepoB" "names every repo that was not pushed"
assert_contains "$OUT" "pushed RepoA" "still reports the repos that were pushed"
assert_contains "$(git -C "$PUBWS/RepoA" tag -l --format='%(contents)' release-v9.9.8)" \
  "local-containerized lane" "the tag text comes from the manifest, not a fixed profile"
rm "$PUBWS/RepoB.git/hooks/pre-receive"
unset RE_IMAGETOOLS STUB_REGISTRY

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
