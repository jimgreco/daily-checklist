const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../web/app.js"), "utf8");

function editorFixture() {
  const context = vm.createContext({
    state: { selectedDate: new Date(2026, 9, 20) },
    quantity: item => item.quantity || 1,
    scheduleModeForItem: item => item.schedule || "everyDay",
    normalizedRecurrence: value => value ? structuredClone(value) : null,
    normalizedFollowUpPolicy: value => value ? structuredClone(value) : null,
  });
  vm.runInContext(source.slice(source.indexOf("  function startOfDay("), source.indexOf("  const recurrenceOrdinals")), context);
  vm.runInContext(source.slice(source.indexOf("  function duplicateDraft("), source.indexOf("  function updateFollowUpControls(")), context);
  return context;
}

test("editing a routine without an explicit start keeps its implicit creation boundary", () => {
  const context = editorFixture();
  const values = context.editorValues({
    id: "older-routine", title: "Vitamins", createdAt: "2026-06-01T12:00:00.000Z", startDate: null,
  });
  assert.equal(values.start, "");
  assert.equal(context.localISO(values.start), null);
});

test("a new routine still starts on the day being browsed", () => {
  assert.equal(editorFixture().editorValues(null).start, "2026-10-20");
});

test("editing an explicit start date retains its local calendar day", () => {
  const context = editorFixture();
  const date = new Date(2026, 5, 1);
  assert.equal(context.editorValues({ startDate: date.toISOString() }).start, "2026-06-01");
});

function saveFixture() {
  const context = editorFixture();
  const item = {
    id: "routine", title: "Vitamins", notes: "", schedule: "everyDay", customWeekdays: [],
    recurrence: null, reminderMinutes: null, followUpPolicy: null, quantity: 3,
    completedDates: [], completionCounts: {}, skippedDates: [], openDates: [],
    createdAt: "2026-06-01T12:00:00.000Z", startDate: null, endedAt: null,
    groupID: null, sortOrder: 0, pauseWindows: [], scheduleRevision: 0,
    missedBehavior: "markMissed", carryoverStartDate: null,
    carryoverResolvedThroughDate: null, occurrences: {},
  };
  const queued = [];
  Object.assign(context, {
    structuredClone,
    FormData: class { constructor(form) { this.values = form.values; } get(key) { return this.values[key] ?? null; } },
    recurrenceFromForm: () => null,
    normalizedScheduleRevision: value => value || 0,
    mutation: (kind, values) => ({ kind, ...values }),
    queue: value => queued.push(value),
    render() {}, persistData() {}, sync() {}, showToast() {},
  });
  Object.assign(context.state, { items: [item], groups: [], modal: { type: "editor", item: structuredClone(item) } });
  vm.runInContext(source.slice(source.indexOf("  function saveEditor("), source.indexOf('  app.addEventListener("click"')), context);
  const form = {
    values: { title: "Vitamins", notes: "", schedule: "everyDay", quantity: "3", startDate: "", endDate: "" },
    querySelectorAll: () => [],
  };
  return { context, item, form, queued };
}

test("browser editor keeps progress received by sync after the editor opened", () => {
  const { context, item, form, queued } = saveFixture();
  context.state.items = [{
    ...item, completedDates: ["2026-10-19"], completionCounts: { "2026-10-19": 3 },
    skippedDates: ["2026-10-18"], openDates: ["2026-10-17"],
    occurrences: { "routine:0:2026-10-19": { outcome: "done", completionCount: 3 } },
  }];
  form.values.title = "Morning vitamins";
  context.saveEditor(form);
  const saved = context.state.items[0];
  assert.equal(saved.title, "Morning vitamins");
  assert.equal(saved.completionCounts["2026-10-19"], 3);
  assert.deepEqual(saved.completedDates, ["2026-10-19"]);
  assert.deepEqual(saved.skippedDates, ["2026-10-18"]);
  assert.deepEqual(saved.openDates, ["2026-10-17"]);
  assert.equal(saved.occurrences["routine:0:2026-10-19"].outcome, "done");
  assert.equal(JSON.stringify(queued[0].changedFields), '["title"]');
});

test("saving an unchanged editor does not rewrite synced fields", () => {
  const { context, form, queued } = saveFixture();
  context.saveEditor(form);
  assert.equal(queued.length, 0);
  assert.equal(context.state.modal, null);
});

test("a stale editor cannot recreate an item removed by sync", () => {
  const { context, form, queued } = saveFixture();
  context.state.items = [];
  context.saveEditor(form);
  assert.equal(context.state.items.length, 0);
  assert.equal(queued.length, 0);
  assert.equal(context.state.modal, null);
});

