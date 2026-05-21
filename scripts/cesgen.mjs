#!/usr/bin/env node
/**
 * cesgen — Critical Event Sequence code generator.
 *
 * Reads `examples/machines/*.json` and emits typed stubs in TypeScript,
 * C++, and Scala so adding a new domain machine is a JSON change rather
 * than a patch across three runtime codebases.
 *
 * Emitted artifacts per machine:
 *   • All vector IDs as a string-literal union (TS) / enum class (C++) /
 *     sealed trait (Scala) — so consumers can reference states by name
 *     with compile-time checks instead of magic strings.
 *   • All sequence IDs in the same form.
 *   • Initial-states-per-sequence and transition (next-state) tables.
 *   • Output-vectors-per-state literal tables.
 *   • Input / output dimensions and the full perceptualMapping.
 *
 * One aggregate registry per language pulls all generated machines into a
 * map keyed by machine slug for runtime lookup and verification testing.
 *
 * Usage:
 *   node scripts/cesgen.mjs --names RSFlipFlop,RS2,MultiStep,DLX001
 *   node scripts/cesgen.mjs --domains AGX,DCX,HSPH
 *   node scripts/cesgen.mjs --all                       # every file in examples/machines
 *   node scripts/cesgen.mjs --names RSFlipFlop --check  # exit non-zero if output differs from disk
 *
 * Output roots can be overridden with --out-ts <dir> --out-cpp <dir> --out-scala <dir>.
 * Defaults are:
 *   src/generated/machines/                                  (TS)
 *   ../RealityEngine_CPP/include/reality/generated/          (C++)
 *   scala/src/main/scala/com/realityengine/generated/        (Scala)
 *
 * The Scala output directory is created on demand and only written if the
 * Scala source tree exists in the AI repo (it does today under scala/).
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const MACHINES_DIR = path.join(ROOT, 'examples', 'machines');

// ── CLI ──────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { names: [], domains: [], all: false, check: false, outTs: null, outCpp: null, outScala: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') args.all = true;
    else if (a === '--check') args.check = true;
    else if (a === '--names')   args.names   = argv[++i].split(',').filter(Boolean);
    else if (a === '--domains') args.domains = argv[++i].split(',').filter(Boolean);
    else if (a === '--out-ts')    args.outTs    = argv[++i];
    else if (a === '--out-cpp')   args.outCpp   = argv[++i];
    else if (a === '--out-scala') args.outScala = argv[++i];
    else if (a === '-h' || a === '--help') { printHelp(); process.exit(0); }
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  args.outTs    ??= path.join(ROOT, 'src', 'generated', 'machines');
  args.outCpp   ??= path.resolve(ROOT, '..', 'RealityEngine_CPP', 'include', 'reality', 'generated');
  args.outScala ??= path.join(ROOT, 'scala', 'src', 'main', 'scala', 'com', 'realityengine', 'generated');
  return args;
}

function printHelp() {
  console.log('Usage: cesgen.mjs [--names a,b,c] [--domains AGX,DCX] [--all] [--check]');
  console.log('                  [--out-ts DIR] [--out-cpp DIR] [--out-scala DIR]');
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function pascalCase(s) {
  return s.replace(/[^A-Za-z0-9]+/g, ' ').trim().split(/\s+/)
    .map(p => p ? p[0].toUpperCase() + p.slice(1) : '')
    .join('');
}

function snakeCase(s) {
  return s.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '').toLowerCase();
}

function safeIdent(s) {
  // Identifier safe for TS / C++ / Scala enum members.
  let id = pascalCase(s);
  if (!/^[A-Za-z_]/.test(id)) id = '_' + id;
  return id || '_';
}

function listMachineFiles(args) {
  const all = fs.readdirSync(MACHINES_DIR).filter(f => f.endsWith('.json')).sort();
  if (args.all) return all;
  const picked = new Set();
  for (const name of args.names) {
    const exact = all.find(f => f === `${name}.json` || f.startsWith(`${name}_`) || f.startsWith(`${name}.`));
    if (exact) picked.add(exact);
    else console.warn(`(skip) no machine file matched --names ${name}`);
  }
  for (const prefix of args.domains) {
    for (const f of all) if (f.toUpperCase().startsWith(prefix.toUpperCase())) picked.add(f);
  }
  return [...picked].sort();
}

// Normalize one raw machine JSON into a generator-internal spec.
function normalize(filePath) {
  const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const m = raw.machine ?? raw;
  const slug = path.basename(filePath, '.json');
  const pascal = safeIdent(slug);
  const mapping = m.perceptualMapping ?? { input: { offset: 0, length: 0 }, output: { offset: 0, length: 0 } };
  const sequences = (m.sequences ?? []).map(s => ({
    id: s.id,
    name: s.name,
    ident: safeIdent(s.id),
    initial: (s.vectors ?? []).filter(v => v.isInitial).map(v => v.id),
    vectors: (s.vectors ?? []).map(v => ({
      id: v.id,
      ident: safeIdent(v.id),
      isInitial: !!v.isInitial,
      elements: (v.elements ?? []).map(e => e.value),
      next: v.nextVectorIds ?? [],
      outputs: (v.outputVectors ?? []).map(o => o.vector ?? []),
    })),
  }));
  // Deduplicated, alphabetized state ID list across the whole machine.
  const stateIds = [...new Set(sequences.flatMap(s => s.vectors.map(v => v.id)))].sort();
  return {
    file:          path.basename(filePath),
    slug,
    pascalName:    pascal,
    machineId:     m.id ?? `machine-${slug.toLowerCase()}`,
    machineName:   m.name ?? slug,
    description:   m.description ?? '',
    perceptualMapping: mapping,
    inputDim:      mapping.input?.length ?? 0,
    outputDim:     mapping.output?.length ?? 0,
    sequences,
    stateIds,
  };
}

// ── TypeScript emitter ───────────────────────────────────────────────────────

function emitTs(spec) {
  const stateMembers = spec.stateIds.map(id => `  ${safeIdent(id)}: ${JSON.stringify(id)},`).join('\n');
  const seqMembers   = spec.sequences.map(s => `  ${s.ident}: ${JSON.stringify(s.id)},`).join('\n');

  const initialBody = spec.sequences.map(s => {
    const list = s.initial.map(i => `StateId.${safeIdent(i)}`).join(', ');
    return `  [SequenceId.${s.ident}]: [${list}],`;
  }).join('\n');

  const allVectors = spec.sequences.flatMap(s => s.vectors);
  const transitions = allVectors.map(v => {
    const list = v.next.map(n => `StateId.${safeIdent(n)}`).join(', ');
    return `  [StateId.${v.ident}]: [${list}],`;
  }).join('\n');

  const outputs = allVectors.map(v => {
    const arrays = v.outputs.map(o => `[${o.join(', ')}]`).join(', ');
    return `  [StateId.${v.ident}]: [${arrays}],`;
  }).join('\n');

  const initialVecs = allVectors.filter(v => v.isInitial).map(v => `StateId.${v.ident}`).join(', ');

  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
// Source: examples/machines/${spec.file}
/* eslint-disable */
import type { PerceptualMapping } from '../../models/types.js';

