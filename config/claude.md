# RealityEngine_CI Config Guidance

This directory holds generated and shared runtime configuration for the integrated universe.

- Keep `integrations.json` compatible with every PE implementation that consumes `INTEGRATIONS_CONFIG`.
- Keep registry/config defaults aligned with `/Users/johnt/workspace/GitHub/claude.md`.
- Treat generated runtime manifests as operational state unless the user explicitly asks to commit them.
- Use JSON schema-aware editing where available.

