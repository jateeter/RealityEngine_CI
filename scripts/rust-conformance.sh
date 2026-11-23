#!/usr/bin/env bash
# rust-conformance.sh: the follower lane for RealityEngine_Rust, kept as a name
# (docs, runbooks and older invocations use it). The lane is
# scripts/follower-conformance.sh, which holds any follower against the voters;
# this is `--follower rust` with every other argument passed through, including
# --rust-repo DIR.
exec bash "$(dirname "${BASH_SOURCE[0]}")/follower-conformance.sh" --follower rust "$@"
