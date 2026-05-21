#!/usr/bin/env node

import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

const root = new URL('../', import.meta.url);
const machinesDir = new URL('../examples/machines/', import.meta.url);
const docsPath = new URL('../docs/EXAMPLE_DOMAIN_COMPENDIUM.md', import.meta.url);
const wikiCompendiumPath = new URL('../wiki/Example-Machine-Compendium.md', import.meta.url);
const wikiInterconnectionPath = new URL('../wiki/Machine-Interconnection-Index.md', import.meta.url);
const nestedWikiHomePath = new URL('../wiki/RealityEngine_AI.wiki/Home.md', import.meta.url);
const nestedWikiCompendiumPath = new URL('../wiki/RealityEngine_AI.wiki/Example-Machine-Compendium.md', import.meta.url);
const nestedWikiInterconnectionPath = new URL('../wiki/RealityEngine_AI.wiki/Machine-Interconnection-Index.md', import.meta.url);

function esc(value) {
  return String(value ?? '')
    .replace(/\|/g, '\\|')
    .replace(/\n/g, ' ')
    .trim();
}

function slug(value) {
  return String(value || 'unnamed')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'unnamed';
}

function range(region) {
  if (!region) return '';
  return `[${region.offset}:${region.offset + region.length}]`;
}

function overlap(a, b) {
  const start = Math.max(a.offset, b.offset);
  const end = Math.min(a.offset + a.length, b.offset + b.length);
  return end > start ? { offset: start, length: end - start } : null;
}

function machineCode(file) {
  const match = file.match(/^([A-Z]+[0-9]{3})_/);
  if (match) return match[1];
  return file.replace(/\.json$/, '');
}

function relMachinePath(file) {
  return `examples/machines/${file}`;
}

const files = readdirSync(machinesDir)
  .filter((file) => file.endsWith('.json'))
  .sort();

const machines = files.map((file) => {
  const document = JSON.parse(readFileSync(join(machinesDir.pathname, file), 'utf8'));
  const machine = document.machine || {};
  const metadata = machine.metadata || {};
  const mapping = machine.perceptualMapping || {};
  const inputSequences = machine.inputSequences || metadata.inputSequences || [];
  const tagging = metadata.tagging || {};
  const tags = Array.isArray(tagging.allTags)
    ? tagging.allTags
    : (Array.isArray(metadata.tags) ? metadata.tags : []);
  const downstream = Array.isArray(metadata.downstreamMachines) ? metadata.downstreamMachines : [];
  return {
    file,
    code: machineCode(file),
    name: machine.name || file.replace(/\.json$/, ''),
    description: machine.description || '',
    category: metadata.category || 'uncategorized',
    domain: metadata.domain || metadata.workstream || metadata.operationalFocus || 'Unspecified',
    workstream: metadata.workstream || '',
    focus: metadata.operationalFocus || metadata.focusDescription || '',
    aiTrigger: metadata.aiTrigger || metadata.predictiveFlowTrigger || metadata.predictiveOptimizationTrigger || '',
    dispatchableAgent: metadata.dispatchableAgent || '',
    upstreamMachine: metadata.upstreamMachine || '',
    downstreamMachines: downstream,
    tags,
    tagging,
    input: mapping.input || null,
    output: mapping.output || null,
    sequenceCount: machine.sequenceCount ?? (Array.isArray(machine.sequences) ? machine.sequences.length : 0),
    inputSequenceCount: Array.isArray(inputSequences) ? inputSequences.length : 0,
  };
});

const byDomain = new Map();
for (const machine of machines) {
  if (!byDomain.has(machine.category)) byDomain.set(machine.category, []);
  byDomain.get(machine.category).push(machine);
}

const sortedDomains = [...byDomain.keys()].sort();

const positions = new Set();
for (const machine of machines) {
  for (const region of [machine.input, machine.output]) {
    if (!region) continue;
    for (let i = region.offset; i < region.offset + region.length; i += 1) positions.add(i);
  }
}
const maxDimension = positions.size ? Math.max(...positions) + 1 : 0;
const holes = [];
for (let i = 0; i < maxDimension; i += 1) if (!positions.has(i)) holes.push(i);

const interconnections = [];
for (const source of machines) {
  if (!source.output) continue;
  for (const target of machines) {
    if (source.file === target.file || !target.input) continue;
    const shared = overlap(source.output, target.input);
    if (!shared) continue;
    interconnections.push({
      source,
      target,
      overlap: shared,
      crossDomain: source.category !== target.category,
    });
  }
}
interconnections.sort((a, b) =>
  a.source.category.localeCompare(b.source.category) ||
  a.target.category.localeCompare(b.target.category) ||
  a.source.name.localeCompare(b.source.name) ||
  a.target.name.localeCompare(b.target.name)
);