export const machineId   = ${JSON.stringify(spec.machineId)};
export const machineName = ${JSON.stringify(spec.machineName)};
export const machineSlug = ${JSON.stringify(spec.slug)};

export const perceptualMapping: PerceptualMapping = {
  input:  { offset: ${spec.perceptualMapping.input?.offset ?? 0},  length: ${spec.inputDim} },
  output: { offset: ${spec.perceptualMapping.output?.offset ?? 0}, length: ${spec.outputDim} },
};

export const inputDim  = ${spec.inputDim} as const;
export const outputDim = ${spec.outputDim} as const;

export const StateId = {
${stateMembers}
} as const;
export type StateId = typeof StateId[keyof typeof StateId];

export const SequenceId = {
${seqMembers}
} as const;
export type SequenceId = typeof SequenceId[keyof typeof SequenceId];

export const initialStates: Record<SequenceId, StateId[]> = {
${initialBody}
};

// Globally-initial states (across every sequence) — useful for warm-start handlers.
export const initialStatesAll: StateId[] = [${initialVecs}];

export const transitions: Record<StateId, StateId[]> = {
${transitions}
};

export const outputs: Record<StateId, ReadonlyArray<ReadonlyArray<number>>> = {
${outputs}
};
`;
}

function emitTsIndex(specs) {
  const lines = specs.map(s =>
    `import * as ${s.pascalName} from './${s.slug}.js';`
  ).join('\n');
  const entries = specs.map(s =>
    `  ${JSON.stringify(s.slug)}: ${s.pascalName},`
  ).join('\n');
  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
${lines}

export const machines = {
${entries}
} as const;
export type MachineSlug = keyof typeof machines;
`;
}

