#!/usr/bin/env node
/**
 * migrate-bits-per-element — Option A1 of the cell-storage refactor.
 *
 * Walks every machine in examples/machines and computes the smallest
 * `bitsPerElement` (1, 2, 4, or 8) that holds every value the machine
 * emits, then writes it into `perceptualMapping.bitsPerElement`.
 *
 * What's a "value the machine emits"?
 *   - the integer value of every CES vector element (`vector.elements[i].value`)
 *   - the integer value of every output vector element (`outputVectors[i].vector[k]`)
 *
 * The engine's internal Float64 storage stays unchanged for now — this
 * migration proves the corpus values FIT in narrow cells (so a future
 * packed-storage refactor is safe) and lets the API layer emit packed
 * payloads immediately.
 *
 * Conservative rounding rule: any non-integer value the machine carries
 * forces bitsPerElement=8.  Most machines emit clean ordinals (0/1 or
 * 0..3) and will land at 1- or 2-bit cells.
 *
 * Usage:
 *   node scripts/migrate-bits-per-element.mjs --report        # dry-run human report
 *   node scripts/migrate-bits-per-element.mjs --report --json # CI-friendly
 *   node scripts/migrate-bits-per-element.mjs --apply         # write into JSONs
 *   node scripts/migrate-bits-per-element.mjs --check         # exit 1 if declared < computed
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const DEFAULT_DIR = path.join(ROOT, 'examples', 'machines');

// Inline copy of CellPacking.minBitsForValues so the CLI doesn't need
// the dist/ build artifact.  Same semantics.
function minBitsForValues(values) {
  let max = 0;
  let sawNonInteger = false;
  for (const v of values) {
    if (!Number.isFinite(v)) throw new RangeError(`non-finite value: ${v}`);
    if (v < 0)               throw new RangeError(`negative value: ${v}`);
    if (v > 255)             throw new RangeError(`value ${v} > 255`);
    if (!Number.isInteger(v)) sawNonInteger = true;
    if (v > max) max = v;
  }
  if (sawNonInteger) return 8;   // anything fractional needs all 8 bits
  if (max <= 1)   return 1;
  if (max <= 3)   return 2;
  if (max <= 15)  return 4;
  return 8;
}

function collectValues(m) {
  const vals = [];
  for (const seq of m.sequences ?? []) {
    for (const v of seq.vectors ?? []) {
      for (const e of v.elements ?? []) {
        if (typeof e.value === 'number') vals.push(e.value);
      }
      for (const out of v.outputVectors ?? []) {
        for (const x of out.vector ?? []) {
          if (typeof x === 'number') vals.push(x);
        }
      }
    }
  }
  return vals;
}

function parseArgs(argv) {
  const args = { report: false, apply: false, check: false, json: false, dir: DEFAULT_DIR };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--report') args.report = true;
    else if (a === '--apply')  args.apply  = true;
    else if (a === '--check')  args.check  = true;
    else if (a === '--json')   args.json   = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('Usage: migrate-bits-per-element [--report|--apply|--check] [--json] [--machines-dir DIR]'); process.exit(0); }
    else { console.error(`unknown arg: ${a}`); process.exit(2); }
  }
  if (!args.report && !args.apply && !args.check) args.report = true;
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`dir not found: ${args.dir}`); process.exit(2); }
  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json')).sort();

  const records = [];
  const histogram = { 1: 0, 2: 0, 4: 0, 8: 0 };
  let driftCount = 0, applied = 0, declaredAlready = 0;
  const drift = [];

  for (const f of files) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(args.dir, f), 'utf8')); } catch { continue; }
    const m = raw.machine ?? raw;
    const pm = m.perceptualMapping;
    if (!pm) continue;

    const vals = collectValues(m);
    let computed;
    try { computed = minBitsForValues(vals); }
    catch (e) { computed = null; }

    const declared = typeof pm.bitsPerElement === 'number' ? pm.bitsPerElement : null;
    if (declared !== null) declaredAlready++;

    const rec = { file: f, machineName: m.name ?? null, computed, declared, valueCount: vals.length, maxValue: vals.length ? Math.max(...vals) : 0 };
    records.push(rec);
    if (computed !== null) histogram[computed]++;

    if (declared !== null && computed !== null && declared < computed) {
      drift.push({ file: f, declared, computed });
      driftCount++;
    }

    if (args.apply && computed !== null && declared !== computed) {
      pm.bitsPerElement = computed;
      fs.writeFileSync(path.join(args.dir, f), JSON.stringify(raw, null, 2) + '\n');
      applied++;
    }
  }

  const summary = {
    tool: 'migrate-bits-per-element', version: '1.0.0',
    machinesScanned: records.length,
    declaredAlready,
    appliedThisRun: applied,
    histogram,
    driftCount,
    drift,
  };

  if (args.json) {
    console.log(JSON.stringify({ ...summary, records }, null, 2));
  } else {
    console.log(`migrate-bits-per-element: ${records.length} machines scanned`);
    console.log(`  machines with bitsPerElement already declared: ${declaredAlready}`);
    console.log(`  applied this run: ${applied}`);
    console.log('  bit-width histogram (computed):');
    for (const w of [1, 2, 4, 8]) console.log(`    ${w}-bit cells: ${histogram[w]}`);
    if (drift.length > 0) {
      console.log('');
      console.log(`  ✗ drift (declared < computed) — ${drift.length} machine(s):`);
      for (const d of drift) console.log(`    ${d.file}: declared=${d.declared}, computed=${d.computed}`);
    }
    const float64Total = records.reduce((n, r) => n + r.valueCount * 8, 0);
    const packedTotal  = records.reduce((n, r) => n + Math.ceil((r.valueCount * (r.computed ?? 8)) / 8), 0);
    if (float64Total > 0) {
      console.log('');
      console.log(`  cumulative storage for all CES vector values (if packed at the computed width):`);
      console.log(`    float64 baseline: ${float64Total.toLocaleString()} bytes`);
      console.log(`    packed at computed width: ${packedTotal.toLocaleString()} bytes`);
      console.log(`    shrink factor: ${(float64Total / Math.max(packedTotal, 1)).toFixed(1)}×`);
    }
  }

  if (args.check && driftCount > 0) {
    console.error(`\nmigrate-bits-per-element --check failed: ${driftCount} machine(s) declare a smaller bitsPerElement than their values require`);
    process.exit(1);
  }
}

main();
