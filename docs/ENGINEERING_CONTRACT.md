# Engineering Contract

Last reviewed: 2026-09-14

**This file is authoritative for the standing rules below.** Every repository's
`CLAUDE.md` points here rather than restating them, the same way each engine
points at `BUILD_CONTROL_CONTRACT.md` instead of carrying its own copy of the
build rules.

## Why this file exists

These four rules were written into eighteen `CLAUDE.md` files across six
repositories, in full, by copy. That is the defect the rules themselves warn
about, arriving in the guidance rather than in the code:

- **Duplicated text drifts.** Three of the four rules reached eight files; the
  fourth reached eighteen. Nothing kept them in step, and nothing would have
  reported it if a copy had been edited in place.
- **A rule added to one copy applies only where someone happened to look.**
  Adding the fifth rule meant editing eighteen files and hoping. That is not a
  contract, it is a convention with good intentions.
- **A reader cannot tell which copy is current.** With no authority, every copy
  is equally plausible, and the most recently edited one is not necessarily the
  most correct.

One file, many pointers. Change it here and every repository is changed.

---

## MUST: every use of the word "registry" carries a qualifier

**The word "registry" MUST NEVER appear unqualified. Every single use of the
word takes a qualifier naming which registry is meant.**

A hard requirement, not a style preference. It applies to every occurrence in
every context, with no exceptions: prose, end-of-task summaries, commit
messages, PR bodies, issue titles and bodies, code comments, docstrings,
variable and function names, log lines, and documentation.

Wrong, in every case:

- "the registry"
- "a versioned registry"
- "the registry file" / "update the registry" / "registry-backed"
- "check the registry first"
- "registry drift"

Right — a qualifier every time:

- "the **instance** registry"
- "a versioned **cesgen** registry"
- "the **arbitration** registry"
- "**machine** registry drift"

If you type the word "registry" and the word immediately before it is not a
qualifier, stop and add one. Re-read every summary and every message for the
bare word before sending it — that is where this rule is actually broken,
because the surrounding context makes the referent feel obvious in the moment.
That feeling is exactly the assumption the rule exists to block.

### Qualifiers currently in use

**This list is open, not exhaustive.** A registry added later gets a qualifier
too; nothing is ever promoted to being "the registry" by virtue of being the one
under discussion.

| Qualifier | What it names |
| --- | --- |
| **instance** registry | `/tmp/re-registry/re-registry.json`, served at `:5999/re-registry.json`. Running RE/PE instances with `re_url`/`pe_url`/ports, plus `services` and `allocation`. What `RE_REGISTRY_URL` points at. |
| **machine** registry | The machines a runtime holds in memory, reported by `GET /api/machines`. Distinct from `GET /api/machines/json/list`, the on-disk corpus catalog — they answered 163 and 21 for the same universe. |
| **cesgen** registry | `RealityEngine_Machines/domains/ces-contract-registry.json`. Which CES contract shards exist, what corpus each was recorded against, whether each is current. |
| **arbitration** registry | `machines/domains/arbitration-registry.json`. |
| **domain** registry | `machines/domains/domain-registry.json`. |
| **semantic-bus** registry | `machines/domains/semantic-bus-registry.json`. |
| **tag** registry | `RealityEngine_CI/docs/TAG_REGISTRY.md`. |

---

## MUST: a stale `<registryName>` registry is regenerated, not failed

**Where any `<registryName>` registry disagrees with the dynamic operational
system, the `<registryName>` registry is regenerated from the operational system
automatically.**

The operational system is the authority. A registry is a *materialised view* of
it. A stale view is a cache miss, not a fault.

This holds for each qualified registry on its own terms — instance, machine,
cesgen, arbitration, domain, semantic-bus, tag. None of them is the source of
truth for what the engines are actually doing, and none may be treated as one.

### What this requires of a gate

- **A gate that fails on a stale registry is wrong.** It regenerates and then
  compares, or reports the regeneration as an event. It does not report staleness
  as a defect.
- **A disagreement that survives regeneration is reported as a failure.** Not a
  warning, not a note in a log — a failure. It is also the *only* kind of
  registry disagreement that may fail anything: a split found before
  regeneration is a stale view and is repaired, while a split still present
  after the rebuild means the operational system and a view freshly derived from
  it do not agree, which means the derivation is wrong. That is the case worth
  stopping the line for, and a gate that downgrades it to a warning has removed
  the only signal this whole rule exists to preserve.
