# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

## Start Here

- [Why this system exists](wiki/Why-This-System-Exists.md) states the system's purpose,
  its design commitments, and what it declines to be.
- [System document index](wiki/System-Document-Index.md) maps the documentation across
  all ten repositories and opens with a reading order for a new reader.

## Authoritative Specifications

- [Deployable system wiki](wiki/Deployable-System-Documentation.md) is the
  primary authoritative documentation surface for the deployable system.
- [Deployment contract](DEPLOYMENT_CONTRACT.md) defines service ownership,
  port ranges, native runtime pairs, required environment names, and deployment
  rules.
- [Integrated specification](INTEGRATED_SPECIFICATION.md) is the cross-repo
  documentation index, audit summary, deployment gate list, and roadmap to full
  integrated specifications.

The CI repository owns the executable deployment contract and tracks the wiki
gitlink used for published system documentation. Runtime-local docs must link
back to these files rather than redefining ports or environment names.
