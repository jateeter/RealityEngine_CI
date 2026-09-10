/**
 * What the tri-runtime comparison is entitled to compare, and how.
 *
 * The comparison this backs used to hash whatever `/api/*` responses the
 * browser happened to issue during the flow and require cpp, lsp and scala to
 * agree byte-for-byte on every one of them. That asserts more than
 * `SURFACE_SPEC.md` declares. Byte equivalence is a property the specification
 * grants a surface explicitly — `GET /api/engine/config` carries a "Byte
 * equivalence applies" heading and says why — and a response captured because
 * a React component happened to fetch it inherits no such grant. The gate was
 * therefore reporting divergence on payloads nothing had ever claimed must be
 * identical.
 *
 * Two of them failed the hosted lane on 2026-09-08 (#321). One is an allowance
 * this module declares; the other turned out to be a real defect, and telling
 * them apart is the reason a declared surface beats a blanket hash.
 *
 * - `POST /api/pe/sources/bootstrap-from-machines` — lsp answers
 *   `{"created":17,...,"skipped":0}` where cpp and scala answer
 *   `{"created":0,...,"skipped":17}`. Same `machinesSeen`, same `success`,
 *   same `errors`. The counters report what this idempotent call *did* given
 *   what was already registered, which is downstream of the known reset
 *   divergence (`scripts/CLAUDE.md`, #163): lsp's reset discards its sources
 *   so the call creates them, cpp's keeps them so the call skips them.
 *
 * `GET /api/machines` was the other one, and it was *not* an allowance. Scala
 * emitted 125629 bytes against 124066 for cpp and lsp, and the whole 1563-byte
 * delta was one key: `sequences[].initialEventIds`. It looked like permitted
 * internal augmentation and was not, because it has a consumer. The Scala PE
 * builds its machine corpus from this exact route and reads that key for
 * `provenance()` — see `MachineCorpus.scala`, whose header states "everything
 * comes from `GET /api/machines` ... and each sequence's initial vector ids".
 * cpp and lsp emitted a `{id, name}` summary on the non-`full` path this route
 * takes, so a Scala PE paired with a cpp or lsp RE silently got an empty audit
 * trail. That was a conformance gap, so it stayed compared rather than being
 * filtered — and filtering it would have hidden a defect with a consumer behind
 * the rule written for fields that have none.
 *
 * **Both runtimes now emit the key** (`RealityEngine_CPP#91`,
 * `RealityEngine_LSP#105`, settled in `SURFACE_SPEC.md`, "Open gaps"), so this
 * surface agrees. The rule below is unchanged and stays `projection` with no
 * allowance: it is what would report the key again were it ever dropped.
 *
 * The answer is not a looser comparison, it is a declared one. Every signature
 * the three runtimes have in common resolves to a rule in `PARITY_SURFACE`
 * that states what agreement means for that surface and why. An allowance is a
 * named key with a citation, not a suppressed failure — and what an allowance
 * gives up is separately covered, which is the test of whether it is honest:
 * the bootstrap counters stop being compared, and `GET /api/pe/sources` proves
 * byte-for-byte that all three runtimes ended up holding the same 17 sources.
 *
 * The shared rules about identity filtering live in
 * `scripts/lib/parity_identity.py` and are deliberately *not* mirrored here.
 * That module strips engine-minted ids because the payloads it compares — push
 * responses, trajectory histories — carry ids invented per process. These
 * captures do not, so importing the same filter would drop real content and
 * cost the comparison its teeth. What both layers do share is the boundary
 * rule from `SURFACE_SPEC.md`, "The observable boundary": internal
 * augmentation is filtered at the boundary and reported, never replicated into
 * the other runtimes (#208, #281).
 */

export type Runtime = 'lsp' | 'scala' | 'cpp';

/**
 * How much agreement a surface is held to.
 *
 * - `bytes` — the response bodies must be identical. Presentation is part of
 *   the API, so whitespace and key order count.
 * - `projection` — identical after the rule's declared allowances are removed.
 *   Serialization whitespace normalizes away; key order and array order do
 *   not, because ordering is evidence (`SURFACE_SPEC.md`, "Order is not part
 *   of the evidence unless a field declares one").
 * - `observed` — captured and reported, never compared.
 */
