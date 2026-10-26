#!/usr/bin/env bash
# The run manifest's hostServices must see an nvm-installed openclaw (#592).
#
# regression-test.sh recorded OpenClaw as "missing" in a run in which it passed:
# the manifest's `host-check --json` ran in the harness's own shell, whose PATH is
# the terminal's, and openclaw lives under the pinned Node's nvm directory. Every
# other step that needs that Node runs under NODE_ACTIVATE; this one now does too.
#
# The fake nvm puts a stub openclaw and node on PATH only after `nvm use`, so the
# probe finds them through NODE_ACTIVATE or not at all.
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }

# A fake nvm: `nvm use <v>` prepends the version's bin directory to PATH.
NVMBIN="$T/nvm/versions/node/v26.12.1/bin"
mkdir -p "$NVMBIN" "$T/run"
cat > "$T/nvm/nvm.sh" <<EOF
nvm() { case "\$1" in use) PATH="$NVMBIN:\$PATH"; export PATH ;; *) : ;; esac; return 0; }
EOF
cat > "$NVMBIN/node" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo v26.12.1; exit 0; }
[ -f "${1:-}" ] && { echo "OpenClaw 2026.10.7 (stub)"; exit 0; }
exit 0
EOF
printf '#!/usr/bin/env node\n' > "$NVMBIN/openclaw"
chmod +x "$NVMBIN/node" "$NVMBIN/openclaw"

# The two definitions under test, as regression-test.sh has them.
defs="$(sed -n '/^NODE_ACTIVATE=/,/fi; '"'"'$/p' "$CI_DIR/scripts/regression-test.sh"; sed -n '/^host_services_manifest_json() {/,/^}/p' "$CI_DIR/scripts/regression-test.sh")"
[ -n "$defs" ] || { echo "  FAIL definitions not found"; exit 1; }

run() { # a PATH with no nvm node on it, as the harness's shell has
  env -i HOME="$T" PATH="/usr/bin:/bin:/usr/sbin:/sbin" NVM_DIR="$T/nvm" NODE_VERSION=26.12.1 \
    RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 \
    CI_DIR="$CI_DIR" RUN_DIR="$T/run" /bin/bash -c "$defs"'
    host_services_manifest_json'
}

echo "manifest hostServices"
out="$(run)"
printf '%s' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["openclaw"]["installed"]=="2026.10.7", d["openclaw"]; assert d["node"]["installed"]=="26.12.1", d["node"]' \
  && ok "openclaw 2026.10.7 on Node 26.12.1 is recorded, found through NODE_ACTIVATE" || bad "openclaw not recorded: $out"

# Control: without the activation the same probe cannot see it (the bug).
ctl="$(env -i HOME="$T" PATH="/usr/bin:/bin:/usr/sbin:/sbin" REALITYENGINE_DIR="$T/run2" RE_LATEST_OLLAMA=0.40.8 RE_LATEST_OPENCLAW=2026.10.7 RE_HOST_UPDATE_ISSUES=0 "$CI_DIR/release/realityengine" host-check --json 2>/dev/null || true)"
printf '%s' "$ctl" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["openclaw"]["status"]=="missing", d["openclaw"]' \
  && ok "control: the unactivated shell reports it missing (the original defect)" || bad "control did not reproduce the defect"

[ "$fails" -eq 0 ] && { echo "all ok"; exit 0; }
echo "$fails failure(s)"; exit 1
