# RealityEngine_CI

Deployment, compatibility, and CI tooling for the integrated RealityEngine
system.

## Authoritative Specifications

- [Deployment contract](DEPLOYMENT_CONTRACT.md) defines service ownership,
  port ranges, native runtime pairs, required environment names, and deployment
  rules.
- [Integrated specification](INTEGRATED_SPECIFICATION.md) is the cross-repo
  documentation index, audit summary, deployment gate list, and roadmap to full
  integrated specifications.

The CI repository owns the executable deployment contract. Runtime-local docs
must link back to these files rather than redefining ports or environment
names.