export type Strictness = 'bytes' | 'projection' | 'observed';

export interface SurfaceRule {
  compare: Strictness;
  /** Why this surface is held to this much, in terms a reader can check. */
  why: string;
  /**
   * Internal augmentation: a representation one runtime finds useful and
   * another has no need for, riding on an observable payload and consumed by
   * nothing. Removed at any depth before comparing, and reported.
   * `SURFACE_SPEC.md`, "The observable boundary".
   */
  boundaryFiltered?: readonly string[];
  /**
   * Values that report what a call did given prior state rather than what the
   * surface holds. Two runtimes that reached the same state by different
   * histories disagree here while agreeing on the state itself.
   */
  historyDependent?: readonly string[];
}

/**
 * An undeclared surface is byte-compared, which is what this comparison did
 * for every surface before rules existed. Declaring nothing therefore changes
 * nothing, and a route that joins the flow later cannot slip in under a weaker
 * rule than its peers — it either agrees byte-for-byte or it fails asking to
 * be classified.
 */
export const DEFAULT_RULE: SurfaceRule = {
  compare: 'bytes',
  why: 'undeclared surface — byte-compared by default until classified in PARITY_SURFACE',
};

const EXACT: Readonly<Record<string, SurfaceRule>> = {
  'GET /api/health': {
    compare: 'bytes',
    why: '`{"status":"healthy"}` — no clock, no counter, nothing runtime-local',
  },
  'GET /api/pe/health': {
    compare: 'bytes',
    why: 'as `GET /api/health`, on the PE half of the pair',
  },
  'GET /api/engine/active': {
    compare: 'bytes',
    why:
      'the active CES events after an identical reset and import. Ids here are ' +
      'corpus-declared (`arb-c-event-zero`), so identity filtering would remove ' +
      'the handle that says which event fired',
  },
  'GET /api/machine-graph': {
    compare: 'bytes',
    why: 'derived from the corpus alone; nothing in it is runtime-local',
  },
  'GET /api/pe/state': {
    compare: 'bytes',
    why: 'the assembled input space after the same stimulus — the point of the comparison',
  },
  'GET /api/pe/sources': {
    compare: 'bytes',
    why:
      'the declared source set. Held to bytes deliberately: it is what carries ' +
      'the coverage the bootstrap allowance below gives up',
  },
  'GET /api/pe/mqtt/mappings': {
    compare: 'bytes',
    why: '`{"enabled":false,"mappings":[]}` — configuration, identical by construction',
  },
  'POST /api/pe/reset': {
    compare: 'bytes',
    why: '`{"success":true}`',
  },

  'GET /api/machines': {
    compare: 'projection',
    // No allowance, deliberately. `sequences[].initialEventIds` has a consumer —
    // the Scala PE reads it here for `provenance()` — so a runtime dropping it
    // is a conformance gap, not internal augmentation. All three emit it as of
    // CPP#91 / LSP#105; this rule is what reports it again if one stops.
    // `projection` rather than `bytes` only so the finding arrives as a named
    // key instead of a byte count.
    why:
      'the loaded corpus, which every runtime read from the same machine files. ' +
      'Compared in full, with no allowance: `sequences[].initialEventIds` is ' +
      'consumed by the Scala PE off this exact route (MachineCorpus.scala), so ' +
      'a runtime omitting it hands the PE an empty audit trail and no error',
  },
  'POST /api/pe/sources/bootstrap-from-machines': {
    compare: 'projection',
    historyDependent: ['created', 'skipped'],
    why:
      '`created` and `skipped` report what this idempotent call did given what ' +
      'was already registered, so they carry the reset divergence (#163) rather ' +
      'than anything about this call. `machinesSeen`, `success` and `errors` are ' +
      'the surface and stay compared; the resulting source set is compared ' +
      'byte-for-byte by `GET /api/pe/sources`',
  },
};

