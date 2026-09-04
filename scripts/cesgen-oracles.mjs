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
 * The oracle JSON is a shared contract across the runtimes: each loads it and
 * must produce the expected mergeBatch for every entry.  Identical pass-sets ⇒
 * cross-runtime parity.
 *
 * Consumed by all three engines:
 *
 *   RealityEngine_CPP    tests/cesgen_oracles_parity.cpp        (make e2e-corpus)
 *   RealityEngine_LSP    tests/oracle-parity-tests.lisp         (make test)
 *   RealityEngine_Scala  .../engine/CesgenOraclesParitySpec.scala (sbt test)
 *
 * For a long time only C++ consumed it, so "identical pass-sets" was never
 * actually checked and the claim above described a contract with participants
 * that had never joined.  The three harnesses are deliberately the same shape —
 * same oracle file, same per-machine isolation, same comparison rule — because
 * a harness that differs in what it asserts cannot demonstrate parity of what
 * it asserts about.
 *
 * Each oracle carries `outputMergeTransformation`, the fold the machine
 * declares, because that decides how the expectation is checked: a machine
 * presents one folded Reality Event per instant, so an individual outputVector
 * is not separately observable in mergeBatch, and under a monotone fold the
 * assertion that survives is subsumption rather than equality
 * (docs/FOLD_PLACEMENT.md §5a).
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

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { sequenceEvents, outputEvents, nextEventIds } from './lib/eventKeys.mjs';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const MACHINES_DIR = process.env.MACHINES_DIR
  ? path.resolve(process.env.MACHINES_DIR)
  : path.join(ROOT, '..', 'RealityEngine_Machines', 'machines');

// Corpus files live in domain subdirectories (machines/domains/<name>/);
// walk recursively, keyed by basename (globally unique across the corpus).
function corpusFileMap() {
  const map = new Map();
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.json')) map.set(e.name, p);
    }
  };
  walk(MACHINES_DIR);
  return map;
}
const CORPUS_FILES = corpusFileMap();
function corpusPath(basename) {
  const p = CORPUS_FILES.get(basename);
  if (!p) throw new Error(`machine file not found in corpus: ${basename}`);
  return p;
}

// The master is RealityEngine_Machines/oracles.json. This pointed at
// RealityEngine_CI/examples/oracles.json — a path that does not exist in this
// repository, left over from a deprecated prototype layout. `--check` therefore
// compared the generated set against a missing file and reported drift on every
// run, which is a gate that cannot pass rather than one that catches anything.
const DEFAULT_OUT  = path.join(ROOT, '..', 'RealityEngine_Machines', 'oracles.json');

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
  return JSON.parse(fs.readFileSync(corpusPath(file), 'utf8'));
}

// Build oracles for one machine.  Returns an array of oracle entries.
function buildOracles(file) {
  const raw = loadMachineFile(file).machine ?? loadMachineFile(file);
  const mapping = raw.perceptualMapping;
  if (!mapping?.input || !mapping?.output) return [];

  const machineId = raw.id ?? `machine-${file.replace(/\.json$/, '').toLowerCase()}`;
  // The transformation the engine folds this machine's collection of potential
  // outputs with, at the completion boundary of the atomic matching action.
  // Absent means "or" (RealityEngine_CI/docs/FOLD_PLACEMENT.md §5a). Carried on
  // every oracle so a consumer can tell whether the fold is monotone without
  // reopening the corpus — which is what decides how the expectation is
  // checked, and there are three consumers now.
  const outputMergeTransformation = (raw.outputMergeTransformation ?? 'or').toLowerCase();
  const outRegion = { offset: mapping.output.offset, length: mapping.output.length };
  const inRegion  = { offset: mapping.input.offset,  length: mapping.input.length };

  const oracles = [];

  for (const seq of raw.sequences ?? []) {
    // Build a vector lookup so we can walk nextVectorIds without rescanning.
    const byId = new Map();
    for (const v of sequenceEvents(seq)) byId.set(v.id, v);

    // Walk every path from an initial vector to any vector that emits output.
    // Track visited within a single path to avoid loops.
    const enumerate = (path) => {
      const tail = path[path.length - 1];
      const tailOutputs = outputEvents(tail);
      if (tailOutputs.length > 0) {
        // expectedProvenance walks the path in order — the same chain the
        // engine assembles as predecessors activate each successor in turn.
        const expectedProvenance = path.map(v => v.id);
        for (let k = 0; k < tailOutputs.length; k++) {
          const expectedVector = tailOutputs[k].vector ?? [];
          // The path is part of the identity. Without it distinct oracles
          // collided on one id: KleeneStar reaches `kleene-seq2-001-final` by
          // five routes, each with its own depth and inputs, and all five were
          // emitted under the same id. An id that does not identify an oracle
          // makes a failure report ambiguous and lets a consumer keyed on id
          // silently drop four of them. Hashed rather than spelled out — the
          // provenance chain is long and the id is already the longest field.
          const pathHash = crypto.createHash('sha1')
            .update(expectedProvenance.join('>')).digest('hex').slice(0, 8);
          oracles.push({
            id: `${file}::${seq.id}::${tail.id}::${k}::${path.length === 1 ? 'single-step' : 'chained'}::d${path.length}::${pathHash}`,
            machineFile: file,
            machineId,
            sequenceId:  seq.id,
            vectorId:    tail.id,
            kind:        path.length === 1 ? 'single-step' : 'chained',
            depth:       path.length,
            inputRegion: inRegion,
            inputs:      path.map(v => (v.elements ?? []).map(e => e.value)),
            outputMergeTransformation,
            expected:    { region: outRegion, values: expectedVector, outputIndex: k, provenance: expectedProvenance },
          });
        }
      }
      if (path.length >= MAX_CHAIN_DEPTH) return;
      const visited = new Set(path.map(v => v.id));
      for (const nextId of nextEventIds(tail)) {
        const next = byId.get(nextId);
        if (!next || visited.has(next.id)) continue;
        enumerate([...path, next]);
      }
    };

    for (const v of sequenceEvents(seq)) if (v.isInitial) enumerate([v]);
  }

  return oracles;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const files = [...CORPUS_FILES.keys()].sort();

  const allOracles = [];
  for (const f of files) allOracles.push(...buildOracles(f));

  // Stable ordering for diff-friendliness.
  allOracles.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

  const histogram = {};
  for (const o of allOracles) histogram[o.kind] = (histogram[o.kind] ?? 0) + 1;

  const payload = {
    version:     '1.0.0',
    generatedBy: 'scripts/cesgen-oracles.mjs',
    // Was the literal 'examples/machines/*.json' long after the corpus moved
    // into RealityEngine_Machines/machines/domains/<name>/ and this generator
    // started walking it recursively. A generated file that misreports its own
    // provenance is worse than one that omits it.
    sourceGlob:  path.relative(path.join(ROOT, '..'), MACHINES_DIR) + '/**/*.json',
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
