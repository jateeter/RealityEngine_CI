#!/usr/bin/env bash
# audit-docs.sh — cross-repo documentation audit
#
# Checks:
#   1. SURFACE_SPEC byte-identical across all runtime copies
#   2. Deprecated port references (3299, 3300) outside allowed files
#   3. OpenAPI route parity (generated files current with SURFACE_SPEC)
#   4. Wiki content drift (port tables in files that should only link)
#   5. Stale known-blocker text in contract / operator / wiki docs
#
# Usage (from RealityEngine_CI root):
#   bash scripts/audit-docs.sh [--fix]
#
# --fix   Auto-regenerate stale OpenAPI files (all other checks are read-only).

set -uo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(cd "$CI_DIR/.." && pwd)"

FAIL=0
FIX=false
for arg in "$@"; do [ "$arg" = "--fix" ] && FIX=true; done

# ── Helpers ──────────────────────────────────────────────────────────────────
pass()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail()   { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }
detail() { printf "    %s\n" "$1"; }
hdr()    { printf "\n\033[1m%s\033[0m\n" "$1"; }

# Directories excluded from every grep search (basename match).
GREP_EXCL=(
  --exclude-dir=".git"
  --exclude-dir="node_modules"
  --exclude-dir="target"
  --exclude-dir=".bsp"
  --exclude-dir=".metals"
  --exclude-dir=".idea"
  --exclude-dir="__pycache__"
  --exclude-dir="logs"
  --exclude-dir="data"
  --exclude-dir="run"
  --exclude-dir="quicklisp"          # Lisp vendor packages
  --exclude-dir="RealityEngine_AI.wiki"  # archived old wiki content
  --exclude="*.class"
  --exclude="*.pyc"
  --exclude="releases.txt"           # quicklisp package registry
)

# ── Check 1: Surface spec hashes ─────────────────────────────────────────────
hdr "1. SURFACE_SPEC byte-identical copies"
if bash "$CI_DIR/scripts/check-surface-specs.sh" 2>/dev/null 1>/dev/null; then
  pass "all SURFACE_SPEC copies match canonical (RealityEngine_CPP)"
else
  fail "SURFACE_SPEC drift — propagate from RealityEngine_CPP/SURFACE_SPEC.md"
  output=$(bash "$CI_DIR/scripts/check-surface-specs.sh" 2>&1 || true)
  while IFS= read -r line; do detail "$line"; done <<< "$output"
fi

# ── Check 2: Deprecated port references ──────────────────────────────────────
hdr "2. Deprecated port references (3299, 3300)"
# Use \b word boundaries so hash fragments like 43300d6 are not matched.
# Uses find+xargs rather than grep -r --exclude because BSD grep (macOS) does
# not reliably apply --exclude when --include is also present.
#
# Files explicitly excluded from this check:
#   DEPLOYMENT_CONTRACT.md / REALITY_PERCEPTION_OPERATIONS.md — declare them deprecated
#   INTEGRATED_SPECIFICATION.md — quotes deprecated ports only to describe the fix task
#   Contract-Snapshot.md / audit-docs.sh — generated or meta files
#   healthkit-spezi-app.example.env — comment explicitly labels them deprecated compat
#   EXAMPLE_DOMAIN_COMPENDIUM.md / Example-Machine-Compendium.md — use 3299 as
#     perceptual-space offset ([3295:3299]), not a port number
#   Machine-Interconnection-Index.md — uses [3295:3299] as perceptual-space offset
#   RealityEngine_AI.wiki/ — archived old AI wiki content (corpus submodule)
DEPR_HITS=$(find "$WS" \
    \( -name "*.md" -o -name "*.sh" -o -name "*.env" -o -name "*.txt" \) \
    ! \( \
      -path "*/.git/*" \
      -o -path "*/node_modules/*" \
      -o -path "*/target/*" \
      -o -path "*/.bsp/*" \
      -o -path "*/.metals/*" \
      -o -path "*/quicklisp/*" \
      -o -path "*/RealityEngine_AI.wiki/*" \
      -o -name "DEPLOYMENT_CONTRACT.md" \
      -o -name "Contract-Snapshot.md" \
      -o -name "REALITY_PERCEPTION_OPERATIONS.md" \
      -o -name "INTEGRATED_SPECIFICATION.md" \
      -o -name "audit-docs.sh" \
      -o -name "healthkit-spezi-app.example.env" \
      -o -name "EXAMPLE_DOMAIN_COMPENDIUM.md" \
      -o -name "Example-Machine-Compendium.md" \
      -o -name "Machine-Interconnection-Index.md" \
      -o -name "releases.txt" \
    \) \
    -print0 2>/dev/null \
  | xargs -0 grep -En '\b3299\b|\b3300\b' 2>/dev/null || true)

