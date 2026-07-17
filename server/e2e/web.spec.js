const fs = require("node:fs");
const { expect, test } = require("@playwright/test");

function todayKeyFor(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function todayKey() {
  return todayKeyFor(new Date());
}

function occurrenceIDFor(itemID, scheduleRevision, scheduledDate) {
  return `${itemID}:${scheduleRevision}:${scheduledDate}`;
}

function waitForSync(page) {
  return page.waitForResponse((response) => (
    response.url().endsWith("/api/sync")
      && response.request().method() === "POST"
      && response.status() === 200
  ));
}

function task(page, title) {
  return page.locator(".task").filter({ hasText: title });
}

async function signIn(page) {
  await page.goto("/app");
  await expect(page.getByRole("heading", { name: "Keep your day in sync" })).toBeVisible();
  await Promise.all([
    waitForSync(page),
    page.getByRole("button", { name: "Local dev sign in" }).click()
  ]);
  await expect(page.getByRole("heading", { name: "Ritual Cue" })).toBeVisible();
}

test("shows a calm, private low-data insights state", async ({ page }) => {
  await signIn(page);
  await page.getByRole("button", { name: "Account" }).click();
  await page.getByRole("button", { name: /^Routine insights/ }).click();

  await expect(page.getByRole("heading", { name: "Routine insights" })).toBeVisible();
  await expect(page.getByText("Your patterns will appear here")).toBeVisible();
  await expect(page.getByText(/Nothing is sent to an analytics service/)).toBeVisible();
});

async function saveEditor(page) {
  await Promise.all([
    waitForSync(page),
    page.getByRole("button", { name: "Save" }).click()
  ]);
}

async function createItem(page, title, { notes = "", quantity = 1 } = {}) {
  await page.getByRole("button", { name: "Add checklist item" }).click();
  await expect(page.getByRole("heading", { name: "New item" })).toBeVisible();
  await page.getByLabel("Title").fill(title);
  await page.getByLabel("Notes").fill(notes);
  await page.getByLabel("Quantity").fill(String(quantity));
  await saveEditor(page);
  await expect(task(page, title)).toBeVisible();
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    if (window.name === "preserve-e2e-storage") return;
    window.localStorage.clear();
    window.sessionStorage.clear();
  });
});

