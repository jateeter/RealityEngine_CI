#!/usr/bin/env node

import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

const machinesDir = new URL('../examples/machines/', import.meta.url);
const dryRun = process.argv.includes('--dry-run');

function visitStrings(value, update) {
  if (typeof value === 'string') return update(value);
  if (Array.isArray(value)) return value.map((item) => visitStrings(item, update));
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      value[key] = visitStrings(child, update);
    }
  }
  return value;
}

function rangeKey(region) {
  return `${region.offset}:${region.offset + region.length}`;
}

function addEdge(graph, a, b) {
  if (!graph.has(a)) graph.set(a, new Set());
  if (!graph.has(b)) graph.set(b, new Set());
  graph.get(a).add(b);
  graph.get(b).add(a);
}

const files = readdirSync(machinesDir)
  .filter((file) => file.endsWith('.json'))
  .sort();

const documents = files.map((file) => {
  const path = join(machinesDir.pathname, file);
  return { file, path, document: JSON.parse(readFileSync(path, 'utf8')) };
});

const positions = new Set();
const positionUsers = new Map();
const regionUsers = new Map();
const adjacency = new Map();

for (const { file, document } of documents) {
  const machine = document.machine;
  const mapping = machine?.perceptualMapping;
  if (!machine || !mapping) continue;

  const name = machine.name || file;
  const category = machine.metadata?.category || 'uncategorized';

  for (const side of ['input', 'output']) {
    const region = mapping[side];
    if (!region) continue;
    const user = { file, name, category, side, region };
    const key = rangeKey(region);
    if (!regionUsers.has(key)) regionUsers.set(key, []);
    regionUsers.get(key).push(user);

    for (let offset = region.offset; offset < region.offset + region.length; offset += 1) {
      positions.add(offset);
      if (!positionUsers.has(offset)) positionUsers.set(offset, []);
      positionUsers.get(offset).push(user);
      if (!adjacency.has(offset)) adjacency.set(offset, new Set());
      if (offset > region.offset) addEdge(adjacency, offset - 1, offset);
    }
  }
}

const sortedPositions = [...positions].sort((a, b) => a - b);
const seen = new Set();
const components = [];

for (const start of sortedPositions) {
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
  const domains = new Set();
  const machines = new Set();
  let inputUsers = 0;
  let outputUsers = 0;

  for (const position of values) {
    for (const user of positionUsers.get(position) || []) {
      domains.add(user.category);
      machines.add(user.name);
      if (user.side === 'input') inputUsers += 1;
      if (user.side === 'output') outputUsers += 1;
    }
  }

  components.push({
    positions: values,
    start: values[0],
    end: values[values.length - 1] + 1,
    length: values.length,
    domains: [...domains].sort(),
    machines: [...machines].sort(),
    inputUsers,
    outputUsers,
  });
}

const singleDomainComponents = components.filter((component) => component.domains.length === 1);
const bridgeComponents = components.filter((component) => component.domains.length !== 1);
const domainOrder = [...new Set(singleDomainComponents.map((component) => component.domains[0]))].sort();

const orderedComponents = [];
const domainBlocks = {};
let cursor = 0;

for (const domain of domainOrder) {
  const domainComponents = singleDomainComponents
    .filter((component) => component.domains[0] === domain)
    .sort((a, b) => a.start - b.start);
  const start = cursor;
  for (const component of domainComponents) {
    orderedComponents.push(component);
    cursor += component.length;
  }
  domainBlocks[domain] = {
    start,
    end: cursor,
    length: cursor - start,
    components: domainComponents.length,
  };
}

const bridgeStart = cursor;
for (const component of bridgeComponents.sort((a, b) => a.start - b.start)) {
  orderedComponents.push(component);
  cursor += component.length;
}
const bridgeBlock = {
  start: bridgeStart,
  end: cursor,
  length: cursor - bridgeStart,
  components: bridgeComponents.length,
};

const positionMap = new Map();
let newCursor = 0;
for (const component of orderedComponents) {
  for (const position of component.positions) {
    positionMap.set(position, newCursor);
    newCursor += 1;
  }
}