if [ -z "$DEPR_HITS" ]; then
  pass "no deprecated port (3299, 3300) references outside allowed files"
else
  fail "deprecated port references found outside allowed files"
  while IFS= read -r line; do detail "$line"; done <<< "$DEPR_HITS"
fi

# ── Check 3: OpenAPI route parity ────────────────────────────────────────────
hdr "3. OpenAPI route parity"
if ! python3 -c "import yaml" 2>/dev/null; then
  fail "pyyaml not installed — cannot check OpenAPI parity (pip3 install pyyaml)"
else
  SPEC="$WS/RealityEngine_CPP/SURFACE_SPEC.md"
  OVERLAY_DIR="$CI_DIR/scripts/openapi/overlays"
  GEN_SCRIPT="$CI_DIR/scripts/openapi/generate.py"
  OUT_DIR="$CI_DIR/docs/openapi"

  TMP_DIR=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$TMP_DIR'" EXIT

  PARITY_PASS=true
  for runtime in cpp lsp scala; do
    python3 "$GEN_SCRIPT" \
      --spec    "$SPEC" \
      --overlay "$OVERLAY_DIR/${runtime}.yaml" \
      --out-re  "$TMP_DIR/${runtime}-re.yaml" \
      --out-pe  "$TMP_DIR/${runtime}-pe.yaml" 2>/dev/null

    for surface in re pe; do
      committed="$OUT_DIR/${runtime}-${surface}.yaml"
      generated="$TMP_DIR/${runtime}-${surface}.yaml"
      if [ ! -f "$committed" ]; then
        fail "missing: docs/openapi/${runtime}-${surface}.yaml — run: bash scripts/generate-openapi.sh"
        PARITY_PASS=false
      elif ! diff -q "$committed" "$generated" >/dev/null 2>&1; then
        fail "stale: docs/openapi/${runtime}-${surface}.yaml — run: bash scripts/generate-openapi.sh"
        PARITY_PASS=false
        if $FIX; then
          cp "$generated" "$committed"
          detail "auto-fixed: regenerated ${runtime}-${surface}.yaml"
        fi
      fi
    done
  done

  if $PARITY_PASS; then
    RE_PATHS=$(python3 -c "import yaml; d=yaml.safe_load(open('$TMP_DIR/cpp-re.yaml')); print(len(d['paths']))")
    PE_PATHS=$(python3 -c "import yaml; d=yaml.safe_load(open('$TMP_DIR/cpp-pe.yaml')); print(len(d['paths']))")
    pass "OpenAPI current with SURFACE_SPEC (RE: ${RE_PATHS} paths, PE: ${PE_PATHS} paths)"
  fi

  PROPAGATION_PASS=true
  check_mirror() {
    local source="$1"
    local mirror="$2"
    local label="$3"

    if [ ! -f "$mirror" ]; then
      fail "missing propagated OpenAPI mirror: $label — run: bash scripts/generate-openapi.sh --propagate"
      PROPAGATION_PASS=false
    elif ! diff -q "$source" "$mirror" >/dev/null 2>&1; then
      fail "stale propagated OpenAPI mirror: $label — run: bash scripts/generate-openapi.sh --propagate"
      PROPAGATION_PASS=false
      if $FIX; then
        cp "$source" "$mirror"
        detail "auto-fixed propagated mirror: $label"
      fi
    fi
  }

  check_mirror "$OUT_DIR/cpp-re.yaml" "$WS/RealityEngine_CPP/docs/openapi/reality-engine.yaml" "RealityEngine_CPP/docs/openapi/reality-engine.yaml"
  check_mirror "$OUT_DIR/cpp-pe.yaml" "$WS/RealityEngine_CPP/docs/openapi/perception-engine.yaml" "RealityEngine_CPP/docs/openapi/perception-engine.yaml"
  check_mirror "$OUT_DIR/lsp-re.yaml" "$WS/RealityEngine_LSP/docs/openapi/reality-engine.yaml" "RealityEngine_LSP/docs/openapi/reality-engine.yaml"
  check_mirror "$OUT_DIR/lsp-pe.yaml" "$WS/RealityEngine_LSP/docs/openapi/perception-engine.yaml" "RealityEngine_LSP/docs/openapi/perception-engine.yaml"
  for runtime in cpp lsp scala; do
    check_mirror "$OUT_DIR/${runtime}-re.yaml" "$WS/RealityEngine_Manager/docs/openapi/${runtime}-re.yaml" "RealityEngine_Manager/docs/openapi/${runtime}-re.yaml"
    check_mirror "$OUT_DIR/${runtime}-pe.yaml" "$WS/RealityEngine_Manager/docs/openapi/${runtime}-pe.yaml" "RealityEngine_Manager/docs/openapi/${runtime}-pe.yaml"
  done

  if $PROPAGATION_PASS; then
    pass "propagated OpenAPI mirrors match CI generated specs"
  fi
