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

/** One source as the engine reports it and as the PE Manager renders it. */
interface SourceState {
  id: string;
  name: string;
  type: string;
  active: boolean;
  /** Present for sensors: when the engine last received a value. */
  lastUpdated: number | null;
}

/**
 * What "All On" should leave, derived from the engine rather than assumed.
 *
 * Not every source can be turned on. A sensor is active iff it holds a value
 * inside its TTL, and ingress is the only thing that activates it (SURFACE_SPEC
 * "Sources & Sensors"; the PE Manager's own toggle-all relies on it,
 * RealityEngine_Manager#151). So a localAI sensor that has not reported stays
 * off on every runtime, and asserting zero "Enable source" buttons failed
 * whenever localAI had not fed its sensors — a property of the stack's timing,
 * not of the engines.
 */
interface SourceAccounting {
  total: number;
  active: number;
  /** Sensors with no live value: off because activation is earned, as it must be. */
  awaitingIngress: SourceState[];
  /** Anything else still off after All On: the PE refused a source it should have armed. */
  refused: SourceState[];
  /** Cards the PE Manager rendered, by toggle state. */
  ui: { on: number; off: number; cards: { name: string; title: string }[] };
}

interface EngineRun {
  engine: EngineTarget;
  captures: CapturedResponse[];
  accounting: SourceAccounting | null;
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

async function engineSources(request: APIRequestContext): Promise<SourceState[]> {
  const res = await request.get('/api/pe/sources', { headers: NO_CACHE_HEADERS });
  expect(res.ok(), `GET /api/pe/sources failed: ${res.status()}`).toBeTruthy();
  const body = await res.json() as { sources?: any[] } | any[];
  const list = Array.isArray(body) ? body : body.sources ?? [];
  return list.map((s: any) => ({
    id: String(s.id ?? ''),
    name: String(s.name ?? ''),
    type: String(s.type ?? ''),
    active: s.active === true,
    lastUpdated: typeof s.lastUpdated === 'number' ? s.lastUpdated : null,
  }));
}

async function renderedCards(page: Page): Promise<{ name: string; title: string }[]> {
  return page.$$eval('button[title="Enable source"], button[title="Disable source"]', (buttons) =>
    buttons.map((b) => ({
      title: b.getAttribute('title') ?? '',
      // The card is the toggle's row; its text starts with the source name.
      name: ((b.parentElement as HTMLElement | null)?.innerText ?? '').split('\n')[0].trim(),
    })));
}

/**
 * Turn every source on, then account for what the engine actually holds.
 *
 * Settles on agreement: polls until the PE Manager's rendered toggles match the
 * engine's own source list (the view reconciles with the engine after its
 * writes), rather than on an assumed count.
 */
async function forceAllSourcesOn(page: Page, request: APIRequestContext): Promise<SourceAccounting> {
  const toggleAll = page.getByRole('button', { name: /^(All Off|Mixed)$/ });
  if (await toggleAll.count() && await toggleAll.first().isEnabled()) {
    await toggleAll.first().click();
  }
  let accounting: SourceAccounting | null = null;
  const deadline = Date.now() + 20_000;
  do {
    const sources = await engineSources(request);
    const cards = await renderedCards(page);
    const off = sources.filter((s) => !s.active);
    accounting = {
      total: sources.length,
      active: sources.length - off.length,
      awaitingIngress: off.filter((s) => s.type === 'sensor'),
      refused: off.filter((s) => s.type !== 'sensor'),
      ui: {
        on: cards.filter((c) => c.title === 'Disable source').length,
        off: cards.filter((c) => c.title === 'Enable source').length,
        cards,
      },
    };
    if (accounting.ui.on === accounting.active && accounting.ui.off === off.length) break;
    await page.waitForTimeout(500);
  } while (Date.now() < deadline);
  return accounting!;
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
    let accounting: SourceAccounting | null = null;
    try {
      // `\\(` — the backslash must survive the string literal to reach the regex.
      // Written as '\\(' in a single-quoted TS string, JS drops the backslash and
      // Playwright compiles /^Sources ([1-9]/ — an unterminated group — which
      // throws SyntaxError at match time rather than failing an assertion. The
      // header of this file warns about the same class of bug in the spec it
      // replaced; this is it in the opposite direction (under-escaped).
      await expect(page.locator('text=/^Sources \\([1-9]/').first()).toBeVisible({ timeout: 15_000 });
      accounting = await forceAllSourcesOn(page, page.request);
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
      accounting,
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

function asSurfaceCapture(capture: CapturedResponse, minted: MintedId[] = []): SurfaceCapture {
  let body = Buffer.from(capture.bodyBase64, 'base64');
  if (minted.length) {
    let text = body.toString('utf8');
    for (const m of minted) text = text.split(m.id).join(m.token);
    // A runtime orders entries by its own minted ids, so once those ids are
    // normalised the order of the entries they keyed is an artifact too. Only a
    // body that actually names a minted entry is put in canonical form; every
    // other body stays byte for byte.
    if (text.includes('minted:')) {
      try {
        text = JSON.stringify(canonicalJson(JSON.parse(text)));
      } catch {
        /* not JSON: compared as substituted text */
      }
    }
    body = Buffer.from(text, 'utf8');
  }
  return {
    status: capture.status,
    body,
    sha256: minted.length ? sha256(body) : capture.sha256,
  };
}

/** Keys sorted; arrays of machine-keyed entries ordered by their (normalised) identity. */
function canonicalJson(value: unknown): unknown {
  if (Array.isArray(value)) {
    const items = value.map(canonicalJson);
    const keyed = items.length > 1 && items.every(
      (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && typeof (v as any).machineId === 'string');
    if (!keyed) return items;
    const key = (v: any) => JSON.stringify([v.machineId, v.sequenceId ?? '', v.vector?.id ?? v.id ?? '']);
    return [...items].sort((a: any, b: any) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value as object).sort().map((k) => [k, canonicalJson((value as any)[k])]));
  }
  return value;
}

/**
 * Identity a runtime minted for itself — the one thing compared here that is
 * allowed to differ.
 *
 * Corpus machines carry corpus-derived ids (`machine-arbitrationreader`), equal
 * on every runtime, which is why identity is otherwise not filtered (see
 * e2e/CLAUDE.md). Entries an integration registers at runtime do not: localAI
 * imports its machines and declares its sensors over the API, and each loader
 * mints its own id for them — three runtimes, three id formats
 * (`machine-1U5HAGL-…`, `machine-1790983605546-…`, `source-1790…`), and every
 * surface that names them differs by bytes while saying the same thing. Against
 * a stack with localAI running, that failed every compared surface.
 *
 * The rule is narrow and stated by evidence, not by name prefix: an entry
 * present on all three runtimes under one name, whose id differs between them.
 * Its id becomes `minted:<kind>:<name>` in every body of that runtime before the
 * comparison; everything else, including every corpus id, is still compared
 * byte for byte. The substitutions are reported, so the allowance is auditable.
 */
interface MintedId {
  kind: 'machine' | 'source';
  name: string;
  id: string;
  token: string;
}

function latestBody(run: EngineRun, path: string): any | null {
  const hit = [...run.captures].reverse().find(c => c.method === 'GET' && c.path === path && c.ok);
  if (!hit) return null;
  try {
    return JSON.parse(Buffer.from(hit.bodyBase64, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

function mintedIds(runs: EngineRun[]): Record<Runtime, MintedId[]> {
  const listed = (run: EngineRun, path: string, key: string): Map<string, string> => {
    const body = latestBody(run, path);
    const list: any[] = Array.isArray(body) ? body : body?.[key] ?? [];
    const out = new Map<string, string>();
    for (const e of list) if (typeof e?.name === 'string' && typeof e?.id === 'string') out.set(e.name, e.id);
    return out;
  };
  const result = Object.fromEntries(runs.map(r => [r.engine.runtime, [] as MintedId[]])) as Record<Runtime, MintedId[]>;
  for (const [kind, path, key] of [['machine', '/api/machines', 'machines'], ['source', '/api/pe/sources', 'sources']] as const) {
    const maps = runs.map(r => listed(r, path, key));
    for (const name of maps[0]?.keys() ?? []) {
      const ids = maps.map(m => m.get(name));
      if (ids.some(id => id === undefined) || new Set(ids).size === 1) continue;
      runs.forEach((r, i) => result[r.engine.runtime].push({ kind, name, id: ids[i]!, token: `minted:${kind}:${name}` }));
    }
  }
  // Longest first, so an id that contains another (a test source's
  // `test-<machineId>`) is replaced whole before its machine id is.
  for (const list of Object.values(result)) list.sort((a, b) => b.id.length - a.id.length);
  return result;
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

  const minted = mintedIds(runs);
  const findings: SurfaceFinding[] = [];
  const noRuntimeImplements: ReturnType<typeof unanimousSilence>[] = [];
  for (const signature of signatures) {
    const captures = {
      lsp: asSurfaceCapture(byRuntime.lsp.get(signature)!, minted.lsp),
      scala: asSurfaceCapture(byRuntime.scala.get(signature)!, minted.scala),
      cpp: asSurfaceCapture(byRuntime.cpp.get(signature)!, minted.cpp),
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
    // The minted-identity allowance, entry by entry (see mintedIds).
    mintedIdentity: (minted.lsp ?? []).map(m => ({ kind: m.kind, name: m.name })),
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
      sourceAccounting: run.accounting,
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
      mintedIdentity: comparison.mintedIdentity,
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
    const a = run.accounting;
    expect(a, `${run.engine.runtime} source accounting was not taken: ${run.errors.join('; ')}`).toBeTruthy();
    // Every source the engine allows to be on is on. A sensor awaiting its
    // first (or next) value is not a failure; any other inactive source is.
    expect(a!.refused.map((s) => `${s.type} ${s.name}`),
      `${run.engine.runtime} left sources off that All On should arm`).toEqual([]);
    // The PE Manager shows the engine's state: one toggle per source, on where
    // the engine is active and off where it is not.
    expect({ on: a!.ui.on, off: a!.ui.off },
      `${run.engine.runtime} PE Manager toggles disagree with the engine ` +
        `(${a!.active} active, ${a!.awaitingIngress.length} awaiting ingress, ${a!.total} total)`)
      .toEqual({ on: a!.active, off: a!.total - a!.active });
    console.log(
      `  ${run.engine.runtime}: ${a!.active}/${a!.total} sources on; ` +
        `${a!.awaitingIngress.length} sensor(s) awaiting ingress` +
        (a!.awaitingIngress.length ? ` (${a!.awaitingIngress.map((s) => s.name).join(', ')})` : ''),
    );
  }

  if (comparison.mintedIdentity.length) {
    console.log(
      `  runtime-minted identity normalised for ${comparison.mintedIdentity.length} entr` +
        `${comparison.mintedIdentity.length === 1 ? 'y' : 'ies'}: ` +
        comparison.mintedIdentity.map(m => `${m.kind} ${m.name}`).join(', '),
    );
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