function remapRegion(region) {
  const start = positionMap.get(region.offset);
  const end = positionMap.get(region.offset + region.length - 1);
  if (start === undefined || end === undefined || end - start + 1 !== region.length) {
    throw new Error(`Cannot remap non-contiguous region [${region.offset}:${region.offset + region.length}]`);
  }
  region.offset = start;
}

function remapRangeText(text) {
  return text.replace(/\[(\d+):(\d+)\]/g, (match, startText, endText) => {
    const start = Number(startText);
    const end = Number(endText);
    if (end <= start) return match;
    const mappedStart = positionMap.get(start);
    const mappedEnd = positionMap.get(end - 1);
    if (mappedStart === undefined || mappedEnd === undefined) return match;
    if (mappedEnd - mappedStart + 1 !== end - start) return match;
    return `[${mappedStart}:${mappedEnd + 1}]`;
  });
}

let mappingsUpdated = 0;
if (!dryRun) {
  for (const { path, document } of documents) {
    const mapping = document.machine?.perceptualMapping;
    if (mapping) {
      remapRegion(mapping.input);
      remapRegion(mapping.output);
      mappingsUpdated += 1;
    }
    visitStrings(document, remapRangeText);
    writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
  }
}

const crossDomainRegions = [];
for (const [range, users] of regionUsers.entries()) {
  const categories = [...new Set(users.map((user) => user.category))].sort();
  const sides = [...new Set(users.map((user) => user.side))].sort();
  if (categories.length > 1 && sides.includes('input') && sides.includes('output')) {
    const [startText, endText] = range.split(':');
    const start = Number(startText);
    const end = Number(endText);
    const mappedStart = positionMap.get(start);
    const mappedEnd = positionMap.get(end - 1);
    const mappedRange = mappedStart !== undefined && mappedEnd !== undefined
      ? `${mappedStart}:${mappedEnd + 1}`
      : range;
    crossDomainRegions.push({
      range: mappedRange,
      categories,
      inputMachines: users.filter((user) => user.side === 'input').map((user) => user.name).sort(),
      outputMachines: users.filter((user) => user.side === 'output').map((user) => user.name).sort(),
    });
  }
}

const totalRegions = [...regionUsers.values()].length;
const connectedRegions = [...regionUsers.values()].filter((users) => {
  const sides = new Set(users.map((user) => user.side));
  return sides.has('input') && sides.has('output');
}).length;

const totalMachineInterconnects = [...regionUsers.values()].reduce((count, users) => {
  const inputs = users.filter((user) => user.side === 'input');
  const outputs = users.filter((user) => user.side === 'output');
  return count + inputs.length * outputs.length;
}, 0);

const crossDomainMachineInterconnects = [...regionUsers.values()].reduce((count, users) => {
  const inputs = users.filter((user) => user.side === 'input');
  const outputs = users.filter((user) => user.side === 'output');
  let subtotal = 0;
  for (const input of inputs) {
    for (const output of outputs) {
      if (input.category !== output.category) subtotal += 1;
    }
  }
  return count + subtotal;
}, 0);

const report = {
  dryRun,
  machinesScanned: documents.length,
  mappingsUpdated,
  previousMaxDimension: sortedPositions.length ? Math.max(...sortedPositions) + 1 : 0,
  remappedMaxDimension: newCursor,
  domainBlocks,
  crossDomainBridgeBlock: bridgeBlock,
  components: {
    total: components.length,
    singleDomain: singleDomainComponents.length,
    crossDomainBridge: bridgeComponents.length,
  },
  interconnects: {
    totalRegions,
    connectedRegions,
    totalMachineInterconnects,
    crossDomainMachineInterconnects,
    crossDomainRatio: totalMachineInterconnects ? Number((crossDomainMachineInterconnects / totalMachineInterconnects).toFixed(4)) : 0,
  },
  crossDomainRegions,
};

console.log(JSON.stringify(report, null, 2));
