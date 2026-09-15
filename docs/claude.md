# RealityEngine_CI Docs Guidance

This directory documents application orchestration, deployment, APIs, and integration architecture.

- Update docs when `startUniverse.sh`, registry shape, OpenClaw/localAI wiring, or e2e commands change.
- Keep generated OpenAPI docs distinct from hand-written architecture notes.
- Link back to `/Users/johnt/workspace/GitHub/claude.md` for the current application map.
- Use markdown LSP support for structural edits.

## Standing rules — authoritative in `../docs/ENGINEERING_CONTRACT.md`

These apply here and are **not** restated in this file. They were previously
copied into eighteen `claude.md` files across six repositories, which is the
duplication problem the rules themselves warn about: copies drift, a rule added
to one applies only where someone looked, and with no authority a reader cannot
tell which copy is current.

| Rule | In short |
| --- | --- |
| Qualify every "registry" | Never the bare word — instance / machine / cesgen / arbitration / domain / semantic-bus / tag. |
| Verify a merge beyond the hosted checks | A green PR is not a verified PR; the hosted path cannot reach the integration points. Name what you could not exercise, and record what you noticed but did not chase. |
| Never commit to main | Branch from `origin/main`, PR, verify, squash-merge, clean up. |

Read the contract for the full text, the qualifier table, and the cleanup steps.
