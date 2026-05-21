#!/usr/bin/env node
/**
 * backfill-governance — auto-populate metadata.governance and
 * metadata.triggerConfig.rules across every machine in examples/machines.
 *
 * Rationale: step 7 promoted the CES JSON to the sole source of truth for
 * paging.  Before this script, only FallDetection had a governance block.
 * After this script, every machine in the example universe carries an
 * appropriate paging contract derived from:
 *
 *   - its primary domain (→ owner team, escalation policy, SLA tier)
 *   - any severity signals it already carries (out.metadata.severity,
 *     out.metadata.tier, out.metadata.ragStatusCode, descriptive text)
 *   - its sequence/vector structure (→ triggerConfig.rules[])
 *
 * Idempotent — re-running on a file produces no changes.  Machines that
 * already declare metadata.governance keep their existing block; their
 * triggerConfig.rules are also preserved as-authored.  This keeps
 * FallDetection.json and CommunityCommandAgent.json untouched by default.
 *
 * Usage:
 *   node scripts/backfill-governance.mjs              # write changes
 *   node scripts/backfill-governance.mjs --check      # exit 1 if any file would change
 *   node scripts/backfill-governance.mjs --machines-dir DIR
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

function parseArgs(argv) {
  const args = { check: false, dir: path.join(ROOT, 'examples', 'machines') };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check') args.check = true;
    else if (a === '--machines-dir') args.dir = path.resolve(argv[++i]);
    else if (a === '-h' || a === '--help') {
      console.log('Usage: backfill-governance [--check] [--machines-dir DIR]');
      process.exit(0);
    }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return args;
}

// ── Domain → governance defaults ─────────────────────────────────────────────

// owner team + SLA profile + escalation policy keyed by the primary domain
// taxonomy already in the corpus (metadata.tagging.primaryDomain).
const DOMAIN_PROFILES = {
  'health-personal':    { team: 'patient-safety-on-call',     pager: 'pagerduty:patient-safety',     sla: { warning: 600,  error: 60  } },
  'health-services':    { team: 'public-health-on-call',      pager: 'pagerduty:public-health',      sla: { warning: 1800, error: 600 } },
  'community-services': { team: 'social-services-on-call',    pager: 'pagerduty:social-services',    sla: { warning: 1800, error: 600 } },
  'life-balance':       { team: 'wellness-coaching-team',     pager: 'slack:#wellness-coaching',     sla: { warning: 3600, error: 900 } },
  'legal-services':     { team: 'legal-operations',           pager: 'pagerduty:legal-ops',          sla: { warning: 1800, error: 600 } },
  'agriculture':        { team: 'agriculture-operations',     pager: 'pagerduty:ag-ops',             sla: { warning: 3600, error: 900 } },
  'built-space':        { team: 'facilities-operations',      pager: 'pagerduty:facilities',         sla: { warning: 3600, error: 600 } },
  'data-center':        { team: 'datacenter-noc',             pager: 'pagerduty:datacenter-noc',     sla: { warning: 300,  error: 120 } },
  'transportation':     { team: 'transit-operations',         pager: 'pagerduty:transit-ops',        sla: { warning: 300,  error: 120 } },
  'ai-services':        { team: 'ml-platform-on-call',        pager: 'pagerduty:ml-platform',        sla: { warning: 1800, error: 300 } },
  'digital-logic':      { team: 'reliability-engineering',    pager: 'slack:#reliability-test',      sla: {} },   // test/demo — no SLA
  'meta-ces':           { team: 'platform-orchestration',     pager: 'pagerduty:platform-orch',      sla: { warning: 900,  error: 300 } },
};
const DEFAULT_PROFILE = { team: 'unrouted', pager: 'slack:#triage', sla: {} };

function primaryDomain(m) {
  return (m.metadata?.tagging?.primaryDomain
       ?? m.metadata?.domain
       ?? m.metadata?.category
       ?? 'unknown').toString();
}

function profileFor(m) {
  const d = primaryDomain(m);
  return DOMAIN_PROFILES[d] ?? DEFAULT_PROFILE;
}

function machineSlug(filename) {
  return filename.replace(/\.json$/i, '');
}

// ── Severity inference ───────────────────────────────────────────────────────

// Order matters: we check error first, then warning, then info — but each
// pattern is anchored on word boundaries so substrings of common English
// words don't false-positive (e.g. "required" must not match "red.").
// Conservative defaults are info/GREEN so a missing signal doesn't trigger
// pages — operators upgrade severity per-rule once they've reviewed.
const KEYWORDS = {
  error: [
    'urgent', 'critical', 'fatal', 'emergency', 'fail', 'failure',
    'crisis', 'overload', 'breach', 'evacuation', 'hazard',
    'red', 'shutdown', 'lockdown', 'agent_dispatch', 'dispatch',
    'stop_immediately', 'tier-1', 'tier1', 'high_risk', 'high-risk',
  ],
  warning: [
    'warning', 'amber', 'elevated', 'degraded', 'saturated', 'overheat',
    'escalating', 'escalation', 'drift', 'concern', 'watch',
    'caution', 'alert', 'investigate', 'sustained', 'declining',
    'falling', 'rising', 'imbalance',
  ],
  info: [
    'ok', 'nominal', 'green', 'ready', 'optimize', 'optimization',
    'normal', 'stable', 'baseline', 'maintenance', 'routine', 'healthy',
    'on-target', 'restored', 'recovered', 'cleared', 'service_due',
  ],
};

// Compile each keyword as a word-boundary regex once, then reuse.  Word
// boundaries treat hyphens/underscores as word characters in JS, so words
// like "high-risk" still match correctly.
const KEYWORD_REGEXES = Object.fromEntries(
  Object.entries(KEYWORDS).map(([status, ks]) => [status, ks.map(k => new RegExp(`\\b${k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i'))])
);

function classify(text) {
  if (!text) return null;
  const t = String(text);
  for (const status of ['error', 'warning', 'info']) {
    for (const re of KEYWORD_REGEXES[status]) {
      if (re.test(t)) return status;
    }
  }
  return null;
}

const STATUS_TO_RAG = { ok: 'GREEN', info: 'GREEN', warning: 'AMBER', error: 'RED' };

/**
 * Infer (processStatus, ragStatusCode, descriptionSource) for one output
 * vector of one sequence.  Checks, in order:
 *   1. explicit out.metadata.processStatus  (already authored)
 *   2. explicit out.metadata.ragStatusCode  → map to processStatus
 *   3. explicit out.metadata.severity       → keyword classify
 *   4. explicit out.metadata.tier           → keyword classify
 *   5. out.metadata.description / label     → keyword classify
 *   6. sequence.name keywords
 *   7. vector.id keywords
 * Fallback: info / GREEN.
 */
