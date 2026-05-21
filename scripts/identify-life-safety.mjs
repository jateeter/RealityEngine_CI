#!/usr/bin/env node
/**
 * identify-life-safety — classifier + tagger for life-safety sequences.
 *
 * Today only FallDetection.json carries `metadata.severity: "life-safety"`.
 * Many other sequences in the corpus describe genuinely life-safety
 * scenarios (suicide screening, overdose response, mobile crisis dispatch,
 * fire/evacuation, seizure, anaphylaxis, hypoglycemia, …) but go untagged,
 * so the strict-STA gate (step 12) and tier-1 governance contracts cannot
 * enforce against them.
 *
 * This tool:
 *
 *   1. Reads every machine JSON and applies layered heuristics:
 *      - "strong"  : a sequence whose name/description contains an
 *                    unambiguous life-threat keyword AND whose
 *                    triggerConfig rule for it is processStatus='error'
 *                    OR ragStatusCode='RED'.
 *      - "medium"  : owner team is patient-safety / public-health AND
 *                    the sequence carries any RED rule.  These are
 *                    "safety-significant" — call to review.
 *      - "weak"    : everything else.
 *
 *   2. For each "strong" candidate, runs the STA analyzer (step 12).
 *      A candidate that passes STA can be tagged safely; one that fails
 *      goes on a remediation list — it's exactly the kind of machine
 *      whose chain may silently abort under multi-bit input jumps.
 *
 *   3. In --apply mode, writes `metadata.severity = "life-safety"` to
 *      the sequence's own metadata block AND promotes the machine-level
 *      severity to "life-safety" if at least one sequence qualifies.
 *      (FallDetection-style machine-level tagging stays intact.)
 *
 *   4. Reports the overall partitioning of the machine space.
 *
 * Usage:
 *   node scripts/identify-life-safety.mjs --report          # dry run, human-readable
 *   node scripts/identify-life-safety.mjs --report --json   # CI-friendly
 *   node scripts/identify-life-safety.mjs --apply           # write tags (skip STA-failing candidates)
 *   node scripts/identify-life-safety.mjs --apply --include-medium  # also tag "safety-significant"
 *
 * The classifier is conservative by design.  Over-tagging would force
 * STA enforcement on machines that don't need it; under-tagging leaves
 * real life-safety chains unprotected.  When in doubt, lean toward
 * "medium" / safety-significant — those surface for human review without
 * tightening the gate.
 */

import fs from 'node:fs';
import path from 'node:path';
import { computeSta } from './ces-sta-check.mjs';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const DEFAULT_DIR = path.join(ROOT, 'examples', 'machines');

// ── Keyword bank ─────────────────────────────────────────────────────────────
//
// Word-boundary regex against the lowercased text of (sequence.name,
// sequence.metadata.description, triggerConfig.rules[].description,
// machine.name, machine.description).  Categories are organised by
// failure mode: missing the signal yields direct, near-term, irreversible
// harm to a person.

const LIFE_SAFETY_KEYWORDS = [
  // Patient-direct emergencies
  'fall', 'overdose', 'suicide', 'self-harm', 'self harm',
  'cardiac', 'cardiopulmonary', 'cardiac arrest',
  'stroke', 'seizure', 'anaphyl', 'choking', 'aspirat',
  'hypoglycem', 'diabetic crisis',
  'respiratory failure', 'respiratory distress',
  'sepsis', 'septic',
  'hemorrhage', 'bleeding',
  'wandering', 'elopement', 'asphyx', 'drown',
  // Behavioural / mental health acute
  'crisis', 'psychiatric crisis', 'acute psychosis',
  'mobile crisis', 'crisis dispatch', 'crisis response',
  'imminent harm', 'safety plan',
  // Environment / facility emergencies
  'evacuation', 'fire', 'smoke', 'gas leak',
  'weapon', 'active shooter', 'violence', 'assault',
  // Severity escalations that imply EMS
  'emergency dispatch', 'ems', 'ambulance', '911',
];

// Patient-care / safety-significant but not necessarily LIFE-safety on
// their own.  Promotes to "medium" when paired with RED severity.
const SAFETY_SIGNIFICANT_KEYWORDS = [
  'patient safety', 'patient-safety',
  'fall risk', 'medication adherence', 'medication safety',
  'isolation', 'abuse', 'neglect',
  'social isolation', 'eviction', 'homelessness',
  'food insecurity', 'food safety',
];

