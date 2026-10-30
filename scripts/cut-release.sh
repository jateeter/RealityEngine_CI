#!/usr/bin/env bash
# Cut a release from a certified regression run.
#
# A release is a pinned set of commits across every repo plus the images built
# from exactly those commits, by digest (RELEASE.md, decision A2). Cutting one
# means: take the manifest generated from the certifying runs, confirm the
# workspace still matches it, and tag every repo at the commit those runs
# built. The images are promoted to the same tag afterwards, by digest
# (release-images.yml with promote_from).
#
# Dry-run by default. Nothing is tagged and nothing is pushed until --execute,
# and pushing tags is a separate opt-in on top of that, because a pushed tag is
# the hard-to-reverse step.
#
#   scripts/cut-release.sh --manifest releases/release-v0.0.1.json          # rehearse
#   scripts/cut-release.sh --manifest releases/release-v0.0.1.json --execute
#   scripts/cut-release.sh --manifest releases/release-v0.0.1.json --execute --push
#
# Before anything is tagged, the manifest must be eligible
# (`release-manifest.py check`, ReleaseRoadmap E4: images by digest from their
# pins, the E1 lane and the native lane green, pim-mirror and every parity
# stage passed, every omission decided), the workspace must match it, and no
# repo's origin and no registry image may carry the tag at another commit or
# digest (`release-manifest.py published`). RE_IMAGETOOLS replaces
# `docker buildx imagetools` for tests.
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

# Application releases are tagged release-vN.M.Z (release-vN.M.Z-rcN for a
# candidate): D1 in docs/MVP_ROADMAP.md, decided 2026-09-25. Plain vN.M.Z is a
# component's own release (localHealthkitBridge v0.1.0 already exists), and the
# same tag on every pinned repo would collide with it. Checked before anything
# else touches a repository.
[[ "$VERSION" =~ ^release-v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] \
  || die "manifest version '$VERSION' is not an application release tag: expected release-vN.M.Z or release-vN.M.Z-rcN (RELEASE.md, Tag conventions)"

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

# ── The manifest must be eligible (E4) ──────────────────────────────────────

python3 "$CI_DIR/scripts/release-manifest.py" check --manifest "$MANIFEST" \
  || die "refusing to cut $VERSION: the manifest is not eligible"
echo

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

# ── Nothing on a remote or in the registry may already disagree ─────────────

echo "Checking every origin and the registry for $VERSION..."
python3 "$CI_DIR/scripts/release-manifest.py" published --manifest "$MANIFEST" \
  --workspace "$WORKSPACE" --expect absent-or-equal \
  || die "refusing to cut $VERSION: a remote tag or an image already disagrees with the manifest, or could not be checked"
echo

# The tag text is the manifest's own account of what certified it.
TAG_MESSAGE=$(python3 - "$MANIFEST" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
c = m["certifiedBy"]
lines = [f"RealityEngine {m['version']}", ""]
lines.append(f"Certified by run {c['runId']} ({c.get('profile', '?')} lane, {c.get('engineSpec', '?')}) "
             f"on {len(m.get('images', []))} images by digest from {m.get('imagesFile', {}).get('tag', '?')}.")
n = c.get("native")
if n:
    lines.append(f"Native lane: run {n['runId']} ({n.get('profile', '?')}, {n.get('engineSpec', '?')}).")
    for name, d in sorted((n.get("drift") or {}).items()):
        lines.append(f"Native lane ran {name} at {d['sha'][:12]}: {d.get('reason', '')}")
omitted = {**c.get("omissions", {}), **((n or {}).get("omissions", {}))}
for name, reason in sorted(omitted.items()):
    lines.append(f"Omitted: {name}: {reason}")
lines.append(f"Every repo and image in this release is pinned by releases/{m['version']}.json.")
print("\n".join(lines))
EOF
)

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
PUSH_FAILED=()
while read -r name sha; do
  [ -n "$name" ] || continue
  if git -C "$WORKSPACE/$name" push origin "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "  pushed $name"
  else
    echo "  FAILED $name"
    PUSH_FAILED+=("$name")
  fi
done <<< "$REPOS"

echo
if [ "${#PUSH_FAILED[@]}" -gt 0 ]; then
  echo "error: $VERSION was not pushed to ${#PUSH_FAILED[@]} repo(s): ${PUSH_FAILED[*]}" >&2
  echo "A partial publication is not a release. Push those tags, then check:" >&2
  echo "    python3 scripts/release-manifest.py published --manifest $MANIFEST --expect equal" >&2
  exit 1
fi
CANDIDATE=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('imagesFile',{}).get('tag',''))" "$MANIFEST")
echo "Tags for $VERSION pushed to every repo. Promote the images by digest next:"
echo "    gh workflow run release-images.yml --ref main -f tag=$VERSION -f promote_from=$CANDIDATE"
echo "then confirm every tag and image resolves to the manifest:"
echo "    python3 scripts/release-manifest.py published --manifest $MANIFEST --expect equal"
