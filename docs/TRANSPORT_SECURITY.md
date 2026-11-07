# Transport Security

Version 1.0.0, 2026-11-06. Authoritative for how RealityEngine encrypts data in
motion (RealityEngine_CI#668). The rule itself is in
[`ENGINEERING_CONTRACT.md`](ENGINEERING_CONTRACT.md), "every link is TLS 1.3";
the profile is [`config/transport-profile.json`](../config/transport-profile.json).

## The pieces

| Piece | File | Issue |
|---|---|---|
| The profile: TLS 1.3, AEAD suites, `X25519MLKEM768` preferred, ECDSA P-384, 90-day leaves | `config/transport-profile.json` | #725 |
| Every link, its status today, its owner and its issue | `config/transport-inventory.json`, checked by `scripts/check-transport-inventory.py` | #725 |
| The PKI: a CA per install, service and instance certificates, rotation, revocation | `scripts/lib/re_pki.py` | #726 |
| No new plaintext or disabled verification | `scripts/check-insecure-transport.py`, baseline `config/insecure-transport-baseline.json` | #727 |
| Each link measured live | the probe stage in `regression-test.sh` | #728 |
| Release gate, `re-init` on the PKI, install docs | `check-transport-inventory.py --require-compliant`, `release/` | #729 |

## The PKI

**One CA per install, per lane.** The native lane, the dev compose lane and a
release install are different instance sets (as instance UUIDs are), so each
has its own CA:

| Lane | State directory |
|---|---|
| native | `~/.reality-engine/pki/native` |
| docker | `~/.reality-engine/pki/docker` |
| release | the install's directory (#729) |

`RE_PKI_DIR` overrides the directory; `RE_PKI_LANE` picks the lane. The state
is kept across universes and never in a repository. The CA key is `0600`, and
`init` never replaces an existing CA: a half-present CA is refused, not
repaired.

**Certificates.** Every key is ECDSA P-384, signed with SHA-384.
- The CA is valid for 1,825 days.
- A leaf is valid for 90 days, and is re-issued once it is within 30 days of
  expiry.
- A leaf's kind decides its extended key usage:

  | Kind | EKU |
  |---|---|
  | `server` | serverAuth |
  | `client` | clientAuth |
  | `both` (an engine instance, which serves and calls) | serverAuth, clientAuth |

- A server certificate needs at least one DNS or IP SAN.
- An engine instance's certificate also carries `urn:uuid:<instance_uuid>`, the
  UUID from `scripts/lib/instance_uuids.py`. A peer that checks that SAN knows
  which instance it is talking to, not just which host.

**Issuing.** `re_pki.py issue NAME --kind K --dns D --ip I [--instance-uuid U]`
is idempotent.
- A current certificate with the same kind and SANs is kept.
- A changed one, or one inside its renewal window, is re-issued.
- The certificate it replaces is revoked at once, so a stale copy stops
  verifying.

`re_pki.py renew` re-issues everything inside its window. Lane start-up runs it
before services start.

**Revocation.** `revoke NAME` adds the certificate to the CA's CRL
(`ca/ca.crl`). A service that verifies peers loads the CRL with the CA; the probe
stage (#728) checks that a revoked certificate is refused.

**Consuming it.** A service gets its paths from `re_pki.py paths NAME`: `key`,
`cert`, `chain` (cert plus CA), `ca` and `crl`. Each lane passes these to its
containers or processes, and a repository's TLS issue says how its service loads
them:
- the engines' native spawns;
- the compose mounts;
- the JVM keystore built from them for Scala;
- the release `re-init`.

## The runtime contract

Every service that serves or calls a link follows this contract, so each
repository's TLS issue implements the same thing.

**Inputs.** The lane passes four paths, issued by `re_pki.py` (RealityEngine_CI#732):

| Variable | Holds |
|---|---|
| `RE_TLS_CERT` | the service's chain (its certificate, then the CA) |
| `RE_TLS_KEY` | its private key |
| `RE_TLS_CA` | the install CA, the only trust anchor for internal links |
| `RE_TLS_CRL` | the CA's revocation list |

**Serving.**
- **TLS 1.3 only,** with the profile's suites and groups (`X25519MLKEM768`
  first). A stack whose TLS library lacks the hybrid group uses a fallback group
  from the profile and reports it.
- **The same ports, `https`/`wss` instead of `http`/`ws`.** There is no plaintext
  listener and no redirect from one.
- **Service ports require a client certificate** from the install CA (mTLS):
  the engines' RE and PE, the lifecycle service API, `re-mcp`, the instance
  registry, the observability ingest ports.
- **User-facing ports require server TLS only.** Users and devices authenticate
  on top of it. These are the Manager frontend, `assets-dokieli`, `assets-css`,
  Open WebUI, Grafana, and the PE's device ingest.
- **Health endpoints are served over TLS too,** and healthchecks verify against
  `RE_TLS_CA`.

**Calling.**
- Verify the peer against `RE_TLS_CA`, with the hostname or IP check on, and
  check `RE_TLS_CRL`.
- Present the service's own certificate wherever the peer requires one.
- A peer that is an engine instance may also check its `urn:uuid:` SAN against
  the instance registry's `instance_uuid`.
- An external party is verified against the system store, for that link only.

**Transition.** Each service first serves TLS whenever `RE_TLS_CERT` is set, and
keeps its plaintext path only while it is unset. A lane turns TLS on once
every voter and every client on that lane is ready (RealityEngine_CI#732). The
plaintext paths are then deleted, and each deletion retires its occurrences
from the insecure-transport baseline. A release requires every link
`compliant` (RealityEngine_CI#729).

## Trust

- **Services** trust exactly the install CA, given to them as a file, and keep
  hostname and identity checks on. A service never trusts the OS store for an
  internal link, and never disables verification.
- **Browsers and the OS** (Manager, dokieli, Open WebUI) need the install CA in
  the user's trust store. Changing a trust store is the owner's step, never a
  script's. `re_pki.py trust-command` prints the command to run (on macOS,
  `security add-trusted-cert`).
- **Devices** (the iPhone running the HealthKit bridge) are given the CA through
  a configuration profile the owner installs (localHealthkitBridge#52).

## External parties

They are held strictly: a link that doesn't meet the profile is refused, not
recorded as an exception. The external parties are:
- the Yuma MQTT broker;
- image and model downloads;
- any other outside service.

A party that meets the profile with a public CA is verified against the system
store for that link only.

## Known deficiencies

A deficiency is a link that falls short of the profile because a component
can't meet it. Only the owner accepts one. It is recorded on the link in
`config/transport-inventory.json`, with what falls short, what compensates,
the remedy, and `allows`, the exact status or mTLS value it permits. The
release gate lists accepted deficiencies, and fails anything beyond what each
allows.

| Link | Deficiency | Compensation | Remedy | Accepted |
|---|---|---|---|---|
| lifecycle → `assets-css` | **CSS does not verify client certificates,** so the link is TLS 1.3 without mTLS. | The lifecycle service authenticates with Solid-OIDC and DPoP-bound tokens (localAssetStorageStack ROADMAP phase 2). | mTLS once CSS verifies client certificates. | owner, 2026-11-07 |
| engines → the Yuma MQTT broker | **The broker is reached as `mqtt://yuma.lateraledge.cloud:1883`:** plaintext to an external party. | None in transport; MQTT carries only regression sensor traffic. | `mqtts` on TLS 1.3 once the broker offers it. | owner, 2026-11-07 |

**A consequence, not a deficiency: OpenAPI "Try it".** Engine RE and PE ports
require a client certificate (mTLS). A browser, or the OpenAPI pages'
"Try it" button (`scripts/serve-openapi`), therefore can't call an engine
directly. Those calls go through Manager, whose backend holds a client
certificate. The generated OpenAPI documents' `servers` entries still name the
engines' ports; they describe the internal surface and are not a route a
browser can use (owner, 2026-11-07).

**Components and their TLS:**
- **The OpenClaw gateway** serves HTTPS and WSS natively (OpenClaw 2026.10.8:
  `gateway.tls.enabled`, `certPath`, `keyPath`, and `caPath` to verify clients).
  It is held to TLS 1.3 and the profile's suites through `NODE_OPTIONS`.
- **Ollama** has no native TLS: 0.40.13 has no TLS setting, and its FAQ points
  to a reverse proxy. The owner's decision on it is pending (RealityEngine_CI#668).

## Replacing what exists

Two older CAs are retired by this PKI:
- `certs/generate-dev-certs.sh`: one RSA dev CA, with a single shared RSA server
  certificate for every service name;
- `release/init/reinit.py`'s own RSA CA (#729).

`scripts/lib/re_tls.py`, which the verification stages use to trust the dev CA,
moves to the lane's `re_pki` CA as each stage's link is converted. Its
unverified fallback goes when the probe stage lands.