const LIFE_SAFETY_RES = LIFE_SAFETY_KEYWORDS.map(k => new RegExp(`\\b${k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i'));
const SAFETY_SIG_RES  = SAFETY_SIGNIFICANT_KEYWORDS.map(k => new RegExp(`\\b${k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i'));

function matchesAny(res, text) {
  if (!text) return null;
  for (const re of res) if (re.test(text)) return re.source.replace(/\\b/g, '');
  return null;
}

// ── Classification ───────────────────────────────────────────────────────────

function classifySequence(m, seq, machineText) {
  // sequence-local text: the keyword MUST appear here, not in machine-wide
  // prose.  A machine that mentions "crisis conditions" generically does
  // not make every one of its sequences life-safety.
  const seqLocalText = [
    seq.name ?? '', seq.id ?? '',
    seq.metadata?.description ?? '',
  ].join(' ');
  const ruleForSeq = (m.metadata?.triggerConfig?.rules ?? [])
    .filter(r => r.sequenceId === seq.id);
  const ruleText = ruleForSeq.map(r => r.description ?? '').join(' ');
  const localText = `${seqLocalText}\n${ruleText}`;

  const lsHit  = matchesAny(LIFE_SAFETY_RES, localText);
  const ssHit  = matchesAny(SAFETY_SIG_RES, localText);
  // Machine-prose corroboration only — never alone sufficient to escalate
  // a sequence; downgrades a "medium" to a "strong" hint when paired with
  // local signal.
  const machineKeyword = matchesAny(LIFE_SAFETY_RES, machineText);
  const hasRed   = ruleForSeq.some(r => r.ragStatusCode === 'RED' || r.processStatus === 'error');
  const hasAmber = ruleForSeq.some(r => r.ragStatusCode === 'AMBER' || r.processStatus === 'warning');
  const gov = m.metadata?.governance ?? null;
  const teamHit = /patient-safety|public-health|crisis/i.test(gov?.ownerTeam ?? '');

  // Strong: life-threat keyword in sequence-local text AND a RED rule
  // for the sequence.  Both signals required — keyword alone is suggestive,
  // RED alone is operationally significant but not necessarily life-safety.
  if (lsHit && hasRed) {
    return { tier: 'strong', keyword: lsHit, hasRed, hasAmber, ownerTeam: gov?.ownerTeam, ruleCount: ruleForSeq.length, machineKeyword };
  }
  // Medium: any one of —
  //   (a) life-threat keyword + AMBER but no RED  (escalation possible but not asserted),
  //   (b) safety-significant keyword + RED,
  //   (c) team is patient-safety / public-health and the sequence asserts RED.
  if ((lsHit && hasAmber) || (ssHit && hasRed) || (teamHit && hasRed)) {
    return { tier: 'medium', keyword: lsHit ?? ssHit ?? null, hasRed, hasAmber, ownerTeam: gov?.ownerTeam, ruleCount: ruleForSeq.length, machineKeyword };
  }
  return { tier: 'weak', keyword: lsHit ?? ssHit ?? null, hasRed, hasAmber, ownerTeam: gov?.ownerTeam, ruleCount: ruleForSeq.length, machineKeyword };
}

// ── CLI args + main ──────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { report: false, apply: false, json: false, includeMedium: false, dir: DEFAULT_DIR };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--report') args.report = true;
    else if (a === '--apply') args.apply = true;
    else if (a === '--json') args.json = true;
    else if (a === '--include-medium') args.includeMedium = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') { console.log('Usage: identify-life-safety [--report|--apply] [--json] [--include-medium] [--machines-dir DIR]'); process.exit(0); }
    else { console.error(`unknown arg: ${a}`); process.exit(2); }
  }
  if (!args.report && !args.apply) args.report = true;
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`machines dir not found: ${args.dir}`); process.exit(2); }

  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json')).sort();

  const machineRecords = [];
  const seqStats   = { strong: 0, medium: 0, weak: 0 };
  const domainPartition = new Map();
  const remediation = [];   // strong candidates that fail STA

  let strongMachines = 0, mediumMachines = 0, operationsMachines = 0;
  let alreadyTagged = 0;

  for (const f of files) {
    let raw;
    try { raw = JSON.parse(fs.readFileSync(path.join(args.dir, f), 'utf8')); }
    catch (e) { continue; }
    const m = raw.machine ?? raw;
    const domain = (m.metadata?.tagging?.primaryDomain ?? m.metadata?.domain ?? 'unknown').toString();
    const machineText = `${m.name ?? ''} ${m.description ?? ''}`;

    const classifications = [];
    let maxTier = 'weak';
    for (const seq of m.sequences ?? []) {
      const c = classifySequence(m, seq, machineText);
      classifications.push({ id: seq.id, ...c });
      seqStats[c.tier]++;
      if (c.tier === 'strong') maxTier = 'strong';
      else if (c.tier === 'medium' && maxTier !== 'strong') maxTier = 'medium';
    }

    const machineRec = {
      file: f,
      machineName: m.name ?? null,
      domain,
      currentSeverity: m.metadata?.severity ?? null,
      classification: maxTier,
      sequenceClassifications: classifications,
    };
    machineRecords.push(machineRec);

    if (m.metadata?.severity === 'life-safety') alreadyTagged++;

    if (maxTier === 'strong') {
      strongMachines++;
      // STA cross-check: refuse to tag a machine whose chains would
      // explode under the strict STA gate.
      const sta = computeSta(raw);
      if (sta.summary.intraViolations > 0) {
        remediation.push({ file: f, machineName: m.name, intraViolations: sta.summary.intraViolations,
          firstOffender: sta.sequences.find(s => s.anyViolation)?.transitions.find(t => t.violation || t.error) ?? null });
      } else {
        machineRec.staClean = true;
      }
    } else if (maxTier === 'medium') {
      mediumMachines++;
    } else {
      operationsMachines++;
    }

    const dp = domainPartition.get(domain) ?? { strong: 0, medium: 0, weak: 0, total: 0 };
    dp[maxTier]++;
    dp.total++;
    domainPartition.set(domain, dp);
  }

  // ── Apply tagging (writes back to JSON) ───────────────────────────────────
  let written = 0;
  if (args.apply) {
    const eligibleFiles = new Set(machineRecords.filter(r =>
      (r.classification === 'strong' && r.staClean) ||
      (args.includeMedium && r.classification === 'medium')
    ).map(r => r.file));
    for (const rec of machineRecords) {
      if (!eligibleFiles.has(rec.file)) continue;
      const filePath = path.join(args.dir, rec.file);
      const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
      const m = raw.machine ?? raw;
      const tier = rec.classification;
      // Sequence-level tags (only for sequences whose own classification matches).
      for (const seq of m.sequences ?? []) {
        const c = rec.sequenceClassifications.find(cc => cc.id === seq.id);
        if (!c) continue;
        if (c.tier === 'strong' || (args.includeMedium && c.tier === 'medium')) {
          seq.metadata ??= {};
          if (seq.metadata.severity !== 'life-safety') seq.metadata.severity = 'life-safety';
        }
      }
      // Machine-level: promote severity iff at least one strong sequence and
      // it isn't already set to "life-safety".
      m.metadata ??= {};
      if (tier === 'strong' && m.metadata.severity !== 'life-safety') {
        m.metadata.severity = 'life-safety';
      }
      fs.writeFileSync(filePath, JSON.stringify(raw, null, 2) + '\n');
      written++;
    }
  }

  // ── Render report ────────────────────────────────────────────────────────
  const summary = {
    tool: 'identify-life-safety', version: '1.0.0',
    machinesScanned: machineRecords.length,
    alreadyTagged,
    classification: {
      strongMachines, mediumMachines, operationsMachines,
      strongSequences: seqStats.strong,
      mediumSequences: seqStats.medium,
      weakSequences:   seqStats.weak,
    },
    remediationNeeded: remediation.length,
    tagsApplied: written,
  };

  if (args.json) {
    console.log(JSON.stringify({
      ...summary,
      domainPartition: Object.fromEntries(domainPartition),
      machineRecords,
      remediation,
    }, null, 2));
    return;
  }

  console.log(`identify-life-safety: scanned ${summary.machinesScanned} machines`);
  console.log(`  already tagged metadata.severity='life-safety':  ${alreadyTagged}`);
  console.log('');
  console.log('Machine-level partition by maximum-tier sequence:');
  console.log(`  strong  (life-safety):       ${strongMachines}`);
  console.log(`  medium  (safety-significant): ${mediumMachines}`);
  console.log(`  weak    (operations):         ${operationsMachines}`);
  console.log('');
  console.log('Sequence-level partition:');
  console.log(`  strong  (life-safety):       ${seqStats.strong}`);
  console.log(`  medium  (safety-significant): ${seqStats.medium}`);
  console.log(`  weak    (operations):         ${seqStats.weak}`);
  console.log('');
  console.log('Per-domain partition (strong / medium / weak / total):');
  const sortedDomains = [...domainPartition.entries()].sort((a, b) => b[1].strong - a[1].strong || b[1].total - a[1].total);
  for (const [domain, dp] of sortedDomains) {
    console.log(`  ${domain.padEnd(20)} ${String(dp.strong).padStart(4)} / ${String(dp.medium).padStart(4)} / ${String(dp.weak).padStart(4)} / ${dp.total}`);
  }

  if (remediation.length > 0) {
    console.log('');
    console.log(`STA remediation list (${remediation.length} machine(s) match life-safety heuristics but FAIL STA — cannot be tagged until graph is fixed):`);
    for (const r of remediation) {
      const t = r.firstOffender;
      console.log(`  ✗ ${r.file}  (${r.intraViolations} intra-seq violation(s))` + (t ? `  e.g. ${t.from} → ${t.to} HD=${t.hd}` : ''));
    }
  }

  if (args.apply) {
    console.log('');
    console.log(`✓ tagged ${written} machine(s) — re-run with --report to verify`);
  } else {
    console.log('');
    console.log(`(dry run — re-run with --apply to write metadata.severity='life-safety' to ${strongMachines} machine(s))`);
  }
}

main();
