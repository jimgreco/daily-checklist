const { expect, test } = require('@playwright/test');

test.use({ timezoneId: 'America/New_York' });

test.beforeEach(async ({ page }) => {
  await page.clock.install({ time: new Date('2026-10-22T16:00:00Z') });
  await page.route('**/auth/refresh', route => route.fulfill({ status: 503, json: { error: 'Synthetic offline' } }));
  await page.route('**/api/sync', route => route.fulfill({ status: 503, json: { error: 'Synthetic offline' } }));
  await page.addInitScript(() => {
    localStorage.clear();
    localStorage.setItem('dailyWeb.user', JSON.stringify({ id: 'remaining-test', name: 'Synthetic User' }));
    localStorage.setItem('dailyWeb.accountID', 'remaining-test');
    const item = (id, title, extra = {}) => ({
      id, title, notes: 'Synthetic focus test', schedule: 'everyDay', customWeekdays: [],
      quantity: 1, completedDates: [], completionCounts: {}, skippedDates: [], openDates: [],
      createdAt: '2026-10-20T12:00:00Z', startDate: null, endedAt: null,
      groupID: 'morning', sortOrder: 0, pauseWindows: [], ...extra,
    });
    localStorage.setItem('dailyWeb.cache', JSON.stringify({
      groups: [{ id: 'morning', name: 'Morning', sortOrder: 0 }],
      items: [item('open', 'Review calendar'),
        item('partial', 'Drink water', { quantity: 3, completionCounts: { '2026-10-22': 1 } }),
        item('done', 'Take vitamins', { completedDates: ['2026-10-22'] }),
        item('skip', 'Skipped walk', { skippedDates: ['2026-10-22'] }),
        item('pause', 'Paused ritual', { pauseWindows: [{ startDate: '2026-10-22' }] }),
        item('ended', 'Archived ritual', { endedAt: '2026-10-21T12:00:00Z' })],
    }));
    localStorage.setItem('dailyWeb.pending', JSON.stringify([{ id: 'existing-offline-edit' }]));
  });
  await page.goto('/app');
  await expect(page.getByRole('button', { name: 'Remaining only', exact: true })).toBeVisible();
});

const row = (page, title) => page.locator('.task').filter({ hasText: title });
const saved = page => page.evaluate(() => ['dailyWeb.accountID', 'dailyWeb.cache', 'dailyWeb.pending'].map(key => localStorage.getItem(key)));

for (const width of [390, 1280]) {
  test(`remaining focus preserves history, search and dates at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 844 });
    const before = await saved(page);
    const filter = page.getByRole('button', { name: 'Remaining only', exact: true });
    await filter.click();
    await expect(filter).toHaveAttribute('aria-pressed', 'true');
    await expect(filter).toBeFocused();
    await expect(row(page, 'Review calendar')).toBeVisible();
    await expect(row(page, 'Drink water')).toContainText('1/3');
    await expect(row(page, 'Take vitamins')).toHaveCount(0);
    await expect(row(page, 'Skipped walk')).toHaveCount(0);
    await expect(row(page, 'Paused ritual')).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath(`remaining-${width}.png`), fullPage: true });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.getByLabel('Search tasks').fill('vitamins');
    await expect(page.getByText('0 matching tasks', { exact: true })).toBeVisible();
    await expect(page.getByText('No matching rituals', { exact: true })).toBeVisible();
    await filter.click();
    await expect(row(page, 'Take vitamins')).toBeVisible();
    await filter.click();
    await page.getByRole('button', { name: 'Clear search', exact: true }).click();
    await expect(filter).toHaveAttribute('aria-pressed', 'true');
    await Promise.all([
      page.waitForResponse(response => response.url().endsWith('/api/sync')),
      page.evaluate(() => window.dispatchEvent(new Event('online'))),
    ]);
    await expect(filter).toHaveAttribute('aria-pressed', 'true');
    await page.getByRole('button', { name: 'Next day' }).click();
    await expect(row(page, 'Take vitamins')).toBeVisible();
    await expect(filter).toHaveAttribute('aria-pressed', 'true');
    await page.getByRole('button', { name: 'Previous day' }).click();
    await expect(row(page, 'Take vitamins')).toHaveCount(0);
    await page.getByRole('button', { name: 'All items', exact: true }).click();
    await expect(filter).toHaveCount(0);
    await expect(row(page, 'Take vitamins')).toBeVisible();
    await expect(row(page, 'Paused ritual')).toBeVisible();
    await page.getByRole('button', { name: 'Archive', exact: true }).click();
    await expect(row(page, 'Archived ritual')).toBeVisible();
    await expect(filter).toHaveCount(0);
    await page.getByRole('button', { name: 'Today', exact: true }).click();
    await expect(filter).toHaveAttribute('aria-pressed', 'true');
    expect(await saved(page)).toEqual(before);
  });
}

test('completed quantities disappear, repeated focus changes preserve queued progress, and reopen restores a row', async ({ page }, testInfo) => {
  const filter = page.getByRole('button', { name: 'Remaining only', exact: true });
  await filter.click();
  await row(page, 'Drink water').getByRole('button', { name: 'Mark complete', exact: true }).click();
  await expect(row(page, 'Drink water')).toContainText('2/3');
  await row(page, 'Drink water').getByRole('button', { name: 'Mark complete', exact: true }).click();
  await expect(row(page, 'Drink water')).toHaveCount(0);
  await row(page, 'Review calendar').getByRole('button', { name: 'Mark complete', exact: true }).click();
  await expect(page.getByText('No remaining tasks for this day.', { exact: true })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath('remaining-empty.png'), fullPage: true });
  const before = await saved(page);
  for (let i = 0; i < 4; i++) await filter.click();
  expect(await saved(page)).toEqual(before);
  await filter.click();
  await row(page, 'Drink water').getByRole('button', { name: 'Mark incomplete', exact: true }).click();
  await filter.click();
  await expect(row(page, 'Drink water')).toContainText('0/3');
  const values = await saved(page);
  const item = JSON.parse(values[1]).items.find(item => item.id === 'open');
  expect(item.completedDates).toEqual(['2026-10-22']);
  expect(JSON.parse(values[2])).toEqual(expect.arrayContaining([expect.objectContaining({ id: 'existing-offline-edit' })]));
});

test('still-open work remains actionable when no scheduled tasks remain', async ({ page }, testInfo) => {
  await page.addInitScript(() => {
    const cache = JSON.parse(localStorage.getItem('dailyWeb.cache'));
    cache.items = cache.items.map(item => ({ ...item, completedDates: ['2026-10-22'], completionCounts: { '2026-10-22': item.quantity }, skippedDates: [] }));
    cache.items.push({
      id: 'overdue', title: 'File receipt', notes: 'Synthetic carryover', schedule: 'custom',
      customWeekdays: [4], quantity: 1, completedDates: [], completionCounts: {}, skippedDates: [], openDates: [],
      createdAt: '2026-10-20T12:00:00Z', startDate: null, endedAt: null, groupID: 'morning',
      sortOrder: 9, pauseWindows: [], missedBehavior: 'keepUntilDone', carryoverStartDate: '2026-10-21',
    });
    localStorage.setItem('dailyWeb.cache', JSON.stringify(cache));
  });
  await page.reload();
  await page.getByRole('button', { name: 'Remaining only', exact: true }).click();
  await expect(page.getByText('File receipt', { exact: true })).toBeVisible();
  await expect(page.getByText('No scheduled tasks remaining for this day.', { exact: true })).toBeVisible();
  await expect(page.getByText('No remaining tasks for this day.', { exact: true })).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath('remaining-carryover.png'), fullPage: true });
});