const positionUsers = new Map();
const adjacency = new Map();
function addEdge(a, b) {
  if (!adjacency.has(a)) adjacency.set(a, new Set());
  if (!adjacency.has(b)) adjacency.set(b, new Set());
  adjacency.get(a).add(b);
  adjacency.get(b).add(a);
}
for (const machine of machines) {
  for (const side of ['input', 'output']) {
    const region = machine[side];
    if (!region) continue;
    for (let offset = region.offset; offset < region.offset + region.length; offset += 1) {
      if (!positionUsers.has(offset)) positionUsers.set(offset, []);
      positionUsers.get(offset).push({ machine, side });
      if (!adjacency.has(offset)) adjacency.set(offset, new Set());
      if (offset > region.offset) addEdge(offset - 1, offset);
    }
  }
}

const components = [];
const seen = new Set();
for (const start of [...positions].sort((a, b) => a - b)) {
  if (seen.has(start)) continue;
  const stack = [start];
  const values = [];
  seen.add(start);
  while (stack.length) {
    const current = stack.pop();
    values.push(current);
    for (const next of adjacency.get(current) || []) {
      if (!seen.has(next)) {
        seen.add(next);
        stack.push(next);
      }
    }
  }
  values.sort((a, b) => a - b);
  const domains = [...new Set(values.flatMap((position) =>
    (positionUsers.get(position) || []).map((user) => user.machine.category)
  ))].sort();
  components.push({
    start: values[0],
    end: values[values.length - 1] + 1,
    length: values.length,
    domains,
  });
}

const domainBlocks = {};
const domainBridgeRanges = {};
for (const domain of sortedDomains) {
  const domainComponents = components.filter((component) => component.domains.length === 1 && component.domains[0] === domain);
  const bridgeComponents = components.filter((component) => component.domains.length > 1 && component.domains.includes(domain));
  const start = domainComponents.length ? Math.min(...domainComponents.map((component) => component.start)) : 0;
  const end = domainComponents.length ? Math.max(...domainComponents.map((component) => component.end)) : 0;
  domainBlocks[domain] = {
    start,
    end,
    length: domainComponents.reduce((sum, component) => sum + component.length, 0),
    components: domainComponents.length,
  };
  domainBridgeRanges[domain] = bridgeComponents.map((component) => `[${component.start}:${component.end}]`);
}

const bridgeComponents = components.filter((component) => component.domains.length > 1);
const bridgeBlock = bridgeComponents.length
  ? {
      start: Math.min(...bridgeComponents.map((component) => component.start)),
      end: Math.max(...bridgeComponents.map((component) => component.end)),
      length: bridgeComponents.reduce((sum, component) => sum + component.length, 0),
      components: bridgeComponents.length,
    }
  : { start: 0, end: 0, length: 0, components: 0 };

const interconnectionsByDomain = new Map();
for (const edge of interconnections) {
  const key = `${edge.source.category} -> ${edge.target.category}`;
  interconnectionsByDomain.set(key, (interconnectionsByDomain.get(key) || 0) + 1);
}

function domainOverviewTable() {
  const lines = [
    '| Domain | Machines | Vector Block | Input Sequences | Interconnections Out | Interconnections In | Search Terms |',
    '| --- | ---: | ---: | ---: | ---: | ---: | --- |',
  ];
  for (const domain of sortedDomains) {
    const domainMachines = byDomain.get(domain);
    const block = domainBlocks[domain];
    const inputSequences = domainMachines.reduce((sum, machine) => sum + machine.inputSequenceCount, 0);
    const out = interconnections.filter((edge) => edge.source.category === domain).length;
    const incoming = interconnections.filter((edge) => edge.target.category === domain).length;
    const terms = [...new Set(domainMachines.flatMap((machine) => [
      machine.category,
      machine.domain,
      machine.workstream,
      ...machine.tags.slice(0, 4),
    ].filter(Boolean)))].slice(0, 12).join(', ');
    const bridge = domainBridgeRanges[domain].length ? `; bridge ${domainBridgeRanges[domain].join(', ')}` : '';
    lines.push(`| ${esc(domain)} | ${domainMachines.length} | [${block.start}:${block.end}]${bridge} | ${inputSequences} | ${out} | ${incoming} | ${esc(terms)} |`);
  }
  return lines.join('\n');
}

