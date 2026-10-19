#!/usr/bin/env bash
# advance-node.sh — move every repo, image and local install to one Node minor.
#
# One minor everywhere, and it tracks upstream: when Dependabot proposes a new
# node image (or nodejs.org ships a newer minor of the current major), this is
# how the whole workspace moves with it. Dependabot alone cannot: it bumps a
# Dockerfile's FROM tag and nothing else, so its PR leaves .nvmrc, the other
# repos, localOpenClawStack's digest pin and the local nvm behind, and
# scripts/tests/test-node-env.sh fails it until this script is run.
#
#   scripts/advance-node.sh                 # plan: what moves from where to where
#   scripts/advance-node.sh --execute       # branch, rewrite, commit, push, PR per repo; local nvm
#   scripts/advance-node.sh --to 26.12      # a named minor instead of the newest
#   scripts/advance-node.sh --rewrite-only DIR [--from X.Y] --to X.Y
#                                           # rewrite one checkout in place, nothing else
#
# The minor is held once per repo, in .nvmrc; workflows read it with
# actions/setup-node `node-version-file`, and scripts/lib/node-env.sh and
# regression-test.sh read CI's. What cannot read a file is rewritten here:
#   - every .nvmrc
#   - node:<minor>-<variant> image references (Dockerfiles, compose,
#     release/images.json, localOpenClawStack's NODE_IMAGE build arg)
#   - a strict engines range ">=<minor>.0 <next>.0" (package.json and lockfile)
# then the local side: `nvm install`, nvm's default and stable aliases (global
# packages carried over from the previous default), and localOpenClawStack's
# operator .env NODE_IMAGE digest (backed up first; nothing else in it moves).
#
# Without --execute it prints the plan and exits 0 having changed nothing, the
# same master switch as regression-test.sh.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$CI_DIR/.." && pwd)"
read -r -a REPOS <<< "${RE_NODE_REPOS:-RealityEngine_CI RealityEngine_Manager RealityEngine_Machines localAIStack localOpenClawStack OpenCommons-Health---Personal-Information-Management}"
EXECUTE=false; TO=""; FROM=""; REWRITE_DIR=""

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=true ;;
    --to) TO="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --rewrite-only) REWRITE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "advance-node: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "advance-node: $*" >&2; exit 1; }
valid_minor() { [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]; }

# Newest released minor of the given major, from the nodejs.org release index.
newest_minor() {
  curl --fail --silent --show-error --max-time 30 https://nodejs.org/dist/index.json |
    jq -er --arg m "v$1." '[.[].version | select(startswith($m))][0] | ltrimstr("v") | split(".")[0:2] | join(".")'
}

# Rewrite one checkout from minor $2 to minor $3. Prints each file it changes.
rewrite_repo() {
  local dir="$1" old="$2" new="$3" f
  local old_re="${old//./\\.}"
  local old_next="${old%.*}.$(( ${old#*.} + 1 ))" new_next="${new%.*}.$(( ${new#*.} + 1 ))"
  while IFS= read -r f; do
    [ "$(tr -d '[:space:]' < "$dir/$f")" = "$old" ] || continue
    printf '%s\n' "$new" > "$dir/$f"; echo "  $f"
  done < <(git -C "$dir" ls-files '.nvmrc' '*/.nvmrc')
  while IFS= read -r f; do
    perl -pi -e "s/\\bnode:${old_re}-/node:${new}-/g" "$dir/$f"; echo "  $f"
  done < <(git -C "$dir" grep -lE "node:${old_re}-" -- ':!*.md' || true)
  while IFS= read -r f; do
    perl -pi -e "s/\">=${old_re}\\.0 <${old_next//./\\.}\\.0\"/\">=${new}.0 <${new_next}.0\"/g" "$dir/$f"; echo "  $f"
  done < <(git -C "$dir" grep -lF "\">=${old}.0 <${old_next}.0\"" -- 'package.json' '*/package.json' 'package-lock.json' '*/package-lock.json' || true)
}

if [ -n "$REWRITE_DIR" ]; then
  [ -n "$TO" ] || die "--rewrite-only needs --to"
  [ -n "$FROM" ] || FROM="$(tr -d '[:space:]' < "$REWRITE_DIR/.nvmrc")"
  if ! valid_minor "$FROM" || ! valid_minor "$TO"; then die "minors must look like 26.12 (from '$FROM', to '$TO')"; fi
  [ "$FROM" != "$TO" ] || { echo "advance-node: $REWRITE_DIR is already on $TO"; exit 0; }
  echo "advance-node: $REWRITE_DIR $FROM -> $TO"
  rewrite_repo "$REWRITE_DIR" "$FROM" "$TO"
  exit 0
