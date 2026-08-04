import { APIRequestContext, test } from '@playwright/test';

/**
 * Corpus guards for specs that depend on specific machines.
 *
 * The universe can boot with `--machine-corpus=standard-deployment`, a
 * deliberately small 12-machine manifest (config/standard-deployment-corpus.txt)
 * that proves each engine can load, list, and evaluate machine JSON. It does not
 * contain the digital-logic fixtures — MultiStep, RS2, RSFlipFlop — that the
 * interconnection specs drive.
 *
 * Those specs should skip loudly on such a universe, not fail. A 404 for a
 * machine the corpus never claimed to load says nothing about the product.
 *
 * Not named *.spec.ts, so Playwright's testMatch does not collect it.
 */

/** Names of machines absent from the running engine's corpus. */
export async function missingMachines(
  request: APIRequestContext,
  baseUrl: string,
  names: string[],
): Promise<string[]> {
  const missing: string[] = [];
  for (const name of names) {
    try {
      const resp = await request.get(`${baseUrl}/api/machines/json/${name}`, {
        ignoreHTTPSErrors: true,
      });
      if (!resp.ok()) missing.push(name);
    } catch {
      missing.push(name);
    }
  }
  return missing;
}

/**
 * Skip the current test when the corpus lacks any required machine. Call from
 * `test.beforeEach`. The skip reason names the machines and points at the cause,
 * so a skipped run is diagnosable without opening the workflow file.
 */
export async function skipUnlessMachines(
  request: APIRequestContext,
  baseUrl: string,
  names: string[],
): Promise<void> {
  const missing = await missingMachines(request, baseUrl, names);
  test.skip(
    missing.length > 0,
    `corpus is missing ${missing.join(', ')} — these specs need the full corpus; ` +
      'a --machine-corpus=standard-deployment universe does not load the digital-logic fixtures',
  );
}
