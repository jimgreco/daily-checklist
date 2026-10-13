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
    normalizedRecurrence: value => value || null,
    normalizedFollowUpPolicy: value => value || null,
  });
  vm.runInContext(source.slice(source.indexOf("  function startOfDay("), source.indexOf("  const recurrenceOrdinals")), context);
  vm.runInContext(source.slice(source.indexOf("  function editorValues("), source.indexOf("  function updateFollowUpControls(")), context);
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
