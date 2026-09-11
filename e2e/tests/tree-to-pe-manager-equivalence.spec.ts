import { test, expect, Page, APIRequestContext, APIResponse, TestInfo } from '@playwright/test';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import {
  compareSurface,
  describeFinding,
  unanimousSilence,
  isDeclared,
  ruleFor,
  type Runtime,
  type SurfaceCapture,
  type SurfaceFinding,
} from '../lib/parity-surface';

interface EngineTarget {
  id: string;
  runtime: Runtime;
}

interface CapturedResponse {
  engine: Runtime;
  method: string;
  url: string;
  path: string;
  status: number;
  ok: boolean;
  bodyBase64: string;
  sha256: string;
  byteLength: number;
}

interface EngineRun {
  engine: EngineTarget;
  captures: CapturedResponse[];
  sourceCountText: string;
  activeCountText: string;
  treeRowCount: number;
  treeLoadedOk: boolean;
  disableSourceCount: number;
  enableSourceCount: number;
  sourcePresentationOk: boolean;
  errors: string[];
}

const ENGINES: EngineTarget[] = [
  { id: 'lsp-1', runtime: 'lsp' },
  { id: 'scala-1', runtime: 'scala' },
  { id: 'cpp-1', runtime: 'cpp' },
];

const NO_CACHE_HEADERS = {
  'Cache-Control': 'no-cache, no-store, max-age=0, must-revalidate',
  Pragma: 'no-cache',
} as const;

test.describe.configure({ mode: 'serial' });

function sha256(bytes: Buffer): string {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function safeFilePart(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 120) || 'root';
}

function apiPath(url: string): string | null {
  const parsed = new URL(url);
  if (!parsed.pathname.startsWith('/api/')) return null;
  return `${parsed.pathname}${parsed.search}`;
}

function capturedResponse(engine: Runtime, method: string, url: string, status: number, ok: boolean, body: Buffer): CapturedResponse | null {
  const path = apiPath(url);
  if (!path) return null;
  return {
    engine,
    method,
    url,
    path,
    status,
    ok,
    bodyBase64: body.toString('base64'),
    sha256: sha256(body),
    byteLength: body.length,
  };
}

/**
 * Whether a signature is compared at all.
 *
 * The Manager control-plane exclusions that used to live here as three inline
 * path checks are now `observed` rules in `e2e/lib/parity-surface.ts`, next to
 * every other statement about what agreement means for a surface. One table,
 * one place to read, one place to change.
 */
function comparable(method: string, path: string): boolean {
  return ruleFor(`${method} ${path}`).compare !== 'observed';
}

async function waitForTreeRows(page: Page): Promise<{ rowCount: number; loadedOk: boolean }> {
  await page.locator('.rep-body').waitFor({ state: 'visible', timeout: 30_000 });
  try {
    await expect
      .poll(async () => page.locator('.rep-row').count(), {
        timeout: 45_000,
        intervals: [250, 500, 1_000],
      })
      .toBeGreaterThan(0);
    const rowCount = await page.locator('.rep-row').count();
    return { rowCount, loadedOk: true };
  } catch {
    const rowCount = await page.locator('.rep-row').count();
    return { rowCount, loadedOk: false };
  }
}

async function captureRequestResponse(engine: EngineTarget, method: string, response: APIResponse): Promise<CapturedResponse> {
  const body = await response.body();
  const capture = capturedResponse(engine.runtime, method, response.url(), response.status(), response.ok(), body);
  expect(capture, `${method} ${response.url()} should be an API response`).toBeTruthy();
  return capture!;
}

async function switchEngine(request: APIRequestContext, engine: EngineTarget): Promise<CapturedResponse> {
  const res = await request.post('/api/engines/active', {
    data: { id: engine.id },
    headers: { 'Content-Type': 'application/json', ...NO_CACHE_HEADERS },
  });
  const capture = await captureRequestResponse(engine, 'POST', res);
  expect(res.ok(), `engine switch to ${engine.id} failed: ${res.status()}`).toBeTruthy();
  return capture;
}

