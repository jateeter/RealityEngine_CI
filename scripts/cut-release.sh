#!/usr/bin/env bash
# Cut a release from a certified regression run.
#
# A release is a *pinned set of commits across every repo*, not a build
# artifact — the application is composed from sibling repos at run time. So
# cutting one means: take the manifest a green certification run produced,
# confirm the workspace still matches it, and tag every repo at the commit that
# run actually built.
#
# Dry-run by default. Nothing is tagged and nothing is pushed until --execute,
# and pushing tags is a separate opt-in on top of that, because a pushed tag is
# the hard-to-reverse step.
#
#   scripts/cut-release.sh --manifest releases/v0.1.0-rc1.json          # rehearse
#   scripts/cut-release.sh --manifest releases/v0.1.0-rc1.json --execute
#   scripts/cut-release.sh --manifest releases/v0.1.0-rc1.json --execute --push
#
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$CI_DIR/.." && pwd)"
MANIFEST=""
EXECUTE=false
PUSH=false
ALLOW_DIRTY=false

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)    MANIFEST="$2"; shift 2 ;;
    --manifest=*)  MANIFEST="${1#*=}"; shift ;;
    --workspace)   WORKSPACE="$2"; shift 2 ;;
    --workspace=*) WORKSPACE="${1#*=}"; shift ;;
    --execute)     EXECUTE=true; shift ;;
    --push)        PUSH=true; shift ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    -h|--help)     usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "missing --manifest (see releases/)"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# ── What the manifest claims ────────────────────────────────────────────────

VERSION=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$MANIFEST")
RUN_ID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['certifiedBy']['runId'])" "$MANIFEST")
RUN_STATUS=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['certifiedBy']['status'])" "$MANIFEST")
PROVISIONAL=$(python3 -c "import json,sys;print('yes' if 'provisional' in json.load(open(sys.argv[1])) else 'no')" "$MANIFEST")

echo "Release  : $VERSION"
echo "Certified: run $RUN_ID (status: $RUN_STATUS)"
echo "Workspace: $WORKSPACE"
echo

# A provisional manifest was pinned from a run that did not pass. Tagging one
# would publish an uncertified set under a release name, which is the single
# thing this whole process exists to prevent.
if [ "$PROVISIONAL" = "yes" ]; then
  python3 -c "import json,sys;print('  '+json.load(open(sys.argv[1]))['provisional']['reason'])" "$MANIFEST" >&2
  die "refusing to cut a release from a provisional manifest"
fi

# ── The workspace must still be the thing that was certified ────────────────

echo "Verifying the workspace matches the pinned set..."
VERIFY_ARGS=(verify --manifest "$MANIFEST" --workspace "$WORKSPACE")
[ "$ALLOW_DIRTY" = true ] && VERIFY_ARGS+=(--allow-dirty)
if ! python3 "$CI_DIR/scripts/release-manifest.py" "${VERIFY_ARGS[@]}"; then
  echo >&2
  echo "The workspace has drifted from the certified set. Tagging now would put" >&2
  echo "the release name on commits that were never certified together." >&2
  echo "Check out the pinned commits, or cut from a manifest matching this tree." >&2
  exit 1
fi
echo

# ── Tag every repo at the commit that run built ─────────────────────────────

REPOS=$(python3 -c "
import json,sys
for r in json.load(open(sys.argv[1]))['repos']:
    print(r['name'], r['sha'])
" "$MANIFEST")

TAG_MESSAGE="RealityEngine $VERSION

Certified by regression run $RUN_ID (hosted profile, cpp:1,lsp:1,scala:1).
Every repo in this release is pinned by ${MANIFEST##*/}."

echo "Tagging $VERSION:"
FAILED=0
while read -r name sha; do
  [ -n "$name" ] || continue
  repo_dir="$WORKSPACE/$name"

  if [ ! -d "$repo_dir/.git" ]; then
    echo "  SKIP  $name — not checked out"
    FAILED=1
    continue
  fi

  existing=$(git -C "$repo_dir" rev-parse -q --verify "refs/tags/$VERSION^{commit}" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    if [ "$existing" = "$sha" ]; then
      echo "  ok    $name — already tagged at ${sha:0:12}"
    else
      echo "  ERROR $name — $VERSION already exists at ${existing:0:12}, manifest pins ${sha:0:12}"
      FAILED=1
    fi
    continue
  fi

  if [ "$EXECUTE" = true ]; then
    git -C "$repo_dir" tag -a "$VERSION" "$sha" -m "$TAG_MESSAGE"
    echo "  TAG   $name ${sha:0:12}"
  else
    echo "  would tag $name ${sha:0:12}"
  fi
done <<< "$REPOS"

[ "$FAILED" -eq 0 ] || die "one or more repos could not be tagged; nothing was pushed"

# ── Push, as a separate decision ────────────────────────────────────────────

echo
if [ "$EXECUTE" != true ]; then
  echo "Dry run. Re-run with --execute to create the tags locally."
  exit 0
fi

if [ "$PUSH" != true ]; then
  echo "Tags created locally. They are not pushed."
  echo "A pushed tag is the hard-to-reverse step, so it is a separate opt-in:"
  echo "    $0 --manifest $MANIFEST --execute --push"
  exit 0
fi

echo "Pushing tags:"
while read -r name sha; do
  [ -n "$name" ] || continue
  git -C "$WORKSPACE/$name" push origin "refs/tags/$VERSION" >/dev/null 2>&1 \
    && echo "  pushed $name" \
    || echo "  FAILED $name — push it manually"
done <<< "$REPOS"

echo
echo "Release $VERSION cut and pushed."
