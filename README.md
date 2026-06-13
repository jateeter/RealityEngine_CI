# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

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