function inferSeverity(sequence, vector, output, lifeSafety) {
  const om = output.metadata ?? {};
  // 1. explicit processStatus on the output already (rare)
  if (om.processStatus && ['ok','info','warning','error'].includes(om.processStatus)) {
    return { processStatus: om.processStatus, ragStatusCode: om.ragStatusCode ?? STATUS_TO_RAG[om.processStatus], from: 'out.processStatus' };
  }
  // 2. explicit ragStatusCode
  if (om.ragStatusCode) {
    const rag = String(om.ragStatusCode).toUpperCase();
    if (rag === 'GREEN') return { processStatus: 'info',    ragStatusCode: 'GREEN', from: 'out.ragStatusCode' };
    if (rag === 'AMBER') return { processStatus: 'warning', ragStatusCode: 'AMBER', from: 'out.ragStatusCode' };
    if (rag === 'RED')   return { processStatus: 'error',   ragStatusCode: 'RED',   from: 'out.ragStatusCode' };
  }
  // 3-5. text classification from various signals
  for (const [src, txt] of [
    ['out.severity',    om.severity],
    ['out.tier',        om.tier],
    ['out.label',       om.label],
    ['out.description', om.description],
    ['seq.name',        sequence.name],
    ['vec.id',          vector.id],
  ]) {
    const c = classify(txt);
    if (c) return { processStatus: c, ragStatusCode: STATUS_TO_RAG[c], from: src };
  }
  // 6. life-safety machines that have no other signal default to warning,
  //    not info, since silence is dangerous in that domain.
  if (lifeSafety) {
    return { processStatus: 'warning', ragStatusCode: 'AMBER', from: 'life-safety-default' };
  }
  return { processStatus: 'info', ragStatusCode: 'GREEN', from: 'default' };
}

