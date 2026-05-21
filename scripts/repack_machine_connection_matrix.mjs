#!/usr/bin/env node

import { readdirSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

const machinesDir = new URL('../examples/machines/', import.meta.url);

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

const files = readdirSync(machinesDir)
  .filter((file) => file.endsWith('.json'))
  .sort();

const documents = files.map((file) => {
  const path = join(machinesDir.pathname, file);
  return { file, path, document: JSON.parse(readFileSync(path, 'utf8')) };
});

const occupied = new Set();
for (const { document } of documents) {
  const mapping = document.machine?.perceptualMapping;
  if (!mapping) continue;
  for (const region of [mapping.input, mapping.output]) {
    for (let i = region.offset; i < region.offset + region.length; i += 1) {
      occupied.add(i);
    }
  }
}

const sortedPositions = [...occupied].sort((a, b) => a - b);
const positionMap = new Map(sortedPositions.map((position, index) => [position, index]));

function compactRegion(region) {
  const start = positionMap.get(region.offset);
  const end = positionMap.get(region.offset + region.length - 1);
  if (start === undefined || end === undefined || end - start + 1 !== region.length) {
    throw new Error(`Cannot compact non-contiguous region [${region.offset}:${region.offset + region.length}]`);
  }
  region.offset = start;
}

function compactRangeText(text) {
  return text.replace(/\[(\d+):(\d+)\]/g, (match, startText, endText) => {
    const start = Number(startText);
    const end = Number(endText);
    if (end <= start) return match;
    const compactStart = positionMap.get(start);
    const compactEnd = positionMap.get(end - 1);
    if (compactStart === undefined || compactEnd === undefined || compactEnd < compactStart) return match;
    if (compactEnd - compactStart + 1 !== end - start) return match;
    return `[${compactStart}:${compactEnd + 1}]`;
  });
}

let mappingsUpdated = 0;
for (const { path, document } of documents) {
  const mapping = document.machine?.perceptualMapping;
  if (mapping) {
    compactRegion(mapping.input);
    compactRegion(mapping.output);
    mappingsUpdated += 1;
  }
  visitStrings(document, compactRangeText);
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
}

const previousMax = Math.max(...sortedPositions) + 1;
console.log(JSON.stringify({
  machinesScanned: documents.length,
  mappingsUpdated,
  previousMaxDimension: previousMax,
  compactedMaxDimension: sortedPositions.length,
  removedPositions: previousMax - sortedPositions.length,
}, null, 2));
