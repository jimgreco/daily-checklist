const { expect, test } = require('@playwright/test');

test.use({ timezoneId: 'America/New_York' });

test.beforeEach(async ({ page }) => {
  await page.clock.install({ time: new Date('2026-10-28T16:00:00Z') });
  await page.route('**/auth/refresh', route => route.fulfill({ status: 503, json: { error: 'Synthetic offline' } }));
  await page.route('**/api/sync', route => route.fulfill({ status: 503, json: { error: 'Synthetic offline' } }));
  await page.addInitScript(() => {
    if (localStorage.getItem('duplicate-fixture')) return;
    localStorage.clear();
    localStorage.setItem('duplicate-fixture', '1');
    localStorage.setItem('dailyWeb.user', JSON.stringify({ id: 'duplicate-test', name: 'Synthetic User' }));
    localStorage.setItem('dailyWeb.accountID', 'duplicate-test');
    localStorage.setItem('dailyWeb.cache', JSON.stringify({
      groups: [{ id: 'home', name: 'Home', sortOrder: 0 }],
      items: [{
        id: 'source', title: 'Water kitchen herbs', notes: 'Basil and mint dry out first.',
        schedule: 'custom', customWeekdays: [], recurrence: { kind: 'interval', interval: 2, unit: 'week', anchorDate: '2026-06-01' },
        quantity: 3, reminderMinutes: 540, followUpPolicy: { delayMinutes: 60, maximumCount: 2 },
        completedDates: ['2026-09-30'], completionCounts: { '2026-09-30': 3 }, skippedDates: ['2026-09-28'], openDates: [],
        createdAt: '2026-06-01T12:00:00Z', startDate: '2026-06-01T12:00:00Z', endedAt: '2026-10-01T04:00:00Z',
        groupID: 'home', sortOrder: 0, pauseWindows: [{ startDate: '2026-10-01' }],
        scheduleRevision: 7, missedBehavior: 'keepUntilDone', carryoverStartDate: '2026-06-01',
        carryoverResolvedThroughDate: '2026-09-30',
        occurrences: { 'source:7:2026-09-30': { outcome: 'done', completionCount: 3, resolvedDate: '2026-09-30', hiddenUntil: null, scheduledDate: '2026-09-30', scheduleRevision: 7 } },
      }],
    }));
    localStorage.setItem('dailyWeb.pending', JSON.stringify([{ id: 'existing-offline-edit' }]));
  });
  await page.goto('/app');
  await page.getByRole('button', { name: 'Archive', exact: true }).click();
});

const saved = page => page.evaluate(() => ['dailyWeb.cache', 'dailyWeb.pending'].map(key => localStorage.getItem(key)));

for (const width of [390, 1280]) {
  test(`duplicate draft cancels cleanly and saves an independent routine at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 844 });
    const before = await saved(page);
    const original = JSON.parse(before[0]).items[0];
    const duplicate = page.getByRole('button', { name: 'Duplicate Water kitchen herbs', exact: true });
    await duplicate.click();
    await expect(page.getByRole('heading', { name: 'Duplicate item', exact: true })).toBeVisible();
    await expect(page.getByLabel('Title', { exact: true })).toHaveValue('Water kitchen herbs (copy)');
    await expect(page.getByLabel('Start date', { exact: true })).toHaveValue('2026-10-28');
    await expect(page.getByLabel('Last day', { exact: true })).toHaveValue('');
    await expect(page.getByLabel('Anchor date', { exact: true })).toHaveValue('2026-06-01');
    await expect(page.getByRole('combobox', { name: 'Schedule', exact: true })).toHaveValue('interval');
    await expect(page.getByLabel('Quantity', { exact: true })).toHaveValue('3');
    await expect(page.getByLabel('Reminder', { exact: true })).toHaveValue('09:00');
    await expect(page.getByRole('combobox', { name: 'Group', exact: true })).toHaveValue('home');
    await expect(page.getByRole('button', { name: 'End item', exact: true })).toHaveCount(0);
    expect(await saved(page)).toEqual(before);
    await expect(page.locator('.scrim')).toHaveCSS('opacity', '1');
    await expect(page.locator('[data-editor]')).toHaveCSS('opacity', '1');
    await page.screenshot({ path: testInfo.outputPath(`duplicate-draft-${width}.png`), fullPage: true, animations: 'disabled' });
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    expect(await saved(page)).toEqual(before);

    await duplicate.click();
    await page.getByLabel('Title', { exact: true }).fill('Water balcony herbs');
    await page.getByLabel('Start date', { exact: true }).fill('2026-10-29');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    const after = await saved(page);
    const items = JSON.parse(after[0]).items;
    expect(items).toHaveLength(2);
    expect(items.find(item => item.id === original.id)).toEqual(original);
    const copy = items.find(item => item.id !== original.id);
    expect(copy.title).toBe('Water balcony herbs');
    expect(copy.startDate).toBe('2026-10-29T04:00:00.000Z');
    expect(copy.endedAt).toBeNull();
    expect(copy.scheduleRevision).toBe(0);
    expect(copy.completedDates).toEqual([]);
    expect(copy.completionCounts).toEqual({});
    expect(copy.skippedDates).toEqual([]);
    expect(copy.openDates).toEqual([]);
    expect(copy.pauseWindows).toEqual([]);
    expect(copy.occurrences).toEqual({});
    expect(copy.carryoverResolvedThroughDate).toBeNull();
    expect(copy.carryoverStartDate).toBe('2026-10-28');
    for (const key of ['notes', 'quantity', 'reminderMinutes', 'followUpPolicy', 'recurrence', 'groupID', 'missedBehavior']) {
      expect(copy[key]).toEqual(original[key]);
    }
    const mutations = JSON.parse(after[1]);
    expect(mutations).toHaveLength(2);
    expect(mutations[0]).toEqual({ id: 'existing-offline-edit' });
    expect(mutations[1]).toMatchObject({ kind: 'upsert', itemID: copy.id });
    await page.getByRole('button', { name: 'All items', exact: true }).click();
    await expect(page.getByText('Water balcony herbs', { exact: true })).toHaveCount(0);
    await page.getByRole('button', { name: 'Next day', exact: true }).click();
    await expect(page.getByText('Water balcony herbs', { exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath(`duplicate-saved-${width}.png`), fullPage: true, animations: 'disabled' });
    await page.reload();
    const restored = JSON.parse((await saved(page))[0]).items;
    expect(restored.find(item => item.id === copy.id)).toEqual(copy);
    expect(restored.find(item => item.id === original.id)).toEqual(original);
  });
}
