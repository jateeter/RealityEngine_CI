#!/usr/bin/env node
/**
 * ces-diff — Critical Event Sequence diff / migration tooling.
 *
 * Given two machine JSON files (old + new), reports:
 *
 *   • Structural diff — vectors added / removed / modified, sequences added /
 *     removed / modified, perceptualMapping changes, metadata.compose changes.
 *
 *   • Behavioral diff — for every oracle in examples/oracles.json that targets
 *     this machine, run both versions through PerceptualSpaceSimulator and
 *     compare the resulting mergeBatch.  Reports four kinds of behavioral
 *     change per oracle: now-fires, no-longer-fires, values-changed,
 *     provenance-changed.
 *
 *   • Life-safety risk tagging — escalates structural changes that touch
 *     output values, provenance chains, or perceptualMapping; flagged so an
 *     operator can refuse to merge without explicit review.
 *
 * Required preconditions for evolving life-safety CES logic:
 *   1. ces-diff completes without errors.
 *   2. Every behavioral delta is acknowledged (or the new behavior is
 *      explicitly preferred → migrate via --apply-oracle-updates).
 *   3. The risk score is below the threshold the team has agreed on for the
 *      reviewing pair.
 *
 * Usage:
 *   node scripts/ces-diff.mjs --left <old.json> --right <new.json>
 *   node scripts/ces-diff.mjs --left <old.json> --right <new.json> --json
 *   node scripts/ces-diff.mjs --left <old.json> --right <new.json> --apply-oracle-updates --i-understand-the-risk
 *
 * The script requires `npm run build` to have been run — it imports the
 * compiled engine from `dist/`.
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

// ── CLI ──────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = {
    left: null, right: null,
    json: false,
    applyOracleUpdates: false,
    acknowledged: false,
    oraclesFile: path.join(ROOT, 'examples', 'oracles.json'),
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--left')                       args.left = argv[++i];
    else if (a === '--right')                 args.right = argv[++i];
    else if (a === '--json')                  args.json = true;
    else if (a === '--apply-oracle-updates')  args.applyOracleUpdates = true;
    else if (a === '--i-understand-the-risk') args.acknowledged = true;
    else if (a === '--oracles')               args.oraclesFile = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help')    { printHelp(); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  if (!args.left || !args.right) { printHelp(); process.exit(2); }
  return args;
}

function printHelp() {
  console.log('Usage: ces-diff --left <old.json> --right <new.json> [--json] [--apply-oracle-updates --i-understand-the-risk] [--oracles PATH]');
}

// ── Structural diff ──────────────────────────────────────────────────────────

function unpackMachine(rawJson) {
  const obj = JSON.parse(rawJson);
  return obj.machine ?? obj;
}

/**
 * Compare element arrays.  Returns null if structurally identical, else an
 * object describing the diff at element granularity.  We compare value,
 * threshold, and comparatorType — every input a vector exposes to the
 * matcher.
 */
function diffElements(left, right) {
  const max = Math.max(left.length, right.length);
  const perIndex = [];
  let anyChange = false;
  for (let i = 0; i < max; i++) {
    const l = left[i] ?? null;
    const r = right[i] ?? null;
    const changed = JSON.stringify(l) !== JSON.stringify(r);
    if (changed) anyChange = true;
    perIndex.push({ index: i, before: l, after: r, changed });
  }
  return anyChange ? { perIndex } : null;
}

function diffVector(left, right) {
  const changes = {};
  if (left.isInitial !== right.isInitial) changes.isInitial = { before: left.isInitial, after: right.isInitial };

  const elementDiff = diffElements(left.elements ?? [], right.elements ?? []);
  if (elementDiff) changes.elements = elementDiff;

  const lNext = (left.nextVectorIds ?? []).slice().sort();
  const rNext = (right.nextVectorIds ?? []).slice().sort();
  if (JSON.stringify(lNext) !== JSON.stringify(rNext)) changes.nextVectorIds = { before: left.nextVectorIds ?? [], after: right.nextVectorIds ?? [] };

  const lOut = JSON.stringify(left.outputVectors ?? []);
  const rOut = JSON.stringify(right.outputVectors ?? []);
  if (lOut !== rOut) changes.outputVectors = { before: left.outputVectors ?? [], after: right.outputVectors ?? [] };

  return Object.keys(changes).length === 0 ? null : changes;
}

