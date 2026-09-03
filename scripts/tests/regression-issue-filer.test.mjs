import test from 'node:test';
import assert from 'node:assert/strict';

import {
  extractOccurrenceLines,
  failureSignature,
  issueTitle,
  parseFailingStages,
  renderIssueBody,
} from '../lib/regression-issue-filer.mjs';

const SAMPLE_SUMMARY = [
  '# Regression Test Run gha-1-1',
  '',
  '- Status: `failed`',
  '',
  '## Results',
  '',
  '- Build: `passed`',
  '- Service readiness: `passed`',
  '- ISRE/OSRE trajectory parity: `failed`',
  '  - Failures: 2',
  '- Universal vectors (contract): `failed`',
  '  - Failures: 5',
  '- MQTT Yuma: `passed`',
  '- MCP: `passed`',
  '- Arbiter conformance: `not-run`',
  '- OpenClaw: `passed`',
  '- Deployment suite: `not-run`',
  '',
].join('\n');

test('parseFailingStages extracts only failed stages as stable slugs', () => {
  assert.deepEqual(
    parseFailingStages(SAMPLE_SUMMARY),
    ['trajectory-parity', 'universal-vectors']
  );
});

test('parseFailingStages returns an empty list when nothing failed', () => {
  const passing = SAMPLE_SUMMARY
    .replace('- ISRE/OSRE trajectory parity: `failed`', '- ISRE/OSRE trajectory parity: `passed`')
    .replace('- Universal vectors (contract): `failed`', '- Universal vectors (contract): `passed`');
  assert.deepEqual(parseFailingStages(passing), []);
});

test('failureSignature is stable regardless of input order and falls back when empty', () => {
  assert.equal(failureSignature(['universal-vectors', 'trajectory-parity']), 'trajectory-parity, universal-vectors');
  assert.equal(failureSignature(['trajectory-parity', 'universal-vectors']), 'trajectory-parity, universal-vectors');
  assert.equal(failureSignature([]), 'unspecified');
});

test('issueTitle keys the title on the failure signature, not a run id', () => {
  assert.equal(
    issueTitle(failureSignature(parseFailingStages(SAMPLE_SUMMARY))),
    'Regression failure: trajectory-parity, universal-vectors'
  );
});

test('two runs with the same failing stages produce the same title (dedup works)', () => {
  const firstRunSummary = SAMPLE_SUMMARY;
  const secondRunSummary = SAMPLE_SUMMARY.replace('gha-1-1', 'gha-2-1');
  const firstTitle = issueTitle(failureSignature(parseFailingStages(firstRunSummary)));
  const secondTitle = issueTitle(failureSignature(parseFailingStages(secondRunSummary)));
  assert.equal(firstTitle, secondTitle);
});

test('a run with a different failing stage set produces a different title', () => {
  const differentFailure = SAMPLE_SUMMARY
    .replace('- Universal vectors (contract): `failed`', '- Universal vectors (contract): `passed`')
    .replace('- MCP: `passed`', '- MCP: `failed`');
  const originalTitle = issueTitle(failureSignature(parseFailingStages(SAMPLE_SUMMARY)));
  const newTitle = issueTitle(failureSignature(parseFailingStages(differentFailure)));
  assert.notEqual(originalTitle, newTitle);
  assert.equal(newTitle, 'Regression failure: mcp, trajectory-parity');
});

test('renderIssueBody starts a single occurrence when there is no previous body', () => {
  const body = renderIssueBody({
    signature: 'trajectory-parity, universal-vectors',
    runId: 'gha-1-1',
    runUrl: 'https://example.test/runs/1',
    timestamp: '2026-09-03T00:00:00.000Z',
    summary: 'summary contents',
  });
  assert.match(body, /## Occurrences \(1\)/);
  assert.match(body, /- `gha-1-1` — https:\/\/example\.test\/runs\/1 — 2026-09-03T00:00:00\.000Z/);
  assert.equal(extractOccurrenceLines(body).length, 1);
});

test('renderIssueBody accumulates occurrences across updates instead of discarding history', () => {
  const first = renderIssueBody({
    signature: 'trajectory-parity, universal-vectors',
    runId: 'gha-1-1',
    runUrl: 'https://example.test/runs/1',
    timestamp: '2026-09-03T00:00:00.000Z',
    summary: 'first summary',
  });
  const second = renderIssueBody({
    signature: 'trajectory-parity, universal-vectors',
    runId: 'gha-2-1',
    runUrl: 'https://example.test/runs/2',
    timestamp: '2026-09-04T00:00:00.000Z',
    summary: 'second summary',
    previousBody: first,
  });
  assert.match(second, /## Occurrences \(2\)/);
  const occurrences = extractOccurrenceLines(second);
  assert.equal(occurrences.length, 2);
  assert.match(occurrences[0], /gha-2-1/);
  assert.match(occurrences[1], /gha-1-1/);
  assert.match(second, /second summary/);
  assert.doesNotMatch(second, /first summary/);

  const third = renderIssueBody({
    signature: 'trajectory-parity, universal-vectors',
    runId: 'gha-3-1',
    runUrl: 'https://example.test/runs/3',
    timestamp: '2026-09-05T00:00:00.000Z',
    summary: 'third summary',
    previousBody: second,
  });
  assert.match(third, /## Occurrences \(3\)/);
  assert.equal(extractOccurrenceLines(third).length, 3);
});
