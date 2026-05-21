#!/usr/bin/env node
/**
 * cesgen-oracles — derive a canonical oracle set from the machine corpus.
 *
 * For every machine in examples/machines/, every vector that has at least
 * one outputVector becomes an oracle: given the input pattern P, the engine
 * must produce output O at the machine's output region after the right
 * number of steps.
 *
 * Two oracle kinds are generated:
 *
 *   • single-step: vector V is isInitial and has outputVectors.  One step
 *                  with V.elements as the input yields V.outputVectors[k].
 *
 *   • chained:     vector V (with outputVectors) is reachable from some
 *                  isInitial vector via a path through nextVectorIds.  N
 *                  steps with each path-vector's elements yield the same
 *                  output.  Depth is capped at MAX_CHAIN_DEPTH to keep the
 *                  set finite.
 *
 * The oracle JSON is the shared contract between RealityEngine_AI and
 * RealityEngine_CPP: both load it and must produce the expected mergeBatch
 * for every entry.  Identical pass-sets ⇒ cross-runtime parity.
 *
 * Usage:
 *   node scripts/cesgen-oracles.mjs                # write examples/oracles.json
 *   node scripts/cesgen-oracles.mjs --check        # exit 1 if file would change
 *   node scripts/cesgen-oracles.mjs --out PATH     # alternate output path
 *
 * To regenerate after editing a machine JSON:
 *   node scripts/cesgen-oracles.mjs
 *
 * To gate CI on drift:
 *   node scripts/cesgen-oracles.mjs --check
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const MACHINES_DIR = path.join(ROOT, 'examples', 'machines');
const DEFAULT_OUT  = path.join(ROOT, 'examples', 'oracles.json');

// Deep chains explode combinatorially; 4 input steps is enough to cover the
// rising-edge pattern (2-step) and all of the staged-sensor machines in the
// corpus while keeping the oracle set small enough to run on every push.
const MAX_CHAIN_DEPTH = 4;

function parseArgs(argv) {
  const args = { check: false, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check') args.check = true;
    else if (a === '--out') args.out = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('Usage: cesgen-oracles.mjs [--check] [--out PATH]'); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return args;
}

function loadMachineFile(file) {
  return JSON.parse(fs.readFileSync(path.join(MACHINES_DIR, file), 'utf8'));
}

// Build oracles for one machine.  Returns an array of oracle entries.
function buildOracles(file) {
  const raw = loadMachineFile(file).machine ?? loadMachineFile(file);
  const mapping = raw.perceptualMapping;
  if (!mapping?.input || !mapping?.output) return [];

  const machineId = raw.id ?? `machine-${file.replace(/\.json$/, '').toLowerCase()}`;
  const outRegion = { offset: mapping.output.offset, length: mapping.output.length };
  const inRegion  = { offset: mapping.input.offset,  length: mapping.input.length };

  const oracles = [];

  for (const seq of raw.sequences ?? []) {
    // Build a vector lookup so we can walk nextVectorIds without rescanning.
    const byId = new Map();
    for (const v of seq.vectors ?? []) byId.set(v.id, v);

    // Walk every path from an initial vector to any vector that emits output.
    // Track visited within a single path to avoid loops.
    const enumerate = (path) => {
      const tail = path[path.length - 1];
      if (tail.outputVectors && tail.outputVectors.length > 0) {
        // expectedProvenance walks the path in order — the same chain the
        // engine assembles as predecessors activate each successor in turn.
        const expectedProvenance = path.map(v => v.id);
        for (let k = 0; k < tail.outputVectors.length; k++) {
          const expectedVector = tail.outputVectors[k].vector ?? [];
          oracles.push({
            id: `${file}::${seq.id}::${tail.id}::${k}::${path.length === 1 ? 'single-step' : 'chained'}`,
            machineFile: file,
            machineId,
            sequenceId:  seq.id,
            vectorId:    tail.id,
            kind:        path.length === 1 ? 'single-step' : 'chained',
            depth:       path.length,
            inputRegion: inRegion,
            inputs:      path.map(v => (v.elements ?? []).map(e => e.value)),
            expected:    { region: outRegion, values: expectedVector, outputIndex: k, provenance: expectedProvenance },
          });
        }
      }
      if (path.length >= MAX_CHAIN_DEPTH) return;
      const visited = new Set(path.map(v => v.id));
      for (const nextId of tail.nextVectorIds ?? []) {
        const next = byId.get(nextId);
        if (!next || visited.has(next.id)) continue;
        enumerate([...path, next]);
      }
    };

    for (const v of seq.vectors ?? []) if (v.isInitial) enumerate([v]);
  }

  return oracles;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const files = fs.readdirSync(MACHINES_DIR).filter(f => f.endsWith('.json')).sort();

  const allOracles = [];
  for (const f of files) allOracles.push(...buildOracles(f));

  // Stable ordering for diff-friendliness.
  allOracles.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

  const histogram = {};
  for (const o of allOracles) histogram[o.kind] = (histogram[o.kind] ?? 0) + 1;

  const payload = {
    version:     '1.0.0',
    generatedBy: 'scripts/cesgen-oracles.mjs',
    sourceGlob:  'examples/machines/*.json',
    machineCount: files.length,
    oracleCount:  allOracles.length,
    histogram,
    maxChainDepth: MAX_CHAIN_DEPTH,
    oracles:     allOracles,
  };
  const serialized = JSON.stringify(payload, null, 2) + '\n';

  if (args.check) {
    const existing = fs.existsSync(args.out) ? fs.readFileSync(args.out, 'utf8') : null;
    if (existing !== serialized) {
      console.error(`[drift] ${path.relative(ROOT, args.out)} would change`);
      console.error('Regenerate with: node scripts/cesgen-oracles.mjs');
      process.exit(1);
    }
    console.log(`cesgen-oracles: ${allOracles.length} oracles verified`);
    return;
  }

  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, serialized);
  console.log(`cesgen-oracles: ${allOracles.length} oracles emitted to ${path.relative(ROOT, args.out)}`);
  console.log(`  histogram: ${JSON.stringify(histogram)}`);
}

main();