- **A measurement is never taken from a registry when the operational system can
  be asked directly.** A registry answers "what was recorded"; the running system
  answers "what is true now". Substituting the first for the second is the same
  error as reading a launch seed in place of a live value (#364), and it is
  silent in the same way.

### Where this bites today

`RealityEngine_Machines/domains/ces-contract-registry.json` and its gate in
`tests/contracts/ces_contract_registry_test.py`: the gate fails on any shard the
corpus has moved out from under, naming the machines. Under this rule it
regenerates those shards and fails only if the regenerated contract still
disagrees.

This does not weaken §4 of `QUORUM_CONTRACT.md` — a derived artifact must still
be *able to tell it is stale*. That remains the precondition. This says what
happens next once it can: it refreshes itself rather than stopping the line.

## MUST: verify a merge beyond the hosted checks

**A green PR is not a verified PR. Never merge on the hosted checks alone.**

The hosted path does not exercise this system's integration points. A PR can
show every check green and still be unverified, because the checks that ran were
a security scan and — at most — a corpus gate. `localAIStack`,
`localOpenClawStack`, Ollama, Qdrant, MQTT, the OpenClaw ACP gateway and the
multi-engine universe are **not** reachable from the hosted runners, so nothing
on that path can tell you whether the change works where it has to work.

Observed repeatedly: RealityEngine_Machines PRs report exactly one check
(GitGuardian). That is not evidence about the corpus, the registries, the
engines, or any bridge.

Before merging, verify **locally**, and say in the PR which of these you ran and
what they returned:

- The repo's own gates — `validate-corpus.sh`, the contract suite, `npm test`,
  `make test`, `sbt test` — whichever the change touches.
- The integration points the change can reach: a live 3-of-3 universe, the local
  AI stack, the OpenClaw gateway, MQTT — whichever the change can affect.
- The specific behaviour the change claims, with the numbers it produced.

If an integration point cannot be exercised, **say so in the PR** and name it.
An unverified area that is named is a known gap; an unverified area that is
silent reads as tested.

A hosted green tells you the change did not break the hosted path. That is worth
having and is not the question being asked at merge time.

### The PR body is the audit trail — record what you did not chase

The same principle, one step further out. When work surfaces a finding that is
**not** what the change fixes — something noticed in passing and deliberately
left alone — it goes in the PR body, in its own section, headed
"Noted, not fixed here".

An incidental observation has nowhere else to live. It is not a commit, because
nothing was changed for it; not an issue, because it may not warrant one yet;
and not a code comment, because it is not about any particular line. Dropped for
being off-topic, it is gone. In a PR body it is attached, dated, and
attributable to the change that surfaced it, so whoever meets the same symptom
later can find when it was first seen and what was already known.

Say what was observed, with the numbers. Say plainly that it was not chased. Say
why it does not affect the change, if it does not. Do not fold it into the
change's own narrative — being off-topic is precisely what makes it worth
recording.

Example, RealityEngine_CI#377: while verifying a `--check` fix,
`GET /api/machines` returned 93 entries resolving to 80 distinct machine names,
suggesting a re-import adds a second entry under a new id rather than replacing
it. Unrelated to that PR, de-duplicated by name so the result was unaffected,
recorded rather than investigated.

---

## MUST: this repository is the authority — peripheral CI stays minimal

**`RealityEngine_CI` is where verification lives and where guidance is
authoritative. Look here first, before deciding how anything is verified.**

Every other repository in the focus set — `RealityEngine_Machines`,
`RealityEngine_Manager`, `RealityEngine_CPP`, `RealityEngine_LSP`,
`RealityEngine_Scala`, `localAIStack`, `localOpenClawStack`,
`localHealthkitBridge` — keeps its repo-specific CI **deliberately minimal**:
enough to force the local validation, never enough to stand in for it. A fix is
fully verified by this repo, against a live universe.

### Why

A per-repo lane can only exercise what a lone checkout reaches. It cannot stand
up a 3-of-3 universe, cannot reach `localAIStack` or the OpenClaw gateway, and
cannot answer whether a change works where it has to work. Its green is
therefore an invitation to believe a change is verified when the integration
points were never touched — the precise failure the rule above exists to stop.

Keeping those lanes small keeps the verification burden where it can actually be
discharged, and keeps the local run non-optional rather than something a green
checkmark excuses.

### In practice

- **Check this repo's `docs/` before adding or extending CI anywhere else**, and
  follow what it says.
- A peripheral lane may run cheap, checkout-local gates: schema validation, unit
  tests, a linter, a repo's own `--check` generators.
- It may **not** install heavy toolchains, check out sibling repositories, or
  otherwise approximate a universe. That work belongs here. A peripheral lane
  that needs three sibling checkouts to be meaningful has outgrown its remit and
  is doing this repo's job badly.
- **Never present a peripheral repo's green CI as verification of a fix.** Say
  what ran locally, and say what this repo still has to confirm.

### Not yet: freestanding per-repo CI

Each repo standing on its own CI is a future state, and a deliberate one. It is
not a direction to build toward incrementally, and a peripheral lane should not
grow "towards" it a job at a time. When that change is made it will be made
here, on purpose, and this section will say so.

---

## MUST: the guidance file is `CLAUDE.md`, in uppercase

**Every Claude guidance file is named `CLAUDE.md`. Never `claude.md`.** One case
everywhere: the filename on disk, the name recorded in git, and every reference
to it in prose.

This is not tidiness. The workspace sits on a case-insensitive filesystem, where
`claude.md` and `CLAUDE.md` are the **same file** -- one inode, two names -- and
tooling disagrees about which name it is:

- A per-repo `git ls-files` sweep reports whichever case git recorded, so a file
  committed in the other case is invisible to it.
- `Path.resolve()` treats the two names as distinct paths. A dedupe keyed on the
  resolved path therefore processes one file **twice**. On 2026-09-17 that
  nearly wrote a duplicate standing-rule row into the workspace-root map; it was
  caught by comparing `st_ino`, not by the path check meant to stop it.
- On a case-sensitive filesystem -- any Linux CI runner -- the two names are
  genuinely different files. A reference written in the wrong case resolves on a
  developer's Mac and 404s in CI.

In practice:

- Create every new guidance file as `CLAUDE.md`.
- Renaming an existing one needs a temporary name or `git mv -f`; a direct
  `git mv claude.md CLAUDE.md` fails on a case-insensitive filesystem because
  the destination already exists.
- Update prose references to match, including the workspace-root map path.
- When enumerating these files, dedupe on `(st_dev, st_ino)`, never on a
  resolved path string.

---

## MUST: never commit to main — branch, PR, verify, merge, clean up

**No change reaches `main` in any repo except through a branch and a pull
request.** Not documentation, not a one-line fix, not a "trivial" follow-up, and
not a hotfix for a gate that is currently red. There is no size or urgency
threshold below which this stops applying.

The full workflow, every time:

1. **Branch from `origin/main`** — `git fetch origin main && git checkout -B <branch> origin/main`.
   Branch from the remote, not from whatever the local `main` happens to be: a
   stale local ref is how a change gets built on a tree that no longer exists.
2. **Commit** with a message that says what changed and *why*, including the
   evidence that motivated it.
3. **Push** and **open a PR**.
4. **Verify** — see the section above. State in the PR which gates ran, what
   they returned, and what could not be exercised.
5. **Merge** — squash, and delete the remote branch.
6. **Clean up** — delete the local branch, `git worktree prune`, and remove any
   run directories the work created.

Two things about cleanup that are easy to get wrong:

- **Squash-merged branches are not ancestors of `main`.** `git merge-base
  --is-ancestor` and "empty diff against origin/main" both report *nothing to
  delete*, and a branch that is merely behind `main` shows a diff full of
  reversions. `git branch -d` refuses them as "not fully merged". Ask the forge
  which PRs merged — `gh pr list --state merged --json headRefName` — confirm
  the branch is among them, and only then `git branch -D`.
- **Never delete a branch with an open PR.** Check state before pruning.

Why this is absolute: a direct commit to `main` has no diff anyone reviewed, no
place to record the verification, and nothing to revert cleanly if it is wrong.
It also breaks the only reliable cleanup signal — a merged PR — so the branch
inventory stops meaning anything.

---

## MUST: shell work runs in bash — `/opt/homebrew/bin/bash`, not zsh

**Shell work runs in bash 5 from Homebrew, `/opt/homebrew/bin/bash`.** Not the
interactive default zsh, and not macOS `/bin/bash`, which is 3.2 from 2007 (no
associative arrays, no `mapfile`, no `${var^^}`).

A command runner or agent tool that starts in zsh does not satisfy this by
default. Route the work through bash explicitly:

- **Any command with a loop, an unquoted variable, a glob, or `set --`** goes
  through `/opt/homebrew/bin/bash` — a heredoc (`/opt/homebrew/bin/bash <<'EOF'
  … EOF`) or a script file — with `set -euo pipefail`. A single plain command
  may run as it is.
- Quote globs regardless of shell; pass flag lists as arrays (`"${flags[@]}"`).
- **Check the exit status of the command you care about, not the tail of a
  pipeline.** `echo "exit=$?"` after a pipe reports the last stage, and
  `pgrep -f "<pattern>"` matches the watcher's own command line.

### Why

zsh differs from bash exactly where scripts are fragile, and the failures are
mostly *silent wrong answers*, not errors:

- An unquoted `$var` does not word-split: `c++ $CXXFLAGS file.cpp` passed every
  flag as one argument, so a "fast compile" measurement timed a failed
  invocation; `for i in $ids; do curl …/$i` sent the whole list as one malformed
  URL, so a cleanup removed nothing.
- `set -- $spec` does not split: a background wait on PR checks polled with empty
  arguments and never finished.
- An unmatched glob is fatal (`grep --include=*.py`, `ls dir/*.py`), and
  `echo ====` is `=cmd` expansion.

Every one of these happened in this workspace, several after the rule had
already been written down in an agent memory — which is why it is a contract
rule now rather than a note.

## Amending this file

Change it here, in a branch, through a PR, like anything else. Do not copy a
rule back into a repository's `CLAUDE.md`: the pointer is the mechanism, and a
local copy silently becomes a competing authority the moment this file moves on.

If a repository needs a rule that genuinely applies only to it, that belongs in
that repository's own `CLAUDE.md` under its own heading — not as a variant of a
rule stated here.
