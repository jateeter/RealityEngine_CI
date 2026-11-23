#!/usr/bin/env bash
# go-toolchain.sh: the Go toolchain RealityEngine_GO is built with
# (docs/BUILD_CONTROL_CONTRACT.md, RealityEngine_CI#836).
#
# One Go version for every lane: the one in RealityEngine_GO's .go-version,
# which go.mod's `go` line repeats. The build never lets Go fetch another
# toolchain (GOTOOLCHAIN=local), so what built the artifact is what the pin
# says, or the build is refused, as JDK 25 is held for Scala.
#
#   source scripts/lib/go-toolchain.sh
#   go_bin <RealityEngine_GO dir>    # prints the go binary, or fails naming why
#   go_build_engines <dir>           # builds bin/reality-engine, bin/perception-engine
#
# Where the pinned Go is looked for, in order: `go` on PATH, then
# $GO_SDK_DIR/go<version>/bin/go (default ~/sdk), the layout of go.dev's
# archives and of golang.org/dl.

go_pinned_version() {  # go_pinned_version <dir>
  local file="$1/.go-version"
  [ -f "$file" ] || { echo "go-toolchain: no .go-version in $1" >&2; return 1; }
  tr -d '[:space:]' < "$file"
}

go_bin() {  # go_bin <dir>
  local want candidate have
  want="$(go_pinned_version "$1")" || return 1
  for candidate in "$(command -v go 2>/dev/null || true)" "${GO_SDK_DIR:-$HOME/sdk}/go$want/bin/go"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    have="$(GOTOOLCHAIN=local "$candidate" env GOVERSION 2>/dev/null || true)"
    if [ "$have" = "go$want" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "go-toolchain: Go $want (RealityEngine_GO .go-version) is not installed." >&2
  echo "  Install it from https://go.dev/dl/ (go$want.darwin-arm64.tar.gz, checksum verified)" >&2
  echo "  into ${GO_SDK_DIR:-$HOME/sdk}/go$want, or put that version's go on PATH." >&2
  return 1
}

go_build_engines() {  # go_build_engines <dir>
  local dir="$1" go
  go="$(go_bin "$dir")" || return 1
  (cd "$dir" && mkdir -p bin &&
    GOTOOLCHAIN=local "$go" build -trimpath -o bin/reality-engine ./cmd/reality-engine &&
    GOTOOLCHAIN=local "$go" build -trimpath -o bin/perception-engine ./cmd/perception-engine)
}
