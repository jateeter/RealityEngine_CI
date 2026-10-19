#!/usr/bin/env python3
"""Compare two regression runs' measurements, not their stage statuses
(ReleaseRoadmap E2: native lane vs local-containerized at the same commits).

regression-report.py --compare-run compares stage statuses, so two lanes that
pass the same stages compare as identical whatever they measured. This compares
what they measured: every JSON under reports/ and responses/ present in both
runs, with the values that legitimately differ between two runs masked —
timestamps, epochs, UUIDs, origins and ports, paths, run ids, generated ids —
and lists sorted where their order is the instance registry's rather than a
measurement. Prints each file that still differs with its first differing
paths; exits 1 if any does, unless --report-only.

    scripts/compare-lane-runs.py RUN_DIR_A RUN_DIR_B [--report-only]
"""
import json, re, sys
from pathlib import Path

VOLATILE_KEY = re.compile(r"(?i)(at$|time|elapsed|duration|ms$|_ms|latency|url|port|path|dir$|file$|"
                          r"runid|run_id|uuid|lamport|started|pid|log|host|generated|took|seconds|age|"
                          # A header date; a truncated preview (its full body is a
                          # report of its own); the lane's name for itself.
                          r"^date$|Preview$|^lane$)")
MASKS = [
    (re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z?"), "<ts>"),
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "<uuid>"),
    (re.compile(r"https?://[^\s\"/]+"), "<origin>"),
    (re.compile(r"/(Users|private|tmp|app|install|volumes)/[^\s\"]*"), "<path>"),
    (re.compile(r"\b1[0-9]{12}\b"), "<epoch>"),
    (re.compile(r"-[0-9a-f]{8,9}\b"), "-<rand>"),
]
SORT_KEYS = ("instance", "instanceId", "name", "sensorId", "id")


def ikey(x):
    if isinstance(x, dict):
        for k in SORT_KEYS:
            if isinstance(x.get(k), str):
                return x[k]
    return x if isinstance(x, str) else None


def norm(v, key=""):
    if isinstance(v, dict):
        return {k: ("<v>" if VOLATILE_KEY.search(k) and not isinstance(x, (dict, list)) else norm(x, k))
                for k, x in v.items()}
    if isinstance(v, list):
        out = [norm(x, key) for x in v]
        keys = [ikey(x) for x in out]
        if out and all(k is not None for k in keys):
            # Instance order is the instance registry's, not a measurement.
            out = [o for _, o in sorted(zip(keys, out), key=lambda t: (t[0], json.dumps(t[1], sort_keys=True)))]
        return out
    if isinstance(v, int) and v > 10**12:
        return "<epoch>"
    if isinstance(v, str):
        for rx, rep in MASKS:
            v = rx.sub(rep, v)
    return v


def diff(a, b, path="$", out=None):
    out = [] if out is None else out
    if type(a) is not type(b):
        out.append(f"{path}: {str(a)[:80]} != {str(b)[:80]}")
    elif isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}.{k}: only in {'B' if k not in a else 'A'}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: length {len(a)} != {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(f"{path}: {str(a)[:80]} != {str(b)[:80]}")
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    report_only = "--report-only" in sys.argv
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    ra, rb = Path(args[0]), Path(args[1])
    run_ids = re.compile("|".join(re.escape(r.name) for r in (ra, rb)))
    MASKS.insert(0, (run_ids, "<run>"))
    files = sorted({p.relative_to(ra) for d in ("reports", "responses") for p in (ra / d).rglob("*.json")}
                   & {p.relative_to(rb) for d in ("reports", "responses") for p in (rb / d).rglob("*.json")})
    skip = {"reports/regression-comparison.json", "reports/regression-status.json", "reports/images.json"}
    same = differ = 0
    for f in files:
        if str(f) in skip:
            continue
        try:
            a, b = (norm(json.loads((r / f).read_text())) for r in (ra, rb))
        except Exception as e:  # noqa: BLE001
            print(f"UNREADABLE {f}: {e}")
            continue
        d = diff(a, b)
        if d:
            differ += 1
            print(f"DIFF {f} ({len(d)})")
            for line in d[:6]:
                print("     " + line)
        else:
            same += 1
    print(f"\n{same} identical after normalisation, {differ} differ, of {same + differ} shared files")
    return 1 if differ and not report_only else 0


if __name__ == "__main__":
    sys.exit(main())