fi

# ── Check 4: Wiki content drift ───────────────────────────────────────────────
hdr "4. Wiki content drift"
WIKI_DIR="$CI_DIR/wiki"
# Flag markdown table rows containing backtick-quoted runtime port numbers.
# Ranges: 3000-3099 (CI Docker TLS) and 5000-5899 (native runtimes).
# Contract-Snapshot.md is the generated summary; it is expected to carry tables.
PORT_ROW_RE='^\|.*`[35][0-9]{3}`'

DRIFT_PASS=true
while IFS= read -r -d '' wf; do
  bn="$(basename "$wf")"
  [ "$bn" = "Contract-Snapshot.md" ] && continue

  hits=$(grep -En "$PORT_ROW_RE" "$wf" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    fail "wiki drift: $bn contains port table rows (link to DEPLOYMENT_CONTRACT.md instead)"
    while IFS= read -r line; do detail "$line"; done <<< "$(printf '%s\n' "$hits" | head -5)"
    DRIFT_PASS=false
  fi
done < <(find "$WIKI_DIR" -maxdepth 1 -name "*.md" -print0 2>/dev/null)

$DRIFT_PASS && pass "no port-table drift in wiki files"

# ── Check 5: Stale known-blocker text ────────────────────────────────────────
hdr "5. Stale known-blocker text"
# Patterns indicating an unresolved issue. Chosen to avoid false-positives:
#   - "not yet green" is a specific state phrase
#   - "e2e blocker" is a specific issue label
#   - "FIXME" is an explicit deferral marker
#   - "open question" flags un-decided design choices in operator docs
# "No known blockers remain" is NOT matched because none of these patterns
# appear in that positive phrasing.
BLOCKER_RE='not yet green|e2e blocker|FIXME|open question'

BLOCKER_TARGETS=(
  "$CI_DIR/INTEGRATED_SPECIFICATION.md"
  "$CI_DIR/DEPLOYMENT_CONTRACT.md"
  "$CI_DIR/wiki/Deployable-System-Documentation.md"
  "$CI_DIR/wiki/Home.md"
  "$CI_DIR/wiki/Documentation-Taxonomy.md"
  "$WS/RealityEngine_CPP/docs"
  "$WS/RealityEngine_LSP/docs"
  "$WS/RealityEngine_Scala/perception-engine/docs"
  "$WS/localHealthkitBridge/README.md"
  "$WS/localOpenClawStack/README.md"
  "$WS/localAIStack/README.md"
)

BLOCKER_EXCL=(
  --exclude-dir="openapi"
  --exclude="Contract-Snapshot.md"
)

BLOCKER_PASS=true
for target in "${BLOCKER_TARGETS[@]}"; do
  [ -e "$target" ] || continue
  hits=$(grep -rEin "$BLOCKER_RE" \
    "${GREP_EXCL[@]}" \
    "${BLOCKER_EXCL[@]}" \
    --include="*.md" \
    "$target" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      fail "stale blocker text: $line"
    done <<< "$hits"
    BLOCKER_PASS=false
  fi
done

$BLOCKER_PASS && pass "no stale known-blocker text in contract / operator / wiki docs"

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mAll documentation audit checks passed.\033[0m\n"
  exit 0
else
  printf "\033[31m%d check(s) failed.\033[0m\n" "$FAIL"
  exit 1
fi