function diffSequences(left, right) {
  const lById = new Map();
  for (const s of left ?? []) lById.set(s.id, s);
  const rById = new Map();
  for (const s of right ?? []) rById.set(s.id, s);

  const added = [];
  const removed = [];
  const modified = [];

  for (const [id, seq] of lById) {
    if (!rById.has(id)) { removed.push({ sequenceId: id, name: seq.name }); continue; }
    const r = rById.get(id);
    const lvById = new Map();
    for (const v of seq.vectors ?? []) lvById.set(v.id, v);
    const rvById = new Map();
    for (const v of r.vectors ?? []) rvById.set(v.id, v);

    const vAdded = [], vRemoved = [], vModified = [];
    for (const [vid, lv] of lvById) {
      if (!rvById.has(vid)) { vRemoved.push(vid); continue; }
      const d = diffVector(lv, rvById.get(vid));
      if (d) vModified.push({ vectorId: vid, changes: d });
    }
    for (const [vid] of rvById) if (!lvById.has(vid)) vAdded.push(vid);

    if (vAdded.length || vRemoved.length || vModified.length || (seq.name !== r.name)) {
      const entry = {
        sequenceId: id,
        ...(seq.name !== r.name ? { nameChange: { before: seq.name, after: r.name } } : {}),
        ...(vAdded.length ? { vectorsAdded: vAdded } : {}),
        ...(vRemoved.length ? { vectorsRemoved: vRemoved } : {}),
        ...(vModified.length ? { vectorsModified: vModified } : {}),
      };
      modified.push(entry);
    }
  }
  for (const [id, seq] of rById) if (!lById.has(id)) added.push({ sequenceId: id, name: seq.name });

  return { added, removed, modified };
}

function diffMachine(leftRaw, rightRaw) {
  const L = unpackMachine(leftRaw);
  const R = unpackMachine(rightRaw);

  const structural = {
    name:        L.name === R.name ? null : { before: L.name, after: R.name },
    description: L.description === R.description ? null : { before: L.description, after: R.description },
    perceptualMapping: JSON.stringify(L.perceptualMapping) === JSON.stringify(R.perceptualMapping)
      ? null : { before: L.perceptualMapping, after: R.perceptualMapping },
    arbiterRule: L.arbiterRule === R.arbiterRule ? null : { before: L.arbiterRule, after: R.arbiterRule },
    compose:     JSON.stringify(L.metadata?.compose ?? null) === JSON.stringify(R.metadata?.compose ?? null)
      ? null : { before: L.metadata?.compose ?? null, after: R.metadata?.compose ?? null },
    sequences:   diffSequences(L.sequences, R.sequences),
  };

  return { left: L, right: R, structural };
}

// ── Risk tagging ─────────────────────────────────────────────────────────────

/**
 * Assign a coarse risk level to a structural diff.  The rule of thumb is
 * conservative: any change to a vector's elements, any change to the
 * output values, and any change to perceptualMapping is high-risk because
 * each can silently shift what gets asserted.  Lower-risk changes:
 * cosmetic name/description, transition-graph additions that don't touch
 * existing paths.
 */
