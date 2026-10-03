// e2e/lib/unscheduled.ts: what a cross-engine byte comparison sets aside (#518).
import test from 'node:test';
import assert from 'node:assert/strict';

import { isSlotName, slotRegionsOf, withoutLiveTimes, withoutMintedIds, withoutNamed, withoutSlots } from '../../e2e/lib/unscheduled.ts';

const U1 = '0f4ef7ec-8dde-4922-b5ae-7c75f1b14861';
const U2 = '37de874f-f960-4992-898c-63279e4a89e1';

test('minted ids of every kind become one token per kind', () => {
  assert.equal(withoutMintedIds(`{"id":"machine-${U1}"}`), '{"id":"minted:machine"}');
  assert.equal(withoutMintedIds(`"source-${U1}" "source-${U2}"`), '"minted:source" "minted:source"');
  assert.equal(withoutMintedIds(`"test-machine-${U1}"`), '"minted:test-machine"');
  assert.equal(withoutMintedIds(`"${U2}"`), '"minted:id"');
});

test('corpus ids are left alone', () => {
  const corpus = '{"id":"machine-arbitrationreader","source":"test-machine-aicapacitythrottler"}';
  assert.equal(withoutMintedIds(corpus), corpus);
});

test('a slot is a source with a slot segment', () => {
  assert.ok(isSlotName('localai/health/slot/pulse'));
  assert.ok(isSlotName('slot/x'));
  assert.ok(!isSlotName('localai/health/rollup'));
  assert.ok(!isSlotName('localai/slots'));
});

const sources = {
  sources: [
    { name: 'localai/health/rollup', region: { offset: 7574, length: 4 } },
    { name: 'localai/health/slot/pulse', region: { offset: 7600, length: 1 } },
    { name: 'localai/health/slot/sleep', region: { offset: 7601, length: 1 } },
  ],
};

test('slot regions are collected from any depth', () => {
  assert.deepEqual(slotRegionsOf(sources), [[7600, 1], [7601, 1]]);
});

test('slot sources and entries over slot regions are dropped; the rest stays', () => {
  const slots = slotRegionsOf(sources);
  const state = {
    sources: sources.sources,
    lastPush: { activeRegions: [{ offset: 7574, length: 4 }, { offset: 7600, length: 1 }] },
  };
  assert.deepEqual(withoutSlots(state, slots), {
    sources: [{ name: 'localai/health/rollup', region: { offset: 7574, length: 4 } }],
    lastPush: { activeRegions: [{ offset: 7574, length: 4 }] },
  });
});

test('slot cells of a perceptual vector are zeroed, its length kept', () => {
  const vector = Array.from({ length: 7610 }, () => 1);
  const out = withoutSlots({ assembledVector: vector }, [[7600, 2]]);
  assert.equal(out.assembledVector.length, 7610);
  assert.deepEqual(out.assembledVector.slice(7598, 7603), [1, 1, 0, 0, 1]);
});

test('with no slots nothing changes', () => {
  const v = { a: [1, 2, 3], b: [{ name: 'x', region: { offset: 0, length: 1 } }] };
  assert.deepEqual(withoutSlots(v, []), v);
});

test('live-source wall-clock times are set aside; never-updated stays null', () => {
  const a = { sources: [{ name: 's', lastUpdated: 1791035771089 }, { name: 't', lastUpdated: null }] };
  const b = { sources: [{ name: 's', lastUpdated: 1791035771047 }, { name: 't', lastUpdated: null }] };
  assert.deepEqual(withoutLiveTimes(a), withoutLiveTimes(b));
  assert.equal(withoutLiveTimes(a).sources[1].lastUpdated, null);
  const c = { sources: [{ name: 't', lastUpdated: 1 }] };
  assert.notDeepEqual(withoutLiveTimes({ sources: [{ name: 't', lastUpdated: null }] }), withoutLiveTimes(c));
});

test('entries an integration removed on its own schedule are set aside by name', () => {
  const v = { sources: [{ name: 'keep' }, { name: 'localai/personal_health_baseline / 5 sequences' }] };
  assert.deepEqual(withoutNamed(v, new Set(['localai/personal_health_baseline / 5 sequences'])), { sources: [{ name: 'keep' }] });
  assert.deepEqual(withoutNamed(v, new Set()), v);
});