// ── C++ emitter ──────────────────────────────────────────────────────────────

function emitCpp(spec) {
  const ns = snakeCase(spec.slug);
  const stateEnum = spec.stateIds.length === 0
    ? '  // (no states)'
    : spec.stateIds.map((id, i) => `  ${safeIdent(id)}${i + 1 === spec.stateIds.length ? '' : ','}  // ${id}`).join('\n');
  const stateStrings = spec.stateIds.length === 0
    ? '    default: return "";'
    : spec.stateIds.map(id => `    case StateId::${safeIdent(id)}: return ${JSON.stringify(id)};`).join('\n');

  const seqEnum = spec.sequences.length === 0
    ? '  // (no sequences)'
    : spec.sequences.map((s, i) => `  ${s.ident}${i + 1 === spec.sequences.length ? '' : ','}  // ${s.id}`).join('\n');
  const seqStrings = spec.sequences.length === 0
    ? '    default: return "";'
    : spec.sequences.map(s => `    case SequenceId::${s.ident}: return ${JSON.stringify(s.id)};`).join('\n');

  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
// Source: examples/machines/${spec.file}
#pragma once

#include <string_view>

namespace reality::generated::${ns} {

inline constexpr std::string_view machine_id    = ${JSON.stringify(spec.machineId)};
inline constexpr std::string_view machine_name  = ${JSON.stringify(spec.machineName)};
inline constexpr std::string_view machine_slug  = ${JSON.stringify(spec.slug)};

inline constexpr int input_offset  = ${spec.perceptualMapping.input?.offset ?? 0};
inline constexpr int input_length  = ${spec.inputDim};
inline constexpr int output_offset = ${spec.perceptualMapping.output?.offset ?? 0};
inline constexpr int output_length = ${spec.outputDim};

enum class StateId {
${stateEnum}
};

constexpr std::string_view state_id_string(StateId s) {
  switch (s) {
${stateStrings}
  }
  return "";
}

enum class SequenceId {
${seqEnum}
};

constexpr std::string_view sequence_id_string(SequenceId s) {
  switch (s) {
${seqStrings}
  }
  return "";
}

} // namespace reality::generated::${ns}
`;
}

function emitCppIndex(specs) {
  const includes = specs.map(s => `#include "reality/generated/${s.slug}.hpp"`).join('\n');
  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
#pragma once

${includes}
`;
}

// ── Scala emitter ────────────────────────────────────────────────────────────

function emitScala(spec) {
  const stateCases = spec.stateIds.length === 0
    ? '  // (no states)'
    : spec.stateIds.map(id => `  case object ${safeIdent(id)} extends StateId { val id = ${JSON.stringify(id)} }`).join('\n');
  const stateAll = spec.stateIds.map(id => `StateId.${safeIdent(id)}`).join(', ');
  const seqCases = spec.sequences.length === 0
    ? '  // (no sequences)'
    : spec.sequences.map(s => `  case object ${s.ident} extends SequenceId { val id = ${JSON.stringify(s.id)} }`).join('\n');
  const seqAll = spec.sequences.map(s => `SequenceId.${s.ident}`).join(', ');

  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
// Source: examples/machines/${spec.file}
package com.realityengine.generated.${snakeCase(spec.slug)}

object MachineSpec {
  val machineId    = ${JSON.stringify(spec.machineId)}
  val machineName  = ${JSON.stringify(spec.machineName)}
  val machineSlug  = ${JSON.stringify(spec.slug)}
  val inputOffset  = ${spec.perceptualMapping.input?.offset ?? 0}
  val inputLength  = ${spec.inputDim}
  val outputOffset = ${spec.perceptualMapping.output?.offset ?? 0}
  val outputLength = ${spec.outputDim}
}

sealed trait StateId { def id: String }
object StateId {
${stateCases}
  val all: List[StateId] = List(${stateAll})
}

sealed trait SequenceId { def id: String }
object SequenceId {
${seqCases}
  val all: List[SequenceId] = List(${seqAll})
}
`;
}

