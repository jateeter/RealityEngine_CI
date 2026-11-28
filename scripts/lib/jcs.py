"""RFC 8785 JSON Canonicalization Scheme (JCS), and the re-snapshot/1 digest.

The engines serialize snapshots and K-line bundles with JCS (SURFACE_SPEC "The
snapshot body": "Serialization: RFC 8785 (JCS) throughout"). A harness that
builds a snapshot body to restore (a near-miss re-established in a sandbox,
RealityEngine_CI#605) must compute the same digest, so numbers are written as
ECMAScript writes them: the shortest round-trip digits, positional between
1e-7 and 1e21, exponential outside it.
"""

from __future__ import annotations

import hashlib
import json
import math
from typing import Any


def number(x: float | int) -> str:
    if isinstance(x, bool):
        raise TypeError("a bool is not a number")
    if isinstance(x, int) and abs(x) < 2 ** 53:
        return str(x)
    f = float(x)
    if math.isnan(f) or math.isinf(f):
        raise ValueError("JCS has no NaN or Infinity")
    if f == 0:
        return "0"
    if f == int(f) and abs(f) < 1e21:
        return str(int(f))
    r = repr(f)  # shortest round-trip digits
    mantissa, _, exp = r.partition("e")
    digits = mantissa.replace("-", "").replace(".", "").lstrip("0") or "0"
    # The decimal exponent n of 0.d1d2...dk x 10^n, as ECMAScript's Number::toString defines it.
    if exp:
        point = mantissa.replace("-", "").find(".")
        lead = len(mantissa.replace("-", "")) if point < 0 else point
        n = int(exp) + lead
    else:
        body = mantissa.replace("-", "")
        intpart, _, frac = body.partition(".")
        if intpart.strip("0"):
            n = len(intpart.lstrip("0"))
        else:
            n = -(len(frac) - len(frac.lstrip("0")))
    digits = digits.rstrip("0") or "0"
    k = len(digits)
    sign = "-" if f < 0 else ""
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    e = n - 1
    return sign + digits[0] + ("." + digits[1:] if k > 1 else "") + "e" + ("+" if e > 0 else "-") + str(abs(e))


def dumps(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(dumps(v) for v in value) + "]"
    if isinstance(value, dict):
        # Keys ordered by their UTF-16 code units, as RFC 8785 requires.
        keys = sorted(value, key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + dumps(value[k]) for k in keys) + "}"
    raise TypeError(f"not JSON: {type(value).__name__}")


def snapshot_digest(body: dict) -> str:
    """sha256:<hex> over BODY without digest and the clocks' instance and lamport."""
    copy = json.loads(json.dumps(body))
    copy.pop("digest", None)
    for end in ("from", "to"):
        clock = (((copy.get("kline") or {}).get("clocks") or {}).get(end))
        if isinstance(clock, dict):
            clock.pop("instance", None)
            clock.pop("lamport", None)
    return "sha256:" + hashlib.sha256(dumps(copy).encode("utf-8")).hexdigest()
