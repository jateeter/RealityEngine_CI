#!/usr/bin/env node
/**
 * ces-sta-check — Single Transition Assumption analyzer.
 *
 * Hand-maintained `metadata.singleTransitionAssumption` blocks have been
 * the only record of "does this CES honor the one-bit-change-per-tick
 * invariant?".  Step 12 of the roadmap promotes that to a static
 * analyzer that walks the sequence graph mechanically.
 *
 * What the analyzer does, per machine:
 *
 *   1. For every sequence, enumerate intra-sequence transitions
 *      (vector V → V' where V' ∈ V.nextVectorIds AND V' is in the same
 *      sequence).  For each transition compute the Hamming distance
 *      between V.state and V'.state, where the per-element "state" is
 *      `value >= threshold` (with threshold default 0.5).
 *
 *   2. Flag intra-sequence HD > 1 — those are "multi-bit jumps" that
 *      can be silently aborted at runtime if any of the skipped
 *      intermediate states would have failed to match.
 *
 *   3. Compare the computed result against any hand-maintained
 *      `metadata.singleTransitionAssumption.compliant` claim and report
 *      drift (claim says "compliant: true" but a real HD>1 exists, or
 *      claim says "compliant: false" but the graph is clean).
 *
 *   4. For machines tagged `severity: "life-safety"`, intra-sequence
 *      STA violations are escalated to errors and fail `--check` so a
 *      CI gate refuses the deploy.  Non-life-safety machines surface
 *      warnings.
 *
 * Usage:
 *   node scripts/ces-sta-check.mjs --report                     # human-readable audit
 *   node scripts/ces-sta-check.mjs --report --json              # CI-friendly
 *   node scripts/ces-sta-check.mjs --check                      # exit 1 on life-safety violations
 *   node scripts/ces-sta-check.mjs --check --strict             # exit 1 on ANY violation
 *   node scripts/ces-sta-check.mjs --machines NAME,NAME         # scope to a subset
 *   node scripts/ces-sta-check.mjs --machines-dir DIR           # alternate corpus
 *
 * The analyzer is also exported (computeSta) so the Jest test suite and
 * MachineLoader can call into the same logic — see src/services/StaChecker.ts.
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const DEFAULT_DIR = path.join(ROOT, 'examples', 'machines');

// ── Pure analyzer (also imported from src/services/StaChecker.ts) ───────────

const DEFAULT_THRESHOLD = 0.5;

/** Element state: high iff element.value >= element.threshold (default 0.5). */
function elementState(el) {
  const t = (el && typeof el.threshold === 'number') ? el.threshold : DEFAULT_THRESHOLD;
  return (el?.value ?? 0) >= t ? 1 : 0;
}

/** Vector state: array of 0/1 over each element. */
function vectorState(v) {
  return (v.elements ?? []).map(elementState);
}