test("shows the sign-in gate and serves browser-compatible security headers", async ({ page, request }) => {
  const response = await request.get("/app");
  expect(response.status()).toBe(200);
  const csp = response.headers()["content-security-policy"];
  expect(csp).toContain("script-src 'self' https://accounts.google.com https://appleid.cdn-apple.com");
  expect(csp).toContain("connect-src 'self'");
  expect(csp).toContain("frame-ancestors 'none'");

  await page.goto("/app");
  await expect(page.getByRole("heading", { name: "Keep your day in sync" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Local dev sign in" })).toBeVisible();
});

test("expired browser sessions preserve cached routines and pending changes for reauthentication", async ({ page }) => {
  const cachedItem = {
    id: "cached-session-item",
    title: "Preserved routine",
    schedule: "everyDay",
    completedDates: [],
    completionCounts: {},
    skippedDates: [],
    openDates: [],
    createdAt: "2026-07-01T12:00:00.000Z",
    startDate: "2026-07-01T12:00:00.000Z",
    groupID: null,
    sortOrder: 0,
    pauseWindows: []
  };
  const pendingMutation = {
    id: "cached-session-mutation",
    kind: "completion",
    stamp: "2026-07-13T12:00:00.000Z",
    itemID: cachedItem.id,
    completionDate: "2026-07-13",
    completed: true,
    completionCount: 1
  };
  await page.addInitScript(({ item, mutation }) => {
    localStorage.setItem("dailyWeb.user", JSON.stringify({
      id: "expired-session-user",
      email: "expired@ritualcue.local",
      name: "Expired Session"
    }));
    localStorage.setItem("dailyWeb.accountID", "expired-session-user");
    localStorage.setItem("dailyWeb.cache", JSON.stringify({ items: [item], groups: [] }));
    localStorage.setItem("dailyWeb.pending", JSON.stringify([mutation]));
  }, { item: cachedItem, mutation: pendingMutation });
  await page.route("**/auth/refresh", (route) => route.fulfill({
    status: 401,
    contentType: "application/json",
    body: JSON.stringify({ error: "Invalid refresh token" })
  }));

  await page.goto("/app");

  await expect(page.getByRole("heading", { name: "Keep your day in sync" })).toBeVisible();
  await expect(page.getByText(/Your session expired.*still saved in this browser/)).toBeVisible();
  const persisted = await page.evaluate(() => ({
    accountID: localStorage.getItem("dailyWeb.accountID"),
    cache: JSON.parse(localStorage.getItem("dailyWeb.cache")),
    pending: JSON.parse(localStorage.getItem("dailyWeb.pending"))
  }));
  expect(persisted.accountID).toBe("expired-session-user");
  expect(persisted.cache.items).toEqual([{
    ...cachedItem,
    recurrence: null,
    scheduleRevision: 0,
    occurrences: {}
  }]);
  expect(persisted.pending).toEqual([pendingMutation]);
});

test("groups today with missed irregular work and resolves only the latest occurrence", async ({ page }) => {
  const today = new Date();
  const twoDaysAgo = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 2, 12);
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1, 12);
  const twoDaysAgoDate = todayKeyFor(twoDaysAgo);
  const yesterdayDate = todayKeyFor(yesterday);
  const todayDate = todayKey();
  const twoDaysAgoOccurrenceID = occurrenceIDFor("carryover-item", 0, twoDaysAgoDate);
  const yesterdayOccurrenceID = occurrenceIDFor("carryover-item", 0, yesterdayDate);
  const todayOccurrenceID = occurrenceIDFor("carryover-item", 0, todayDate);
  const carryoverItem = {
    id: "carryover-item",
    title: "Refill the bird feeder",
    notes: "Still useful a day late",
    schedule: "custom",
    customWeekdays: [twoDaysAgo.getDay() + 1, yesterday.getDay() + 1, today.getDay() + 1],
    reminderMinutes: null,
    quantity: 2,
    completedDates: [],
    completionCounts: {},
    skippedDates: [yesterdayDate],
    openDates: [],
    createdAt: twoDaysAgo.toISOString(),
    startDate: twoDaysAgo.toISOString(),
    endedAt: null,
    groupID: null,
    sortOrder: 0,
    pauseWindows: [],
    scheduleRevision: 0,
    missedBehavior: "keepUntilDone",
    carryoverStartDate: twoDaysAgoDate,
    carryoverResolvedThroughDate: null,
    occurrences: {
      [yesterdayDate]: {
        outcome: "open",
        completionCount: 0,
        resolvedDate: null,
        hiddenUntil: null
      }
    }
  };
  await page.goto("/app");
  await page.route("**/auth/refresh", (route) => route.fulfill({
    status: 503,
    contentType: "application/json",
    body: JSON.stringify({ error: "Offline for local carryover test" })
  }));
  await page.evaluate(({ items }) => {
    window.name = "preserve-e2e-storage";
    localStorage.setItem("dailyWeb.user", JSON.stringify({
      id: "carryover-test-user",
      email: "carryover@ritualcue.local",
      name: "Carryover Test"
    }));
    localStorage.setItem("dailyWeb.accountID", "carryover-test-user");
    localStorage.setItem("dailyWeb.cache", JSON.stringify({ items, groups: [] }));
    localStorage.setItem("dailyWeb.pending", "[]");
  }, { items: [carryoverItem] });
  await page.reload();

  await expect(page.getByRole("heading", { name: "Ritual Cue" })).toBeVisible();
  const carryover = page.locator(".carryover-task").filter({ hasText: carryoverItem.title });
  await expect(page.getByText("Still open", { exact: true })).toBeVisible();
  await expect(carryover.getByText("3 occurrences", { exact: true })).toBeVisible();
  await expect(carryover.getByText("2 days late", { exact: true })).toBeVisible();
  await expect(carryover.getByText("0/2", { exact: true })).toBeVisible();

  await expect(page.getByRole("button", { name: /All\s+1/ })).toHaveCount(0);
  await expect(page.locator(".task:not(.carryover-task)").filter({ hasText: carryoverItem.title })).toHaveCount(0);

  await carryover.getByRole("button", { name: `Complete still-open ${carryoverItem.title}` }).click();
  await expect(carryover.getByText("1/2", { exact: true })).toBeVisible();
  let cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  expect(cached.items.find((item) => item.id === carryoverItem.id).carryoverResolvedThroughDate).toBeNull();
  const partialMutations = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.pending")));
  expect(partialMutations.findLast((entry) => entry.kind === "occurrence")).toMatchObject({
    itemID: carryoverItem.id,
    occurrenceID: todayOccurrenceID,
    occurrenceDate: todayDate,
    occurrence: {
      outcome: "open",
      completionCount: 1,
      resolvedDate: null,
      hiddenUntil: null,
      scheduleRevision: 0,
      scheduledDate: todayDate
    }
  });

  await carryover.getByRole("button", { name: `Complete still-open ${carryoverItem.title}` }).click();
  await expect(carryover).toHaveCount(0);
  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  const resolved = cached.items.find((item) => item.id === carryoverItem.id);
  expect(resolved.completedDates).toContain(todayDate);
  expect(resolved.completedDates).not.toContain(yesterdayDate);
  expect(resolved.completionCounts[todayDate]).toBe(2);
  expect(resolved.carryoverResolvedThroughDate).toBe(todayDate);
  expect(resolved.occurrences[todayOccurrenceID]).toEqual({
    outcome: "done",
    completionCount: 2,
    resolvedDate: todayDate,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: todayDate
  });
  expect(resolved.skippedDates).not.toContain(yesterdayDate);
  expect(resolved.occurrences[yesterdayOccurrenceID]).toEqual({
    outcome: "missed",
    completionCount: 0,
    resolvedDate: todayDate,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: yesterdayDate
  });
  expect(resolved.occurrences[twoDaysAgoOccurrenceID]).toEqual({
    outcome: "missed",
    completionCount: 0,
    resolvedDate: todayDate,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: twoDaysAgoDate
  });
  expect(resolved.occurrences[yesterdayDate]).toBeUndefined();

  const todayOccurrence = page.locator(".task:not(.carryover-task)").filter({ hasText: carryoverItem.title });
  await expect(todayOccurrence.getByRole("button", { name: "Mark incomplete" })).toBeVisible();
  await todayOccurrence.getByRole("button", { name: `History for ${carryoverItem.title}` }).click();
  const scheduledLabel = yesterday.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
  const handledLabel = today.toLocaleDateString([], { month: "short", day: "numeric" });
  const historyRow = page.locator(".history-row").filter({ hasText: scheduledLabel });
  const historyState = historyRow.locator("select[data-history-state]");
  await expect(historyState).toHaveValue("missed");
  await historyState.selectOption("done");
  await expect(historyRow.getByText("Completed 1 day late", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Done" }).click();

  await page.getByRole("button", { name: "Account" }).click();
  await page.getByRole("button", { name: /^Routine insights/ }).click();
  const lateInsight = page.locator(".insight-card").filter({ hasText: "Late completions" });
  await expect(lateInsight.locator("strong")).toHaveText("1");
  await page.getByRole("button", { name: "Done" }).click();

  await todayOccurrence.getByRole("button", { name: `History for ${carryoverItem.title}` }).click();
  await historyState.selectOption("open");
  await expect(historyState).toHaveValue("open");
  await historyState.selectOption("missed");
  await expect(historyState).toHaveValue("missed");

  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  const dismissedAsMissed = cached.items.find((item) => item.id === carryoverItem.id);
  expect(dismissedAsMissed.skippedDates).not.toContain(yesterdayDate);
  expect(dismissedAsMissed.occurrences[yesterdayOccurrenceID]).toEqual({
    outcome: "missed",
    completionCount: 0,
    resolvedDate: todayDate,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: yesterdayDate
  });
  await expect(historyRow.locator("select[data-history-state]")).toHaveValue("missed");
  await expect(historyRow.getByText(`Handled ${handledLabel}`, { exact: true })).toBeVisible();
});

test("configures carryover only for irregular schedules and preserves its history when disabled", async ({ page }) => {
  const title = `E2E weekly reset ${Date.now()}`;
  await signIn(page);
  await page.getByRole("button", { name: "Add checklist item" }).click();
  await page.getByLabel("Title").fill(title);
  const keepVisible = page.getByLabel("Keep visible until handled", { exact: false });
  await expect(keepVisible).toBeHidden();
  await page.getByLabel("Schedule").selectOption("weekends");
  await expect(keepVisible).toBeVisible();
  await expect(keepVisible).not.toBeChecked();
  await page.getByLabel("Schedule").selectOption("custom");
  await expect(keepVisible).toBeChecked();
  const todayWeekday = new Date().getDay() + 1;
  const otherWeekday = todayWeekday === 1 ? 2 : 1;
  await page.locator(`.weekday[data-day="${todayWeekday}"]`).click();
  await expect(keepVisible).toBeChecked();
  await page.locator(`.weekday[data-day="${otherWeekday}"]`).click();
  await expect(keepVisible).not.toBeChecked();
  await keepVisible.check();
  await saveEditor(page);

  let cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  let saved = cached.items.find((item) => item.title === title);
  expect(saved.missedBehavior).toBe("keepUntilDone");
  expect(saved.scheduleRevision).toBe(0);
  expect(saved.carryoverStartDate).toBe(todayKey());
  expect(saved.carryoverResolvedThroughDate).toBeNull();
  expect(saved.occurrences).toEqual({});

  await page.getByRole("button", { name: "All items" }).click();
  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await page.locator(`.weekday[data-day="${otherWeekday}"]`).click();
  await saveEditor(page);

  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  saved = cached.items.find((item) => item.title === title);
  const revisionZeroOccurrenceID = occurrenceIDFor(saved.id, 0, todayKey());
  expect(saved.scheduleRevision).toBe(1);
  expect(saved.carryoverStartDate).toBe(todayKey());
  expect(saved.occurrences[revisionZeroOccurrenceID]).toEqual({
    outcome: "open",
    completionCount: 0,
    resolvedDate: null,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: todayKey()
  });

  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await page.getByLabel("Schedule").selectOption("everyDay");
  await expect(page.getByLabel("Keep visible until handled", { exact: false })).toBeHidden();
  await saveEditor(page);

  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  saved = cached.items.find((item) => item.title === title);
  expect(saved.missedBehavior).toBe("markMissed");
  expect(saved.scheduleRevision).toBe(2);
  expect(saved.carryoverStartDate).toBe(todayKey());
  expect(saved.occurrences[revisionZeroOccurrenceID]).toEqual({
    outcome: "missed",
    completionCount: 0,
    resolvedDate: todayKey(),
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: todayKey()
  });
  const revisionOneOccurrenceID = occurrenceIDFor(saved.id, 1, todayKey());
  expect(saved.occurrences[revisionOneOccurrenceID]).toEqual({
    outcome: "missed",
    completionCount: 0,
    resolvedDate: todayKey(),
    hiddenUntil: null,
    scheduleRevision: 1,
    scheduledDate: todayKey()
  });

  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await page.getByRole("button", { name: "End item" }).click();
  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  saved = cached.items.find((item) => item.title === title);
  expect(saved.endedAt).toBeTruthy();
  expect(saved.scheduleRevision).toBe(3);
});

test("creates, previews, syncs, and edits advanced recurrence offline", async ({ page }) => {
  const title = `E2E month-end close ${Date.now()}`;
  const anchorDate = "2024-01-31";
  const ordinalAnchorDate = "2024-01-01";
  await signIn(page);
  await page.getByRole("button", { name: "Add checklist item" }).click();
  await page.getByLabel("Title").fill(title);
  await page.getByLabel("Schedule").selectOption("monthlyDay");
  await expect(page.getByLabel("Every", { exact: true })).toHaveValue("1");
  await expect(page.getByRole("spinbutton", { name: "Day of month" })).toHaveValue(String(new Date().getDate()));
  await page.getByLabel("Every", { exact: true }).fill("2");
  await page.getByRole("spinbutton", { name: "Day of month" }).fill("31");
  await page.getByLabel("Anchor date").fill(anchorDate);
  await page.getByLabel("Start date").fill(todayKey());

  await expect(page.locator("[data-schedule-summary]")).toHaveText(
    "Every 2 months on day 31 (last day in shorter months)"
  );
  const preview = page.locator("[data-schedule-dates]");
  await expect(preview.locator("span")).toHaveCount(5);
  await expect(page.getByLabel("Keep visible until handled", { exact: false })).toBeChecked();

  await saveEditor(page);
  await page.getByRole("button", { name: "All items" }).click();
  await expect(task(page, title)).toContainText("Every 2 months on day 31");

  let cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  let saved = cached.items.find((item) => item.title === title);
  expect(saved.schedule).toBe("custom");
  expect(saved.customWeekdays).toEqual([]);
  expect(saved.recurrence).toEqual({
    kind: "monthlyDay",
    interval: 2,
    anchorDate,
    dayOfMonth: 31
  });
  expect(saved.scheduleRevision).toBe(0);
  expect(saved.missedBehavior).toBe("keepUntilDone");

  await page.evaluate(() => {
    window.name = "preserve-e2e-storage";
    sessionStorage.clear();
  });
  await page.route("**/auth/refresh", (route) => route.fulfill({
    status: 503,
    contentType: "application/json",
    body: JSON.stringify({ error: "Offline for recurrence cache test" })
  }));
  await page.reload();

  await expect(page.getByRole("heading", { name: "Ritual Cue" })).toBeVisible();
  await page.getByRole("button", { name: "All items" }).click();
  await expect(task(page, title)).toContainText("Every 2 months on day 31");
  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await expect(page.getByLabel("Schedule")).toHaveValue("monthlyDay");
  await expect(page.getByLabel("Every", { exact: true })).toHaveValue("2");
  await expect(page.getByRole("spinbutton", { name: "Day of month" })).toHaveValue("31");
  await expect(page.getByLabel("Anchor date")).toHaveValue(anchorDate);

  await page.getByLabel("Schedule").selectOption("monthlyOrdinal");
  await page.getByLabel("Every", { exact: true }).fill("1");
  await page.getByRole("combobox", { name: "Occurrence", exact: true }).selectOption("-1");
  await page.getByRole("combobox", { name: "Weekday", exact: true }).selectOption("3");
  await page.getByLabel("Anchor date").fill(ordinalAnchorDate);
  await expect(page.locator("[data-schedule-summary]")).toHaveText("Last Tuesday monthly");
  await page.getByRole("button", { name: "Save" }).click();

  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  saved = cached.items.find((item) => item.title === title);
  expect(saved.recurrence).toEqual({
    kind: "monthlyOrdinal",
    interval: 1,
    anchorDate: ordinalAnchorDate,
    ordinal: -1,
    weekday: 3
  });
  expect(saved.scheduleRevision).toBe(1);
  const pending = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.pending")));
  expect(pending.findLast((entry) => entry.kind === "upsert").item.recurrence).toEqual(saved.recurrence);
});

test("requires a still-open resolution before ending a deferred or paused item", async ({ page }) => {
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1, 12);
  const tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1, 12);
  const todayDate = todayKey();
  const yesterdayDate = todayKeyFor(yesterday);
  const tomorrowDate = todayKeyFor(tomorrow);
  const title = "Replace the air filter";
  const item = {
    id: "end-carryover-item",
    title,
    notes: "Can be handled after the due date",
    schedule: "custom",
    customWeekdays: [yesterday.getDay() + 1],
    reminderMinutes: null,
    quantity: 2,
    completedDates: [],
    completionCounts: { [yesterdayDate]: 1 },
    skippedDates: [],
    openDates: [],
    createdAt: yesterday.toISOString(),
    startDate: yesterday.toISOString(),
    endedAt: null,
    groupID: null,
    sortOrder: 0,
    pauseWindows: [{ startDate: todayDate, endDate: tomorrowDate }],
    scheduleRevision: 0,
    missedBehavior: "keepUntilDone",
    carryoverStartDate: yesterdayDate,
    carryoverResolvedThroughDate: todayDate,
    occurrences: {
      [yesterdayDate]: {
        outcome: "open",
        completionCount: 1,
        resolvedDate: null,
        hiddenUntil: tomorrowDate
      }
    }
  };

  await page.goto("/app");
  await page.route("**/auth/refresh", (route) => route.fulfill({
    status: 503,
    contentType: "application/json",
    body: JSON.stringify({ error: "Offline for local carryover test" })
  }));
  await page.evaluate(({ cachedItem }) => {
    window.name = "preserve-e2e-storage";
    localStorage.setItem("dailyWeb.user", JSON.stringify({
      id: "end-carryover-test-user",
      email: "ending@ritualcue.local",
      name: "Ending Test"
    }));
    localStorage.setItem("dailyWeb.accountID", "end-carryover-test-user");
    localStorage.setItem("dailyWeb.cache", JSON.stringify({ items: [cachedItem], groups: [] }));
    localStorage.setItem("dailyWeb.pending", "[]");
  }, { cachedItem: item });
  await page.reload();

  await expect(page.getByText("Still open", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "All items" }).click();
  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await page.getByLabel("Schedule").selectOption("weekdays");
  await page.getByRole("button", { name: "Save" }).click();
  let cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  const yesterdayOccurrenceID = occurrenceIDFor(item.id, 0, yesterdayDate);
  const edited = cached.items.find((candidate) => candidate.id === item.id);
  expect(edited.scheduleRevision).toBe(1);
  expect(edited.carryoverStartDate).toBe(todayDate);
  expect(edited.occurrences[yesterdayOccurrenceID]).toEqual({
    outcome: "open",
    completionCount: 1,
    resolvedDate: null,
    hiddenUntil: tomorrowDate,
    scheduleRevision: 0,
    scheduledDate: yesterdayDate
  });
  await task(page, title).getByRole("button", { name: `Edit ${title}` }).click();
  await page.getByRole("button", { name: "End item" }).click();
  await expect(page.getByRole("heading", { name: "Handle still-open task?" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Complete latest and end" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Skip overdue and end" })).toBeVisible();
  await page.getByRole("button", { name: "Cancel" }).click();
  await expect(page.getByRole("heading", { name: "Edit item" })).toBeVisible();

  await page.getByLabel("Last day").fill(todayDate);
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("heading", { name: "Handle still-open task?" })).toBeVisible();
  await expect(page.getByText("1 still-open occurrence", { exact: false })).toBeVisible();
  await page.getByRole("button", { name: "Skip overdue and end" }).click();
  cached = await page.evaluate(() => JSON.parse(localStorage.getItem("dailyWeb.cache")));
  const ended = cached.items.find((candidate) => candidate.id === item.id);
  expect(ended.endedAt).toBeTruthy();
  expect(ended.scheduleRevision).toBe(2);
  expect(ended.completedDates).not.toContain(yesterdayDate);
  expect(ended.completionCounts[yesterdayDate]).toBeUndefined();
  expect(ended.skippedDates).toContain(yesterdayDate);
  expect(ended.carryoverResolvedThroughDate).toBe(todayDate);
  expect(ended.occurrences[yesterdayOccurrenceID]).toEqual({
    outcome: "skipped",
    completionCount: 0,
    resolvedDate: todayDate,
    hiddenUntil: null,
    scheduleRevision: 0,
    scheduledDate: yesterdayDate
  });
});

