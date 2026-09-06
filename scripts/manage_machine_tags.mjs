#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
// The canonical corpus, in RealityEngine_Machines. This read
// RealityEngine_CI/examples/machines/ — the retired RealityEngine_AI layout —
// while 1,016 corpus machines still declare this script as their `managedBy`,
// so the declared owner could not reach what it owns.
const machinesDir = process.env.MACHINES_DIR
  ? path.resolve(process.env.MACHINES_DIR)
  : path.join(root, '..', 'RealityEngine_Machines', 'machines');
const schemaVersion = '1.0.0';
const managedBy = 'scripts/manage_machine_tags.mjs';
const checkOnly = process.argv.includes('--check');

const capabilityTerms = new Set([
  'agent-dispatcher',
  'ai-triggers',
  'automation',
  'capacity',
  'capacity-balancer',
  'compliance',
  'critical-event',
  'dispatchable-agents',
  'e2e',
  'equity',
  'evidence',
  'forecast',
  'governance',
  'guardrail',
  'interoperability',
  'learning-loop',
  'maintenance',
  'monitoring',
  'optimization',
  'outcome-stabilizer',
  'predictive',
  'projection',
  'referral',
  'referral-optimizer',
  'resource-router',
  'risk',
  'routing',
  'signal-monitor',
  'workflow',
]);

const integrationTerms = new Set([
  'ai-services',
  'cross-domain-interconnect',
  'digital-logic',
  'health-services',
  'healthcare',
  'local-ai',
  'machine-interconnect',
  'pe-re',
  'perceptual-space',
]);

function normalizeTag(value) {
  return String(value ?? '')
    .normalize('NFKD')
    .replace(/[^\x00-\x7F]/g, ' ')
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-');
}

function add(tags, value) {
  const tag = normalizeTag(value);
  if (tag) tags.add(tag);
}

function addWords(tags, value) {
  for (const part of String(value ?? '').split(/[\s,;/|()[\]{}:]+/)) add(tags, part);
}

// machineCode is load-bearing: schemas/ai-trigger-envelope.schema.json requires
// it, and backfill-writeback-contracts.py / backfill-autonomy-contracts.py read
// it. Where the corpus already carries one it wins, because normalizeTag splits
// on camelCase and has no notion of an acronym boundary — it derives
// "open-claw-completion-e2e" from OpenClawCompletionE2E, "health-kit-vitals-
// monitor" from HealthKitVitalsMonitor and "rsring-latch-stage-a" from
// RSRingLatchStageA, against corpus values that are correct. Derive only when
// there is nothing to preserve.
function codeFromFilename(file, existing) {
  if (existing) return existing;
  const stem = file.replace(/\.json$/i, '');
  const match = stem.match(/^([A-Z]+[0-9]{3})[_-]/);
  return match ? match[1].toLowerCase() : normalizeTag(stem);
}

function familyFromFilename(file, name) {
  const stem = file.replace(/\.json$/i, '');
  const prefix = stem.match(/^([A-Z]+)[0-9]{3}[_-]/)?.[1];
  if (prefix) {
    const families = {
      AGX: 'agriculture-generated',
      BSX: 'built-space-well-generated',
      CSX: 'community-services-generated',
      DCX: 'data-center-generated',
      DLX: 'digital-logic-generated',
      HSPH: 'health-services-generated',
      LBL: 'life-balance-generated',
      LSX: 'legal-services-generated',
      TFX: 'transportation-generated',
    };
    return families[prefix] || `${prefix.toLowerCase()}-generated`;
  }
  return normalizeTag(name || stem);
}

function splitDomain(domain) {
  return String(domain ?? '')
    .split(/\s+[-—]\s+|\s+\/\s+|,/)
    .map(normalizeTag)
    .filter(Boolean);
}

function classify(rawTags) {
  const domainTags = new Set();
  const capabilityTags = new Set();
  const workflowTags = new Set();
  const integrationTags = new Set();

  for (const tag of rawTags) {
    if (integrationTerms.has(tag)) integrationTags.add(tag);
    else if (capabilityTerms.has(tag) || [...capabilityTerms].some((term) => tag.includes(term))) capabilityTags.add(tag);
    else workflowTags.add(tag);
  }

  return {
    domainTags: [...domainTags],
    capabilityTags: [...capabilityTags],
    workflowTags: [...workflowTags],
    integrationTags: [...integrationTags],
  };
}

function sorted(values) {
  return [...new Set(values.filter(Boolean))].sort();
}

