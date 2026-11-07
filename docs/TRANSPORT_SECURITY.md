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

## Replacing what exists

Two older CAs are retired by this PKI:
- `certs/generate-dev-certs.sh`: one RSA dev CA, with a single shared RSA server
  certificate for every service name;
- `release/init/reinit.py`'s own RSA CA (#729).

`scripts/lib/re_tls.py`, which the verification stages use to trust the dev CA,
moves to the lane's `re_pki` CA as each stage's link is converted. Its
unverified fallback goes when the probe stage lands.
