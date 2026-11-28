# Sandbox experiments: replaying near-misses on a replica

RealityEngine_CI#605, part of #603. The specification is SURFACE_SPEC
"Sandboxed learning deployment".

An **abandoned K-line** is a near-miss. A machine's sequence got part of the way
along its path and then failed at one step, and the K-line records where. A
**sandbox replica** is a new engine instance, booted from the same corpus, where
those near-misses can be put back and varied. Nothing a replica does reaches the
instance it was copied from.

The learning these experiments are meant to feed is RealityEngine_CI#562
(difference-net learning from near-misses), which is on hold. The ledger
described below is the data #562 will read.

## Run an experiment

The universe must be running on the TLS lane (`RE_TLS=on`) with K-line capture
on (`--kline-capture`, or switched on through each engine's API).

```bash
cd RealityEngine_CI
export RE_REGISTRY_URL="$(cat .universe-registry-url)"

# 1. The source's near-misses, and the completed K-lines of the same machines.
python3 scripts/sandbox.py export --registry "$RE_REGISTRY_URL" --from cpp-1 --out near-misses.jsonl

# 2. A replica of cpp-1. startUniverse.sh finds the running universe's corpus and
#    registry; it starts nothing else.
./startUniverse.sh --sandbox-from=cpp-1 --bundle=near-misses.jsonl
#    It prints the replica's name, e.g. cpp-1-c19b7152.

# 3. Replay. With no --kline it takes a spread: the earliest near-miss of each
#    focal sequence, a machine at a time, up to --sample (default 8). Each is
#    replayed as it happened, then with the failing cell flipped across its
#    threshold, or with the cells you name.
python3 scripts/sandbox.py replay --name cpp-1-c19b7152
python3 scripts/sandbox.py replay --name cpp-1-c19b7152 --kline <id> --vary 928=0.4 --vary 931=0.9

# 4. Stop it. Its state and results stay.
python3 scripts/sandbox.py down --name cpp-1-c19b7152
```

**When to hash the source.** `export` is the source's own write: it marks the
segments it exported. A check that the source store is untouched therefore
hashes it after the export.

`sandbox.py up` does the same as step 2 without `startUniverse.sh`. It takes
`--registry`, `--from`, `--bundle` and `--corpus <machines dir>`, and also
`--repo <engine checkout>` and `--name`.

## What each replay does

1. **Restore.** It builds a narrowed `re-snapshot/1` from the K-line record,
   with the record's `scope` and its `activeBefore` as the active list, and
   restores it (`POST /api/runtime/restore`). The scoped machines are now
   exactly where they stood when the near-miss opened.
2. **Present.** It presents the record's ISRE pairs through `POST /api/perceive`,
   one per step. The faithful run must reproduce the recorded OSREs over the
   scope's output regions, outside `sharedCells`, and must be abandoned again.
3. **Vary.** It presents the same pairs again, with the last step (the failing
   one) changed: by default the `difference.cell` flipped across its threshold.
4. **Record.** The replica captures the K-lines both runs produce, in its own
   store. The experiment is appended to the ledger.

## Where results live

Everything is under `$RE_INSTANCE_STATE_DIR/sandbox/<name>/`, by default
`~/.reality-engine/sandbox/<name>/`:

| Path | What |
|---|---|
| `replica.json` (`replica.stopped.json` once stopped) | the replica: runtime, URL, UUID, source, bundle, fingerprint |
| `registry.json` | its own instance registry, a sandbox one (`RE_REGISTRY_SANDBOX`) |
| `klines/<replica uuid>/segment-*.jsonl` | the K-lines the replica recorded |
| `klines/<replica uuid>/imported/<source uuid>/bundle-*.jsonl` | the bundle, read-only (0444), as the source sealed it |
| `experiments.jsonl` | one line per experiment (see below) |
| `replica.log` | the engine's log |

Each ledger line holds:
- `causedBy`: `{kline, source, bundleSha256}`, the imported K-line the
  experiment re-establishes;
- `focal` and `difference`, from that record;
- `faithful` and `varied`: whether the run was restored and reproduced, the
  replica K-lines it produced (`klines[].id`), and whether it completed or was
  abandoned;
- `vary`: the cells changed at the failing step.

The engines' own K-line records have no `causedBy` field. The ledger is the link
from a replica's K-lines back to the near-miss they came from.

## Isolation

- **A new instance.** A replica's UUID is allocated in the `sandbox` lane
  (`sandbox/<name>/<source id>`), never the source's. Production instance
  registries refuse it.
- **Nothing live.** It is an RE only: no PE, no MQTT, HealthKit, ACP, OpenClaw,
  MCP, Ollama or localAI variable is passed to it.
- **Nothing flows back.** The source is read only through its own export route.
  The regression stage checks that the source's K-line store and the instance
  registry are byte-identical before and after.
- **The same corpus.** `up` compares the replica's corpus fingerprint with the
  bundle's and refuses to start on a mismatch.
- **TLS only.** A replica has its own lane certificate and is never plaintext.

## In regression

The `sandbox` stage (`scripts/regression-sandbox.py`) runs after
`kline-boundaries`, which leaves near-misses in every voter's store. For each
voter it:
1. exports the near-misses;
2. boots a replica and replays 8 of them;
3. stops the replica;
4. checks the faithful replays reproduced, the replica recorded K-lines of its
   own, the bundle was imported read-only, and the source's store and the
   registry are unchanged.

The voters must agree on every replay's outcome. Measured 2026-11-27 on the
regression corpus: 8 of 8 reproduced on each runtime, 2 completed when varied on
each, 240 replica K-lines each, the sources unchanged, about 100 s.

## On a release install

`realityengine sandbox` does the same, beside a release install (INSTALL.md,
"Experimenting with near-misses"):

```bash
./realityengine sandbox export --from cpp-1 --out near.jsonl
./realityengine sandbox up --from cpp-1 --bundle near.jsonl [--name NAME]
./realityengine sandbox replay --name NAME [--kline ID] [--sample N] [--vary CELL=VALUE]
./realityengine sandbox down --name NAME
./realityengine sandbox list
```

- **The work.** The checks, admission and replays are `scripts/sandbox.py`
  itself, carried unchanged in the `re-init` image and run as its
  `sandbox-export`, `sandbox-prepare`, `sandbox-check`, `sandbox-replay` and
  `sandbox-down` jobs.
- **The launch.** The replica is a container started from the instance's own
  image, with the env and command `re-init configure` gives that runtime's RE,
  less `QDRANT_URL`. It has:
  - the install's `corpus-boot` volume, read-only;
  - a certificate from the install's CA, naming its container;
  - its own store and clock, under `<install>/state/sandbox/<name>/`.
- **Its network** is its own (`<project>-sandbox-<name>`). The install's
  services do not resolve from it, and it does not resolve from theirs. `check`
  and `replay` run there; `export` runs on the install's network.
- **TLS on only.** `uninstall` removes every replica's container and network,
  and `--purge` removes the results with the install.

Measured 2026-11-27 on a release install (images from main, TLS on, capture on),
cpp-1, lsp-1 and scala-1 each:
- 6 of 6 near-misses reproduced, and the same 4 of 6 completed when varied;
- 171 replica K-lines;
- the bundle imported read-only;
- the source's store in the `engine-klines` volume, and the instance registry,
  byte-identical before and after;
- no container or network left after `down`.
