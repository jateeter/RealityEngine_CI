#!/usr/bin/env bash
# Unit tests for agreement_clusters in scripts/regression-universal-vectors.py.
#
# The stage compared every runtime against instance_order[0] — whichever
# instance the registry listed first, which is also the engine localAIStack's
# bridge writes to. On 2026-08-17 that engine held 17 machines while the others
# held 7, so every comparison ran against the contaminated party: two runtimes
# that agreed exactly with each other were both reported as diverging, and
# jateeter/RealityEngine_LSP#38 was filed on that reading (jateeter/RealityEngine_CI#138).
#
# These pin the property that replaced it: agreement is a property of the set,
# and the reported clusters do not depend on which instance came first.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$CI_DIR/scripts/regression-universal-vectors.py"

PASS=0; FAIL=0
assert_eq() {
  if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASS=$((PASS+1))
  else echo "  FAIL: $3"; echo "        expected: $2"; echo "        actual:   $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Signatures arrive on stdin as {"instance": signature}; order is argv.
cat > "$TMP/clusters.py" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("uv", sys.argv[1])
uv = importlib.util.module_from_spec(spec); spec.loader.exec_module(uv)
sigs = json.load(sys.stdin)
print(json.dumps(uv.agreement_clusters(sigs, sys.argv[2:])))
PYEOF
clusters() { python3 "$TMP/clusters.py" "$TOOL" "$@"; }

echo "== agreement_clusters =="

A='{"cpp-1":[1],"lsp-1":[1],"scala-1":[1]}'
assert_eq "$(printf '%s' "$A" | clusters cpp-1 lsp-1 scala-1)" \
  '[["cpp-1", "lsp-1", "scala-1"]]' \
  "all three identical -> one cluster"

# The case that produced the misfiled issue: the first-listed instance is the
# outlier and the other two agree.
B='{"cpp-1":[9],"lsp-1":[1],"scala-1":[1]}'
assert_eq "$(printf '%s' "$B" | clusters cpp-1 lsp-1 scala-1)" \
  '[["lsp-1", "scala-1"], ["cpp-1"]]' \
  "first-listed instance is the outlier -> majority cluster reported first"

assert_eq "$(printf '%s' "$B" | clusters scala-1 lsp-1 cpp-1)" \
  '[["lsp-1", "scala-1"], ["cpp-1"]]' \
  "same result regardless of instance order"

C='{"cpp-1":[1],"lsp-1":[2],"scala-1":[3]}'
assert_eq "$(printf '%s' "$C" | clusters cpp-1 lsp-1 scala-1)" \
  '[["cpp-1"], ["lsp-1"], ["scala-1"]]' \
  "three-way disagreement -> three singleton clusters"

# No majority. Reporting one side as the reference would reinstate exactly the
# designated-baseline problem this replaced, so the tie stays a tie.
D='{"cpp-1":[1],"lsp-1":[2]}'
assert_eq "$(printf '%s' "$D" | clusters cpp-1 lsp-1)" \
  '[["cpp-1"], ["lsp-1"]]' \
  "two runtimes split evenly -> tied singletons, no majority invented"

E='{"only-1":[1]}'
assert_eq "$(printf '%s' "$E" | clusters only-1)" \
  '[["only-1"]]' \
  "single instance -> one cluster (the caller still fails it separately)"

echo
echo "Totals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
