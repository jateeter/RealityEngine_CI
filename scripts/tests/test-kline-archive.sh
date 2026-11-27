#!/usr/bin/env bash
# Unit tests for scripts/lib/kline_archive.py (RealityEngine_CI#603): the K-line
# historical archive. No engines, no network, no Docker: the archive's two HTTP
# calls are replaced in-process by a stub engine that serves bundles the way
# the engines do (header line, then records; sha256 over the body), and the
# archive lives in a scratch directory (RE_KLINE_ARCHIVE_DIR).
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
RE_KLINE_ARCHIVE_DIR="$TMP/archive" python3 - "$CI_DIR/scripts/lib" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import kline_archive as ka

passed = failed = 0
def check(cond, what):
    global passed, failed
    if cond: passed += 1; print(f"  PASS: {what}")
    else: failed += 1; print(f"  FAIL: {what}")

UUID_RE, UUID_PE = "01a2aaaa-0000-7000-8000-00000000a001", "01a2aaaa-0000-7000-8000-00000000a002"
class Engine:
    """Bundles as the engines build them: `since`/`from` inclusive by commit."""
    def __init__(self): self.klines, self.isre, self.exports, self.corrupt = [], [], [], False
    def add(self, commit):
        self.klines.append({"format": "re-kline/1", "id": f"{UUID_RE}:{commit}", "close": {"commit": commit}})
        self.isre.append({"format": "re-isre-composition/1", "re": {"commit": commit}})
    def bundle(self, fmt, source, rows):
        body = "".join(json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n" for r in rows)
        sha = hashlib.sha256(body.encode()).hexdigest()
        if self.corrupt: body = body.replace("re-kline/1", "re-kline/X", 1)
        return json.dumps({"format": fmt, "source": {"instance": source}, "count": len(rows), "sha256": sha}) + "\n" + body
    def post(self, url, payload):
        self.exports.append((url.rsplit("/api/", 1)[1], payload))
        if url.endswith("/api/klines/export"):
            return 200, self.bundle("re-kline-bundle/1", UUID_RE, [r for r in self.klines if r["close"]["commit"] >= payload["since"]])
        return 200, self.bundle("re-isre-bundle/1", UUID_PE, [r for r in self.isre if r["re"]["commit"] >= payload["from"]])
    def get(self, url):
        return {"instance": UUID_RE if url.endswith("/api/engine/clock") else UUID_PE}

eng = Engine()
ka.post_text = lambda url, payload, timeout=300: eng.post(url, payload)
ka.get_json = lambda url, timeout=30: eng.get(url)
inst = {"id": "cpp-1", "runtime": "cpp", "re_url": "https://stub.invalid:1", "pe_url": "https://stub.invalid:2"}
base = ka.root()
check(base == Path(os.environ["RE_KLINE_ARCHIVE_DIR"]), "RE_KLINE_ARCHIVE_DIR names the archive")

for c in (3, 4, 5): eng.add(c)
entries = ka.catalog(base)
r1 = [ka.archive_one(base, entries, inst, k) for k in ("klines", "isre")]
check([r["result"] for r in r1] == ["archived", "archived"], "a first export archives both halves")
check(r1[0]["commits"] == [3, 5] and r1[0]["records"] == 3, "the K-line bundle spans commits 3..5")
check(eng.exports[0] == ("klines/export", {"since": 0}) and eng.exports[1] == ("isre-composition/export", {"from": 0}),
      "an empty catalog exports from commit 0")
f = base / r1[0]["file"]
check(f.is_file() and not (f.stat().st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH)), "an archived bundle is read-only")
check(f.parts[-3] == UUID_RE and f.parts[-2] == "klines", "bundles are kept by participant UUID and kind")
check(len(ka.catalog(base)) == 2, "the catalog holds one line per bundle")

r2 = ka.archive_one(base, ka.catalog(base), inst, "klines")
check(r2["result"] == "nothing new" and eng.exports[-1][1] == {"since": 6}, "a re-run exports from the commit after the newest archived")

for c in (6, 7): eng.add(c)
r3 = ka.archive_one(base, ka.catalog(base), inst, "klines")
check(r3["result"] == "archived" and r3["commits"] == [6, 7], "new records are archived once, nothing twice")

eng.add(8); eng.corrupt = True
before = sorted(p.name for p in (base / UUID_RE / "klines").iterdir())
try:
    ka.archive_one(base, ka.catalog(base), inst, "klines"); refused = False
except ValueError as exc:
    refused = "sha256" in str(exc)
check(refused, "a bundle whose body does not match its sha256 is refused")
check(sorted(p.name for p in (base / UUID_RE / "klines").iterdir()) == before and len(ka.catalog(base)) == 3,
      "a refused bundle writes nothing")
eng.corrupt = False

class A: pass
check(ka.cmd_verify(A()) == 0, "verify accepts every archived bundle")
os.chmod(f, 0o644); f.write_text(f.read_text().replace("re-kline/1", "re-kline/Z", 1))
check(ka.cmd_verify(A()) == 1, "verify catches a bundle changed after it was archived")

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
