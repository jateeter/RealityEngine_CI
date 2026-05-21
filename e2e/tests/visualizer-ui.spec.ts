import { test, expect, Page } from '@playwright/test';

const VISUALIZER_URL = 'https://localhost:5173';

interface MachineListResponse {
  machines: Array<{ id: string; name: string; description?: string }>;
}

async function gotoSelectionAndGetMachines(page: Page) {
  const machinesResponsePromise = page.waitForResponse(
    response => response.url().includes('/api/machines') && response.status() === 200
  );

  await page.goto(VISUALIZER_URL);
  await page.waitForLoadState('networkidle');

  const machinesResponse = await machinesResponsePromise;
  return machinesResponse.json() as Promise<MachineListResponse>;
}

test.describe('Visualizer UI - Stable Behavior', () => {
  test('should render the machine selection shell', async ({ page }) => {
    await gotoSelectionAndGetMachines(page);

    await expect(page.getByText('Reality Engine')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Interconnect' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Tobias' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Files' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'New Machine' })).toBeVisible();
  });

  test('should render machine cards for loaded machines', async ({ page }) => {
    const machinesPayload = await gotoSelectionAndGetMachines(page);
    expect(machinesPayload.machines.length).toBeGreaterThan(0);

    await expect(page.locator('.mc-card')).toHaveCount(machinesPayload.machines.length);
  });

  test('should filter machine cards using search input', async ({ page }) => {
    const machinesPayload = await gotoSelectionAndGetMachines(page);
    expect(machinesPayload.machines.length).toBeGreaterThan(0);

    const firstMachine = machinesPayload.machines[0];
    const query = firstMachine.name.slice(0, 3).toLowerCase();

    await page.locator('.msv-search').fill(query);

    const expectedMatches = machinesPayload.machines.filter(machine => {
      const description = machine.description || '';
      return `${machine.name} ${description}`.toLowerCase().includes(query);
    }).length;

    await expect(page.locator('.mc-card')).toHaveCount(expectedMatches);
    await expect(page.locator('.mc-name').first()).toContainText(new RegExp(query, 'i'));
  });

  test('should navigate to machine interconnection view and render graph container', async ({ page }) => {
    await gotoSelectionAndGetMachines(page);

    await page.getByRole('button', { name: 'Interconnect' }).click();

    await expect(page.getByRole('heading', { name: 'Machine Interconnection View' })).toBeVisible();
    await expect(page.locator('.machine-graph-view')).toBeVisible();
  });
});