/** Hamming distance between two equal-length state arrays.  Returns null on length mismatch. */
function hammingDistance(a, b) {
  if (a.length !== b.length) return null;
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

/**
 * Compute the STA report for one machine JSON.  Returns:
 *   {
 *     machineId, machineName, lifeSafety, declared,
 *     sequences: [{ id, transitions: [...], maxIntraHD, anyViolation }],
 *     summary: { intraViolations, interJumps, drift: <string|null> }
 *   }
 */
export function computeSta(rawJsonOrObj) {
  const obj = typeof rawJsonOrObj === 'string' ? JSON.parse(rawJsonOrObj) : rawJsonOrObj;
  const m = obj.machine ?? obj;
  const machineId = m.id ?? null;
  const machineName = m.name ?? null;
  const md = m.metadata ?? {};
  const lifeSafety = md.severity === 'life-safety';
  const declared = md.singleTransitionAssumption ?? null;

  // Build a global vectorId → (sequenceId, vector) index so we can detect
  // inter-sequence jumps (rare but real in some demo machines).
  const indexByVector = new Map();
  for (const seq of m.sequences ?? []) {
    for (const v of seq.vectors ?? []) {
      indexByVector.set(v.id, { sequenceId: seq.id, vector: v });
    }
  }

  const sequences = [];
  let intraViolations = 0;
  let interJumps = 0;

  for (const seq of m.sequences ?? []) {
    const localByVector = new Map();
    for (const v of seq.vectors ?? []) localByVector.set(v.id, v);

    const transitions = [];
    let maxIntra = 0;
    let anyViolation = false;

    for (const v of seq.vectors ?? []) {
      const vState = vectorState(v);
      for (const nextId of v.nextVectorIds ?? []) {
        const local = localByVector.get(nextId);
        if (local) {
          const hd = hammingDistance(vState, vectorState(local));
          if (hd === null) {
            transitions.push({ from: v.id, to: nextId, kind: 'intra', hd: null, error: 'element-count-mismatch' });
            anyViolation = true;
            intraViolations++;
            continue;
          }
          maxIntra = Math.max(maxIntra, hd);
          const intra = { from: v.id, to: nextId, kind: 'intra', hd, fromState: vState, toState: vectorState(local) };
          if (hd > 1) { intra.violation = true; anyViolation = true; intraViolations++; }
          transitions.push(intra);
        } else {
          // nextVectorIds pointer lands in a different sequence (rare —
          // some demos use this for "exit to another workflow") OR
          // dangles (broken JSON).
          const found = indexByVector.get(nextId);
          if (found) {
            const hd = hammingDistance(vState, vectorState(found.vector));
            transitions.push({ from: v.id, to: nextId, kind: 'inter-sequence', hd, targetSequenceId: found.sequenceId });
            interJumps++;
          } else {
            transitions.push({ from: v.id, to: nextId, kind: 'dangling', hd: null, error: 'next vector id not found in machine' });
            anyViolation = true;
            intraViolations++;
          }
        }
      }
    }

    sequences.push({ id: seq.id, name: seq.name, transitions, maxIntraHD: maxIntra, anyViolation });
  }

  // Drift detection vs declared singleTransitionAssumption block.
  let drift = null;
  if (declared && typeof declared.compliant === 'boolean') {
    const computedCompliant = intraViolations === 0;
    if (declared.compliant !== computedCompliant) {
      drift = `declared compliant=${declared.compliant} but computed compliant=${computedCompliant}`;
    }
    if (typeof declared.maxHammingDistanceIntraSequence === 'number') {
      const declaredMax = declared.maxHammingDistanceIntraSequence;
      const computedMax = sequences.reduce((mx, s) => Math.max(mx, s.maxIntraHD), 0);
      if (declaredMax !== computedMax) {
        drift = (drift ? drift + '; ' : '') +
          `declared maxHammingDistanceIntraSequence=${declaredMax} but computed=${computedMax}`;
      }
    }
  }

  return {
    machineId, machineName, lifeSafety, declared,
    sequences,
    summary: { intraViolations, interJumps, drift },
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { report: false, check: false, json: false, strict: false, dir: DEFAULT_DIR, names: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--report') args.report = true;
    else if (a === '--check') args.check = true;
    else if (a === '--json') args.json = true;
    else if (a === '--strict') args.strict = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '--machines') args.names = new Set(argv[++i].split(',').filter(Boolean));
    else if (a === '-h' || a === '--help') { printHelp(); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  if (!args.report && !args.check) args.report = true;
  return args;
}

function printHelp() {
  console.log('Usage: ces-sta-check [--report|--check] [--json] [--strict] [--machines NAME,...] [--machines-dir DIR]');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`machines dir not found: ${args.dir}`); process.exit(2); }

  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json'))
    .filter(f => !args.names || args.names.has(f.replace(/\.json$/, '')))
    .sort();

  const results = [];
  for (const f of files) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(args.dir, f), 'utf8')); }
    catch (e) { continue; }
    const sta = computeSta(raw);
    sta.file = f;
    results.push(sta);
  }

  const lifeSafetyViolations = results.filter(r => r.lifeSafety && r.summary.intraViolations > 0);
  const otherViolations      = results.filter(r => !r.lifeSafety && r.summary.intraViolations > 0);
  const driftEntries         = results.filter(r => r.summary.drift);

  if (args.json) {
    console.log(JSON.stringify({
      tool: 'ces-sta-check', version: '1.0.0',
      machinesScanned: results.length,
      lifeSafetyViolations: lifeSafetyViolations.length,
      otherViolations: otherViolations.length,
      driftEntries: driftEntries.length,
      results,
    }, null, 2));
  } else if (args.report) {
    console.log(`ces-sta-check: ${results.length} machines scanned`);
    console.log(`  intra-sequence violations:        ${results.reduce((n, r) => n + r.summary.intraViolations, 0)}`);
    console.log(`  inter-sequence jumps:             ${results.reduce((n, r) => n + r.summary.interJumps, 0)}`);
    console.log(`  life-safety machines violating:   ${lifeSafetyViolations.length}`);
    console.log(`  non-life-safety machines violating: ${otherViolations.length}`);
    console.log(`  declared/computed drift:          ${driftEntries.length}`);

    for (const r of lifeSafetyViolations) {
      console.log(`\n  ✗ life-safety violation in ${r.file} (${r.machineName})`);
      for (const seq of r.sequences) {
        for (const t of seq.transitions) {
          if (t.violation || t.error) {
            console.log(`      ${seq.id}: ${t.from} → ${t.to}  HD=${t.hd}${t.error ? ` (${t.error})` : ''}`);
          }
        }
      }
    }
    for (const r of driftEntries) {
      console.log(`\n  ⚠ drift in ${r.file} — ${r.summary.drift}`);
    }
    if (otherViolations.length && args.strict) {
      console.log('\n  non-life-safety violations (--strict mode flags these too):');
      for (const r of otherViolations) console.log(`    ⚠ ${r.file}: ${r.summary.intraViolations} intra-seq HD>1`);
    }
  }

  if (args.check) {
    const fatal = lifeSafetyViolations.length + (args.strict ? otherViolations.length : 0);
    if (fatal > 0) {
      console.error(`\nces-sta-check FAILED: ${fatal} machine(s) violate STA`);
      process.exit(1);
    }
  }
}

// Only run the CLI when invoked directly — guards against double-execution
// when another script imports `computeSta` from this file (the import would
// otherwise trigger main()).
const __invokedAsScript = process.argv[1] && import.meta.url === new URL(process.argv[1], 'file://').href;
if (__invokedAsScript) main();