test("covers create, edit, complete, skip, export, and delete-account flows", async ({ page }) => {
  const suffix = Date.now();
  const originalTitle = `E2E vitamins ${suffix}`;
  const editedTitle = `E2E morning vitamins ${suffix}`;
  const skippedTitle = `E2E stretch ${suffix}`;

  await signIn(page);
  await createItem(page, originalTitle, { notes: "Before breakfast", quantity: 3 });

  await task(page, originalTitle).getByRole("button", { name: `Edit ${originalTitle}` }).click();
  await expect(page.getByRole("heading", { name: "Edit item" })).toBeVisible();
  await page.getByLabel("Title").fill(editedTitle);
  await page.getByLabel("Notes").fill("After breakfast");
  await saveEditor(page);
  await expect(task(page, editedTitle)).toBeVisible();

  for (let count = 1; count <= 3; count += 1) {
    await Promise.all([
      waitForSync(page),
      task(page, editedTitle).getByRole("button", { name: "Mark complete" }).click()
    ]);
  }
  await expect(page.getByText("Completed", { exact: true })).toBeVisible();
  await expect(task(page, editedTitle).getByRole("button", { name: "Mark incomplete" })).toBeVisible();

  await createItem(page, skippedTitle, { notes: "Evening mobility" });
  await Promise.all([
    waitForSync(page),
    task(page, skippedTitle).getByRole("button", { name: "Skip" }).click()
  ]);
  await expect(page.getByText("Skipped", { exact: true })).toBeVisible();
  await expect(task(page, skippedTitle).getByText("Skipped today")).toBeVisible();

  await page.getByRole("button", { name: "Account" }).click();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: /^Export data/ }).click();
  const download = await downloadPromise;
  const path = await download.path();
  expect(path).toBeTruthy();

  const exported = JSON.parse(fs.readFileSync(path, "utf8"));
  const edited = exported.checklist.items.find((item) => item.title === editedTitle);
  const skipped = exported.checklist.items.find((item) => item.title === skippedTitle);
  expect(edited.notes).toBe("After breakfast");
  expect(edited.quantity).toBe(3);
  expect(edited.completedDates).toContain(todayKey());
  expect(skipped.skippedDates).toContain(todayKey());

  page.once("dialog", async (dialog) => {
    expect(dialog.message()).toContain("Delete your Ritual Cue account");
    await dialog.accept();
  });
  await page.getByRole("button", { name: /^Delete account/ }).click();
  await expect(page.getByRole("heading", { name: "Keep your day in sync" })).toBeVisible();
});
