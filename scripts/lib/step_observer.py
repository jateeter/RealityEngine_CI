"""Observe a step at its completion point, never by elapsed time (RealityEngine_CI#375).

Every runtime composes a step's machines in parallel, joins every composer, and
only then resolves OSRE(n) atomically; the committed (ISRE(n), OSRE(n)) pair is
published through the runtime's own synchronisation primitive and served by

    GET {re}/api/engine/steps/{n}/pair?timeoutMs=W

which waits on that primitive for up to W ms (SURFACE_SPEC.md, "Step
completion"). This module is the observer's half: it waits for the pair rather
than sleeping (`--settle-ms` is gone), keeps the pairs it has seen keyed by step
number, and checks the steps it was told to expect arrive in order with nothing
in between.

A step number the observer did not cause — a push from another app instance, a
retained MQTT delivery — breaks contiguity, and is reported as an exclusivity
violation naming the step, never as an engine divergence
(docs/OBSERVATION_EXCLUSIVITY.md).

No HTTP of its own: the caller passes its GET, so each stage keeps its own
timeouts and error shape, as with reset_contract.py.
"""

from __future__ import annotations

from typing import Any, Callable

Json = dict[str, Any]
Getter = Callable[[str], tuple[int, Any]]

# The window an observer waits for a pair. Matches the route's default; the
# route refuses anything above 60000.
DEFAULT_WINDOW_MS = 5000


class StepNotResolved(Exception):
    """Step n did not resolve within the window (the route's 408)."""


class StepNotRetained(Exception):
    """Step n resolved but is no longer retained (the route's 410)."""


class StepObserver:
    """The (ISRE, OSRE) pairs one engine committed, keyed by step number."""

    def __init__(self, get: Getter, re_url: str, window_ms: int = DEFAULT_WINDOW_MS):
        self._get = get
        self._re = re_url.rstrip("/")
        self.window_ms = window_ms
        self.pairs: dict[int, tuple[Json, Json]] = {}
        self.last_step: int | None = None
        self.violations: list[str] = []

    def await_pair(self, step: int) -> tuple[Json, Json]:
        """Wait for step `step`'s pair, record it, and return (isre, osre)."""
        status, payload = self._get(
            f"{self._re}/api/engine/steps/{step}/pair?timeoutMs={self.window_ms}")
        if status == 408:
            raise StepNotResolved(f"step {step} not resolved within {self.window_ms} ms")
        if status == 410:
            raise StepNotRetained(f"step {step} is no longer retained")
        if status != 200 or not isinstance(payload, dict):
            raise RuntimeError(f"GET /api/engine/steps/{step}/pair returned {status}")
        if payload.get("stepNumber") != step:
            raise RuntimeError(
                f"GET /api/engine/steps/{step}/pair answered step {payload.get('stepNumber')}")
        pair = (payload["isre"], payload["osre"])
        self.pairs[step] = pair
        return pair

    def observe_push(self, push_response: Any) -> tuple[Json, Json]:
        """The pair for the step a push caused, read from its `step.stepNumber`.

        The push names the RE step it produced; the observer waits for that
        step's pair at its completion point and checks it follows the last one
        directly. A gap means a step the observer did not cause ran between
        two of its own — an interloper — and is recorded by number.
        """
        step = None
        if isinstance(push_response, dict) and isinstance(push_response.get("step"), dict):
            step = push_response["step"].get("stepNumber")
        if not isinstance(step, int):
            raise RuntimeError("push response carries no step.stepNumber to observe")
        if self.last_step is not None and step != self.last_step + 1:
            between = list(range(self.last_step + 1, step))
            self.violations.append(
                f"step(s) {between} ran between this observer's steps {self.last_step} and "
                f"{step}: another app instance stepped the engine (RealityEngine_CI#307)"
                if between else
                f"step {step} does not follow {self.last_step}: the engine's step numbering "
                f"went backwards or repeated — a reset or a concurrent driver")
        self.last_step = step
        return self.await_pair(step)