function tagRisk(structural) {
  const advisories = [];
  let high = false, medium = false;

  if (structural.perceptualMapping) {
    high = true;
    advisories.push('perceptualMapping changed — every existing oracle and every interconnected machine is affected.');
  }
  if (structural.compose) {
    high = true;
    advisories.push('metadata.compose subscriptions changed — meta-CES wiring will rewire across runtimes.');
  }
  for (const seq of structural.sequences.removed) {
    high = true;
    advisories.push(`Sequence ${seq.sequenceId} removed — any oracle on that sequence will fail.`);
  }
  for (const seq of structural.sequences.added) {
    medium = true;
    advisories.push(`Sequence ${seq.sequenceId} added — new behavior; no existing oracle covers it.`);
  }
  for (const seq of structural.sequences.modified) {
    if (seq.vectorsRemoved?.length) {
      high = true;
      advisories.push(`${seq.sequenceId}: vectors removed ${JSON.stringify(seq.vectorsRemoved)} — chains using them will no longer terminate.`);
    }
    for (const vm of seq.vectorsModified ?? []) {
      if (vm.changes.outputVectors) {
        high = true;
        advisories.push(`${seq.sequenceId}/${vm.vectorId}: output values changed — asserter contract broken; downstream listeners affected.`);
      }
      if (vm.changes.elements) {
        high = true;
        advisories.push(`${seq.sequenceId}/${vm.vectorId}: matching elements changed — vector now activates on different input.`);
      }
      if (vm.changes.nextVectorIds) {
        medium = true;
        advisories.push(`${seq.sequenceId}/${vm.vectorId}: nextVectorIds changed — transition graph altered; provenance chains may differ.`);
      }
      if (vm.changes.isInitial) {
        high = true;
        advisories.push(`${seq.sequenceId}/${vm.vectorId}: isInitial flipped — sequence entry points changed.`);
      }
    }
  }
  return { level: high ? 'high' : medium ? 'medium' : 'low', advisories };
}

// ── Behavioral diff via the engine ───────────────────────────────────────────

async function loadEngine() {
  const sim = await import(path.join(ROOT, 'dist', 'engine', 'PerceptualSpaceSimulator.js'));
  const loader = await import(path.join(ROOT, 'dist', 'services', 'MachineLoader.js'));
  return { sim, loader };
}

/**
 * Silence the engine's `[PE]` growth logs and similar console.log noise
 * while we're running simulations.  Without this, --json mode produces
 * a stream of log lines mixed with the report and downstream parsers
 * break.  Restored on exit.
 */
function silenceConsoleDuringEngine(fn) {
  const origLog = console.log;
  const origInfo = console.info;
  console.log = () => {};
  console.info = () => {};
  return Promise.resolve(fn()).finally(() => {
    console.log = origLog;
    console.info = origInfo;
  });
}

function denseInput(region, values) {
  const v = new Array(region.offset + region.length).fill(0);
  const n = Math.min(region.length, values.length);
  for (let i = 0; i < n; i++) v[region.offset + i] = values[i];
  return v;
}

async function runOracleAgainst(rawMachineJson, oracleId, oracles, sim, loader) {
  // Find the oracle by id.
  const o = oracles.oracles.find(x => x.id === oracleId);
  if (!o) return null;
  const machine = loader.MachineLoader.loadFromJSON(rawMachineJson, `diff::${oracleId}::${Date.now()}::${Math.random()}`);
  const s = new sim.PerceptualSpaceSimulator(0);
  s.addMachine(machine);
  let last = null;
  for (const stepInput of o.inputs) last = s.processImmediate(denseInput(o.inputRegion, stepInput));
  return last?.mergeBatch ?? [];
}

