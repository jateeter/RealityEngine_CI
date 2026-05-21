#!/usr/bin/env node
/**
 * cesgen-contracts — per-machine output-stream contracts for cross-runtime parity.
 *
 * For every input chain we can enumerate from a machine's JSON (same paths
 * the cesgen-oracles tool produces), we run the chain through the AI engine
 * one step at a time and record:
 *
 *   - the full mergeBatch at every step (not just the terminal)
 *   - the full eventBus at every step
 *
 * The recorded stream is the contract: any divergence in either engine,
 * at any step, is a parity bug.  Because we record EVERY step's output —
 * not just the terminal — this catches the failure modes the oracle tests
 * can't.  In particular, the original motivation:
 *
 *   "the silent dimension-bound skip on the Scala side ... eight domains'
 *    worth of expected outputs would have gone missing."
 *
 * Eight domains of silent zeros would have produced eight domains' worth of
 * mergeBatch deltas — the contract test would have refused to ship.
 *
 * Usage:
 *   node scripts/cesgen-contracts.mjs              # regenerate examples/contracts.json
 *   node scripts/cesgen-contracts.mjs --check      # exit 1 if file would change
 *   node scripts/cesgen-contracts.mjs --machines NAME,NAME,...  # subset (still writes whole file)
 *
 * Precondition: `npm run build` (the script imports the compiled engine).
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const MACHINES_DIR = path.join(ROOT, 'examples', 'machines');
const DEFAULT_OUT  = path.join(ROOT, 'examples', 'contracts.json');
const MAX_CHAIN_DEPTH = 4;   // same cap as cesgen-oracles

// ── CLI ──────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { check: false, out: DEFAULT_OUT, names: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check') args.check = true;
    else if (a === '--out') args.out = path.resolve(argv[++i]);
    else if (a === '--machines') args.names = new Set(argv[++i].split(',').filter(Boolean));
    else if (a === '-h' || a === '--help') { console.log('Usage: cesgen-contracts [--check] [--out PATH] [--machines NAME,...]'); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return args;
}

// ── Chain enumeration (same algorithm as cesgen-oracles) ─────────────────────

function enumerateChains(machineFile) {
  const raw = JSON.parse(fs.readFileSync(path.join(MACHINES_DIR, machineFile), 'utf8'));
  const m = raw.machine ?? raw;
  const mapping = m.perceptualMapping;
  if (!mapping?.input || !mapping?.output) return [];

  const inRegion  = { offset: mapping.input.offset,  length: mapping.input.length };
  const chains = [];

  for (const seq of m.sequences ?? []) {
    const byId = new Map();
    for (const v of seq.vectors ?? []) byId.set(v.id, v);

    const walk = (path) => {
      const tail = path[path.length - 1];
      if (tail.outputVectors && tail.outputVectors.length > 0) {
        chains.push({
          id: `${machineFile}::${seq.id}::${tail.id}`,
          machineFile,
          sequenceId: seq.id,
          terminalVectorId: tail.id,
          inputRegion: inRegion,
          inputs: path.map(v => (v.elements ?? []).map(e => e.value)),
        });
      }
      if (path.length >= MAX_CHAIN_DEPTH) return;
      const visited = new Set(path.map(v => v.id));
      for (const nid of tail.nextVectorIds ?? []) {
        const next = byId.get(nid);
        if (!next || visited.has(next.id)) continue;
        walk([...path, next]);
      }
    };

    for (const v of seq.vectors ?? []) if (v.isInitial) walk([v]);
  }
  return chains;
}

// ── Engine runner ────────────────────────────────────────────────────────────

async function loadEngine() {
  const sim = await import(path.join(ROOT, 'dist', 'engine', 'PerceptualSpaceSimulator.js'));
  const loader = await import(path.join(ROOT, 'dist', 'services', 'MachineLoader.js'));
  return { sim, loader };
}

function denseInput(region, values) {
  const v = new Array(region.offset + region.length).fill(0);
  const n = Math.min(region.length, values.length);
  for (let i = 0; i < n; i++) v[region.offset + i] = values[i];
  return v;
}

/**
 * Strip the mergeBatch entry to the canonical engine-state fields we want
 * cross-runtime parity on.  Governance is deliberately omitted — that
 * field is derived from JSON metadata and parity is already exercised by
 * cesgen_governance; here we focus on raw engine behavior.
 */
