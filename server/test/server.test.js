const test = require("node:test");
const assert = require("node:assert/strict");
const {
  applyMutation,
  materializeAccount,
  validSyncRequest,
  stampWins
} = require("../src/server");

function account() {
  return { items: {}, appliedMutations: {}, eveningReminder: null };
}

test("validates a sync request", () => {
  assert.equal(validSyncRequest({ deviceID: "device-1234", mutations: [] }), true);
  assert.equal(validSyncRequest({ deviceID: "../bad", mutations: [] }), false);
});

test("field-level merging preserves unrelated offline edits", () => {
  const state = account();
  applyMutation(state, {
    id: "m1",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title", "notes", "schedule", "customWeekdays", "reminderMinutes", "createdAt"],
    item: {
      title: "Walk dog",
      notes: "",
      schedule: "everyDay",
      customWeekdays: [],
      reminderMinutes: null,
      createdAt: "2026-06-24T09:00:00.000Z"
    }
  }, "device-a");
  applyMutation(state, {
    id: "m2",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T11:00:00.000Z",
    changedFields: ["notes"],
    item: { notes: "Bring bags" }
  }, "device-b");
  applyMutation(state, {
    id: "m3",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T11:01:00.000Z",
    changedFields: ["title"],
    item: { title: "Walk Pepper" }
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.equal(item.title, "Walk Pepper");
  assert.equal(item.notes, "Bring bags");
});

test("completion conflicts resolve per date", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title"],
    item: { title: "Pills" }
  }, "device-a");
  applyMutation(state, {
    id: "done",
    itemID: "item-1",
    kind: "completion",
    stamp: "2026-06-24T12:00:00.000Z",
    completionDate: "2026-06-24",
    completed: true
  }, "device-a");
  applyMutation(state, {
    id: "old-undone",
    itemID: "item-1",
    kind: "completion",
    stamp: "2026-06-24T11:00:00.000Z",
    completionDate: "2026-06-24",
    completed: false
  }, "device-b");

  assert.deepEqual(materializeAccount(state).items[0].completedDates, ["2026-06-24"]);
});

test("deletion tombstones prevent stale-device resurrection", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title"],
    item: { title: "Pills" }
  }, "device-a");
  applyMutation(state, {
    id: "delete",
    itemID: "item-1",
    kind: "delete",
    stamp: "2026-06-24T11:00:00.000Z"
  }, "device-a");
  applyMutation(state, {
    id: "stale-edit",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-25T11:00:00.000Z",
    changedFields: ["title"],
    item: { title: "Resurrected" }
  }, "device-b");

  assert.equal(materializeAccount(state).items.length, 0);
});

test("ending an item preserves it for historical dates", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title", "createdAt"],
    item: {
      title: "Pills",
      createdAt: "2026-06-20T09:00:00.000Z"
    }
  }, "device-a");
  applyMutation(state, {
    id: "end",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["endedAt"],
    item: { endedAt: "2026-06-25T04:00:00.000Z" }
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.equal(item.title, "Pills");
  assert.equal(item.endedAt, "2026-06-25T04:00:00.000Z");
});

test("optional active dates sync with the item", () => {
  const state = account();
  applyMutation(state, {
    id: "create-dated",
    itemID: "item-dated",
    kind: "upsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["title", "createdAt", "startDate", "endedAt"],
    item: {
      title: "Physical therapy",
      createdAt: "2026-06-25T09:00:00.000Z",
      startDate: "2026-07-01T04:00:00.000Z",
      endedAt: "2026-07-15T04:00:00.000Z"
    }
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.equal(item.startDate, "2026-07-01T04:00:00.000Z");
  assert.equal(item.endedAt, "2026-07-15T04:00:00.000Z");
});

test("groups and item membership are synced and ordered", () => {
  const state = account();
  applyMutation(state, {
    id: "group-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["name", "sortOrder"],
    group: { name: "Home", sortOrder: 1 }
  }, "device-a");
  applyMutation(state, {
    id: "group-morning",
    groupID: "group-morning",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:01:00.000Z",
    changedFields: ["name", "sortOrder"],
    group: { name: "Morning", sortOrder: 0 }
  }, "device-a");
  applyMutation(state, {
    id: "grouped-item",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-25T10:02:00.000Z",
    changedFields: ["title", "groupID", "sortOrder"],
    item: { title: "Take vitamins", groupID: "group-morning", sortOrder: 0 }
  }, "device-a");

  const materialized = materializeAccount(state);
  assert.deepEqual(materialized.groups.map((group) => group.name), ["Morning", "Home"]);
  assert.equal(materialized.items[0].groupID, "group-morning");
});

test("equal timestamps use device ID as deterministic tie breaker", () => {
  assert.equal(
    stampWins(
      { stamp: "2026-06-24T12:00:00.000Z", deviceID: "device-b" },
      { stamp: "2026-06-24T12:00:00.000Z", deviceID: "device-a" }
    ),
    true
  );
});

test("manual order is merged and materialized consistently", () => {
  const state = account();
  for (const [id, title, order] of [["a", "Second", 1], ["b", "First", 0]]) {
    applyMutation(state, {
      id: `create-${id}`,
      itemID: id,
      kind: "upsert",
      stamp: `2026-06-24T10:00:0${order}.000Z`,
      changedFields: ["title", "sortOrder"],
      item: { title, sortOrder: order }
    }, "device-a");
  }

  assert.deepEqual(materializeAccount(state).items.map((item) => item.title), ["First", "Second"]);
});
