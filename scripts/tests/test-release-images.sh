#!/usr/bin/env bash
# Unit tests for scripts/check-release-images.py — no Docker, no network.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/check-release-images.py"

PASS=0; FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"; PASS=$((PASS+1))
  else
    echo "  FAIL: $label (expected $expected, got $actual)"; FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) echo "  PASS: $label"; PASS=$((PASS+1)) ;;
    *) echo "  FAIL: $label"
       echo "        expected to contain: $needle"
       echo "        actual: $(echo "$haystack" | head -c 400)"
       FAIL=$((FAIL+1)) ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake workspace: the tool beside two sibling repos, each with a Dockerfile.
WS="$TMP/ws"
mkdir -p "$WS/RealityEngine_CI/scripts" "$WS/RealityEngine_CI/release" \
         "$WS/RealityEngine_CPP" "$WS/localAIStack/services/api" \
         "$WS/RealityEngine_CI/docker/cpp"
cp "$TOOL" "$WS/RealityEngine_CI/scripts/"
touch "$WS/RealityEngine_CI/docker/cpp/Dockerfile" "$WS/localAIStack/services/api/Dockerfile"
FAKE_TOOL="$WS/RealityEngine_CI/scripts/check-release-images.py"

write_catalog() {            # $1 = JSON for the images array, $2 = registry, $3 = platform
  cat > "$TMP/catalog.json" <<EOF
{ "registry": "${2:-ghcr.io/jateeter}", "platform": "${3:-linux/arm64}", "images": $1 }
EOF
}

run() {                      # sets OUT and RC
  set +e
  OUT="$(python3 "$FAKE_TOOL" --catalog "$TMP/catalog.json" 2>&1)"
  RC=$?
  set -e
}

CPP='{"name":"re-cpp","repo":"RealityEngine_CPP","context":"RealityEngine_CPP","dockerfile":"RealityEngine_CI/docker/cpp/Dockerfile"}'
API='{"name":"re-localai-api","repo":"localAIStack","context":"localAIStack/services/api","dockerfile":"localAIStack/services/api/Dockerfile"}'

echo "valid catalog"
write_catalog "[$CPP, $API]"; run
assert_eq "$RC" 0 "exit 0"
assert_contains "$OUT" "2 checked against their files" "both images checked against real files"

echo "the registry and the platform are the decided ones"
write_catalog "[$CPP]" "docker.io/someone"; run
assert_eq "$RC" 1 "another registry is refused"
assert_contains "$OUT" "expected 'ghcr.io/jateeter'" "names the expected registry"
write_catalog "[$CPP]" "ghcr.io/jateeter" "linux/amd64"; run
assert_eq "$RC" 1 "amd64 is refused"

echo "names"
write_catalog "[$CPP, $CPP]"; run
assert_eq "$RC" 1 "a name listed twice is refused"
assert_contains "$OUT" "re-cpp: listed twice" "names the duplicate"
write_catalog '[{"name":"cpp","repo":"RealityEngine_CPP","context":"RealityEngine_CPP","dockerfile":"RealityEngine_CI/docker/cpp/Dockerfile"}]'; run
assert_eq "$RC" 1 "a name without the re- prefix is refused"

echo "one Dockerfile per image"
write_catalog "[$CPP, {\"name\":\"re-cpp-pe\",\"repo\":\"RealityEngine_CPP\",\"context\":\"RealityEngine_CPP\",\"dockerfile\":\"RealityEngine_CI/docker/cpp/Dockerfile\"}]"; run
assert_eq "$RC" 1 "two images from one Dockerfile and context are refused"
assert_contains "$OUT" "same Dockerfile and context as re-cpp" "names the image it collides with"

echo "files"
write_catalog '[{"name":"re-lsp","repo":"RealityEngine_CI","context":"RealityEngine_CI","dockerfile":"RealityEngine_CI/docker/lsp/Dockerfile"}]'; run
assert_eq "$RC" 1 "a missing Dockerfile is refused"
assert_contains "$OUT" "does not exist" "says it does not exist"
write_catalog '[{"name":"re-init","repo":"RealityEngine_CI","context":"RealityEngine_CI","dockerfile":"RealityEngine_CI/release/init/Dockerfile","status":"planned"}]'; run
assert_eq "$RC" 0 "a planned image may have no Dockerfile yet"
assert_contains "$OUT" "skip re-init (planned" "and it is reported as skipped"
write_catalog '[{"name":"re-pim","repo":"OpenCommons-Health---Personal-Information-Management","context":"OpenCommons-Health---Personal-Information-Management","dockerfile":"OpenCommons-Health---Personal-Information-Management/Dockerfile"}]'; run
assert_eq "$RC" 0 "a repo that is not checked out is not a failure"
assert_contains "$OUT" "0 checked against their files" "but nothing is counted as checked"
assert_contains "$OUT" "not checked out" "and the skip says why"

echo "repos"
write_catalog '[{"name":"re-x","repo":"RealityEngine_AI","context":"RealityEngine_CI","dockerfile":"RealityEngine_CI/docker/cpp/Dockerfile"}]'; run
assert_eq "$RC" 1 "a repo outside the release is refused"

echo "the local-containerized regression lane (E1) — plan mode only"
RT="$CI_DIR/scripts/regression-test.sh"
set +e; OUT="$(bash "$RT" --profile local-containerized 2>&1)"; RC=$?; set -e
assert_eq "$RC" 0 "regression-test.sh accepts --profile local-containerized"
assert_contains "$OUT" "profile:      local-containerized" "and plans it"
set +e; OUT="$(bash "$RT" --profile local --images x.json 2>&1)"; RC=$?; set -e
assert_eq "$RC" 2 "--images outside the containerized lane is refused"
set +e; OUT="$(bash "$RT" --profile nope 2>&1)"; RC=$?; set -e
assert_contains "$OUT" "hosted|local|local-containerized" "an unknown profile names all three"

echo "the containerized lane's image provenance check"
LANE="$CI_DIR/scripts/lib/containerized-lane.sh"
# The check is the heredoc inside containerized_build_images; run it alone.
sed -n "/<<'PYEOF'/,/^PYEOF/p" "$LANE" | sed '1d;$d' > "$TMP/prov.py"
prov() {
  set +e; OUT="$(python3 "$TMP/prov.py" "$1" "$2" 2>&1)"; RC=$?; set -e
}
echo '{"repos":[{"name":"RealityEngine_CPP","worktreeSha":"aaa"}]}' > "$TMP/m.json"
echo '{"images":[{"name":"re-cpp","repo":"RealityEngine_CPP","revision":"aaa"},{"name":"re-x","repo":"Other","revision":"z"}]}' > "$TMP/i.json"
prov "$TMP/i.json" "$TMP/m.json"
assert_eq "$RC" 0 "images built at the run's pins pass"
echo '{"images":[{"name":"re-cpp","repo":"RealityEngine_CPP","revision":"bbb"}]}' > "$TMP/i.json"
prov "$TMP/i.json" "$TMP/m.json"
assert_eq "$RC" 1 "an image built from another commit fails"
assert_contains "$OUT" "re-cpp: built from RealityEngine_CPP bbb" "and names the image"

echo "the committed catalog"
set +e; OUT="$(python3 "$TOOL" 2>&1)"; RC=$?; set -e
assert_eq "$RC" 0 "release/images.json passes"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
