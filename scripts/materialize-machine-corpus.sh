#!/usr/bin/env bash
# Materialize a selected machine corpus into a temporary RealityEngine_Machines-like root.
set -euo pipefail

usage() {
  cat <<'USAGE'
materialize-machine-corpus.sh SOURCE_ROOT MANIFEST OUTPUT_ROOT [EXTRA_MACHINE_DIR...]

SOURCE_ROOT must contain machines/**/*.json.
MANIFEST lists machine JSON paths relative to SOURCE_ROOT/machines, one per
line, or globally unique basenames. Blank lines and comments starting with #
are ignored. Basename entries are resolved against machines/ first, then by a
recursive basename search so the manifest stays valid across corpus
reorganisations.
OUTPUT_ROOT will be recreated with a machines/ directory containing the selected
machine files.

EXTRA_MACHINE_DIR are additional directories searched, in order, for manifest
entries not found under SOURCE_ROOT/machines. They exist because not every
machine a regression lane needs is owned by the corpus repo: localAIStack
declares its own (rag_corrective_cycle, session_rag_context,
session_agent_context) under data/machines and registers them into the RE at
its own startup. Copying those into RealityEngine_Machines would make two
repos the source of truth for one machine, so the manifest reaches them
instead.
USAGE
}

[ "${1:-}" = "--help" ] && { usage; exit 0; }
[ "$#" -ge 3 ] || { usage >&2; exit 2; }

source_root="$1"
manifest="$2"
output_root="$3"
shift 3
extra_dirs=( "$@" )
source_machines="$source_root/machines"
output_machines="$output_root/machines"

[ -d "$source_machines" ] || { echo "source machines directory not found: $source_machines" >&2; exit 1; }
[ -f "$manifest" ] || { echo "manifest not found: $manifest" >&2; exit 1; }
case "$output_root" in
  ""|"/"|"$source_root"|"$source_machines")
    echo "refusing unsafe output root: $output_root" >&2
    exit 1
    ;;
esac

rm -rf "$output_root"
mkdir -p "$output_machines"

count=0
missing=""
ambiguous=""
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$line" ] && continue
  case "$line" in
    /*|*..*) echo "invalid corpus entry: $line" >&2; exit 1 ;;
  esac
  # Direct relative path first, then a recursive basename search for manifests
  # that intentionally stay basename-only across corpus reorganisations.
  src="$source_machines/$line"
  if [ ! -f "$src" ]; then
    matches="$(find "$source_machines" -type f -name "$line" 2>/dev/null)"
    match_count="$(printf '%s' "$matches" | grep -c . || true)"
    if [ "$match_count" -eq 0 ]; then
      # Fall back to the extra roots before declaring the entry missing.
      for _extra in ${extra_dirs[@]+"${extra_dirs[@]}"}; do
        [ -d "$_extra" ] || continue
        matches="$(find "$_extra" -type f -name "$(basename "$line")" 2>/dev/null)"
        match_count="$(printf '%s' "$matches" | grep -c . || true)"
        [ "$match_count" -ge 1 ] && break
      done
    fi
    if [ "$match_count" -eq 0 ]; then
      missing="$missing  $line"$'\n'
      continue
    elif [ "$match_count" -gt 1 ]; then
      ambiguous="$ambiguous  $line -> $(printf '%s' "$matches" | tr '\n' ' ')"$'\n'
      continue
    fi
    src="$(printf '%s' "$matches" | head -n 1)"
  fi
  mkdir -p "$(dirname "$output_machines/$line")"
  cp "$src" "$output_machines/$line"
  count=$((count + 1))
done < "$manifest"

# Report every unresolved entry at once — aborting on the first turns a
# corpus-wide reorganisation into a one-at-a-time debugging session.
if [ -n "$missing" ] || [ -n "$ambiguous" ]; then
  [ -n "$missing" ] && printf 'selected machine(s) not found under %s:\n%s' "$source_machines" "$missing" >&2
  [ -n "$ambiguous" ] && printf 'ambiguous corpus entr(ies) — filenames must be globally unique:\n%s' "$ambiguous" >&2
  exit 1
fi

[ "$count" -gt 0 ] || { echo "manifest selected no machines: $manifest" >&2; exit 1; }
cp "$manifest" "$output_root/standard-deployment-corpus.txt"
printf '%s\n' "$count" > "$output_root/machine-count.txt"
echo "Materialized $count machine(s) into $output_machines"
