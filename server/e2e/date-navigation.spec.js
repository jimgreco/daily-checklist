const { expect, test } = require('@playwright/test');

test.use({ timezoneId: 'America/New_York' });

test.beforeEach(async ({ page }) => {
  await page.route('**/auth/refresh', route => route.fulfill({
    status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Synthetic offline session' }),
  }));
  await page.route('**/api/sync', route => route.fulfill({
    status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Synthetic offline sync' }),
  }));
  await page.addInitScript(() => {
    localStorage.clear();
    localStorage.setItem('dailyWeb.user', JSON.stringify({ id: 'date-navigation-test', name: 'Date Test' }));
    localStorage.setItem('dailyWeb.accountID', 'date-navigation-test');
    localStorage.setItem('dailyWeb.cache', JSON.stringify({ groups: [], items: [{
      id: 'calendar-review', title: 'Review calendar', notes: 'Synthetic date navigation test',
      schedule: 'everyDay', customWeekdays: [], quantity: 1, completedDates: [],
      completionCounts: {}, skippedDates: [], openDates: [], createdAt: '2020-01-01T12:00:00.000Z',
      startDate: null, endedAt: null, groupID: null, sortOrder: 0, pauseWindows: [],
    }] }));
    localStorage.setItem('dailyWeb.pending', JSON.stringify([{ id: 'pending-synthetic-edit' }]));
  });
  await page.goto('/app');
  await expect(page.getByRole('button', { name: 'Choose checklist date' })).toBeVisible();
});

async function storedData(page) {
  return page.evaluate(() => ({
    account: localStorage.getItem('dailyWeb.accountID'),
    cache: localStorage.getItem('dailyWeb.cache'),
    pending: localStorage.getItem('dailyWeb.pending'),
  }));
}

test('jumps to a leap day, preserves filters and offline data, and returns to today', async ({ page }) => {
  await page.getByRole('button', { name: 'All items', exact: true }).click();
  await page.getByRole('button', { name: 'Manual', exact: true }).click();
  await page.getByLabel('Search tasks').fill('calendar');
  const before = await storedData(page);

  await page.getByRole('button', { name: 'Choose checklist date' }).click();
  await expect(page.getByRole('dialog', { name: 'Choose date' })).toBeVisible();
  await page.getByLabel('Checklist date', { exact: true }).fill('2040-02-29');
  await page.getByLabel('Checklist date', { exact: true }).focus();
  await Promise.all([
    page.waitForResponse(response => response.url().endsWith('/api/sync')),
    page.evaluate(() => window.dispatchEvent(new Event('online'))),
  ]);
  await expect(page.getByLabel('Checklist date', { exact: true })).toHaveValue('2040-02-29');
  await expect(page.getByLabel('Checklist date', { exact: true })).toBeFocused();
  await page.getByRole('button', { name: 'View day', exact: true }).click();

  await expect(page.getByRole('heading', { name: 'Feb 29', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Choose checklist date' })).toContainText('2040');
  await expect(page.getByRole('button', { name: 'Choose checklist date' })).toBeFocused();
  await expect(page.getByRole('button', { name: 'All items', exact: true })).toHaveClass('active');
  await expect(page.getByRole('button', { name: 'Time', exact: true })).toBeVisible();
  await expect(page.getByLabel('Search tasks')).toHaveValue('calendar');
  await expect(page.getByText('1 thing left on this day.', { exact: true })).toBeVisible();
  await expect(page.getByText('Review calendar', { exact: true })).toBeVisible();
  expect(await storedData(page)).toEqual(before);

  await page.getByRole('button', { name: 'Next day' }).click();
  await expect(page.getByRole('heading', { name: 'Mar 1', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Previous day' }).click();
  await expect(page.getByRole('heading', { name: 'Feb 29', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Back to today' }).click();
  await expect(page.getByRole('heading', { name: 'Ritual Cue', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Today', exact: true })).toHaveClass('active');
  await expect(page.getByRole('button', { name: 'Back to today' })).toHaveCount(0);
  await expect(page.getByLabel('Search tasks')).toHaveValue('calendar');
  expect(await storedData(page)).toEqual(before);
});

test('cancel and Escape discard the draft, and archive has no date controls', async ({ page }) => {
  const before = await storedData(page);
  for (const action of ['cancel', 'escape']) {
    await page.getByRole('button', { name: 'Choose checklist date' }).click();
    await page.getByLabel('Checklist date', { exact: true }).fill('2040-02-29');
    if (action === 'cancel') await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    else await page.getByLabel('Checklist date', { exact: true }).press('Escape');
    await expect(page.getByRole('dialog', { name: 'Choose date' })).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Ritual Cue', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Choose checklist date' })).toBeFocused();
    expect(await storedData(page)).toEqual(before);
  }
  await page.getByRole('button', { name: 'Choose checklist date' }).click();
  await page.getByLabel('Checklist date', { exact: true }).fill('2040-02-29');
  await page.getByRole('button', { name: 'View day', exact: true }).click();
  await page.getByRole('button', { name: 'Archive', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Ritual Cue', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Choose checklist date' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Previous day' })).toHaveCount(0);
  await expect(page.getByText('Archived routines', { exact: true })).toBeVisible();
});

test('the chosen local date is used for completion while other dates stay unchanged', async ({ page }) => {
  await page.getByRole('button', { name: 'Choose checklist date' }).click();
  await page.getByLabel('Checklist date', { exact: true }).fill('2040-02-29');
  await page.getByRole('button', { name: 'View day', exact: true }).click();
  await page.getByRole('button', { name: 'Mark complete', exact: true }).click();
  const data = await storedData(page);
  const item = JSON.parse(data.cache).items.find(item => item.id === 'calendar-review');
  expect(item.completedDates).toEqual(['2040-02-29']);
  expect(item.completionCounts).toEqual({ '2040-02-29': 1 });
  expect(JSON.parse(data.pending)).toEqual(expect.arrayContaining([
    expect.objectContaining({ id: 'pending-synthetic-edit' }),
    expect.objectContaining({ kind: 'completion', completionDate: '2040-02-29', completed: true }),
  ]));
  await page.getByRole('button', { name: 'Next day' }).click();
  await expect(page.getByRole('button', { name: 'Mark complete', exact: true })).toBeVisible();
});
