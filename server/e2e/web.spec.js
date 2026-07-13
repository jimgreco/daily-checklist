const fs = require("node:fs");
const { expect, test } = require("@playwright/test");

function todayKey() {
  const date = new Date();
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
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
  expect(persisted.cache.items).toEqual([cachedItem]);
  expect(persisted.pending).toEqual([pendingMutation]);
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
