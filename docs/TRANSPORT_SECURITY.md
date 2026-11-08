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
  the engines' RE and PE, the lifecycle service's service listener (ROADMAP
  phase 2; until then its one API is server TLS only, because reviewers use it
  from browsers), `re-mcp`, the instance registry, the observability ingest
  ports.
- **User-facing ports require server TLS only.** Users and devices authenticate
  on top of it. These are the Manager frontend, `assets-dokieli`, `assets-css`,
  Open WebUI, Grafana, and the PE's device ingest.
- **Health endpoints are served over TLS too,** and healthchecks verify against
  `RE_TLS_CA`.
- **Where the certificate is required.** A port with no user-facing routes
  requires the client certificate at the handshake. A port that has some, which
  today is only the engines' PE, requests one at the handshake and verifies any
  certificate presented, so an untrusted one is still refused. It serves those
  routes without one and answers every other route `403`
  `{"error":"client certificate required"}`. The PE's device routes are the
  HealthKit bridge's `POST /api/integrations/healthkit/ingest`,
  `GET …/healthkit/status` and `POST …/healthkit/scope`
  (localHealthkitBridge `docs/INGEST_CONTRACT.md`), which carry its bearer
  token. `…/healthkit/resync` is called by a service and is not one of them.
- **A configuration that cannot be loaded stops the service.** With
  `RE_TLS_CERT` set, a missing or unreadable key, CA or CRL is a startup
  failure, never a plaintext start.

**Calling.**
- Verify the peer against `RE_TLS_CA`, with the hostname or IP check on, and
  check `RE_TLS_CRL`.
- Present the service's own certificate wherever the peer requires one.
- A peer that is an engine instance may also check its `urn:uuid:` SAN against
  the instance registry's `instance_uuid`.
- **Internal or external** is decided from the URL's host. A peer is internal
  when the host is loopback, a private (RFC 1918), link-local or unique-local
  address, a single-label name (a compose service), or a name under
  `.localhost`, `.internal` or `.local`. An internal peer is verified against
  `RE_TLS_CA` alone and gets the service's certificate.
- An external party is verified against the system store, for that link only,
  and held to the profile once the lane is on. With the lane off (`RE_TLS_CA`
  unset) an `https` call keeps the behaviour it had before.
- **Keep connections.** A client pools TLS connections the way it pools
  plaintext ones. A handshake per call puts one on every PE → RE step.