/**
 * machineId is intentionally omitted from the recorded contract — it's a
 * loader-generated transient (random in TS, filename-slugged in C++) that
 * would diverge across runs and across runtimes for the same logical
 * machine.  The contract is already keyed by machineFile.
 */
function projectMergeBatch(mb) {
  return mb.map(op => ({
    region:      op.region,
    sequenceId:  op.sequenceId,
    outputIndex: op.outputIndex,
    values:      op.values,
    provenance:  op.provenance ?? [],
  }));
}

function projectEventBus(eb) {
  return (eb ?? []).map(w => ({
    producerSequenceId:  w.producerSequenceId,
    bitOffset:           w.bitOffset,
    value:               w.value,
    provenance:          w.provenance ?? [],
  }));
}

async function runChain(machineFile, chain, sim, loader) {
  const rawJson = fs.readFileSync(path.join(MACHINES_DIR, machineFile), 'utf8');
  const machine = loader.MachineLoader.loadFromJSON(rawJson, `contract::${chain.id}::${Date.now()}::${Math.random()}`);
  const s = new sim.PerceptualSpaceSimulator(0);
  s.addMachine(machine);

  const stream = [];
  for (let i = 0; i < chain.inputs.length; i++) {
    const step = s.processImmediate(denseInput(chain.inputRegion, chain.inputs[i]));
    stream.push({
      step: i,
      mergeBatch: projectMergeBatch(step.mergeBatch),
      eventBus:   projectEventBus(step.eventBus),
    });
  }
  return stream;
}

// ── Output noise suppression ────────────────────────────────────────────────

function silenceConsole(fn) {
  const log = console.log, info = console.info;
  console.log = () => {}; console.info = () => {};
  return Promise.resolve(fn()).finally(() => { console.log = log; console.info = info; });
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const files = fs.readdirSync(MACHINES_DIR).filter(f => f.endsWith('.json')).sort();
  const selected = args.names ? files.filter(f => args.names.has(f.replace(/\.json$/, ''))) : files;

  const { sim, loader } = await loadEngine();

  const contracts = [];
  await silenceConsole(async () => {
    for (const f of selected) {
      const chains = enumerateChains(f);
      for (const c of chains) {
        const outputStream = await runChain(f, c, sim, loader);
        contracts.push({ ...c, outputStream });
      }
    }
  });

  contracts.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

  // Stream-shape histogram for the report header.
  const stepHist = {};
  let nonemptySteps = 0;
  for (const c of contracts) {
    stepHist[c.outputStream.length] = (stepHist[c.outputStream.length] ?? 0) + 1;
    for (const s of c.outputStream) if (s.mergeBatch.length > 0) nonemptySteps++;
  }

  const payload = {
    version:     '1.0.0',
    generatedBy: 'scripts/cesgen-contracts.mjs',
    sourceGlob:  'examples/machines/*.json',
    machineCount: files.length,
    contractCount: contracts.length,
    nonemptyOutputSteps: nonemptySteps,
    stepLengthHistogram: stepHist,
    maxChainDepth: MAX_CHAIN_DEPTH,
    contracts,
  };
  const serialized = JSON.stringify(payload, null, 2) + '\n';

  if (args.check) {
    const existing = fs.existsSync(args.out) ? fs.readFileSync(args.out, 'utf8') : null;
    if (existing !== serialized) {
      console.error(`[drift] ${path.relative(ROOT, args.out)} would change`);
      console.error('Regenerate with: node scripts/cesgen-contracts.mjs');
      process.exit(1);
    }
    console.log(`cesgen-contracts: ${contracts.length} contracts verified`);
    return;
  }

  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, serialized);
  console.log(`cesgen-contracts: ${contracts.length} contracts emitted (${nonemptySteps} non-empty output steps) → ${path.relative(ROOT, args.out)}`);
}

main().catch(err => { console.error(err); process.exit(1); });