// ── Backfill one machine ────────────────────────────────────────────────────

function backfillMachine(file, raw) {
  const obj = JSON.parse(raw);
  const m = obj.machine ?? obj;
  m.metadata ??= {};

  const profile = profileFor(m);
  const slug = machineSlug(path.basename(file));
  const domain = primaryDomain(m);
  const lifeSafety = m.metadata.severity === 'life-safety'
    || domain === 'health-personal';

  // --- governance block ---------------------------------------------------
  if (!m.metadata.governance) {
    m.metadata.governance = {
      schemaVersion: '1.0.0',
      ownerTeam: profile.team,
      runbook: `https://runbooks.example.org/${domain}/${slug.toLowerCase()}`,
      escalationPolicy: profile.pager,
      contact: {
        primary:   `${profile.team}-primary@example.org`,
        secondary: `${profile.team}-secondary@example.org`,
      },
      sla: {
        ok:      null,
        info:    null,
        warning: profile.sla.warning ?? null,
        error:   profile.sla.error   ?? null,
      },
      notes: `Auto-backfilled by scripts/backfill-governance.mjs from primaryDomain="${domain}".  Review and tune the routing as the team owning ${slug} matures.`,
    };
  }

  // --- triggerConfig.rules ------------------------------------------------
  m.metadata.triggerConfig ??= {};
  const tc = m.metadata.triggerConfig;
  tc.processId   ??= slug.replace(/[^A-Za-z0-9]+/g, '_').toUpperCase();
  tc.processName ??= m.name ?? slug;

  // If rules are already authored, keep them — don't auto-rewrite hand-tuned
  // entries (FallDetection has them, plus a handful of others).
  if (!Array.isArray(tc.rules) || tc.rules.length === 0) {
    const rules = [];
    for (const seq of m.sequences ?? []) {
      for (const v of seq.vectors ?? []) {
        for (const out of v.outputVectors ?? []) {
          const sev = inferSeverity(seq, v, out, lifeSafety);
          const desc = (out.metadata?.description
                     ?? out.metadata?.label
                     ?? seq.name
                     ?? `${seq.id} → ${v.id}`).toString().slice(0, 240);
          rules.push({
            sequenceId: seq.id,
            outputMatches: Array.isArray(out.vector) ? out.vector : [],
            ragStatusCode: sev.ragStatusCode,
            processStatus: sev.processStatus,
            description:   desc,
          });
        }
      }
    }
    if (rules.length > 0) tc.rules = rules;
  }

  return obj;
}

// ── File walk ────────────────────────────────────────────────────────────────

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.dir)) { console.error(`machines dir not found: ${args.dir}`); process.exit(2); }

  const files = fs.readdirSync(args.dir).filter(f => f.endsWith('.json')).sort();
  let changed = 0, skipped = 0, drift = 0;

  for (const f of files) {
    const filePath = path.join(args.dir, f);
    const raw = fs.readFileSync(filePath, 'utf8');
    const obj = backfillMachine(f, raw);
    // Re-stringify with the same 2-space indent + trailing newline that the
    // corpus already uses; preserve the existing key order machine-by-machine
    // (JSON.stringify reproduces insertion order, and we only ever appended
    // fields after the existing keys via `metadata.governance ??= ...`).
    const after = JSON.stringify(obj, null, 2) + '\n';
    if (after === raw) { skipped++; continue; }
    if (args.check) {
      drift++;
      console.error(`[drift] ${f} would change`);
      continue;
    }
    fs.writeFileSync(filePath, after);
    changed++;
  }

  if (args.check) {
    if (drift > 0) {
      console.error(`backfill-governance --check failed: ${drift} file(s) would change`);
      console.error('Regenerate with: node scripts/backfill-governance.mjs');
      process.exit(1);
    }
    console.log(`backfill-governance: ${files.length} machines verified`);
    return;
  }

  console.log(`backfill-governance: ${changed} changed, ${skipped} unchanged, ${files.length} total`);
}

main();
