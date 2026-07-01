#!/usr/bin/env bash
# Materialize a selected machine corpus into a temporary RealityEngine_Machines-like root.
set -euo pipefail

usage() {
  cat <<'USAGE'
materialize-machine-corpus.sh SOURCE_ROOT MANIFEST OUTPUT_ROOT

SOURCE_ROOT must contain machines/*.json.
MANIFEST lists machine JSON filenames, one per line. Blank lines and comments
starting with # are ignored.
OUTPUT_ROOT will be recreated with a machines/ directory containing the selected
machine files.
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
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$line" ] && continue
  case "$line" in
    */*|*..*) echo "invalid corpus entry: $line" >&2; exit 1 ;;
  esac
  src="$source_machines/$line"
  [ -f "$src" ] || { echo "selected machine not found: $src" >&2; exit 1; }
  cp "$src" "$output_machines/$line"
  count=$((count + 1))
done < "$manifest"

[ "$count" -gt 0 ] || { echo "manifest selected no machines: $manifest" >&2; exit 1; }
cp "$manifest" "$output_root/standard-deployment-corpus.txt"
printf '%s\n' "$count" > "$output_root/machine-count.txt"
echo "Materialized $count machine(s) into $output_machines"
