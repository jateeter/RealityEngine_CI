#!/usr/bin/env bash
# install.sh's release constants are the certified ones (RELEASE.md §2).
#
# install.sh is the one command a fresh Mac runs, so a wrong constant is a
# broken install for everyone: an images file it refuses, an installer from the
# wrong commit, a Node the release does not pin. Checked here, without a network
# where the commit is in the clone, and by its public URL where it is not (the
# hosted checkout is shallow).
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$CI_DIR/install.sh"
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1)); else echo "  FAIL: $3 (expected '$2', got '$1')"; FAIL=$((FAIL+1)); fi; }
const() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$S"; }
req() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k]
print(d)' "$CI_DIR/release/host-requirements.json" "$1"; }
sha_of() { shasum -a 256 2>/dev/null | awk '{print $1}' || sha256sum | awk '{print $1}'; }
# The file at <commit>:<path>, from the clone when it has the commit, else from GitHub.
at_commit() {
  if git -C "$CI_DIR" cat-file -e "$1^{commit}" 2>/dev/null; then git -C "$CI_DIR" show "$1:$2"
  else curl -fsSL "https://raw.githubusercontent.com/jateeter/RealityEngine_CI/$1/$2"; fi
}

echo "install.sh"
bash -n "$S"; check "$?" 0 "parses"
check "$(head -1 "$S")" "#!/bin/bash" "runs on the stock macOS /bin/bash"

TAG="$(const RELEASE_TAG)"
check "$TAG" "$(req release)" "RELEASE_TAG is release/host-requirements.json's release"
check "$(const NODE_VERSION)" "$(req node.exact)" "NODE_VERSION is the release's pinned Node"
check "$(const OLLAMA_MIN)" "$(req ollama.min)" "OLLAMA_MIN is the release's minimum Ollama"

file="$CI_DIR/release/candidates/$TAG.images.json"
check "$([ -f "$file" ] && echo present)" present "release/candidates/$TAG.images.json is committed"
check "$(sha_of < "$file")" "$(const IMAGES_SHA256)" "IMAGES_SHA256 is that file's sha256"
check "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$file")" "$TAG" "the images file is $TAG's"
check "$(at_commit "$(const IMAGES_COMMIT)" "release/candidates/$TAG.images.json" | sha_of)" "$(const IMAGES_SHA256)" \
  "IMAGES_COMMIT serves the same file"
check "$(at_commit "$(const INSTALLER_COMMIT)" release/realityengine | sha_of)" "$(const INSTALLER_SHA256)" \
  "INSTALLER_SHA256 is release/realityengine at INSTALLER_COMMIT"

echo ""
echo "install-sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
