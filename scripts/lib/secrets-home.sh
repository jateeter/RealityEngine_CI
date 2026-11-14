#!/usr/bin/env bash
# secrets-home.sh — the suite's one secrets home (owner, 2026-11-14).
#
# Every secret a build path needs lives once per machine, outside every
# repository, one directory per repository:
#
#   $RE_SECRETS_DIR/<repo>/                      (RE_SECRETS_DIR set)
#   $RE_INSTANCE_STATE_DIR/secrets/<repo>/       (the suite's state root)
#   ~/.reality-engine/secrets/<repo>/            (the default)
#
# Outside every repository, so no path can commit it; one place, so the
# operator's checkout, regression-test.sh's cold-start worktrees, startUniverse.sh
# run by hand and any other worktree read the same files. Before this, secrets
# lived in each checkout's gitignored .secrets/, and a worktree that did not have
# them could not use state another checkout had created with them (the asset
# stack's pod store, 2026-11-12/14) or minted a different value (the HealthKit
# bridge token a paired iPhone holds).
#
# regression-test.sh resolves and exports RE_SECRETS_DIR, so everything it starts
# agrees. localAssetStorageStack resolves the same directory in
# scripts/lib/secrets-home.js. Directories 0700, files 0600. An old in-checkout
# copy is migrated with re_secret_copy_verified and never deleted.
#
#   source scripts/lib/secrets-home.sh
#   re_secrets_dir                 # prints the home
#   re_secrets_repo_dir <repo>     # prints <home>/<repo>, created 0700
#   re_secret_copy_verified <src> <dst>   # copy once, 0600, verify; keeps src

re_secrets_dir() {
  if [ -n "${RE_SECRETS_DIR:-}" ]; then
    printf '%s\n' "$RE_SECRETS_DIR"
  else
    printf '%s/secrets\n' "${RE_INSTANCE_STATE_DIR:-$HOME/.reality-engine}"
  fi
}

re_secrets_repo_dir() {
  local dir
  dir="$(re_secrets_dir)/$1"
  ( umask 077; mkdir -p "$dir" )
  chmod 700 "$(re_secrets_dir)" "$dir"
  printf '%s\n' "$dir"
}

# Copy <src> to <dst> when <dst> does not exist yet, 0600, and verify it byte for
# byte. Returns 1 (and leaves no <dst>) when the copy does not verify. <src> is
# never removed: the operator deletes old copies.
re_secret_copy_verified() {
  local src="$1" dst="$2"
  [ -e "$dst" ] && return 0
  ( umask 177; cp "$src" "$dst" )
  chmod 600 "$dst"
  if ! cmp -s "$src" "$dst"; then
    rm -f "$dst"
    echo "secrets-home: copying $src to $dst did not verify; nothing was moved" >&2
    return 1
  fi
}