async function resetPE(request: APIRequestContext, engine: EngineTarget): Promise<CapturedResponse> {
  const res = await request.post('/api/pe/reset', {
    data: {},
    headers: { 'Content-Type': 'application/json', ...NO_CACHE_HEADERS },
  });
  const capture = await captureRequestResponse(engine, 'POST', res);
  expect(res.ok(), `PE reset failed: ${res.status()}`).toBeTruthy();
  return capture;
}

async function installNoCacheFetch(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const originalFetch = window.fetch.bind(window);
    window.fetch = (input: RequestInfo | URL, init: RequestInit = {}) => {
      const headers = new Headers(init.headers || {});
      headers.set('Cache-Control', 'no-cache, no-store, max-age=0, must-revalidate');
      headers.set('Pragma', 'no-cache');
      return originalFetch(input, { ...init, headers });
    };
  });
}

// The PE nav button renders "Perception" beside a ◎ icon span, not "PE Manager".
// Its title is the stable handle. This spec self-skipped for so long — no hosted
// job spawned cpp+lsp+scala — that it accumulated the same UI drift already
// fixed in visualizer-ui.spec.ts (#82).
async function loadCompleteTree(page: Page): Promise<{ rowCount: number; loadedOk: boolean }> {
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('.rep-title')).toContainText(/Reality\s*Engine/, { timeout: 30_000 });
  await expect(page.getByTitle('Open Perception Engine management')).toBeVisible({ timeout: 10_000 });
  return waitForTreeRows(page);
}

async function openPEManager(page: Page): Promise<void> {
  await page.getByTitle('Open Perception Engine management').click();
  await expect(page.getByText('PERCEPTION ENGINE', { exact: true })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText(/Assembled Vector - \d+ elements|Assembled Vector . \d+ elements/)).toBeVisible({ timeout: 20_000 });
}

async function importSources(page: Page): Promise<void> {
  const importButton = page.getByTitle('Import test sources from machine inputSequences');
  await expect(importButton).toBeVisible({ timeout: 10_000 });
  await importButton.click();
  await expect(importButton).toContainText('Import', { timeout: 60_000 });
}

async function forceAllSourcesOn(page: Page): Promise<void> {
  const toggleAll = page.getByRole('button', { name: /^(All Off|Mixed)$/ });
  if (await toggleAll.count() && await toggleAll.first().isEnabled()) {
    await toggleAll.first().click();
  }
  await expect(page.getByTitle('Enable source')).toHaveCount(0, { timeout: 15_000 });
}

async function returnToTree(page: Page): Promise<{ rowCount: number; loadedOk: boolean }> {
  await page.getByTitle('Back to Reality Engine').click();
  await expect(page.getByTitle('Open Perception Engine management')).toBeVisible({ timeout: 30_000 });
  return waitForTreeRows(page);
}

