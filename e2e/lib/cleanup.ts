/**
 * Track what a spec creates so it can be removed even when the spec fails.
 *
 * RealityEngine_CI#278. Specs already delete what they create — but inline, at
 * the end of the test that created it. That is exactly the code that does not
 * run when a test fails, and a failing test is when residue is both most likely
 * and most confusing.
 *
 * Observed: `full-integration.spec.ts` creates "Integration Test Sequence" at
 * line 50 and deletes it at line 120, inside one test. That test failed, the
 * delete never ran, and the sequence stayed on the instance — leaving cpp-1
 * holding a sequence that cpp-2 did not. The doubled family exists so those two
 * can be compared; a spec had silently made them differ.
 *
 * This matters more the moment #278 step 6 merges the jobs into one boot. Today
 * each job gets a fresh universe and residue dies with it. Sharing a universe
 * means residue reaches whatever runs next, including the parity stages, where
 * it presents as an engine divergence.
 *
 * Usage:
 *
 *   const created = trackCreated();
 *   test.afterAll(async ({ request }) => { await created.cleanup(request); });
 *   // ...
 *   created.sequence(API_BASE_URL, id);
 */
import type { APIRequestContext } from '@playwright/test';

type Tracked = { base: string; path: string };

export interface CreatedTracker {
  /** Record a sequence to delete during teardown. */
  sequence(base: string, id: string): void;
  /** Record a vector to delete during teardown. */
  vector(base: string, id: string): void;
  /** Record an arbitrary DELETE-able path. */
  path(base: string, path: string): void;
  /** Delete everything recorded. Never throws — teardown must not mask a failure. */
  cleanup(request: APIRequestContext): Promise<void>;
  /** What is still tracked, for assertions about the tracker itself. */
  pending(): number;
}

export function trackCreated(): CreatedTracker {
  const items: Tracked[] = [];
  return {
    sequence(base, id) {
      if (id) items.push({ base, path: `/api/sequences/${id}` });
    },
    vector(base, id) {
      if (id) items.push({ base, path: `/api/vectors/${id}` });
    },
    path(base, path) {
      if (path) items.push({ base, path });
    },
    pending() {
      return items.length;
    },
    async cleanup(request) {
      // Newest first: a later object may reference an earlier one.
      for (const item of items.reverse()) {
        try {
          await request.delete(`${item.base}${item.path}`);
        } catch {
          // A failed cleanup is not a test result. Swallowing keeps teardown
          // from converting a passing run into a red one, or from masking the
          // real failure in a run that was already red.
        }
      }
      items.length = 0;
    },
  };
}
