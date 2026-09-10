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
