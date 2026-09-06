import { test, expect, Page } from '@playwright/test';
import { endpointOr } from '../lib/registry';

/**
 * Visualizer UI — stable shell behavior.
 *
 * The landing surface is a domain *tree*, not the card grid this suite
 * originally targeted. `.mc-card` / `.msv-search` still exist in the Manager
 * frontend but are no longer rendered on the landing route, so the old
 * assertions resolved to zero elements.
 *
 * Selectors here are the ones the Manager's own passing e2e suite uses
 * (RealityEngine_Manager/visualizer/frontend/e2e/), plus classes observed in
 * the live DOM. Prefer stable classes over role+name: "Interconnect" matches
 * both the nav button and a `.vis-filter-chip` labelled "Interconnects", which
 * is a strict-mode violation.
 */

const VISUALIZER_URL = endpointOr('manager_frontend', 'https://localhost:5173');

/** Machine tree; also the signal that the engine's corpus reached the UI. */
function machineTree(page: Page) {
  return page.getByRole('tree', { name: /Machines grouped by domain/ });
}

async function gotoLanding(page: Page) {
  await page.goto(VISUALIZER_URL);
  // The wordmark renders without a backend, so it is the cheapest "shell is up".
  await expect(page.locator('.rep-title')).toContainText('Reality Engine', { timeout: 30000 });
}

test.describe('Visualizer UI - Stable Behavior', () => {
  test('should render the machine selection shell', async ({ page }) => {
    await gotoLanding(page);

    await expect(page.locator('.rep-subtitle')).toBeVisible();
    // .rep-nav-interconnect disambiguates from the "Interconnects" filter chip.
    await expect(page.locator('.rep-nav-interconnect')).toBeVisible();
    // The PE nav button is labelled "Perception", not "PE Manager". Its title
    // is the stable handle — the visible text sits next to a ◎ icon span.
    await expect(page.getByTitle('Open Perception Engine management')).toBeVisible();
    // Icon-only button; "Help" is its aria-label.
    await expect(page.getByRole('button', { name: 'Help' })).toBeVisible();
  });

  test('should render the machine tree for loaded machines', async ({ page }) => {
    await gotoLanding(page);

    const tree = machineTree(page);
    await expect(tree).toBeVisible({ timeout: 30000 });

    // At least one domain row, and it is a top-level row.
    const firstDomain = tree.getByRole('treeitem').first();
    await expect(firstDomain).toBeVisible();
    await expect(firstDomain).toHaveAttribute('aria-level', '1');

    // Expanding a domain reveals its machines (level-2 rows).
    await firstDomain.click();
    await expect(tree.locator('[role="treeitem"][aria-level="2"]').first())
      .toBeVisible({ timeout: 10000 });
  });

  test('should filter the machine tree using search input', async ({ page }) => {
    await gotoLanding(page);

    const tree = machineTree(page);
    await expect(tree).toBeVisible({ timeout: 30000 });

    // A query that cannot match anything must report the empty state rather
    // than silently leaving the full tree rendered.
    await page.getByPlaceholder(/search domains/).fill('zzz-no-such-machine-xyz');
    await expect(page.getByText('no machines found')).toBeVisible({ timeout: 10000 });

    // Clearing restores the tree.
    await page.locator('.rep-search-clear').click();
    await expect(tree).toBeVisible();
    await expect(tree.getByRole('treeitem').first()).toBeVisible();
  });

  test('should navigate to machine interconnection view and render graph container', async ({ page }) => {
    await gotoLanding(page);

    await page.locator('.rep-nav-interconnect').click();

    await expect(page.locator('.machine-graph-view')).toBeVisible({ timeout: 30000 });
  });
});