fi

git -C "$CI_DIR" fetch -q origin main
FROM="$(git -C "$CI_DIR" show origin/main:.nvmrc | tr -d '[:space:]')"
valid_minor "$FROM" || die "RealityEngine_CI's .nvmrc on origin/main is '$FROM', not a minor"
[ -n "$TO" ] || TO="$(newest_minor "${FROM%%.*}")" || die "could not read the newest Node ${FROM%%.*}.x from nodejs.org"
valid_minor "$TO" || die "--to '$TO' is not a minor like 26.12"
BRANCH="chore/node-$TO"

echo "Node $FROM -> $TO across: ${REPOS[*]}"
[ "$FROM" != "$TO" ] || echo "  origin/main already pins $TO; only the local side is checked"
for r in "${REPOS[@]}"; do
  [ -d "$WORKSPACE/$r/.git" ] || [ -f "$WORKSPACE/$r/.git" ] || { echo "  $r: not checked out under $WORKSPACE — skipped"; continue; }
  echo "  $r: $(git -C "$WORKSPACE/$r" grep -lE "node:${FROM//./\\.}-" origin/main -- ':!*.md' 2>/dev/null | wc -l | tr -d ' ') image file(s), $(git -C "$WORKSPACE/$r" ls-tree -r --name-only origin/main | grep -cE '(^|/)\.nvmrc$' || true) .nvmrc"
done
if ! $EXECUTE; then
  echo "Plan only. Re-run with --execute to branch ($BRANCH), rewrite, push and open a PR per repo, and move the local nvm install."
  exit 0
fi

WT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/advance-node.XXXXXX")"
if [ "$FROM" != "$TO" ]; then
  for r in "${REPOS[@]}"; do
    repo="$WORKSPACE/$r"; [ -e "$repo/.git" ] || continue
    git -C "$repo" fetch -q origin main
    wt="$WT_ROOT/$r"
    git -C "$repo" worktree add -q -b "$BRANCH" "$wt" origin/main
    echo "== $r"
    rewrite_repo "$wt" "$FROM" "$TO"
    if git -C "$wt" diff --quiet; then
      echo "  nothing pins $FROM here"
    else
      git -C "$wt" commit -qam "Node $TO: advance the one-minor pin from $FROM"
      git -C "$wt" push -q -u origin "$BRANCH"
      (cd "$wt" && gh pr create --base main --head "$BRANCH" --title "Node $TO: advance the one-minor pin from $FROM" \
        --body "Moves every Node $FROM pin in this repo to $TO, with the rest of the workspace (RealityEngine_CI \`scripts/advance-node.sh\`). Supersedes any Dependabot node-image PR for $TO.")
    fi
    git -C "$repo" worktree remove "$wt"
  done
fi

# Local side: the nvm install other shells and launchd jobs pick up.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] || die "nvm not found at $NVM_DIR — install it, then re-run"
set +u; . "$NVM_DIR/nvm.sh" --no-use
prev_default="$(nvm version default 2>/dev/null || true)"
nvm install "$TO" >/dev/null
nvm alias default "$TO" >/dev/null; nvm alias stable "$TO" >/dev/null
nvm use "$TO" >/dev/null
case "$prev_default" in v"$TO".*|""|N/A) ;; *) nvm reinstall-packages "$prev_default" >/dev/null ;; esac
set -u
echo "local: nvm default -> $(node -v) (global packages carried from ${prev_default:-none})"

# localOpenClawStack's operator .env pins NODE_IMAGE by digest.
env_file="$WORKSPACE/localOpenClawStack/.env"
if [ -f "$env_file" ] && command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  ref="node:$TO-bookworm-slim"
  docker pull -q "$ref" >/dev/null
  digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$ref")"
  [[ "$digest" == *@sha256:* ]] || die "could not resolve a digest for $ref"
  cp -p "$env_file" "$env_file.bak-node-$FROM"
  perl -pi -e "s|^NODE_IMAGE=.*|NODE_IMAGE=$digest|" "$env_file"
  echo "local: localOpenClawStack .env NODE_IMAGE -> $digest ($ref; previous kept in .env.bak-node-$FROM)"
else
  echo "local: localOpenClawStack .env NODE_IMAGE not re-pinned (no .env or Docker not running)"
fi
rmdir "$WT_ROOT" 2>/dev/null || true