const PATTERNS: ReadonlyArray<{ match: RegExp; rule: SurfaceRule }> = [
  {
    // Manager control plane, not a runtime surface: these answer questions
    // about which instances the registry holds and which one is selected, and
    // vary by engine instance on purpose.
    match: /^GET \/api\/engines(\/[^/]+\/health)?$/,
    rule: { compare: 'observed', why: 'Manager control plane — varies by selected instance by design' },
  },
  {
    match: /^(GET|POST) \/api\/engines\/active$/,
    rule: { compare: 'observed', why: 'Manager control plane — the engine switch itself' },
  },
];

export function ruleFor(signature: string): SurfaceRule {
  const exact = EXACT[signature];
  if (exact) return exact;
  for (const { match, rule } of PATTERNS) {
    if (match.test(signature)) return rule;
  }
  return DEFAULT_RULE;
}

export function isDeclared(signature: string): boolean {
  return ruleFor(signature) !== DEFAULT_RULE;
}

type Json = unknown;

/**
 * Remove `keys` wherever they appear, at any depth.
 *
 * Depth is the whole point. `valuesPacked` was reported nowhere for months
 * while the docstring claiming to report it looked one level above where it
 * lived (#281); a top-level-only filter here would miss
 * `machines[].sequences[].initialEventIds` in exactly the same way.
 */
function dropKeys(value: Json, keys: ReadonlySet<string>): Json {
  if (Array.isArray(value)) return value.map(v => dropKeys(v, keys));
  if (value && typeof value === 'object') {
    const out: Record<string, Json> = {};
    // Insertion order preserved: a runtime presenting the same content in a
    // different order has diverged, and the comparison must still say so.
    for (const [k, v] of Object.entries(value as Record<string, Json>)) {
      if (keys.has(k)) continue;
      out[k] = dropKeys(v, keys);
    }
    return out;
  }
  return value;
}

/**
 * One runtime's comparable content for a surface, as a deterministic string.
 *
 * JSON's single number type does the work `parity_identity.canonical_numbers`
 * does in Python: `0` and `0.0` both parse to the same value here, so the
 * rendering difference that produced a retracted 13-cell divergence cannot
 * recur through this path.
 */
export function project(body: Buffer, rule: SurfaceRule): { text: string; parsed: boolean } {
  if (rule.compare !== 'projection') return { text: body.toString('utf8'), parsed: false };

  let value: Json;
  try {
    value = JSON.parse(body.toString('utf8'));
  } catch {
    // A projection rule on a non-JSON body cannot mean anything, so fall back
    // to the bytes rather than silently comparing nothing.
    return { text: body.toString('utf8'), parsed: false };
  }

  const drop = new Set([...(rule.boundaryFiltered ?? []), ...(rule.historyDependent ?? [])]);
  return { text: JSON.stringify(dropKeys(value, drop)), parsed: true };
}

/**
 * Keys some runtimes emit and others do not, as dotted paths.
 *
 * Reported, never compared — the question of whether a runtime is *required*
 * to emit a key is a contract question, and answering it inside a value
 * comparison is what let a shape divergence masquerade as a behavioural one.
 * Mirrors `parity_identity.shape_only_keys`, including its nested walk.
 */
export function shapeOnlyKeys(payloads: Record<string, Json>): Record<string, string[]> {
  const out: Record<string, string[]> = {};

  const walk = (values: Record<string, Json>, path: string): void => {
    const entries = Object.entries(values);
    if (entries.every(([, v]) => v !== null && typeof v === 'object' && !Array.isArray(v))) {
      const keySets = entries.map(([, v]) => new Set(Object.keys(v as object)));
      const common = [...keySets[0]].filter(k => keySets.every(s => s.has(k)));
      const commonSet = new Set(common);
      for (const [name, v] of entries) {
        for (const key of Object.keys(v as object)) {
          if (!commonSet.has(key)) {
            (out[name] ??= []).push(path ? `${path}.${key}` : key);
          }
        }
      }
      for (const key of common) {
        walk(Object.fromEntries(entries.map(([n, v]) => [n, (v as Record<string, Json>)[key]])), path ? `${path}.${key}` : key);
      }
      return;
    }
    // Homogeneous record arrays: index 0 stands for the array, so one finding
    // is not buried under its own repetitions.
    if (entries.every(([, v]) => Array.isArray(v) && (v as Json[]).length > 0)) {
      walk(Object.fromEntries(entries.map(([n, v]) => [n, (v as Json[])[0]])), `${path}[]`);
    }
  };

  walk(payloads, '');
  for (const name of Object.keys(out)) out[name] = [...new Set(out[name])].sort();
  return out;
}

