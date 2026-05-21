# Community Services Expansion Machines

The community-services domain has been expanded with `90` generated `CSX`
machines, bringing the domain to `102` machines total. These examples are stored
in `examples/machines/` and are loaded automatically at startup with the rest of
the machine corpus.

## Scope

The generated machines cover city-scale service delivery across:

- Health and human services intake, benefits eligibility, and resident case
  navigation.
- Behavioral health crisis response and mobile co-response.
- Law enforcement and public safety coordination.
- Courts, diversion, victim services, and reentry support.
- Homelessness outreach, shelter operations, coordinated entry, housing
  navigation, and supportive services.
- 311, sanitation, accessibility, public restrooms, weather centers, libraries,
  parks, donations, funding, privacy, service equity, and executive optimization.

## Perceptual Mapping

After remapping, community-services occupies `[920:1344]` for domain-local
components and participates in bridge regions `[3415:3507]` for health-services
and transportation interconnects.

Each generated machine uses a 4D input lane:

- Resident need severity
- Eligibility and documentation readiness
- Field capacity or operational readiness
- Safety, mobility, and health risk

Each generated machine emits a 4D output lane:

- `[1,0,0,0]` urgent response
- `[0,1,0,0]` coordinate services
- `[0,0,1,0]` field work order
- `[0,0,0,1]` stable service path

## Interconnects

The `CSX` family includes domain-local chains inside each workstream and
intentional bridge lanes to health-services and transportation:

- Health-services: behavioral health integration, care coordination, community
  health outcomes, environmental health response, emergency preparedness,
  foundational public health, and learning health system routing.
- Transportation: rider alerts, transfer protection, onboard security, fare
  evasion/security triage, weather hazard safety, fleet pullout readiness,
  relief-bus allocation, detour coordination, stop shelter condition, and the
  100-bus fleet command center.

The searchable interconnection index is generated in
`docs/EXAMPLE_DOMAIN_COMPENDIUM.md`.

## Test Sequences

Every `CSX` machine includes five startup-loadable `inputSequences`:

| Sequence | Input vectors | Expected output |
| --- | --- | --- |
| Urgent response | `[1,0,1,1] -> [0,0,1,1]` | `[1,0,0,0]` |
| Coordinate services | `[0,1,1,0]` | `[0,1,0,0]` |
| Field work order | `[1,0,0,1]` | `[0,0,1,0]` |
| Stable service path | `[1,1,0,0]` | `[0,0,0,1]` |
| Baseline without output | `[1,0,1,1]` | no output |

These sequences are represented in machine JSON as both CES graph vectors and
`inputSequences`, so PE simulation sources can load them directly.

## Regeneration

```bash
python3 scripts/generate_community_services_expansion_machines.py
node scripts/remap_machine_connection_matrix_by_domain.mjs
node scripts/generate_example_machine_compendium.mjs
```

After regeneration, validate the corpus with the C++ e2e target:

```bash
make e2e-corpus
make e2e
```