- The engines implement these choices identically (C++ `src/http.cpp`, LSP and
  Scala alike, RealityEngine_CPP#193, LSP#186, Scala#210). A difference shows up
  as an engine divergence, so a change lands in all three together.

**The lane switch.** `RE_TLS=on|off` (default `off`), read by
`scripts/lib/lane-tls.sh`. The native lane issues every instance's certificate
either way, but hands over `RE_TLS_*` and registers `https` URLs only when it is
on.
With the lane on:
- **The instance registry** serves over TLS 1.3 with mTLS, under its own server
  certificate (`registry`, issued by `lane_tls_issue_service`), and
  `.universe-registry-url` and `RE_REGISTRY_URL` are `https`. The shim is
  `scripts/lib/re_tls_server.py`, which holds CI's own listeners to the profile:
  TLS 1.3 only, a lane-CA client certificate required, the lane CRL checked,
  and the profile's suites and groups set through an OpenSSL config it writes
  beside the certificate (Python's `ssl` exposes neither for TLS 1.3). The PQ
  hybrid group is offered when the linked OpenSSL is 3.5 or newer.
- **The harness** trusts the lane CA through `RE_HARNESS_TLS_CA`,
  `RE_HARNESS_TLS_CERT` and `RE_HARNESS_TLS_KEY`, which `lane_tls_init` exports.
  They are not named `RE_TLS_*` because every child of the harness would
  inherit those and serve with its identity. `scripts/lib/re_tls.py` uses them
  with no fallback: a missing file is an error.
- **The regression harness** (`regression-test.sh`) runs `lane_tls_init native`
  itself before the start phase (`prepare_lane_tls`), from the run worktree's
  library, because its stages run after `startUniverse.sh` has returned. It
  reuses the same lane CA. Every Python stage that calls `urlopen` without a
  context calls `re_tls.install_lane_opener()` at import, which installs the
  lane context through urllib's `install_opener` when the lane is on and does
  nothing when it is off.
- **The native lane's universe** (`startUniverse.sh --engines=...`) starts its
  engines on TLS 1.3 with mTLS (C++, LSP and Scala; Rust as a follower). It
  issues Manager its own certificate (`manager`, kind both) and passes it as
  `RE_TLS_*`, so Manager's backend and frontend serve TLS 1.3 and call the
  engines with mTLS. Its readiness polls, `_publish_service` probes and
  post-start checks go through `lane_curl_get`.
  - **localAIStack** runs on its lane overlay (`docker-compose.tls.yml`,
    localAIStack#172): every compose call goes through `las_compose`, which
    adds the overlay when the lane is on. `lane_tls_localai` issues
    `localai-api`, `localai-qdrant` and `localai-redis` (kind both) and links
    them into `~/.reality-engine/localai/tls`. Qdrant and Redis start on it
    whatever `--no-local-ai` says. The engines' `localai` integration
    `baseUrl` becomes https, and loopback Ollama URLs move to the front.
    localAIStack's Open WebUI is not started on the lane.
  - **Ollama's TLS front** (localAIStack `scripts/ollama_tls_front.py`)
    starts in stage 2 whenever Ollama is up, on `127.0.0.1:11443` with its own
    `ollama-front` certificate (`lane_tls_ollama_front_start`).
    `stopUniverse.sh` stops it whatever `--keep-ollama` says.
  - **OpenClaw** runs on the lane with the native gateway only
    (`--openclaw-runtime=native`, the default; localOpenClawStack#92).
    `lane_tls_openclaw` issues `openclaw-gateway` (kind both) and
    `openclaw-browser` (server), links them into
    `~/.reality-engine/openclaw/tls`, and hands that directory over as
    `OPENCLAW_TLS_DIR`, with `OPENCLAW_NATIVE_OLLAMA_URL` on the Ollama front.
    The PEs record `wss://127.0.0.1:18789`. Open WebUI is not started on the
    lane.
  - Consumers not yet on the lane's TLS are refused, not started broken:
    `RE_TLS=on` needs `--no-mcp-http` (#730) until its issue lands.
- **The docker lane** issues each instance (`scala-1`, `cpp-1`, `lsp-1`) a
  certificate from its own `docker` CA, covering the compose service names
  (`engine-<rt>-re`, `engine-<rt>-pe`), `host.docker.internal`, `localhost` and
  `HOST_IP`, with the instance's `urn:uuid:`. Both of the instance's services
  mount it read-only at `/run/re-tls/instance/`, with the lane CA and CRL at
  `/run/re-tls/ca.crt` and `/run/re-tls/ca.crl`, through links under
  `<state>/docker/tls/` (`lane_tls_docker_instance`). The links are not copies,
  so keys stay in the PKI's 0600 files, and the CA directory is never mounted
  because it holds the CA key. `<state>/docker/<id>.tls.env` carries `RE_TLS_*`
  as container paths only when the lane is on. The lane still refuses
  `RE_TLS=on`: its health checks, instance registry URLs and Manager pair are
  plaintext until the engines serve TLS (wave 2). Docker Desktop lets a non-root
  container user read the 0600 key. On Linux the container user must own it,
  which the release lane settles (#729). A CRL replaced on the host reaches a
  running container when the container is recreated.

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
| localai-api → Qdrant | **Qdrant v1.20 cannot be restricted:** with client-certificate verification on it still accepts TLS 1.2 and `TLS_AES_128_GCM_SHA256`, and offers no PQ group. | Its only client, localai-api, offers TLS 1.3 and the profile's suites alone, so the connection always meets the profile and cannot be downgraded; mTLS is required; host ports bind `127.0.0.1`. | A Qdrant setting that restricts protocols and suites. | owner, 2026-11-08 |
| PEs, the ACP adapter → the OpenClaw gateway | **The gateway cannot require client certificates** (OpenClaw 2026.10.8's TLS server has no `requestCert`; `gateway.tls.caPath` is a trust chain only), so the link is TLS 1.3 without mTLS. | Every call needs the gateway bearer token (`verify-deployment.sh` checks the 401); loopback bind; the listener is held to the full profile by localOpenClawStack's `scripts/lib/lane-tls-preload.cjs`. | mTLS once OpenClaw can require client certificates. | owner, 2026-11-08 |
| the browser sidecar's CDP proxy → Chromium | **Chromium serves CDP in plaintext only**, so the hop from the TLS proxy (nginx, TLS 1.3 + mTLS) to Chromium is plaintext on the container's loopback. | Only the proxy reaches it; nothing else for CDP is published. | TLS when Chromium serves CDP over it. | owner, 2026-11-08 |
| Ollama's TLS front → Ollama | **Ollama serves no TLS** (0.40.13; its FAQ offers only a reverse proxy), so the front's hop to Ollama is plaintext on the host's loopback. | Ollama binds `127.0.0.1` only; every client reaches it through the front on TLS 1.3 with mTLS. | Native TLS when Ollama offers it. | owner, 2026-11-07 |

**A consequence, not a deficiency: OpenAPI "Try it".** Engine RE and PE ports
require a client certificate (mTLS). A browser, or the OpenAPI pages'
"Try it" button (`scripts/serve-openapi`), therefore can't call an engine
directly. Those calls go through Manager, whose backend holds a client
certificate. The generated OpenAPI documents' `servers` entries still name the
engines' ports; they describe the internal surface and are not a route a
browser can use (owner, 2026-11-07).

**Components and their TLS:**
- **The OpenClaw gateway** serves HTTPS and WSS natively (OpenClaw 2026.10.8:
  `gateway.tls.enabled`, `certPath`, `keyPath`; `caPath` is a trust chain, not
  client verification: the server sets no `requestCert`). It sets no suites or
  groups, so a Node preload (`NODE_OPTIONS=--require`, localOpenClawStack
  `scripts/lib/lane-tls-preload.cjs`) holds the process to the profile and
  presents its lane certificate on outbound TLS to internal peers: OpenClaw has
  client certificates for MCP servers only (`mcp.servers.<name>.clientCert`),
  none for model providers or CDP.
- **The insecure-transport gate and deficiencies.** An owner-accepted
  deficiency whose link is allowed to be plaintext may name, in
  `deficiency.sources`, the exact occurrences it needs (file, pattern, count);
  `check-insecure-transport.py` allows those on top of the baseline and never
  writes them into it. The CDP proxy's `proxy_pass` to Chromium is the one so
  far.
- **Ollama** has no native TLS: 0.40.13 has no TLS setting, and its FAQ points
  to a reverse proxy. It runs behind a TLS 1.3 front with mTLS, bound to
  loopback (owner, 2026-11-07; the deficiency above; localAIStack#172).
- **macOS's `/usr/bin/curl` cannot speak TLS 1.3** (it is built on
  SecureTransport, and exits with code 4). Mac-side scripts use Homebrew's curl
  (`/opt/homebrew/opt/curl/bin/curl`), Python or Node, with the lane CA.

## Replacing what exists

Two older CAs are retired by this PKI:
- `certs/generate-dev-certs.sh`: one RSA dev CA, with a single shared RSA server
  certificate for every service name;
- `release/init/reinit.py`'s own RSA CA (#729).

`scripts/lib/re_tls.py`, which the verification stages use, trusts the lane's
`re_pki` CA whenever the lane is on, with no fallback. With the lane off it
still trusts the dev CA, and its unverified fallback stays until the docker
lane has moved off `certs/ca.crt` (#732).