async function captureEngineFlow(page: Page, engine: EngineTarget): Promise<EngineRun> {
  const captures: CapturedResponse[] = [];
  const errors: string[] = [];

  const listener = async (response: any) => {
    let body: Buffer;
    try {
      body = await response.body();
    } catch {
      body = Buffer.from('');
    }

    const capture = capturedResponse(
      engine.runtime,
      response.request().method(),
      response.url(),
      response.status(),
      response.ok(),
      body
    );
    if (capture) captures.push(capture);
  };

  page.on('response', listener);
  try {
    const tree = await loadCompleteTree(page);
    if (!tree.loadedOk) {
      errors.push('tree visualization loaded with zero machine/domain/CES rows');
    }
    await openPEManager(page);
    await importSources(page);

    let sourcePresentationOk = true;
    try {
      // `\\(` — the backslash must survive the string literal to reach the regex.
      // Written as '\\(' in a single-quoted TS string, JS drops the backslash and
      // Playwright compiles /^Sources ([1-9]/ — an unterminated group — which
      // throws SyntaxError at match time rather than failing an assertion. The
      // header of this file warns about the same class of bug in the spec it
      // replaced; this is it in the opposite direction (under-escaped).
      await expect(page.locator('text=/^Sources \\([1-9]/').first()).toBeVisible({ timeout: 15_000 });
      await forceAllSourcesOn(page);
      await expect(page.getByTitle('Disable source').first()).toBeVisible({ timeout: 15_000 });
    } catch (error: any) {
      sourcePresentationOk = false;
      errors.push(`source presentation failed: ${error?.message ?? String(error)}`);
    }

    const sourceCountText = await page.locator('text=/^Sources \\(/').first().innerText().catch(() => 'Sources (?)');
    const activeCountText = await page.locator('text=/\d+\/\d+ active/').first().innerText().catch(() => '?/? active');
    const disableSourceCount = await page.getByTitle('Disable source').count();
    const enableSourceCount = await page.getByTitle('Enable source').count();

    const returnedTree = await returnToTree(page);
    if (!returnedTree.loadedOk) {
      errors.push('returned tree view had zero machine/domain/CES rows');
    }

    return {
      engine,
      captures,
      sourceCountText,
      activeCountText,
      treeRowCount: Math.max(tree.rowCount, returnedTree.rowCount),
      treeLoadedOk: tree.loadedOk && returnedTree.loadedOk,
      disableSourceCount,
      enableSourceCount,
      sourcePresentationOk,
      errors,
    };
  } finally {
    page.off('response', listener);
  }
}

function latestComparableBySignature(run: EngineRun): Map<string, CapturedResponse> {
  const out = new Map<string, CapturedResponse>();
  for (const capture of run.captures) {
    if (!comparable(capture.method, capture.path)) continue;
    out.set(`${capture.method} ${capture.path}`, capture);
  }
  return out;
}

function asSurfaceCapture(capture: CapturedResponse): SurfaceCapture {
  return {
    status: capture.status,
    body: Buffer.from(capture.bodyBase64, 'base64'),
    sha256: capture.sha256,
  };
}

/**
 * Compare every signature all three runtimes produced, each under its declared
 * rule.
 *
 * Only the intersection is compared, as before: a signature one runtime never
 * issued is not evidence about the others. What changed is that agreement is
 * now defined per surface in `e2e/lib/parity-surface.ts` rather than assumed to
 * be byte identity everywhere — which asserted more than SURFACE_SPEC.md grants
 * and reported two non-divergences as failures on #321.
 */
