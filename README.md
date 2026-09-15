# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

## Start Here

- [Why this system exists](https://github.com/jateeter/RealityEngine_CI/wiki/Why-This-System-Exists) states the system's purpose,
  its design commitments, and what it declines to be.
- [System document index](https://github.com/jateeter/RealityEngine_CI/wiki/System-Document-Index) maps the documentation across
  all ten repositories and opens with a reading order for a new reader.

## Authoritative Specifications

- [Deployable system](DEPLOYMENT_CONTRACT.md) is the
  primary authoritative documentation surface for the deployable system.
- [Integrated specification](INTEGRATED_SPECIFICATION.md) is the cross-repo
  documentation index, audit summary, deployment gate list, and roadmap to full
  integrated specifications.

The CI repository owns the executable deployment contract and tracks the wiki
gitlink used for published system documentation. Runtime-local docs must link
back to these files rather than redefining ports or environment names.

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

- ## System Depoloyment
  Clone the following github repos into your local workspace:
  RealityEngine_CI
  RealityEngine_Machines
  RealityEngine_Manager
  RealityEngine_CPP
  RealityEngine_LSP
  RealityEngine_Scala
  localAIStack
  localOpenclawStack
  localHealthkitBridge

  from within the RealityEngine_CI repository, enter:
  ./startUniverse.sh --engines=cpp:1,lsp:1,scala:1

  