test("duplicate draft preserves setup but resets old dates and carries no identity or history", () => {
  const context = editorFixture();
  const now = new Date(2026, 9, 28, 9, 30);
  const original = {
    id: "source", title: "Water herbs", notes: "Kitchen plants", schedule: "custom", customWeekdays: [2, 5],
    recurrence: { kind: "interval", interval: 2, unit: "week", anchorDate: "2026-06-01" },
    reminderMinutes: 540, followUpPolicy: { delayMinutes: 60, maximumCount: 2 }, quantity: 3,
    groupID: "home", missedBehavior: "keepUntilDone", createdAt: "2026-01-01T12:00:00Z",
    startDate: "2026-01-01T12:00:00Z", endedAt: "2026-10-01T12:00:00Z",
    completedDates: ["2026-09-30"], completionCounts: { "2026-09-30": 3 },
    skippedDates: ["2026-09-28"], openDates: ["2026-09-27"], pauseWindows: [{ startDate: "2026-10-01" }],
    scheduleRevision: 7, carryoverStartDate: "2026-01-01", carryoverResolvedThroughDate: "2026-09-30",
    occurrences: { old: { outcome: "done", completionCount: 3 } }, sortOrder: 10,
  };
  const before = structuredClone(original);
  const draft = context.duplicateDraft(original, now);
  assert.equal(draft.title, "Water herbs (copy)");
  assert.equal(draft.startDate, new Date(2026, 9, 28).toISOString());
  for (const key of ["notes", "schedule", "reminderMinutes", "quantity", "groupID", "missedBehavior"]) {
    assert.equal(draft[key], original[key]);
  }
  for (const key of ["customWeekdays", "recurrence", "followUpPolicy"]) {
    assert.equal(JSON.stringify(draft[key]), JSON.stringify(original[key]));
    assert.notEqual(draft[key], original[key]);
  }
  for (const key of ["id", "createdAt", "endedAt", "completedDates", "completionCounts", "skippedDates", "openDates", "pauseWindows", "scheduleRevision", "carryoverStartDate", "carryoverResolvedThroughDate", "occurrences", "sortOrder"]) {
    assert.equal(draft[key], undefined, key);
  }
  assert.equal(context.editorValues(draft).start, "2026-10-28");
  assert.equal(context.editorValues(draft).end, "");
  assert.deepEqual(original, before);
});

test("saving a duplicate creates a fresh item and queues only the copy", () => {
  const { context, item, form, queued } = saveFixture();
  const before = structuredClone(item);
  context.crypto = { randomUUID: () => "new-routine" };
  const draft = context.duplicateDraft(item, new Date(2026, 9, 28));
  context.state.modal = { type: "editor", item: null, draft };
  assert.equal(context.state.items.length, 1);
  assert.equal(queued.length, 0);
  Object.assign(form.values, { title: draft.title, startDate: context.editorValues(draft).start });
  context.saveEditor(form);
  const copy = context.state.items[1];
  assert.equal(copy.id, "new-routine");
  assert.equal(copy.title, "Vitamins (copy)");
  assert.equal(copy.startDate, new Date(2026, 9, 28).toISOString());
  assert.equal(copy.endedAt, null);
  assert.equal(copy.scheduleRevision, 0);
  for (const key of ["completedDates", "skippedDates", "openDates", "pauseWindows"]) {
    assert.equal(JSON.stringify(copy[key]), "[]");
  }
  for (const key of ["completionCounts", "occurrences"]) assert.equal(JSON.stringify(copy[key]), "{}");
  assert.equal(queued.length, 1);
  assert.equal(queued[0].kind, "upsert");
  assert.equal(queued[0].itemID, "new-routine");
  assert.deepEqual(context.state.items[0], before);
});

test("duplicate title stays within the editor limit and daily copies disable carryover", () => {
  const draft = editorFixture().duplicateDraft({ title: "a".repeat(120), schedule: "everyDay", missedBehavior: "keepUntilDone" });
  assert.equal(draft.title.length, 120);
  assert.ok(draft.title.endsWith(" (copy)"));
  assert.equal(draft.missedBehavior, "markMissed");
  const emojiDraft = editorFixture().duplicateDraft({ title: "🌱".repeat(60), schedule: "everyDay" });
  assert.equal(emojiDraft.title, "🌱".repeat(56) + " (copy)");
  assert.ok(emojiDraft.title.length <= 120);
});