function compareRuns(runs: EngineRun[]) {
  const byRuntime = Object.fromEntries(
    runs.map(run => [run.engine.runtime, latestComparableBySignature(run)])
  ) as Record<Runtime, Map<string, CapturedResponse>>;

  const runtimes: Runtime[] = ['lsp', 'scala', 'cpp'];
  const allSignatures = [...new Set(runtimes.flatMap(r => [...byRuntime[r].keys()]))].sort();
  const signatures = allSignatures.filter(sig => runtimes.every(r => byRuntime[r].has(sig)));

  // Quorum is 3-of-3, so a signature only some runtimes answered cannot be
  // compared — but it is not nothing, and dropping it silently is how an
  // absent runtime becomes indistinguishable from a conforming one
  // (`docs/QUORUM_CONTRACT.md` §2). Enumerated, with who held it, rather than
  // filtered away. These are browser-observed captures, so an asymmetry here
  // usually means the UI took a different path per engine — which is itself
  // the thing worth seeing.
  const signaturesOutsideQuorum = allSignatures
    .filter(sig => !signatures.includes(sig))
    .map(sig => ({
      signature: sig,
      answeredBy: runtimes.filter(r => byRuntime[r].has(sig)),
      absentFrom: runtimes.filter(r => !byRuntime[r].has(sig)),
    }));

  const findings: SurfaceFinding[] = [];
  const noRuntimeImplements: ReturnType<typeof unanimousSilence>[] = [];
  for (const signature of signatures) {
    const captures = {
      lsp: asSurfaceCapture(byRuntime.lsp.get(signature)!),
      scala: asSurfaceCapture(byRuntime.scala.get(signature)!),
      cpp: asSurfaceCapture(byRuntime.cpp.get(signature)!),
    };
    // Checked before the comparison: all three refusing identically agrees,
    // and `compareSurface` will say so by returning null. What that agreement
    // *means* — nobody implements this shape — is the more useful reading and
    // has to be recorded separately or it is lost in the pass (§3).
    const silence = unanimousSilence(signature, captures);
    if (silence) noRuntimeImplements.push(silence);
    const finding = compareSurface(signature, captures);
    if (finding) findings.push(finding);
  }

  return {
    quorum: { rule: '3-of-3', runtimes, contract: 'docs/QUORUM_CONTRACT.md' },
    comparableSignatures: signatures,
    signaturesOutsideQuorum,
    // Unanimous refusals. Not a failure of any engine; a statement that the
    // shape is unimplemented everywhere (§3).
    noRuntimeImplements,
    // The rule each compared signature resolved to, recorded whether it agreed
    // or not. A gate that only reports its failures cannot be audited for what
    // it stopped checking.
    surfaceRules: signatures.map(signature => {
      const rule = ruleFor(signature);
      return {
        signature,
        compare: rule.compare,
        declared: isDeclared(signature),
        why: rule.why,
        allowances: [...(rule.boundaryFiltered ?? []), ...(rule.historyDependent ?? [])],
      };
    }),
    findings,
    skippedManagerControlCalls: runs.map(run => ({
      runtime: run.engine.runtime,
      count: run.captures.filter(c => !comparable(c.method, c.path)).length,
    })),
  };
}

async function writeCaptureBodies(runs: EngineRun[], testInfo: TestInfo) {
  const outputDir = testInfo.outputPath('api-response-bodies');
  await fs.mkdir(outputDir, { recursive: true });

  const manifest = [];
  let index = 0;
  for (const run of runs) {
    for (const capture of run.captures) {
      const filename = [
        String(index).padStart(4, '0'),
        capture.engine,
        capture.method,
        safeFilePart(capture.path),
        capture.sha256.slice(0, 12),
      ].join('-') + '.body';
      const bodyPath = path.join(outputDir, filename);
      await fs.writeFile(bodyPath, Buffer.from(capture.bodyBase64, 'base64'));
      manifest.push({
        index,
        engine: capture.engine,
        method: capture.method,
        path: capture.path,
        url: capture.url,
        status: capture.status,
        ok: capture.ok,
        byteLength: capture.byteLength,
        sha256: capture.sha256,
        comparable: comparable(capture.method, capture.path),
        bodyFile: path.relative(testInfo.outputDir, bodyPath),
      });
      index += 1;
    }
  }

  return manifest;
}

/**
 * Engine ids this comparison needs. Byte equivalence is only meaningful across
 * distinct runtimes, so all three must be present — a `--engines=scala:2`
 * universe cannot substitute.
 */
async function missingEngines(request: APIRequestContext): Promise<string[]> {
  try {
    const res = await request.get('/api/engines', { headers: NO_CACHE_HEADERS });
    if (!res.ok()) return ENGINES.map(e => e.id);
    const body = await res.json();
    const list: Array<{ id?: string }> = Array.isArray(body) ? body : (body.engines ?? body.instances ?? []);
    const present = new Set(list.map(e => e?.id).filter(Boolean));
    return ENGINES.filter(e => !present.has(e.id)).map(e => e.id);
  } catch {
    return ENGINES.map(e => e.id);
  }
}