// MACHINE_CONCEPT.md §9.1 resolves a machine's domain as
// metadata.tagging.primaryDomain, then metadata.category, then metadata.domain —
// and tests/contracts/domain_organization_test.py requires the result to equal
// the machine's domain directory.
//
// This function used to derive primaryDomain from metadata.category alone,
// inverting that precedence: it overwrote the highest-precedence field from a
// lower one. Two machines carry a machine *class* in `category`
// (FallSensorMotionPreaggregator: "sensor-preaggregator",
// CommunityCommandAgent: "meta-ces") while `domain` and `tagging.primaryDomain`
// hold the real domain, so a --write run wrote a primaryDomain that contradicted
// the directory and failed the gate.
function resolvePrimaryDomain(metadata) {
  return normalizeTag(
    metadata.tagging?.primaryDomain
      || metadata.category
      || metadata.domain
      || 'uncategorized',
  );
}

function buildTagging(file, document) {
  const machine = document.machine || {};
  const metadata = machine.metadata || {};
  const category = normalizeTag(metadata.category || 'uncategorized');
  const primary = resolvePrimaryDomain(metadata);
  const domainParts = splitDomain(metadata.domain || metadata.workstream || '');
  const family = familyFromFilename(file, machine.name);
  const code = codeFromFilename(file, metadata.tagging?.machineCode);

  const raw = new Set();
  add(raw, category);
  add(raw, family);
  add(raw, code);
  add(raw, metadata.domain);
  add(raw, metadata.workstream);
  add(raw, metadata.operationalFocus);
  add(raw, metadata.standardFocus);
  add(raw, metadata.function);
  add(raw, metadata.aiTrigger);
  add(raw, metadata.dispatchableAgent);
  add(raw, metadata.predictiveFlowTrigger);
  add(raw, metadata.predictiveProjectionTrigger);
  add(raw, metadata.predictiveOptimizationTrigger);
  add(raw, metadata.upstreamDomain);
  add(raw, metadata.crossDomainOutputTarget);
  add(raw, machine.name);
  const managedTagging = metadata.tagging?.managedBy === managedBy ? metadata.tagging : null;
  const sourceTags = managedTagging
    ? [
        ...(managedTagging.capabilityTags || []),
        ...(managedTagging.workflowTags || []),
        ...(managedTagging.integrationTags || []),
      ]
    : (metadata.tags || []);
  for (const tag of sourceTags) add(raw, tag);
  for (const tag of domainParts) add(raw, tag);

  const integration = new Set();
  if (metadata.crossDomainInterconnect) add(integration, 'cross-domain-interconnect');
  if (metadata.aiTrigger || metadata.predictiveFlowTrigger || metadata.predictiveProjectionTrigger || metadata.predictiveOptimizationTrigger) {
    add(integration, 'ai-trigger');
  }
  if (metadata.dispatchableAgent) add(integration, 'dispatchable-agent');
  if (metadata.upstreamMachine || metadata.downstreamMachines?.length || metadata.perceptualInterconnect) {
    add(integration, 'machine-interconnect');
  }
  for (const tag of raw) if (integrationTerms.has(tag)) integration.add(tag);

  const validation = new Set(['startup-loadable']);
  if (Array.isArray(machine.inputSequences) && machine.inputSequences.length > 0) {
    add(validation, 'input-sequences');
    add(validation, `input-sequences-${machine.inputSequences.length}`);
  }
  if ((machine.inputSequences || []).some((sequence) => sequence.metadata?.domainEndToEnd)) add(validation, 'domain-e2e');
  if ((machine.sequences || []).length > 0) {
    add(validation, 'ces-sequences');
    add(validation, `ces-sequences-${machine.sequences.length}`);
  }

  const categories = classify(raw);
  for (const tag of integration) categories.integrationTags.push(tag);

  const domainTags = sorted([primary, category, ...domainParts]);
  const capabilityTags = sorted(categories.capabilityTags);
  const workflowTags = sorted(categories.workflowTags.filter((tag) => !domainTags.includes(tag)));
  const integrationTags = sorted(categories.integrationTags);
  const validationTags = sorted([...validation]);
  const allTags = sorted([
    ...domainTags,
    family,
    code,
    ...capabilityTags,
    ...workflowTags,
    ...integrationTags,
    ...validationTags,
  ]);

  return {
    schemaVersion,
    managedBy,
    primaryDomain: primary,
    domainTags,
    family,
    machineCode: code,
    capabilityTags,
    workflowTags,
    integrationTags,
    validationTags,
    allTags,
  };
}

// Corpus files live in domain subdirectories (machines/domains/<name>/);
// walk recursively. Tagging is derived from the basename, which is globally
// unique across the corpus.
function corpusFiles(dir) {
  const found = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) found.push(...corpusFiles(p));
    else if (e.name.endsWith('.json')) found.push(p);
  }
  return found;
}

