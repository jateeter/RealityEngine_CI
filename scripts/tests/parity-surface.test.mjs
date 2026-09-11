/**
 * The declared parity surface, tested against the payloads that produced #321.
 *
 * The fixtures are the real bodies captured by the failing hosted run
 * (E2E Tests 34249753784, job 102151603962), trimmed to the fields under test.
 * A rule that classified those two responses correctly by accident — because a
 * hand-written fixture happened to be shaped conveniently — would be worth
 * nothing, so the shapes here are the ones the runtimes actually emitted.
 *
 * Run: node --test scripts/tests/parity-surface.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';

import {
  compareSurface,
  isDeclared,
  project,
  ruleFor,
  shapeOnlyKeys,
  unanimousSilence,
  DEFAULT_RULE,
} from '../../e2e/lib/parity-surface.ts';

/** A capture as the spec builds one, from a JSON literal. */
function capture(value, status = 200) {
  const body = Buffer.from(typeof value === 'string' ? value : JSON.stringify(value), 'utf8');
  return { status, body, sha256: crypto.createHash('sha256').update(body).digest('hex') };
}

function agreeing(value) {
  return { lsp: capture(value), scala: capture(value), cpp: capture(value) };
}

test('control-plane routes are observed, never compared', () => {
  for (const signature of [
    'GET /api/engines',
    'GET /api/engines/lsp-1/health',
    'POST /api/engines/active',
  ]) {
    assert.equal(ruleFor(signature).compare, 'observed', signature);
  }

  // Observed means observed even when the payloads plainly differ: these vary
  // by selected instance by design.
  const finding = compareSurface('GET /api/engines', {
    lsp: capture({ active: 'lsp-1' }),
    scala: capture({ active: 'scala-1' }),
    cpp: capture({ active: 'cpp-1' }),
  });
  assert.equal(finding, null);
});

test('an undeclared surface is byte-compared, not waved through', () => {
  const signature = 'GET /api/some/route/nobody/classified';
  assert.equal(isDeclared(signature), false);
  assert.equal(ruleFor(signature), DEFAULT_RULE);
  assert.equal(ruleFor(signature).compare, 'bytes');

  assert.equal(compareSurface(signature, agreeing({ a: 1 })), null);

  const finding = compareSurface(signature, {
    lsp: capture({ a: 1 }),
    scala: capture({ a: 2 }),
    cpp: capture({ a: 1 }),
  });
  assert.ok(finding, 'a differing undeclared surface must still fail');
  assert.equal(finding.undeclared, true);
});

test('bytes surfaces catch presentation differences, not only value ones', () => {
  // Same content, different key order. Uniform presentation is part of the API,
  // so this is a divergence and must be reported as one.
  const finding = compareSurface('GET /api/pe/sources', {
    lsp: capture('{"a":1,"b":2}'),
    scala: capture('{"b":2,"a":1}'),
    cpp: capture('{"a":1,"b":2}'),
  });
  assert.ok(finding);
  assert.equal(finding.compare, 'bytes');
});

test('#321: bootstrap-from-machines agrees once the history-dependent counters are dropped', () => {
  const signature = 'POST /api/pe/sources/bootstrap-from-machines';
  assert.equal(ruleFor(signature).compare, 'projection');

  // Verbatim from the failed run: lsp created what cpp and scala skipped,
  // because lsp's reset discards its sources and cpp's keeps them (#163).
  const lsp = capture({ created: 17, errors: [], machinesSeen: 17, skipped: 0, success: true });
  const settled = capture({ created: 0, errors: [], machinesSeen: 17, skipped: 17, success: true });

  assert.equal(compareSurface(signature, { lsp, scala: settled, cpp: settled }), null);
});

test('the bootstrap allowance drops the counters and nothing else', () => {
  const signature = 'POST /api/pe/sources/bootstrap-from-machines';
  const rule = ruleFor(signature);

  assert.deepEqual(rule.historyDependent, ['created', 'skipped']);
  assert.equal(
    project(capture({ created: 1, machinesSeen: 17, skipped: 0, success: true }).body, rule).text,
    JSON.stringify({ machinesSeen: 17, success: true }),
  );

  // A real disagreement on the surface those counters sit beside still fails:
  // the allowance is two named keys, not the response.
  const finding = compareSurface(signature, {
    lsp: capture({ created: 17, errors: [], machinesSeen: 17, skipped: 0, success: true }),
    scala: capture({ created: 0, errors: [], machinesSeen: 16, skipped: 16, success: true }),
    cpp: capture({ created: 0, errors: [], machinesSeen: 17, skipped: 17, success: true }),
  });
  assert.ok(finding, 'a machinesSeen disagreement must survive the allowance');
  assert.deepEqual(finding.allowances, ['created', 'skipped']);
});

