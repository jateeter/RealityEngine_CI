#!/bin/bash
# =============================================================================
# owl-reasoner-check.sh
#
# Reasoner-based validation of the corpus OWL semantics layer (milestone M3).
# Delegates to RealityEngine_Machines/scripts/reason-owl.sh, which merges the
# core ontology with generated ABoxes and runs ROBOT report + reason (ELK).
#
# Non-blocking by design: when ROBOT is not installed the upstream script
# prints SKIPPED and exits 0. CI containers make the gate real by installing
# ROBOT (https://robot.obolibrary.org) and exporting ROBOT_BIN (or putting
# `robot` on PATH).
#
# Usage:
#   ./scripts/owl-reasoner-check.sh [domain]     # default: health-personal
#
# Env:
#   MACHINES_DIR   corpus checkout (default sibling RealityEngine_Machines)
#   ROBOT_BIN      robot executable (passed through)
# =============================================================================
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINES_DIR="${MACHINES_DIR:-$(cd "$CI_DIR/.." && pwd)/RealityEngine_Machines}"
DOMAIN="${1:-health-personal}"

if [ ! -f "$MACHINES_DIR/scripts/reason-owl.sh" ]; then
  echo "owl-reasoner-check: SKIPPED (no reason-owl.sh at $MACHINES_DIR — pull RealityEngine_Machines main)"
  exit 0
fi

exec bash "$MACHINES_DIR/scripts/reason-owl.sh" "$DOMAIN"
