#!/usr/bin/env node
/**
 * ces-governance — validates that every machine that declares triggerConfig
 * rules also declares a governance block, and that the governance fields
 * meet the contract (required ownerTeam, sane SLA values, URL-shaped runbook,
 * known processStatus enum values).
 *
 * Usage:
 *   node scripts/ces-governance.mjs --validate         # human-readable report
 *   node scripts/ces-governance.mjs --validate --json  # CI-friendly
 *   node scripts/ces-governance.mjs --check            # exit 1 if any errors
 *   node scripts/ces-governance.mjs --check --include-warnings   # also fail on warnings
 *
 * Runs against examples/machines by default; override with --machines-dir.
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const DEFAULT_MACHINES = path.join(ROOT, 'examples', 'machines');

function parseArgs(argv) {
  const args = { validate: false, check: false, json: false, includeWarnings: false, dir: DEFAULT_MACHINES };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--validate')         args.validate = true;
    else if (a === '--check')       args.check = true;
    else if (a === '--json')        args.json = true;
    else if (a === '--include-warnings') args.includeWarnings = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') { printHelp(); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  if (!args.validate && !args.check) args.validate = true;
  return args;
}

function printHelp() {
  console.log('Usage: ces-governance [--validate] [--check [--include-warnings]] [--json] [--machines-dir DIR]');
}

const VALID_PROCESS = new Set(['ok', 'info', 'warning', 'error']);

function validateOne(file, raw) {
  const issues = [];
  const m = raw.machine ?? raw;
  const md = m.metadata ?? {};
  const triggerRules = md.triggerConfig?.rules ?? [];
  const gov = md.governance;

  const add = (severity, kind, detail) => issues.push({
    file: path.basename(file),
    machineId: m.id ?? null,
    machineName: m.name ?? null,
    severity, kind, detail,
  });

  if (triggerRules.length > 0 && !gov) {
    add('warning', 'missing-governance',
        'machine declares triggerConfig.rules but no metadata.governance — alerts will route to "unrouted"');
    return issues;
  }
  if (!gov) return issues;

  if (!gov.ownerTeam || typeof gov.ownerTeam !== 'string') {
    add('error', 'missing-required-field', 'metadata.governance.ownerTeam is required');
  }
  if (gov.runbook && !/^https?:\/\//.test(gov.runbook)) {
    add('warning', 'invalid-runbook', `metadata.governance.runbook should be a URL: ${gov.runbook}`);
  }
  for (const [status, seconds] of Object.entries(gov.sla ?? {})) {
    if (!VALID_PROCESS.has(status)) {
      add('warning', 'unknown-process-status', `metadata.governance.sla.${status} — unknown processStatus`);
    }
    if (seconds !== null && (typeof seconds !== 'number' || seconds < 0 || seconds > 86400)) {
      add('warning', 'sla-out-of-range',
          `metadata.governance.sla.${status} = ${seconds} — expected null or 0..86400`);
    }
  }
  for (const rule of triggerRules) {
    if (!rule.processStatus) {
      add('warning', 'rule-has-no-process-status',
          `triggerConfig.rules[sequenceId=${rule.sequenceId}] has no processStatus — paging will have no SLA`);
    }
    if (rule.governance?.slaSeconds !== undefined) {
      const s = rule.governance.slaSeconds;
      if (s !== null && (typeof s !== 'number' || s < 0 || s > 86400)) {
        add('warning', 'sla-out-of-range',
            `triggerConfig.rules[sequenceId=${rule.sequenceId}].governance.slaSeconds = ${s} — expected null or 0..86400`);
      }
    }
  }
  return issues;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`machines dir not found: ${args.dir}`); process.exit(2); }

  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json')).sort();
  const all = [];
  let machinesWithGovernance = 0;
  let machinesWithTriggerRules = 0;

  for (const f of files) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(args.dir, f), 'utf8')); }
    catch (e) { console.error(`skip ${f}: ${e.message}`); continue; }
    const m = raw.machine ?? raw;
    const hasRules = (m.metadata?.triggerConfig?.rules?.length ?? 0) > 0;
    const hasGov = m.metadata?.governance != null;
    if (hasRules) machinesWithTriggerRules++;
    if (hasGov)   machinesWithGovernance++;
    all.push(...validateOne(f, raw));
  }

  const errors   = all.filter(i => i.severity === 'error');
  const warnings = all.filter(i => i.severity === 'warning');

  if (args.json) {
    console.log(JSON.stringify({
      tool: 'ces-governance', version: '1.0.0',
      machinesScanned: files.length,
      machinesWithGovernance,
      machinesWithTriggerRules,
      errors: errors.length,
      warnings: warnings.length,
      issues: all,
    }, null, 2));
  } else {
    console.log(`ces-governance: ${files.length} machines scanned`);
    console.log(`  with governance:    ${machinesWithGovernance}`);
    console.log(`  with triggerRules:  ${machinesWithTriggerRules}`);
    console.log(`  errors:             ${errors.length}`);
    console.log(`  warnings:           ${warnings.length}`);
    if (all.length > 0) {
      console.log('');
      // Group issues per machine for readability.
      const byFile = new Map();
      for (const i of all) {
        if (!byFile.has(i.file)) byFile.set(i.file, []);
        byFile.get(i.file).push(i);
      }
      for (const [file, list] of byFile) {
        console.log(`  ${file}:`);
        for (const i of list) console.log(`    ${i.severity === 'error' ? '✗' : '⚠'} [${i.kind}] ${i.detail}`);
      }
    }
  }

  if (args.check) {
    const fatal = errors.length + (args.includeWarnings ? warnings.length : 0);
    if (fatal > 0) process.exit(1);
  }
}

main();
