#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const machinesDir = path.join(root, 'examples', 'machines');
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

function codeFromFilename(file) {
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

function buildTagging(file, document) {
  const machine = document.machine || {};
  const metadata = machine.metadata || {};
  const category = normalizeTag(metadata.category || 'uncategorized');
  const domainParts = splitDomain(metadata.domain || metadata.workstream || '');
  const family = familyFromFilename(file, machine.name);
  const code = codeFromFilename(file);

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

  const domainTags = sorted([category, ...domainParts]);
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
    primaryDomain: category,
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

let updated = 0;
let mismatches = 0;
const files = fs.readdirSync(machinesDir).filter((file) => file.endsWith('.json')).sort();

for (const file of files) {
  const fullPath = path.join(machinesDir, file);
  const document = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
  document.machine ??= {};
  document.machine.metadata ??= {};
  const tagging = buildTagging(file, document);
  const currentTagging = document.machine.metadata.tagging;
  const currentTags = document.machine.metadata.tags;
  const matches = JSON.stringify(currentTagging) === JSON.stringify(tagging)
    && JSON.stringify(currentTags) === JSON.stringify(tagging.allTags);
  if (!matches) mismatches += 1;
  if (!checkOnly) {
    document.machine.metadata.tagging = tagging;
    document.machine.metadata.tags = tagging.allTags;
    fs.writeFileSync(fullPath, `${JSON.stringify(document, null, 2)}\n`);
    updated += 1;
  }
}

console.log(JSON.stringify({
  checked: files.length,
  updated,
  mismatches,
  schemaVersion,
  managedBy,
  mode: checkOnly ? 'check' : 'write',
}, null, 2));

if (checkOnly && mismatches > 0) process.exit(1);
