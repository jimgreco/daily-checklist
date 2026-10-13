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
  vm.runInContext(source.slice(source.indexOf("  function startOfDay("), source.indexOf("  function isDateKey(")), context);
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