export interface SurfaceFinding {
  signature: string;
  compare: Strictness;
  why: string;
  /** True when no rule claimed this signature and the default applied. */
  undeclared: boolean;
  status: Record<Runtime, number>;
  byteLength: Record<Runtime, number>;
  sha256: Record<Runtime, string>;
  /** Populated on `projection` surfaces; reported whether or not they matched. */
  shapeOnly?: Record<string, string[]>;
  allowances?: string[];
}

export interface SurfaceCapture {
  status: number;
  body: Buffer;
  sha256: string;
}

/**
 * Compare one signature across the three runtimes under its declared rule.
 *
 * Returns `null` when they agree, or when the rule says this surface is
 * observed rather than compared.
 */
export function compareSurface(
  signature: string,
  captures: Record<Runtime, SurfaceCapture>,
): SurfaceFinding | null {
  const rule = ruleFor(signature);
  const runtimes: Runtime[] = ['lsp', 'scala', 'cpp'];

  const shapeOnly =
    rule.compare === 'projection'
      ? shapeOnlyKeys(
          Object.fromEntries(
            runtimes.map(r => {
              try {
                return [r, JSON.parse(captures[r].body.toString('utf8'))];
              } catch {
                return [r, null];
              }
            }),
          ),
        )
      : undefined;

  if (rule.compare === 'observed') return null;

  const sameStatus = runtimes.every(r => captures[r].status === captures.lsp.status);
  const projected = Object.fromEntries(
    runtimes.map(r => [r, project(captures[r].body, rule).text]),
  ) as Record<Runtime, string>;
  const sameContent = runtimes.every(r => projected[r] === projected.lsp);

  if (sameStatus && sameContent) return null;

  const allowances = [...(rule.boundaryFiltered ?? []), ...(rule.historyDependent ?? [])];
  return {
    signature,
    compare: rule.compare,
    why: rule.why,
    undeclared: rule === DEFAULT_RULE,
    status: Object.fromEntries(runtimes.map(r => [r, captures[r].status])) as Record<Runtime, number>,
    byteLength: Object.fromEntries(runtimes.map(r => [r, captures[r].body.length])) as Record<Runtime, number>,
    sha256: Object.fromEntries(runtimes.map(r => [r, captures[r].sha256])) as Record<Runtime, string>,
    ...(shapeOnly && Object.keys(shapeOnly).length ? { shapeOnly } : {}),
    ...(allowances.length ? { allowances } : {}),
  };
}

/** One line per finding, saying what disagreed and what the rule allowed. */
export function describeFinding(finding: SurfaceFinding): string {
  const bytes = `lsp=${finding.byteLength.lsp} scala=${finding.byteLength.scala} cpp=${finding.byteLength.cpp}`;
  const head = finding.undeclared
    ? `${finding.signature} [undeclared surface — classify it in e2e/lib/parity-surface.ts]`
    : `${finding.signature} [${finding.compare}]`;
  const allowed = finding.allowances?.length ? `\n    allowed here: ${finding.allowances.join(', ')}` : '';
  const shape = finding.shapeOnly
    ? `\n    shape-only keys: ${JSON.stringify(finding.shapeOnly)}`
    : '';
  return `  ${head}\n    bytes: ${bytes}\n    why this surface is compared: ${finding.why}${allowed}${shape}`;
}
