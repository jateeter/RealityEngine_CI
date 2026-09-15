# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

## Start Here

- [Why this system exists](https://github.com/jateeter/RealityEngine_CI/wiki/Why-This-System-Exists) states the system's purpose,
  its design commitments, and what it declines to be.
- [System document index](https://github.com/jateeter/RealityEngine_CI/wiki/System-Document-Index) maps the documentation across
  all ten repositories and opens with a reading order for a new reader.

## Authoritative Specifications

- [Deployable system wiki](https://github.com/jateeter/RealityEngine_CI/wiki/Deployable-System-Documentation.md) is the
  primary authoritative documentation surface for the deployable system.
- [Deployment contract](https://github.com/jateeter/RealityEngine_CI/docs/DEPLOYMENT_CONTRACT.md) defines service ownership,
  port ranges, native runtime pairs, required environment names, and deployment
  rules.
- [Integrated specification](https://github.com/jateeter/RealityEngine_CI/docs/INTEGRATED_SPECIFICATION.md) is the cross-repo
  documentation index, audit summary, deployment gate list, and roadmap to full
  integrated specifications.

The CI repository owns the executable deployment contract and tracks the wiki
gitlink used for published system documentation. Runtime-local docs must link
back to these files rather than redefining ports or environment names.

## Deployable System

- [Deployable System Documentation](Deployable-System-Documentation) defines
  the documentation authority model, runtime contract, deployment endpoints,
  environment names, and deployment gates.
- `RealityEngine_CI/DEPLOYMENT_CONTRACT.md` remains the executable service and
  port contract owned by CI.
- `RealityEngine_CI/INTEGRATED_SPECIFICATION.md` records the cross-repo audit,
  validation snapshot, and roadmap.

## Example Machine Corpus

- [Example Machine Compendium](Example-Machine-Compendium) — searchable index of
  all active domains, machines, AI triggers, agents, vector mappings, and
  interconnections generated from `examples/machines/*.json`.
- [Machine Interconnection Index](Machine-Interconnection-Index) — searchable
  output-to-input overlap index for domain-local and cross-domain machine
  interconnections.
- [Life Balance Machines](Life-Balance-Machines) — `100` lifestyle-psychiatry
  tracking, automation, projection, and e2e validation machines.

Current generated corpus:

- `1006` machines
- `11` active domains
- `4109` used perceptual positions
- `1361` machine-level interconnections
- `135` cross-domain interconnections
