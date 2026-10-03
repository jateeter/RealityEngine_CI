# The retired per-chain CES recorder

`regression-ces-contracts.py` and `record-ces-contract-shards.sh` recorded the CES
contract before `record-ces-contracts.py` replaced them on 2026-09-14 (#376). They
are kept, refuse to run without `CES_ALLOW_RETIRED_RECORDER=1`, and are described
here as the fullest statement of the per-chain approach — the rationale behind the
shard and verdict design. This is not a description of what records the contract
today; for that see `scripts/CLAUDE.md`, "The CES contract".

The oracle argument behind both still holds. A contract recorded by replaying through one
engine makes that engine **unfalsifiable**: regenerating makes it pass by
construction, the gate can never find a defect *in* it, and to regenerate you
must already trust the thing the gate exists to check. Its nominated engine was
the deprecated TypeScript prototype, which is out of the focus set; the oracle
is not being rebuilt, it is being removed (#327, direction (2)).

Four verdicts, and only the first becomes a contract:

| verdict | means |
|---|---|
| `agreed` | all three produced the same stream — **this is the contract** |
| `disagreement` | they differ; every cluster's stream is carried, none is the reference |
| `no-runtime-emits` | all three ran and emitted nothing — nobody implements this shape |
| `unmeasurable` | a runtime could not be driven; no evidence either way |

`unmeasurable` exists so a 500 never reads as silence, and `no-runtime-emits`
so silence never reads as a contract with an empty stream. All four are
enumerated in the artifact, never reduced to counts.

Recording is **refused** without a formed quorum or after a failed reset. The
comparison stages can report honestly against a partial lane; this one writes a
file that is consumed later *as* the contract, and a caveat inside a file is
read by whoever opens the file.

This is not an oracle in the strong sense — three runtimes can still be wrong
the same way. Deriving the expected stream from the corpus plus the declared
fold rule would be that, and it is option (3) on #327, not this.

### Shards, and why the contract is not one file

One recording for the whole corpus does not survive a corpus that grows. A
machine added to one domain would mean re-recording all 4941 chains against a
live quorum, and reviewing a diff nobody can read. Divergence is a property of
machine *shape* and the corpus arrives a domain at a time, so the shard boundary
that matches how the corpus mutates is the domain.

`--machine-corpus` therefore takes three selector shapes: `full`, a bare name
for a `config/<name>-corpus.txt` selection, and `domain:<name>` for one corpus
domain. `--list-scopes` prints them all and needs no running universe — the
command that says what is recordable must not itself require a quorum.

`record-ces-contract-shards.sh` drives every scope, cheapest first, skipping
those already current, so an interrupted sweep resumes rather than restarts.

**A shard says which corpus it describes.** Every artifact carries
`corpusFingerprint` — per-machine sha256, using the definition in
`RealityEngine_Machines/scripts/ces_corpus_fingerprint.py`, imported rather than
restated so the recorder and the cesgen registry cannot disagree about what a corpus
change is. `RealityEngine_Machines/domains/ces-contract-registry.json` compares
that with the corpus as it stands, and
`tests/contracts/ces_contract_registry_test.py` fails on any shard the corpus
has moved out from under, naming the machines. That gate lives in the corpus
repo because that is where the change is made and where its author can act.

**Failures are marked, not fatal.** A sweep of a dozen domains is long enough
that something will go wrong partway, so a failed scope is journalled and the
sweep continues. The journal is a file — `.ces-contracts/journal.json`, written
after every scope — because marking that dies with the process does not help a
restart. Restarting is the same command again: recorded-and-current scopes are
skipped by the cesgen registry, failed ones retried, `--skip-failed` steps past them,
`--retry-failed-only` comes back for just those. A failed scope leaves no shard,
since the recorder writes once at the end, so it reads as unrecorded rather than
as a partial contract that looks whole.

Two things deliberately do *not* count as scope failures. Quorum is re-checked
before every scope, and losing a runtime at hour three halts the sweep instead
of marking every remaining domain failed — that is one universe-level fault, not
nine scope-level ones. And `--max-consecutive` (default 3) halts on a run of
failures, because consecutive failures are evidence of one systemic problem and
grinding through the rest produces a dozen identical logs and no new
information.

**Residency is checked before recording, not after.** The recorder drives chains
through the live PE; a machine the engines never loaded emits nothing, and that
is correctly classified `no-runtime-emits`. Correct, and a useless shard —
indistinguishable from a domain that genuinely does nothing. So the driver
refuses a scope whose machines are not resident rather than recording silence.
Domain scopes need `--machine-corpus=full` at boot.