function arraysEqual(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return a === b;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * Locate the mergeBatch entry attributable to this oracle's emitter — the
 * vector whose match would have produced the oracle's output.  Selectors,
 * in priority order:
 *
 *   1. sequenceId match + provenance chain ending at the emitter vectorId
 *      (the strongest selector — survives multi-fire sibling outputs and
 *      Kleene-style alternative paths).
 *   2. sequenceId match alone (fallback for older engines without provenance).
 *
 * Crucially we do NOT use the oracle's expected.values as a selector — that
 * would conflate "this emitter still fires" with "this emitter still fires
 * with the original values", making a values-changed diff look like a
 * no-longer-fires diff.
 */
function findMatch(mergeBatch, oracle) {
  const byChain = mergeBatch.find(op =>
    op.sequenceId === oracle.sequenceId &&
    Array.isArray(op.provenance) && op.provenance.length > 0 &&
    op.provenance[op.provenance.length - 1] === oracle.vectorId);
  if (byChain) return byChain;
  return mergeBatch.find(op =>
    op.sequenceId === oracle.sequenceId &&
    op.region.offset === oracle.expected.region.offset &&
    op.region.length === oracle.expected.region.length);
}

async function behavioralDiff(leftRaw, rightRaw, args) {
  const oracles = JSON.parse(fs.readFileSync(args.oraclesFile, 'utf8'));
  // The oracle generator scopes oracles by machineFile (the JSON filename)
  // because the loaded machine's `id` is generated at load time when the
  // JSON omits a top-level id.  Match the same convention here.
  const rightFile = path.basename(args.right);
  let relevant = oracles.oracles.filter(o => o.machineFile === rightFile);
  if (relevant.length === 0) {
    // Fallback: if the source file is a temp copy, try matching the left file's name.
    const leftFile = path.basename(args.left);
    relevant = oracles.oracles.filter(o => o.machineFile === leftFile);
  }
  if (relevant.length === 0) return { deltas: [], oraclesConsidered: 0 };

  const { sim, loader } = await loadEngine();

  const deltas = [];
  for (const o of relevant) {
    let leftBatch, rightBatch, leftErr = null, rightErr = null;
    try { leftBatch  = await runOracleAgainst(leftRaw,  o.id, oracles, sim, loader); }  catch (e) { leftErr  = e.message; }
    try { rightBatch = await runOracleAgainst(rightRaw, o.id, oracles, sim, loader); } catch (e) { rightErr = e.message; }

    const leftHit  = leftErr  ? null : findMatch(leftBatch,  o);
    const rightHit = rightErr ? null : findMatch(rightBatch, o);

    let changeKind = null;
    if (leftErr || rightErr) changeKind = 'engine-error';
    else if (leftHit && !rightHit)  changeKind = 'no-longer-fires';
    else if (!leftHit && rightHit)  changeKind = 'now-fires';
    else if (leftHit && rightHit) {
      if (!arraysEqual(leftHit.values, rightHit.values))             changeKind = 'values-changed';
      else if (JSON.stringify(leftHit.provenance) !== JSON.stringify(rightHit.provenance)) changeKind = 'provenance-changed';
    }

    if (changeKind) {
      deltas.push({
        oracleId: o.id,
        sequenceId: o.sequenceId,
        vectorId: o.vectorId,
        kind: o.kind,
        depth: o.depth,
        inputs: o.inputs,
        changeKind,
        before: leftHit  ? { values: leftHit.values,  provenance: leftHit.provenance  } : null,
        after:  rightHit ? { values: rightHit.values, provenance: rightHit.provenance } : null,
        leftError: leftErr, rightError: rightErr,
      });
    }
  }
  return { deltas, oraclesConsidered: relevant.length };
}

// ── Oracle migration ─────────────────────────────────────────────────────────

function applyOracleUpdates(oraclesFile, behavioralDeltas) {
  const data = JSON.parse(fs.readFileSync(oraclesFile, 'utf8'));
  const updates = [];
  const removals = [];

  // For each delta we know the new ground-truth from running the new
  // machine.  Rewrite the corresponding oracle's `expected` accordingly,
  // OR drop the oracle if the sequence no longer fires.
  const byId = new Map();
  for (const o of data.oracles) byId.set(o.id, o);

  for (const d of behavioralDeltas) {
    const o = byId.get(d.oracleId);
    if (!o) continue;
    if (d.changeKind === 'no-longer-fires') {
      removals.push(o.id);
      continue;
    }
    if (!d.after) continue;
    o.expected.values = d.after.values;
    if (Array.isArray(d.after.provenance)) o.expected.provenance = d.after.provenance;
    updates.push(o.id);
  }

  // Drop removed oracles by filtering.
  data.oracles = data.oracles.filter(o => !removals.includes(o.id));
  data.oracleCount = data.oracles.length;

  fs.writeFileSync(oraclesFile, JSON.stringify(data, null, 2) + '\n');
  return { updated: updates.length, removed: removals.length };
}

// ── Output formatting ────────────────────────────────────────────────────────

function summarize(structural) {
  const seq = structural.sequences;
  let vectorsModified = 0, vectorsAdded = 0, vectorsRemoved = 0;
  for (const s of seq.modified) {
    vectorsModified += s.vectorsModified?.length ?? 0;
    vectorsAdded    += s.vectorsAdded?.length    ?? 0;
    vectorsRemoved  += s.vectorsRemoved?.length  ?? 0;
  }
  return {
    sequencesAdded:   seq.added.length,
    sequencesRemoved: seq.removed.length,
    sequencesModified: seq.modified.length,
    vectorsAdded, vectorsRemoved, vectorsModified,
    perceptualMappingChanged: structural.perceptualMapping !== null,
    composeChanged:           structural.compose !== null,
    nameChanged:              structural.name !== null,
    descriptionChanged:       structural.description !== null,
  };
}

function renderHuman(report) {
  const lines = [];
  lines.push(`ces-diff: ${report.left.name} → ${report.right.name}`);
  lines.push(`  risk: ${report.risk.level.toUpperCase()}`);
  lines.push('');
  lines.push('Structural:');
  lines.push(`  sequences added/removed/modified: ${report.summary.sequencesAdded}/${report.summary.sequencesRemoved}/${report.summary.sequencesModified}`);
  lines.push(`  vectors   added/removed/modified: ${report.summary.vectorsAdded}/${report.summary.vectorsRemoved}/${report.summary.vectorsModified}`);
  lines.push(`  perceptualMapping changed: ${report.summary.perceptualMappingChanged}`);
  lines.push(`  metadata.compose  changed: ${report.summary.composeChanged}`);
  for (const s of report.structural.sequences.modified) {
    lines.push(`  sequence ${s.sequenceId}:`);
    if (s.vectorsAdded?.length)   lines.push(`    + ${s.vectorsAdded.join(', ')}`);
    if (s.vectorsRemoved?.length) lines.push(`    - ${s.vectorsRemoved.join(', ')}`);
    for (const v of s.vectorsModified ?? []) {
      const kinds = Object.keys(v.changes).join(', ');
      lines.push(`    ~ ${v.vectorId}  [${kinds}]`);
    }
  }
  if (report.risk.advisories.length) {
    lines.push('');
    lines.push('Advisories:');
    for (const a of report.risk.advisories) lines.push(`  ⚠ ${a}`);
  }
  lines.push('');
  lines.push(`Behavioral: ${report.behavioral.oraclesConsidered} oracles considered, ${report.behavioral.deltas.length} delta(s)`);
  for (const d of report.behavioral.deltas) {
    lines.push(`  ${d.changeKind.padEnd(18)} ${d.oracleId}`);
    if (d.before) lines.push(`    before: values=${JSON.stringify(d.before.values)} prov=${JSON.stringify(d.before.provenance)}`);
    if (d.after)  lines.push(`    after : values=${JSON.stringify(d.after.values)}  prov=${JSON.stringify(d.after.provenance)}`);
  }
  return lines.join('\n');
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const leftRaw  = fs.readFileSync(args.left,  'utf8');
  const rightRaw = fs.readFileSync(args.right, 'utf8');

  const { left, right, structural } = diffMachine(leftRaw, rightRaw);
  const risk = tagRisk(structural);

  let behavioral = { deltas: [], oraclesConsidered: 0 };
  if (fs.existsSync(args.oraclesFile)) {
    behavioral = await silenceConsoleDuringEngine(() => behavioralDiff(leftRaw, rightRaw, args));
  }

  const report = {
    tool: 'ces-diff', version: '1.0.0',
    left:  { file: args.left,  machineId: left.id  ?? null, name: left.name  ?? null },
    right: { file: args.right, machineId: right.id ?? null, name: right.name ?? null },
    risk,
    summary: summarize(structural),
    structural,
    behavioral,
  };

  if (args.applyOracleUpdates) {
    if (!args.acknowledged) {
      console.error('--apply-oracle-updates requires --i-understand-the-risk to acknowledge that behavioral assertions are being rewritten.');
      process.exit(2);
    }
    const result = applyOracleUpdates(args.oraclesFile, behavioral.deltas);
    report.oracleMigration = { ...result, file: args.oraclesFile };
  }

  if (args.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(renderHuman(report));
    if (args.applyOracleUpdates) {
      console.log(`\noracle migration: updated=${report.oracleMigration.updated} removed=${report.oracleMigration.removed} → ${report.oracleMigration.file}`);
    }
  }

  // Exit non-zero if there are behavioral deltas and the user didn't
  // acknowledge them — makes ces-diff a natural pre-commit gate.
  if (behavioral.deltas.length > 0 && !args.applyOracleUpdates) {
    process.exitCode = 1;
  }
}

main().catch(err => { console.error(err); process.exit(1); });
