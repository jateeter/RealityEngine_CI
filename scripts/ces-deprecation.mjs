#!/usr/bin/env node
/**
 * ces-deprecation — list / audit deprecated sequences across the corpus.
 *
 * Each sequence may declare:
 *   - schemaVersion: e.g. "1.0.0" — semver-style pin for the sequence body
 *   - deprecatedAt:  ISO date string (YYYY-MM-DD) marking deprecation
 *   - replacedBy:    sequence id (or `machineId::sequenceId`) of the successor
 *
 * Usage:
 *   node scripts/ces-deprecation.mjs --list                     # human-readable
 *   node scripts/ces-deprecation.mjs --list --json              # CI-friendly
 *   node scripts/ces-deprecation.mjs --check --max-age-days 180 # exit 1 if any seq is past the burn-down window
 *   node scripts/ces-deprecation.mjs --replaced-by-missing      # flag deprecatedAt without replacedBy
 *
 * The runtime emits `ces_deprecated_fires_total` whenever one of these
 * sequences asserts an output.  Drive that counter to zero in production
 * by routing traffic to the `replacedBy` successor and then removing the
 * sequence from the JSON.
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const DEFAULT_DIR = path.join(ROOT, 'examples', 'machines');

function parseArgs(argv) {
  const args = { list: false, check: false, json: false, replacedByMissing: false, maxAgeDays: null, dir: DEFAULT_DIR };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--list')       args.list = true;
    else if (a === '--check') args.check = true;
    else if (a === '--json')  args.json = true;
    else if (a === '--max-age-days') args.maxAgeDays = Number(argv[++i]);
    else if (a === '--replaced-by-missing') args.replacedByMissing = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('Usage: ces-deprecation [--list|--check] [--json] [--max-age-days N] [--replaced-by-missing] [--machines-dir DIR]'); process.exit(0); }
    else { console.error(`unknown arg: ${a}`); process.exit(2); }
  }
  if (!args.list && !args.check) args.list = true;
  return args;
}

function daysSince(iso) {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  return Math.floor((Date.now() - t) / 86_400_000);
}

function collect(args) {
  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json')).sort();
  const deprecated = [];
  const versionStats = { withSchemaVersion: 0, withoutSchemaVersion: 0 };
  for (const f of files) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(args.dir, f), 'utf8')); }
    catch (e) { continue; }
    const m = raw.machine ?? raw;
    for (const seq of m.sequences ?? []) {
      if (seq.schemaVersion) versionStats.withSchemaVersion++;
      else versionStats.withoutSchemaVersion++;
      if (!seq.deprecatedAt) continue;
      deprecated.push({
        file: f,
        machineId: m.id ?? null,
        machineName: m.name ?? null,
        sequenceId: seq.id,
        sequenceName: seq.name,
        schemaVersion: seq.schemaVersion ?? null,
        deprecatedAt: seq.deprecatedAt,
        replacedBy: seq.replacedBy ?? null,
        ageDays: daysSince(seq.deprecatedAt),
      });
    }
  }
  return { files: files.length, deprecated, versionStats };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`machines dir not found: ${args.dir}`); process.exit(2); }
  const { files, deprecated, versionStats } = collect(args);

  // Sort deprecated entries by age desc — the longest-stale CESs surface first.
  deprecated.sort((a, b) => (b.ageDays ?? 0) - (a.ageDays ?? 0));

  // Validation issues for --check.
  const issues = [];
  for (const d of deprecated) {
    if (args.replacedByMissing && !d.replacedBy) {
      issues.push({ severity: 'warning', kind: 'deprecation-no-replaced-by',
        file: d.file, sequenceId: d.sequenceId,
        detail: `sequence "${d.sequenceId}" in ${d.file} is deprecated but declares no replacedBy successor` });
    }
    if (args.maxAgeDays !== null && d.ageDays !== null && d.ageDays > args.maxAgeDays) {
      issues.push({ severity: 'error', kind: 'deprecation-past-burn-down',
        file: d.file, sequenceId: d.sequenceId,
        detail: `sequence "${d.sequenceId}" in ${d.file} has been deprecated for ${d.ageDays} days (max allowed: ${args.maxAgeDays})` });
    }
  }

  if (args.json) {
    console.log(JSON.stringify({
      tool: 'ces-deprecation', version: '1.0.0',
      machinesScanned: files,
      sequencesWithSchemaVersion: versionStats.withSchemaVersion,
      sequencesWithoutSchemaVersion: versionStats.withoutSchemaVersion,
      deprecatedCount: deprecated.length,
      deprecated,
      issues,
    }, null, 2));
  } else {
    console.log(`ces-deprecation: scanned ${files} machines`);
    console.log(`  sequences with schemaVersion:    ${versionStats.withSchemaVersion}`);
    console.log(`  sequences without schemaVersion: ${versionStats.withoutSchemaVersion}`);
    console.log(`  deprecated sequences:            ${deprecated.length}`);
    if (deprecated.length > 0) {
      console.log('');
      for (const d of deprecated) {
        const ages = d.ageDays !== null ? `${d.ageDays}d` : '?';
        const rb = d.replacedBy ? ` → ${d.replacedBy}` : ' (no replacedBy)';
        console.log(`  ⚠ ${d.file}::${d.sequenceId}  deprecated ${d.deprecatedAt} (${ages})${rb}`);
      }
    }
    if (issues.length > 0) {
      console.log('');
      console.log('Issues:');
      for (const i of issues) console.log(`  ${i.severity === 'error' ? '✗' : '⚠'} [${i.kind}] ${i.detail}`);
    }
  }

  if (args.check && issues.some(i => i.severity === 'error')) process.exit(1);
}

main();
