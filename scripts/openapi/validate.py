#!/usr/bin/env python3
"""
validate.py — assert a generated OpenAPI document is a valid OpenAPI document.

`audit-docs.sh` check 3 asserts the committed documents are *current*: it
regenerates into a temp directory and diffs. That compares generated output
against generated output, so a generator that consistently emits something
broken compares equal to itself and passes forever. Three defects lived in the
output under that check (RealityEngine_CI#403):

  - `#/components/responses/InternalError` referenced 43 times in each PE
    document and defined in none of them
  - `nullable: true` — 3.0 syntax — inside documents declaring 3.1.0
  - `{vectorId}` and `{sequenceId}` templated into Manager paths with no
    parameter declared, which OpenAPI forbids (fixed in #402, found by reading
    the YAML rather than by any check)

This reads the committed documents and checks them against the specification,
which is the independent measurement check 3 lacks. It deliberately does not
import `generate.py`: a validator that shared the generator's idea of the
document would reproduce the generator's blind spots.

Usage:
  python3 scripts/openapi/validate.py docs/openapi/*.yaml
  python3 scripts/openapi/validate.py --quiet docs/openapi/cpp-re.yaml

Exit status is 0 when every document passes and 1 when any check fails.
"""

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def _walk(node, path="#"):
    """Every (json-pointer, value) pair in the document, depth first."""
    yield path, node
    if isinstance(node, dict):
        for k, v in node.items():
            esc = str(k).replace("~", "~0").replace("/", "~1")
            yield from _walk(v, f"{path}/{esc}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk(v, f"{path}/{i}")


def _resolve(doc, ref: str):
    """The node a local $ref names, or None. Non-local refs return None."""
    if not ref.startswith("#/"):
        return None
    node = doc
    for seg in ref[2:].split("/"):
        seg = seg.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and seg in node:
            node = node[seg]
        elif isinstance(node, list) and seg.isdigit() and int(seg) < len(node):
            node = node[int(seg)]
        else:
            return None
    return node


def check_refs(doc) -> list[str]:
    """Every local $ref resolves.

    A dangling $ref is not cosmetic: a client generator or a docs renderer
    resolves references, so a document carrying one does not fully render or
    generate. Reported per distinct target rather than per occurrence — 43
    references to one missing response is one defect, and counting occurrences
    is what made #403's first reading overstate the problem.
    """
    missing: dict[str, int] = {}
    for _, node in _walk(doc):
        if isinstance(node, dict) and isinstance(node.get("$ref"), str):
            ref = node["$ref"]
            if not ref.startswith("#/"):
                missing[f"{ref} (non-local reference)"] = missing.get(ref, 0) + 1
            elif _resolve(doc, ref) is None:
                missing[ref] = missing.get(ref, 0) + 1
    return [f"unresolved $ref {ref} ({n} reference{'s' if n != 1 else ''})"
            for ref, n in sorted(missing.items())]


def check_path_params(doc) -> list[str]:
    """Every `{name}` in a path template has a matching declared parameter.

    OpenAPI requires it, and the failure is silent: the templated segment simply
    has no documented meaning, so a generated client takes no argument for it.
    Parameters may be declared on the path item or on the operation, and either
    may be a $ref, so all three are resolved before comparing.
    """
    errors = []
    for path, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        templated = set(re.findall(r"\{([^}/]+)\}", path))
        if not templated:
            continue
        shared = _declared_names(doc, item.get("parameters"))
        for method, op in item.items():
            if method.lower() not in HTTP_METHODS or not isinstance(op, dict):
                continue
            declared = shared | _declared_names(doc, op.get("parameters"))
            for name in sorted(templated - declared):
                errors.append(
                    f"{method.upper()} {path}: path template {{{name}}} has no "
                    f"declared parameter")
    return errors


def _declared_names(doc, params) -> set[str]:
    names = set()
    for p in params or []:
        if isinstance(p, dict) and "$ref" in p:
            p = _resolve(doc, p["$ref"])
        if isinstance(p, dict) and p.get("in") == "path" and "name" in p:
            names.add(p["name"])
    return names


def check_version_keywords(doc) -> list[str]:
    """Keywords used must exist in the version the document declares.

    `nullable` was removed in OpenAPI 3.1, which models an optional value as a
    union with the null type. A 3.1 parser does not error on the leftover
    keyword — it ignores it — so the schema silently stops saying the field can
    be null. Checked against the declared version rather than assumed: the two
    RealityEngine_AI documents in this directory declare 3.0.3, where `nullable`
    is correct, and flagging those would be wrong.
    """
    version = str(doc.get("openapi", ""))
    if not version.startswith("3.1"):
        return []
    hits = [p for p, node in _walk(doc)
            if isinstance(node, dict) and "nullable" in node]
    return [f"`nullable` at {p} — removed in OpenAPI 3.1, "
            f"use `type: [<type>, 'null']`" for p in sorted(hits)]


def check_structure(doc) -> list[str]:
    """The document is shaped like an OpenAPI document and says something.

    The empty-paths case is here because an empty `paths` map is *valid*
    OpenAPI, so nothing downstream objects to it — which is how the RE document
    generated 0 routes from prose for two months (see `generate.py::_section`).
    Valid and empty is the shape a parser failure takes, so this treats it as an
    error rather than a document with nothing to say.
    """
    errors = []
    version = doc.get("openapi")
    if not isinstance(version, str) or not re.match(r"^3\.[01]\.\d+$", version):
        errors.append(f"openapi: {version!r} is not a 3.0.x or 3.1.x version string")

    info = doc.get("info")
    if not isinstance(info, dict):
        errors.append("info: missing")
    else:
        for field in ("title", "version"):
            if not info.get(field):
                errors.append(f"info.{field}: missing or empty")

    paths = doc.get("paths")
    if not isinstance(paths, dict):
        errors.append("paths: missing")
    elif not paths:
        errors.append("paths: empty — a document describing no routes is what a "
                      "parser failure looks like, not a surface with no routes")
    return errors


def check_operations(doc) -> list[str]:
    """Every operation declares responses, and operationIds do not collide.

    `responses` is required by the specification. `operationId` is *not* — it is
    optional, and an absent one is not a defect. Only its uniqueness is a MUST,
    and it is the half that matters here: `generate.py` derives ids by slugifying
    the path, so two paths differing only in punctuation would produce one id,
    which parsers accept and every generated client then collapses into a single
    method with one route unreachable.

    Checking presence instead of uniqueness is a mistake worth recording,
    because it fails correct documents: this validator's first run flagged 60
    operations across the two RealityEngine_AI documents, which are valid 3.0.3
    and simply do not use the optional field.
    """
    errors = []
    seen: dict[str, str] = {}
    for path, item in (doc.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        for method, op in item.items():
            if method.lower() not in HTTP_METHODS or not isinstance(op, dict):
                continue
            where = f"{method.upper()} {path}"
            if not op.get("responses"):
                errors.append(f"{where}: no responses declared")
            oid = op.get("operationId")
            if oid:
                if oid in seen:
                    errors.append(
                        f"{where}: operationId {oid!r} already used by {seen[oid]}")
                else:
                    seen[oid] = where
    return errors


CHECKS = (
    ("structure",        check_structure),
    ("$ref resolution",  check_refs),
    ("path parameters",  check_path_params),
    ("version keywords", check_version_keywords),
    ("operations",       check_operations),
)


def validate(path: Path, quiet: bool) -> int:
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        print(f"  \033[31m✗\033[0m {path.name}: not parseable as YAML — {e}")
        return 1
    if not isinstance(doc, dict):
        print(f"  \033[31m✗\033[0m {path.name}: top level is not a mapping")
        return 1

    errors = []
    for name, check in CHECKS:
        errors.extend(f"[{name}] {e}" for e in check(doc))

    if errors:
        print(f"  \033[31m✗\033[0m {path.name}: {len(errors)} problem"
              f"{'s' if len(errors) != 1 else ''}")
        for e in errors:
            print(f"      {e}")
        return 1

    if not quiet:
        n_paths = len(doc.get("paths") or {})
        print(f"  \033[32m✓\033[0m {path.name}: valid OpenAPI "
              f"{doc.get('openapi')} ({n_paths} paths)")
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--quiet", action="store_true",
                    help="Print only failures.")
    args = ap.parse_args()

    failed = 0
    for f in args.files:
        if not f.is_file():
            print(f"  \033[31m✗\033[0m {f}: not a file")
            failed += 1
            continue
        failed += validate(f, args.quiet)

    if failed:
        print(f"\n{failed} document{'s' if failed != 1 else ''} failed validation")
        sys.exit(1)


if __name__ == "__main__":
    main()