// The domain directory a corpus file sits in, or null for machines/core/ and
// anything outside the domain tree.
function domainDirOf(fullPath) {
  const rel = path.relative(machinesDir, fullPath).split(path.sep);
  return rel[0] === 'domains' && rel.length > 2 ? rel[1] : null;
}

// Fields other tooling reads. primaryDomain gates domain membership
// (domain_organization_test.py, build-region-allocation.py, audit-corpus.py,
// build-corpus-index.py); machineCode is required by
// schemas/ai-trigger-envelope.schema.json and read by the writeback/autonomy
// backfills. The tag arrays are descriptive — only the wiki compendium reads
// them, for counts and a search index — so they are reported separately and
// never gate.
const LOAD_BEARING = ['primaryDomain', 'machineCode'];

let updated = 0;
let ownedDrift = 0;
let loadBearingDrift = 0;
let skippedForeign = 0;
let skippedUnowned = 0;
const blocked = [];
const loadBearingReports = [];

const files = corpusFiles(machinesDir).sort();

for (const fullPath of files) {
  const file = path.basename(fullPath);
  const document = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
  if (!document.machine) continue;
  document.machine.metadata ??= {};
  const metadata = document.machine.metadata;
  const currentTagging = metadata.tagging;

  // Ownership. A machine whose tagging block declares a different owner, or
  // that carries a curated block with no owner at all, is not this script's to
  // rewrite — FallSensorMotionPreaggregator carries hand-authored
  // capabilityTags ("sensor-preaggregator", "firmware-contract") that no
  // metadata-derived rule reproduces, and a blind pass would flatten them.
  // Ownership is an explicit declaration, never assumed. A machine with no
  // tagging block at all is not adopted either: writing one is a corpus
  // expansion decision, not a drift repair, and it would mint a primaryDomain
  // for a machine that resolves its domain perfectly well through the
  // metadata.category / metadata.domain fallbacks §9.1 already defines.
  const owner = currentTagging?.managedBy;
  if (owner !== managedBy) {
    if (owner) skippedForeign += 1;
    else skippedUnowned += 1;
    continue;
  }

  const tagging = buildTagging(file, document);

  const lb = LOAD_BEARING.filter(
    (k) => currentTagging && JSON.stringify(currentTagging[k]) !== JSON.stringify(tagging[k]),
  );
  if (lb.length) {
    loadBearingDrift += 1;
    if (loadBearingReports.length < 20) {
      loadBearingReports.push({
        file,
        fields: Object.fromEntries(lb.map((k) => [k, { current: currentTagging[k], derived: tagging[k] }])),
      });
    }
  }

  const matches = JSON.stringify(currentTagging) === JSON.stringify(tagging)
    && JSON.stringify(metadata.tags) === JSON.stringify(tagging.allTags);
  if (!matches) ownedDrift += 1;

  // The domain invariant, enforced where the value is written rather than left
  // for the gate to discover after the fact.
  const dir = domainDirOf(fullPath);
  if (dir && tagging.primaryDomain !== dir) {
    blocked.push(`${file}: derived primaryDomain '${tagging.primaryDomain}' != directory '${dir}'`);
    continue;
  }

  if (!checkOnly && !matches) {
    metadata.tagging = tagging;
    metadata.tags = tagging.allTags;
    fs.writeFileSync(fullPath, `${JSON.stringify(document, null, 2)}\n`);
    updated += 1;
  }
}

console.log(JSON.stringify({
  checked: files.length,
  owned: files.length - skippedForeign - skippedUnowned,
  skippedForeign,
  skippedUnowned,
  loadBearingDrift,
  descriptiveDrift: ownedDrift - loadBearingDrift,
  blockedByDomainInvariant: blocked.length,
  updated,
  schemaVersion,
  managedBy,
  mode: checkOnly ? 'check' : 'write',
}, null, 2));

if (loadBearingReports.length) {
  console.error('\nLoad-bearing drift (primaryDomain / machineCode):');
  for (const r of loadBearingReports) console.error(`  ${r.file} ${JSON.stringify(r.fields)}`);
}
if (blocked.length) {
  console.error('\nRefused to write — derived primaryDomain contradicts the domain directory:');
  for (const b of blocked) console.error(`  ${b}`);
}

// Only load-bearing drift and blocked writes fail. Descriptive tag drift is
// reported, never fatal: the corpus carries enrichment that a metadata-only
// derivation cannot reproduce, and failing on it would make the check a thing
// people learn to ignore.
if (loadBearingDrift > 0 || blocked.length > 0) process.exit(1);