function domainSections() {
  const sections = [];
  for (const domain of sortedDomains) {
    const domainMachines = byDomain.get(domain);
    const block = domainBlocks[domain];
    const workstreams = new Map();
    for (const machine of domainMachines) {
      const key = machine.domain || machine.workstream || 'Unspecified';
      workstreams.set(key, (workstreams.get(key) || 0) + 1);
    }
    const topTerms = [...new Set(domainMachines.flatMap((machine) => [
      machine.workstream,
      machine.focus,
      machine.dispatchableAgent,
      ...machine.tags,
    ].filter(Boolean)))].slice(0, 40);

    sections.push(`## ${domain}\n\n` +
      `Machine count: ${domainMachines.length}\n\n` +
      `Vector block: [${block.start}:${block.end}] (${block.length} domain-local positions)\n\n` +
      (domainBridgeRanges[domain].length ? `Bridge positions: ${domainBridgeRanges[domain].join(', ')}\n\n` : '') +
      `Search terms: ${esc(topTerms.join(', '))}\n\n` +
      '| Workstream / Domain Label | Machines |\n| --- | ---: |\n' +
      [...workstreams.entries()].sort((a, b) => a[0].localeCompare(b[0]))
        .map(([name, count]) => `| ${esc(name)} | ${count} |`).join('\n') +
      '\n\n' +
      '| Code | Machine | Input | Output | Input Sequences | AI Trigger | Agent | Tag Groups | Tags |\n' +
      '| --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n' +
      domainMachines
        .sort((a, b) => a.code.localeCompare(b.code) || a.name.localeCompare(b.name))
        .map((machine) => {
          const groups = [
            `domain:${(machine.tagging.domainTags || []).length}`,
            `capability:${(machine.tagging.capabilityTags || []).length}`,
            `workflow:${(machine.tagging.workflowTags || []).length}`,
            `integration:${(machine.tagging.integrationTags || []).length}`,
            `validation:${(machine.tagging.validationTags || []).length}`,
          ].join(', ');
          return `| ${esc(machine.code)} | [${esc(machine.name)}](${relMachinePath(machine.file)}) | ${range(machine.input)} | ${range(machine.output)} | ${machine.inputSequenceCount} | ${esc(machine.aiTrigger)} | ${esc(machine.dispatchableAgent)} | ${esc(groups)} | ${esc(machine.tags.join(', '))} |`;
        })
        .join('\n'));
  }
  return sections.join('\n\n');
}

function taggingSummary() {
  const schemaVersions = [...new Set(machines.map((machine) => machine.tagging.schemaVersion || 'missing'))].sort();
  const managedBy = [...new Set(machines.map((machine) => machine.tagging.managedBy || 'unmanaged'))].sort();
  const complete = machines.filter((machine) => machine.tagging.schemaVersion && Array.isArray(machine.tagging.allTags)).length;
  const groupTotals = machines.reduce((totals, machine) => {
    totals.domain += (machine.tagging.domainTags || []).length;
    totals.capability += (machine.tagging.capabilityTags || []).length;
    totals.workflow += (machine.tagging.workflowTags || []).length;
    totals.integration += (machine.tagging.integrationTags || []).length;
    totals.validation += (machine.tagging.validationTags || []).length;
    return totals;
  }, { domain: 0, capability: 0, workflow: 0, integration: 0, validation: 0 });
  return [
    '## Tagging Schema',
    '',
    `- Structured machine tags: ${complete}/${machines.length}`,
    `- Schema versions: ${schemaVersions.join(', ')}`,
    `- Managed by: ${managedBy.join(', ')}`,
    `- Tag groups: domain=${groupTotals.domain}, capability=${groupTotals.capability}, workflow=${groupTotals.workflow}, integration=${groupTotals.integration}, validation=${groupTotals.validation}`,
    '',
    '`metadata.tags` remains the backwards-compatible flattened search index. `metadata.tagging` carries the managed tag groups.',
  ].join('\n');
}