test('tree view to PE Manager verifies all sources on and compares captured API response bytes across all engines', async ({ page, request }, testInfo: TestInfo) => {
  test.setTimeout(300_000);
  await installNoCacheFetch(page);

  // Skip rather than 404 on a universe that never spawned these runtimes.
  // Needs `startUniverse.sh --engines=cpp:1,lsp:1,scala:1`; no hosted job
  // provides a tri-runtime universe today (see #79).
  const absent = await missingEngines(request);
  test.skip(
    absent.length > 0,
    `registry is missing ${absent.join(', ')} — byte equivalence needs a tri-runtime ` +
      'universe (--engines=cpp:1,lsp:1,scala:1)',
  );

  const runs: EngineRun[] = [];

  for (const engine of ENGINES) {
    const setupCaptures = [
      await switchEngine(request, engine),
      await resetPE(request, engine),
    ];
    const run = await captureEngineFlow(page, engine);
    run.captures.unshift(...setupCaptures);
    runs.push(run);
  }

  const comparison = compareRuns(runs);
  const captureManifest = await writeCaptureBodies(runs, testInfo);
  const report = {
    generatedAt: new Date().toISOString(),
    engines: runs.map(run => ({
      id: run.engine.id,
      runtime: run.engine.runtime,
      treeRowCount: run.treeRowCount,
      treeLoadedOk: run.treeLoadedOk,
      sourceCountText: run.sourceCountText,
      activeCountText: run.activeCountText,
      disableSourceCount: run.disableSourceCount,
      enableSourceCount: run.enableSourceCount,
      sourcePresentationOk: run.sourcePresentationOk,
      errors: run.errors,
      capturedApiResponses: run.captures.length,
    })),
    comparison: {
      quorum: comparison.quorum,
      comparableResponseCount: comparison.comparableSignatures.length,
      comparableSignatures: comparison.comparableSignatures,
      signaturesOutsideQuorum: comparison.signaturesOutsideQuorum,
      noRuntimeImplements: comparison.noRuntimeImplements,
      surfaceRules: comparison.surfaceRules,
      findingCount: comparison.findings.length,
      findings: comparison.findings,
      skippedManagerControlCalls: comparison.skippedManagerControlCalls,
    },
    captures: captureManifest,
  };
  const manifestPath = testInfo.outputPath('tree-to-pe-manager-api-byte-capture.json');
  await fs.writeFile(manifestPath, JSON.stringify(report, null, 2));

  await testInfo.attach('tree-to-pe-manager-api-byte-capture.json', {
    path: manifestPath,
    contentType: 'application/json',
  });

  for (const run of runs) {
    expect(run.treeLoadedOk, `${run.engine.runtime} tree should contain loaded machine/domain/CES rows: ${run.errors.join('; ')}`).toBe(true);
    expect(run.treeRowCount, `${run.engine.runtime} tree should contain rows`).toBeGreaterThan(0);
    expect(run.sourcePresentationOk, `${run.engine.runtime} should present imported active sources: ${run.errors.join('; ')}`).toBe(true);
    expect(run.disableSourceCount, `${run.engine.runtime} should present active source toggles`).toBeGreaterThan(0);
    expect(run.enableSourceCount, `${run.engine.runtime} should have all visible sources ON`).toBe(0);
  }

  // Enumerated on stdout, not only in the attached manifest. Both of these
  // pass the gate, and both carry information the pass would otherwise swallow
  // (`docs/QUORUM_CONTRACT.md` §2, §3): a shape no runtime implements, and a
  // signature the quorum could not be formed over.
  for (const silent of comparison.noRuntimeImplements) {
    console.log(
      `  no runtime implements this shape: ${silent!.signature} — all three answered HTTP ${silent!.status}`,
    );
  }
  for (const outside of comparison.signaturesOutsideQuorum) {
    console.log(
      `  outside quorum (not compared): ${outside.signature} — answered by ${outside.answeredBy.join('+')}, absent from ${outside.absentFrom.join('+')}`,
    );
  }

  // Each finding names the surface, the rule it was held to, and what that rule
  // already allows — so a failure states which contract was broken rather than
  // leaving a reader to infer it from two byte counts.
  expect(
    comparison.findings.map(f => f.signature),
    'declared parity surface violated:\n' + comparison.findings.map(describeFinding).join('\n')
  ).toEqual([]);
});
