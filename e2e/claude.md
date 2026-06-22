# RealityEngine_CI E2E Guidance

This directory contains full-stack tests for the composed RealityEngine application.

- Prefer tests that consume `RE_REGISTRY_URL` and active engine metadata.
- Keep OpenClaw, Manager, Machines, and byte-equivalence assertions separated.
- Capture evidence without assuming generated reports should be committed.
- When failures diverge by engine, compare C++, LSP, and Scala payload identity before byte equality.

