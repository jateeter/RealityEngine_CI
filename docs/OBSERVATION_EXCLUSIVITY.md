# Observation exclusivity

**An observation is only valid if nothing else acted during it.**

Three separate cross-runtime "engine divergences" investigated in September 2026
turned out to be this one defect. Each was attributed to a runtime first — two
were closed as not reproducible — before the measurement was suspected. This
document exists so the fourth is recognised in minutes rather than days.

## Terminology

Two senses of *instance* appear throughout, and conflating them is most of the
confusion:

- **engine instance** — a runtime in the instance registry: `cpp-1`, `lsp-1`,
  `scala-1`. Addressed by `re_url` / `pe_url`.
- **app instance** — an actor that drives engine instances: the Manager, a
  Perception Engine, a regression stage, an MQTT bridge, an ACP agent, an
  operator with `curl`.

Every case below is one app instance acting inside another app instance's
measurement.

## The three instances

| issue | presented as | actually was |
|---|---|---|
| [#283](https://github.com/jateeter/RealityEngine_CI/issues/283) | a runtime failed to emit an arbitration record | records survive exactly one step; a concurrent PE push replaced them before the harness read |
| [#304](https://github.com/jateeter/RealityEngine_CI/issues/304) | LSP wrote 13 half-activated ISRE cells the others left at zero | MQTT fixtures reached the engine instances 65s apart against a 60s sensor TTL — some stale at read time, one not |
| [#307](https://github.com/jateeter/RealityEngine_CI/issues/307) | LSP recorded 9 trajectory entries for 8 pushes | an asynchronous push landed inside the drive; nothing in the history says who asked |

## How to recognise it

**Three independent implementations appearing to break the same way at the same
moment is nearly always the observer, not the observed.** Whichever engine
instance sits on the wrong side of a timing boundary looks defective, and it is
never the same one twice — which is precisely why it survives investigation and
gets refiled against a different runtime.

**It does not reproduce locally.** A local universe usually runs
`--no-openclaw --no-local-ai`, so the app instances that cause it do not exist.
*"Works here, fails on the lane"* should raise exclusivity before it raises the
engines.

## How to establish it

Build the observation plane before theorising. For #307 that was:

1. **Read every stage of the operation together** — push, OSRE produced, next
   ISRE ready — so a read landing mid-operation is detectable.
2. **Key on identity, not count.** `stepNumber` contiguity distinguishes "one
   operation recorded twice" from "another app instance acted". A length cannot.
3. **Sample during a quiet period.** Anything that grows while nothing is
   driving is an app instance you do not control.
4. **Induce the suspected race** rather than waiting for it. Reproducing the
   signature on demand is what turns a hypothesis into a cause — for #307, one
   concurrent push produced `n+1` contiguous entries for `n` driven, matching the
   reported signature exactly.

## Design consequences

1. **State the exclusivity requirement, and assert it.** A stage driving *n*
   operations requires the observed delta to equal *n*. On failure it reports
   *"another app instance acted during the drive"* — naming the condition
   instead of blaming a runtime. A measurement that assumes exclusivity without
   checking will eventually report someone else's work as a defect.
2. **Records should carry attribution.** The deepest problem in #307 is that
   nothing in the history says *who* pushed. An app-instance id on a recorded
   step would have made it a five-minute question. This is the same argument
   that put `instanceId` in `/api/engine/stats-next`.
3. **A defined observation point is contract, not implementation.**
   `totalActiveSequences` is sampled at the handoff of the completed OSRE for
   exactly this reason: "active" is unambiguous inside one engine instance and
   meaningless across three without a stated moment.
4. **Prefer naming the interference to suppressing it.** Quiescing other app
   instances changes what is being measured; ignoring the extra records hides a
   real signal about who else is writing. Report it.

## Why this grows

Two directions in flight increase the number of app instances sharing engine
instances:

- **[#278](https://github.com/jateeter/RealityEngine_CI/issues/278) step 6**
  merges three CI jobs into a single universe. Today each job gets a fresh boot
  and its residue dies with it; sharing one boot means concurrent app instances
  on the same engine instances, and residue that outlives the stage that made it.
- **Decision-driven deployments.** When agents act on engine state through ACP,
  multiple app instances drive the same engine instances *by design*. **Atomic
  action across app instances becomes the central design problem**, not an edge
  case — and every measurement taken while an agent may act needs an exclusivity
  story before its result means anything.