function interconnectionSummaryTable() {
  const rows = [...interconnectionsByDomain.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  return [
    '| Domain Path | Interconnections |',
    '| --- | ---: |',
    ...rows.map(([path, count]) => `| ${esc(path)} | ${count} |`),
  ].join('\n');
}

function interconnectionTable(edges = interconnections) {
  return [
    '| Source Domain | Source Machine | Source Output | Target Domain | Target Machine | Target Input | Overlap | Type |',
    '| --- | --- | ---: | --- | --- | ---: | ---: | --- |',
    ...edges.map((edge) => `| ${esc(edge.source.category)} | ${esc(edge.source.name)} | ${range(edge.source.output)} | ${esc(edge.target.category)} | ${esc(edge.target.name)} | ${range(edge.target.input)} | ${range(edge.overlap)} | ${edge.crossDomain ? 'cross-domain' : 'domain-local'} |`),
  ].join('\n');
}

const generatedAt = new Date().toISOString();
const summary = `# Example Machine Compendium\n\n` +
  `Generated from \`examples/machines/*.json\` at ${generatedAt}.\n\n` +
  `This page is intentionally indexable and searchable: every active domain, machine name, machine code, trigger, agent, tag, vector range, and interconnection is represented as plain Markdown text.\n\n` +
  `## Corpus Summary\n\n` +
  `- Machines: ${machines.length}\n` +
  `- Active domains: ${sortedDomains.length}\n` +
  `- Used perceptual positions: ${positions.size}\n` +
  `- Max dimension: ${maxDimension}\n` +
  `- Holes: ${holes.length}\n` +
  `- Machine-level interconnections: ${interconnections.length}\n` +
  `- Cross-domain interconnections: ${interconnections.filter((edge) => edge.crossDomain).length}\n` +
  `- Cross-domain bridge block: [${bridgeBlock.start}:${bridgeBlock.end}] (${bridgeBlock.length} positions, ${bridgeBlock.components} components)\n\n` +
  `## Active Domains\n\n${domainOverviewTable()}\n\n` +
  `${taggingSummary()}\n\n` +
  `## Interconnection Summary\n\n${interconnectionSummaryTable()}\n\n` +
  `## Machine Index\n\n${domainSections()}\n\n` +
  `## Full Interconnection Index\n\n${interconnectionTable()}\n`;

const wikiInterconnections = `# Machine Interconnection Index\n\n` +
  `Generated from \`examples/machines/*.json\` at ${generatedAt}.\n\n` +
  `Machine-level interconnections are output-to-input perceptual-space overlaps. Search by domain, machine name, range, or \`cross-domain\`.\n\n` +
  `- Total interconnections: ${interconnections.length}\n` +
  `- Cross-domain interconnections: ${interconnections.filter((edge) => edge.crossDomain).length}\n` +
  `- Domain-local interconnections: ${interconnections.filter((edge) => !edge.crossDomain).length}\n\n` +
  `## Domain Path Summary\n\n${interconnectionSummaryTable()}\n\n` +
  `## Interconnections\n\n${interconnectionTable()}\n`;

writeFileSync(docsPath, summary);
writeFileSync(wikiCompendiumPath, summary);
writeFileSync(wikiInterconnectionPath, wikiInterconnections);

const wikiHome = `# RealityEngine_AI Wiki\n\n` +
  `## Example Machine Corpus\n\n` +
  `- [Example Machine Compendium](Example-Machine-Compendium) — searchable index of all active domains, machines, AI triggers, agents, vector mappings, and interconnections generated from \`examples/machines/*.json\`.\n` +
  `- [Machine Interconnection Index](Machine-Interconnection-Index) — searchable output-to-input overlap index for domain-local and cross-domain machine interconnections.\n\n` +
  `- [Machine Tagging](Machine-Tagging) — managed machine metadata tag schema and validation workflow.\n` +
  `- [Life Balance Machines](Life-Balance-Machines) — lifestyle-psychiatry tracking, automation, projection, and e2e validation machines.\n\n` +
  `Current generated corpus:\n\n` +
  `- \`${machines.length}\` machines\n` +
  `- \`${sortedDomains.length}\` active domains\n` +
  `- \`${positions.size}\` used perceptual positions\n` +
  `- \`${interconnections.length}\` machine-level interconnections\n` +
  `- \`${interconnections.filter((edge) => edge.crossDomain).length}\` cross-domain interconnections\n`;

writeFileSync(nestedWikiHomePath, wikiHome);
writeFileSync(nestedWikiCompendiumPath, summary);
writeFileSync(nestedWikiInterconnectionPath, wikiInterconnections);

console.log(JSON.stringify({
  machines: machines.length,
  activeDomains: sortedDomains.length,
  maxDimension,
  holes: holes.length,
  interconnections: interconnections.length,
  crossDomainInterconnections: interconnections.filter((edge) => edge.crossDomain).length,
  docs: [
    docsPath.pathname.replace(root.pathname, ''),
    wikiCompendiumPath.pathname.replace(root.pathname, ''),
    wikiInterconnectionPath.pathname.replace(root.pathname, ''),
    nestedWikiHomePath.pathname.replace(root.pathname, ''),
    nestedWikiCompendiumPath.pathname.replace(root.pathname, ''),
    nestedWikiInterconnectionPath.pathname.replace(root.pathname, ''),
  ],
}, null, 2));
