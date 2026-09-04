// Pure helpers used by the "Create or update regression failure issue" step
// in .github/workflows/regression-tests.yml. Kept out of the inline
// github-script so the dedup logic can be unit tested with `node --test`
// (see scripts/tests/regression-issue-filer.test.mjs).
//
// The auto-filer used to key the issue title on the run id
// (`gha-<runId>-<attempt>`), which is unique on every run, so `existing` in
// the workflow's issue search never matched and every failing nightly opened
// a new issue (#229). Keying on the set of failing stage labels instead
// means a recurring failure updates one issue and a different failure opens
// a new one.

// Order matches the "## Results" section emitted by
// scripts/regression-report.py::summary_markdown, which is what the
// workflow step reads to build the notification.
const STAGE_SLUGS = {
  'Build': 'build',
  'Service readiness': 'service-readiness',
  'ISRE/OSRE trajectory parity': 'trajectory-parity',
  'Universal vectors (contract)': 'universal-vectors',
  'MQTT Yuma': 'mqtt',
  'MCP': 'mcp',
  'Arbiter conformance': 'arbiter',
  'OpenClaw': 'openclaw',
  'Deployment suite': 'deployment',
};

const OCCURRENCES_START = '<!-- regression-occurrences:start -->';
const OCCURRENCES_END = '<!-- regression-occurrences:end -->';
// Cap how many occurrence lines are kept in the body so a long-lived
// recurring failure issue does not grow without bound (GitHub caps issue
// body size). The true total count is preserved in the heading even once
// the list itself is trimmed.
const MAX_OCCURRENCES_SHOWN = 20;

function slugify(label) {
  return String(label)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

// Scans a `summary.md` produced by regression-report.py for result lines of
// the form "- <label>: `<status>`" and returns the sorted, deduplicated list
// of stage slugs whose status is `failed`.
function parseFailingStages(summaryMarkdown) {
  const text = String(summaryMarkdown || '');
  // Restrict to the "## Results" section so top-matter like "- Status:
  // `failed`" (the overall run status, not a stage) is not picked up.
  const startIdx = text.indexOf('## Results');
  let section = '';
  if (startIdx !== -1) {
    const rest = text.slice(startIdx + '## Results'.length);
    const nextHeadingIdx = rest.indexOf('\n## ');
    section = nextHeadingIdx === -1 ? rest : rest.slice(0, nextHeadingIdx);
  }
  const lineRe = /^-\s+(.+?):\s+`([a-z-]+)`\s*$/gm;
  const failing = new Set();
  let match;
  while ((match = lineRe.exec(section)) !== null) {
    const [, label, status] = match;
    if (status !== 'failed') continue;
    failing.add(STAGE_SLUGS[label] || slugify(label));
  }
  return Array.from(failing).sort();
}

// The failure signature is the stable, run-independent key used to
// deduplicate issues: two runs failing the same set of stages share a
// signature (and therefore an issue); a run failing a different set of
// stages is treated as a different failure and gets its own issue.
function failureSignature(stages) {
  const list = Array.isArray(stages) ? stages : [];
  return list.length ? list.slice().sort().join(', ') : 'unspecified';
}

function issueTitle(signature) {
  return `Regression failure: ${signature}`;
}

function extractOccurrenceLines(body) {
  if (!body) return [];
  const startIdx = body.indexOf(OCCURRENCES_START);
  const endIdx = body.indexOf(OCCURRENCES_END);
  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) return [];
  return body
    .slice(startIdx + OCCURRENCES_START.length, endIdx)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('- '));
}

// The heading records the true total, which keeps counting up even after
// the displayed occurrence list has been trimmed to MAX_OCCURRENCES_SHOWN.
function extractOccurrenceTotal(body) {
  if (!body) return 0;
  const match = body.match(/## Occurrences \((\d+)(?:\s|\))/);
  if (match) return Number(match[1]);
  return extractOccurrenceLines(body).length;
}

// Builds the full issue body. When `previousBody` is provided (the update
// path) any occurrences already recorded in it are carried forward, so the
// recurrence history (which runs, and how many) accumulates on the issue
// instead of being discarded on every `issues.update` the way a plain
// body replacement would.
function renderIssueBody({ signature, runId, runUrl, timestamp, summary, previousBody }) {
  const priorOccurrences = extractOccurrenceLines(previousBody);
  const totalCount = extractOccurrenceTotal(previousBody) + 1;
  const newOccurrence = `- \`${runId}\` — ${runUrl} — ${timestamp}`;
  const occurrences = [newOccurrence, ...priorOccurrences].slice(0, MAX_OCCURRENCES_SHOWN);
  const heading = occurrences.length < totalCount
    ? `## Occurrences (${totalCount} total, showing latest ${occurrences.length})`
    : `## Occurrences (${totalCount})`;
  const lines = [
    `Failure signature: \`${signature}\``,
    '',
    OCCURRENCES_START,
    heading,
    '',
    ...occurrences,
    OCCURRENCES_END,
    '',
    `## Latest summary (\`${runId}\`)`,
    '',
    `Actions run: ${runUrl}`,
    '',
    '```markdown',
    summary,
    '```',
    '',
  ];
  return lines.join('\n');
}

export {
  STAGE_SLUGS,
  slugify,
  parseFailingStages,
  failureSignature,
  issueTitle,
  extractOccurrenceLines,
  extractOccurrenceTotal,
  renderIssueBody,
};