test('#321: /api/machines fails on a dropped initialEventIds, and names the key', () => {
  const signature = 'GET /api/machines';
  const rule = ruleFor(signature);

  // Not an allowance. The Scala PE reads this key off this route for
  // provenance(), so filtering it would hide a gap that has a consumer.
  // CPP#91 and LSP#105 closed the original divergence; this fixture is the
  // regression guard, holding the #321 payloads so a rule change that would
  // re-hide the key fails here.
  assert.equal(rule.boundaryFiltered, undefined);
  assert.equal(rule.historyDependent, undefined);

  const summary = { machines: [{ name: 'Arbitration Reader', sequences: [{ id: 'arb-c', name: 'C' }] }] };
  const withIds = {
    machines: [
      {
        name: 'Arbitration Reader',
        sequences: [{ id: 'arb-c', name: 'C', initialEventIds: ['arb-c-event-zero'] }],
      },
    ],
  };

  const finding = compareSurface(signature, {
    lsp: capture(summary),
    scala: capture(withIds),
    cpp: capture(summary),
  });
  assert.ok(finding, 'a runtime dropping the key must fail');
  assert.deepEqual(finding.shapeOnly, {
    scala: ['machines[].sequences[].initialEventIds'],
  });

  // And it passes now that cpp and lsp emit the key, which is the live state.
  assert.equal(compareSurface(signature, agreeing(withIds)), null);
});

test('shape-only keys are found below the top level', () => {
  // The bug this guards is #281: a top-level-only walk reported nothing while
  // the divergent key sat one level down.
  assert.deepEqual(
    shapeOnlyKeys({
      lsp: { step: { mergeBatch: [{ values: [1] }] } },
      scala: { step: { mergeBatch: [{ values: [1], valuesPacked: 'AA==' }] } },
    }),
    { scala: ['step.mergeBatch[].valuesPacked'] },
  );
});

test('a projection rule on a non-JSON body falls back to bytes', () => {
  const signature = 'GET /api/machines';
  const finding = compareSurface(signature, {
    lsp: capture('not json'),
    scala: capture('not json either'),
    cpp: capture('not json'),
  });
  assert.ok(finding, 'an unparseable body must compare as bytes, not as nothing');
});

// ---------------------------------------------------------------------------
// Quorum is 3-of-3 — docs/QUORUM_CONTRACT.md
// ---------------------------------------------------------------------------

test('a 2-1 split is a finding, not a majority with an outlier', () => {
  // The #349 shape: two runtimes agree, one does not. Under a majority rule
  // this reads as consensus with a deviant. It must read as a disagreement,
  // and the finding must carry all three emissions — not two measured against
  // a designated reference.
  const finding = compareSurface('GET /api/machine-graph', {
    lsp: capture({ edges: ['a->b', 'b->c'] }),
    scala: capture({ edges: ['a->b', 'b->c'] }),
    cpp: capture({ edges: ['b->c', 'a->b'] }),
  });

  assert.ok(finding, 'a 2-1 split must produce a finding');
  // Every runtime is represented. Nothing in the record names a reference,
  // a baseline, a majority or a divergent party.
  for (const runtime of ['lsp', 'scala', 'cpp']) {
    assert.ok(finding.sha256[runtime], `${runtime} must be in the record`);
    assert.ok(finding.byteLength[runtime] > 0, `${runtime} byte length`);
  }
  const serialized = JSON.stringify(finding);
  for (const banned of ['baseline', 'reference', 'majority', 'divergent']) {
    assert.ok(
      !serialized.toLowerCase().includes(banned),
      `the finding must not frame the split in terms of "${banned}"`,
    );
  }
});

test('a 2-1 split is reported identically whichever runtime is the odd one out', () => {
  // Symmetry is the property, and it is the one a designated baseline breaks.
  const odd = value => JSON.stringify(compareSurface('GET /api/machine-graph', value)?.status);
  const a = odd({ lsp: capture({ e: 1 }), scala: capture({ e: 1 }), cpp: capture({ e: 2 }) });
  const b = odd({ lsp: capture({ e: 2 }), scala: capture({ e: 1 }), cpp: capture({ e: 1 }) });
  assert.equal(a, b, 'the verdict must not depend on which runtime dissents');
});

test('unanimous refusal is a reportable result, not a quiet pass', () => {
  const captures = {
    lsp: capture({ error: 'not found' }, 404),
    scala: capture({ error: 'not found' }, 404),
    cpp: capture({ error: 'not found' }, 404),
  };

  // The comparison is right to find nothing: they agree.
  assert.equal(compareSurface('GET /api/scxml/export', captures), null);

  // But the agreement means "nobody implements this shape", and that is the
  // information worth keeping (QUORUM_CONTRACT §3).
  const silence = unanimousSilence('GET /api/scxml/export', captures);
  assert.ok(silence, 'unanimous non-2xx must be surfaced');
  assert.equal(silence.status, 404);
  assert.equal(silence.signature, 'GET /api/scxml/export');
});

test('unanimous success is not silence, and a split refusal is not unanimous', () => {
  assert.equal(unanimousSilence('GET /api/machines', agreeing({ machines: [] })), null);
  assert.equal(
    unanimousSilence('GET /api/machines', {
      lsp: capture({}, 404),
      scala: capture({}, 404),
      cpp: capture({}, 200),
    }),
    null,
    'a split status is a disagreement for compareSurface to report, not silence',
  );
});
