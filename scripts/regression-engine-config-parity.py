#!/usr/bin/env python3
"""
regression-engine-config-parity.py — compare runtime configuration across engines.

`/api/engine/config` exists so configuration can be compared. Nothing compared
it. `historyLimit` was 256 on C++, 250 on LSP and 1000 on Scala for as long as
anyone had looked, and the reason nothing noticed is that no stage could ask all
three what their controls were (RealityEngine_CI#271).

This is that stage. It asserts three things, in order, because each is
meaningless without the one before it:

  1. every runtime carries the universal control set
  2. every runtime declares the specification's default for each of them
  3. the runtimes agree with each other

Order matters. Three runtimes that all omit a control agree perfectly about
nothing, and three that agree on a default the specification does not declare
have converged on the wrong answer — which a runtime-to-runtime comparison alone
reports as a pass.

**The declaration is parsed from SURFACE_SPEC.md**, never restated here. A gate
carrying its own copy of the contract is a second contract: it goes green when
the runtimes match the copy, which is not the same as matching the
specification, and the two drift in exactly the way this pathway exists to
catch.

Quorum is 3-of-3 (docs/QUORUM_CONTRACT.md). A runtime that does not answer is
not agreement, and the composition is reported up front so a two-runtime run is
never read as parity.

Usage:
  python3 scripts/regression-engine-config-parity.py
  python3 scripts/regression-engine-config-parity.py --registry http://127.0.0.1:5999/re-registry.json
  python3 scripts/regression-engine-config-parity.py --json report.json
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib import error, request

CI_DIR = Path(__file__).resolve().parent.parent
SPEC = CI_DIR / "SURFACE_SPEC.md"

UNIVERSAL_HEADING = "##### The universal control set"
INSTRUMENTATION_HEADING = "##### Not every control is universal, and the difference must be sayable"


def parse_declared_controls(spec_path: Path) -> dict[str, dict]:
    """The universal control set, read from the table SURFACE_SPEC declares.

    Located by heading rather than by position. `generate.py::_section` records
    what positional parsing of this document cost: an unrelated edit shifted
    every index by one, the RE document generated from prose, and nothing
    noticed for two months because the audit compared generated output with
    generated output.

    An empty parse is a parser failure, not a specification with no controls,
    and is raised rather than returned — a gate that silently checks nothing is
    the failure this whole pathway exists to remove.
    """
    text = spec_path.read_text()
    if UNIVERSAL_HEADING not in text:
        raise SystemExit(
            f"{spec_path.name}: heading not found: {UNIVERSAL_HEADING!r}\n"
            "  The universal control set is declared under that heading.\n"
            "  If it was renamed, update UNIVERSAL_HEADING to match."
        )
    section = text.split(UNIVERSAL_HEADING, 1)[1]
    # Up to the next heading of any level, so a new subsection cannot silently
    # extend the table's reach.
    section = re.split(r"^#{1,6}\s", section, maxsplit=1, flags=re.M)[0]

    controls: dict[str, dict] = {}
    for line in section.splitlines():
        m = re.match(
            r"^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|",
            line,
        )
        if not m:
            continue
        name, scope, default, mutable = m.groups()
        controls[name] = {
            "scope": scope,
            "default": _literal(default),
            "mutable": _literal(mutable),
        }

    if not controls:
        raise SystemExit(
            f"{spec_path.name}: no controls parsed under {UNIVERSAL_HEADING!r}\n"
            "  Expected rows of the form: | `name` | `scope` | `default` | `mutable` | … |"
        )
    return controls


def _literal(token: str):
    if token == "true":
        return True
    if token == "false":
        return False
    if re.fullmatch(r"-?\d+", token):
        return int(token)
    return token


def read_registry(source: str) -> list[dict]:
    """The instance registry, from a URL or a path.

    The regression stage passes the file the universe wrote
    (/tmp/re-registry/re-registry.json); urlopen alone rejected it as
    "unknown url type" and the stage failed without comparing anything.
    Same reader as regression-machine-set-parity.py.
    """
    if source.startswith(("http://", "https://")):
        with request.urlopen(source, timeout=30) as response:
            return json.loads(response.read().decode("utf-8")).get("instances", [])
    return json.loads(Path(source).read_text(encoding="utf-8")).get("instances", [])


def read_config(base: str) -> tuple[dict | None, str | None]:
    """The control document, or a reason it could not be read.

    A 404 is a conformance fact — this runtime does not implement the pathway —
    and is reported as such rather than as a transport error, because the two
    call for different work.
    """
    try:
        with request.urlopen(f"{base}/api/engine/config", timeout=300) as response:
            return json.loads(response.read().decode("utf-8")), None
    except error.HTTPError as exc:
        if exc.code == 404:
            return None, "does not implement GET /api/engine/config"
        return None, f"HTTP {exc.code}"
    except (error.URLError, OSError, ValueError) as exc:
        return None, f"{type(exc).__name__}: {exc}"


def summarise_value(control: dict) -> object:
    """What may be compared across runtimes for this control's value.

    For `scope: engine` that is the value itself. For `scope: machine` it is the
    entry count and the distribution — never the keys, which are machine ids and
    are minted per runtime, so the same machine is `machine-1789677668723-235803635`
    on C++ and `machine-1U4PASL-6KJA1USAFM6O` on LSP. Comparing them would
    require an equality id generation forbids (SURFACE_SPEC, "Byte equivalence
    applies"; RealityEngine_CI#397).
    """
    if control.get("scope") != "machine":
        return control.get("value")
    value = control.get("value") or {}
    if not isinstance(value, dict):
        return {"malformed": repr(value)[:80]}
    counts: dict[str, int] = {}
    for v in value.values():
        counts[json.dumps(v, sort_keys=True)] = counts.get(json.dumps(v, sort_keys=True), 0) + 1
    return {"entries": len(value), "distribution": dict(sorted(counts.items()))}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry",
                    default=os.environ.get("RE_REGISTRY_URL",
                                           "http://127.0.0.1:5999/re-registry.json"))
    ap.add_argument("--json", help="Write the full report to this path.")
    args = ap.parse_args()

    declared = parse_declared_controls(SPEC)
    print(f"declared universal controls (from {SPEC.name}): {', '.join(sorted(declared))}")

    try:
        instances = read_registry(args.registry)
    except Exception as exc:  # noqa: BLE001 — the registry being unreachable is the message
        print(f"instance registry unreadable at {args.registry}: {exc}", file=sys.stderr)
        sys.exit(2)

    report: dict = {"quorum_composition": [i["id"] for i in instances],
                    "declared": declared, "runtimes": {}, "findings": []}
    print(f"quorum composition: {', '.join(report['quorum_composition']) or '(empty)'}")

    configs: dict[str, dict] = {}
    for inst in instances:
        doc, why = read_config(inst["re_url"])
        if doc is None:
            report["runtimes"][inst["id"]] = {"unreadable": why}
            report["findings"].append(f"{inst['id']}: {why}")
            continue
        controls = {c["name"]: c for c in doc.get("controls", []) if isinstance(c, dict) and "name" in c}
        configs[inst["id"]] = controls
        report["runtimes"][inst["id"]] = {"controls": sorted(controls)}

    # A runtime that did not answer is not agreement. Refuse rather than compare
    # the remainder and print a verdict that reads like parity.
    if len(configs) < len(instances) or len(configs) < 2:
        print("\nQUORUM NOT FORMED — not comparing")
        for line in report["findings"]:
            print(f"  ✗ {line}")
        _write(args.json, report)
        sys.exit(1)

    failures = 0

    # 1. Presence. Checked before agreement: three runtimes that all omit a
    #    control agree perfectly about nothing.
    print("\n1. every runtime carries the universal set")
    for name in sorted(declared):
        missing = [rid for rid, controls in configs.items() if name not in controls]
        if missing:
            failures += 1
            line = f"{name}: absent on {', '.join(sorted(missing))}"
            report["findings"].append(line)
            print(f"  ✗ {line}")
        else:
            print(f"  ✓ {name}")

    # 2. Conformance to the declaration. Before runtime-to-runtime agreement,
    #    because three runtimes agreeing on an undeclared default have converged
    #    on the wrong answer and a mutual comparison calls that a pass.
    print("\n2. every runtime declares the specification's default")
    for name, spec in sorted(declared.items()):
        for field in ("scope", "default", "mutable"):
            wrong = {rid: controls[name].get(field)
                     for rid, controls in configs.items()
                     if name in controls and controls[name].get(field) != spec[field]}
            if wrong:
                failures += 1
                line = (f"{name}.{field}: specification declares {spec[field]!r}; "
                        + ", ".join(f"{rid} reports {v!r}" for rid, v in sorted(wrong.items())))
                report["findings"].append(line)
                print(f"  ✗ {line}")
    if not any("specification declares" in f for f in report["findings"]):
        print(f"  ✓ all {len(declared)} controls match the declaration on every runtime")

    # 3. Mutual agreement, including the current values.
    print("\n3. the runtimes agree with each other")
    for name in sorted(declared):
        present = {rid: c[name] for rid, c in configs.items() if name in c}
        if len(present) < 2:
            continue
        values = {rid: summarise_value(c) for rid, c in present.items()}
        distinct = {json.dumps(v, sort_keys=True) for v in values.values()}
        if len(distinct) > 1:
            failures += 1
            line = f"{name}: value differs — " + ", ".join(
                f"{rid}={json.dumps(v, sort_keys=True)}" for rid, v in sorted(values.items()))
            # A machine-scoped control has one entry per resident machine, so an
            # entry-count difference is a statement about the corpus, not about
            # configuration — and during startup it is a statement about the
            # clock. Observed while writing this stage: Scala reported 1336
            # where the others reported 1338, and ten seconds later all three
            # reported 1338. It was mid-load, and reading it as a Scala defect
            # would have been wrong.
            #
            # Still a failure — the runtimes genuinely disagreed at the moment
            # of measurement — but attributed honestly, so nobody goes looking
            # for a configuration bug that is not there.
            if (present[sorted(present)[0]].get("scope") == "machine"
                    and len({v.get("entries") for v in values.values()
                             if isinstance(v, dict)}) > 1):
                line += ("  [entry counts differ: machine residency, not configuration — "
                         "compare GET /api/machines, and re-run if the universe was still loading]")
            report["findings"].append(line)
            print(f"  ✗ {line}")
        else:
            shown = json.dumps(next(iter(values.values())), sort_keys=True)
            print(f"  ✓ {name} = {shown[:90]}")

    # Controls a runtime carries that the specification does not declare. Not a
    # failure — instrumentation controls are legitimate and declared separately
    # (SURFACE_SPEC, "Not every control is universal") — but reported, because a
    # control nobody declared is how a fourth default gets in.
    extra = {rid: sorted(set(c) - set(declared)) for rid, c in configs.items()}
    extra = {rid: names for rid, names in extra.items() if names}
    if extra:
        print("\n   beyond the universal set (not a failure):")
        for rid, names in sorted(extra.items()):
            print(f"     {rid}: {', '.join(names)}")
        report["beyond_universal"] = extra

    print()
    if failures:
        print(f"FAIL — {failures} configuration finding{'s' if failures != 1 else ''}")
    else:
        print(f"PASS — {len(declared)} universal controls agree across "
              f"{len(configs)} runtimes and match {SPEC.name}")
    _write(args.json, report)
    sys.exit(1 if failures else 0)


def _write(path: str | None, report: dict) -> None:
    if path:
        Path(path).write_text(json.dumps(report, indent=2, sort_keys=True))
        print(f"report: {path}")


if __name__ == "__main__":
    main()