function emitScalaIndex(specs) {
  // Aggregator object exposing every generated machine spec by slug.
  const imports = specs.map(s =>
    `import com.realityengine.generated.${snakeCase(s.slug)}.{MachineSpec => ${s.pascalName}Spec}`
  ).join('\n');
  const entries = specs.map(s =>
    `    ${JSON.stringify(s.slug)} -> ${s.pascalName}Spec`
  ).join(',\n');
  return `// AUTOGENERATED by scripts/cesgen.mjs — do not edit by hand.
package com.realityengine.generated

${imports}

object Machines {
  val all: Map[String, AnyRef] = Map(
${entries}
  )
}
`;
}

// ── File I/O ─────────────────────────────────────────────────────────────────

function writeIfChanged(file, content, args) {
  if (args.check) {
    const existing = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
    if (existing !== content) {
      console.error(`[drift] ${path.relative(ROOT, file)} would change`);
      return false;
    }
    return true;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const existing = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (existing === content) return true;
  fs.writeFileSync(file, content);
  console.log(`[write] ${path.relative(ROOT, file)}`);
  return true;
}

// ── Main ─────────────────────────────────────────────────────────────────────

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.all && args.names.length === 0 && args.domains.length === 0) {
    printHelp();
    process.exit(2);
  }

  const files = listMachineFiles(args);
  if (files.length === 0) {
    console.error('no machines selected');
    process.exit(2);
  }

  const specs = files.map(f => normalize(path.join(MACHINES_DIR, f)));
  let ok = true;

  for (const spec of specs) {
    ok = writeIfChanged(path.join(args.outTs,    `${spec.slug}.ts`),  emitTs(spec),    args) && ok;
    ok = writeIfChanged(path.join(args.outCpp,   `${spec.slug}.hpp`), emitCpp(spec),   args) && ok;
    if (fs.existsSync(path.join(ROOT, 'scala'))) {
      ok = writeIfChanged(path.join(args.outScala, `${spec.slug}.scala`), emitScala(spec), args) && ok;
    }
  }

  // The registry index aggregates every generated module on disk, so it is
  // only rewritten when the caller asked for a full regen (--all) — otherwise
  // a partial run like `--names RSFlipFlop` would shrink the index and break
  // every other generated machine's exports.
  if (args.all) {
    const indexSpecs = listOnDiskSpecs(args.outTs);
    ok = writeIfChanged(path.join(args.outTs,    'index.ts'),    emitTsIndex(indexSpecs),    args) && ok;
    ok = writeIfChanged(path.join(args.outCpp,   'index.hpp'),   emitCppIndex(indexSpecs),   args) && ok;
    if (fs.existsSync(path.join(ROOT, 'scala'))) {
      ok = writeIfChanged(path.join(args.outScala, 'Machines.scala'), emitScalaIndex(indexSpecs), args) && ok;
    }
  }

  if (!ok) {
    console.error(args.check ? 'cesgen --check failed: generated files are out of date' : 'cesgen failed');
    process.exit(1);
  }
  console.log(`cesgen: ${specs.length} machine(s) ${args.check ? 'verified' : 'emitted'}`);
}

// Walk the TS output directory and rebuild the spec list from the source JSON
// of every existing per-machine file.  Used so the index always reflects the
// union of generated machines rather than the subset passed to this invocation.
function listOnDiskSpecs(outTs) {
  if (!fs.existsSync(outTs)) return [];
  const slugs = fs.readdirSync(outTs)
    .filter(f => f.endsWith('.ts') && f !== 'index.ts')
    .map(f => f.replace(/\.ts$/, ''))
    .sort();
  return slugs.map(slug => normalize(path.join(MACHINES_DIR, `${slug}.json`)));
}

main();
