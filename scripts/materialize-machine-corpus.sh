#!/usr/bin/env bash
# Materialize a selected machine corpus into a temporary RealityEngine_Machines-like root.
set -euo pipefail

usage() {
  cat <<'USAGE'
materialize-machine-corpus.sh SOURCE_ROOT MANIFEST OUTPUT_ROOT

SOURCE_ROOT must contain a machines/ directory.
MANIFEST lists machine JSON filenames (basenames), one per line. Blank lines
and comments starting with # are ignored. Entries are resolved against
machines/ first, then by a recursive basename search so the manifest stays
valid across corpus reorganisations (the corpus is domain-organized and
filenames are globally unique).
OUTPUT_ROOT will be recreated with a flat machines/ directory containing the
selected machine files.
USAGE
}

[ "${1:-}" = "--help" ] && { usage; exit 0; }
[ "$#" -eq 3 ] || { usage >&2; exit 2; }

source_root="$1"
manifest="$2"
output_root="$3"
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
    */*|*..*) echo "invalid corpus entry: $line" >&2; exit 1 ;;
  esac
  # Flat path first, then a recursive basename search — the corpus is
  # domain-organized (machines/domains/<domain>/) and filenames are globally
  # unique, so the manifest can stay basename-only and survive reorganisation.
  src="$source_machines/$line"
  if [ ! -f "$src" ]; then
    matches="$(find "$source_machines" -type f -name "$line" 2>/dev/null)"
    match_count="$(printf '%s' "$matches" | grep -c . || true)"
    if [ "$match_count" -eq 0 ]; then
      missing="$missing  $line"$'\n'
      continue
    elif [ "$match_count" -gt 1 ]; then
      ambiguous="$ambiguous  $line -> $(printf '%s' "$matches" | tr '\n' ' ')"$'\n'
      continue
    fi
    src="$(printf '%s' "$matches" | head -n 1)"
  fi
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
