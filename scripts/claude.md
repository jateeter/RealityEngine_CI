# RealityEngine_CI Scripts Guidance

This directory contains operational helpers for startup, testing, OpenAPI, and visualizer workflows.

- Keep script defaults aligned with `startUniverse.sh` and the root application map.
- Prefer explicit `RE_REGISTRY_URL`, `RE_BASE_URL`, `PE_BASE_URL`, `VIZ_BASE_URL`, and `VIZ_FRONTEND_URL`.
- Preserve compatibility with native multi-engine runs.
- Use `bash-language-server` for shell changes.

