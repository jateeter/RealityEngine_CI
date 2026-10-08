#!/usr/bin/env bash
# No consumer may assume the instance registry is on :5999.
#
# 5999 is the registry shim's port only with fixed ports. Under --free-ports it
# takes an OS-assigned port, and startUniverse.sh records the address it serves
# in .universe-registry-url. Consumers that fell back from RE_REGISTRY_URL
# straight to a literal http://127.0.0.1:5999 looked for the registry where
# nothing listened whenever they were run without the variable exported — about
# thirty of them across the repositories on 2026-10-08.
#
# The fallback lives in one place: scripts/lib/registry-url.sh (bash) and
# scripts/lib/registry_url.py (Python), which read RE_REGISTRY_URL, then
# .universe-registry-url, then ${RE_REGISTRY_PORT:-5999}. This gate fails any
# other host:5999 URL in code. Comments, and fixtures under scripts/tests/, are
# exempt: they describe the default rather than depend on it.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CI_DIR"

fail=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  text="${hit#*:*:}"
  before="${text%%5999*}"
  before="${before//:\/\//}"     # the URL's own "//" is not a comment
  case "$before" in
    *"#"*|*"//"*) continue ;;   # the literal sits in a comment
  esac
  echo "FAIL literal :5999 registry address:"
  echo "     $hit"
  echo "     Resolve it with scripts/lib/registry-url.sh or registry_url.py."
  fail=1
done < <(git grep -nE '(127\.0\.0\.1|localhost|host\.docker\.internal):5999' -- \
           '*.sh' '*.py' '*.js' '*.mjs' '*.ts' '*.yml' '*.yaml' '*.json' 'Dockerfile*' '*.example' \
           ':!scripts/tests/**' ':!**/node_modules/**' || true)

if [ "$fail" -eq 0 ]; then
  echo "PASS no consumer assumes the instance registry is on :5999"
fi
exit "$fail"
