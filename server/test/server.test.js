const test = require("node:test");
const assert = require("node:assert/strict");
const {
  applyMutation,
  appleWebAuthConfigured,
  materializeAccount,
  upsertUser,
  validSyncRequest,
  stampWins
} = require("../src/server");

let listener;
let baseURL;

test.before(async () => {
  const { server } = require("../src/server");
  await new Promise((resolve) => {
    listener = server.listen(0, "127.0.0.1", () => {
      baseURL = `http://127.0.0.1:${listener.address().port}`;
      resolve();
    });
  });
});

test.after(async () => {
  if (listener) await new Promise((resolve) => listener.close(resolve));
});

test("serves the mobile website and public auth configuration", async () => {
  const page = await fetch(`${baseURL}/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /^text\/html/);
  assert.match(await page.text(), /Daily Checklist/);

  const config = await fetch(`${baseURL}/auth/config`);
  assert.equal(config.status, 200);
  assert.deepEqual(await config.json(), {
    google_client_id: null,
    apple_client_id: null
  });
});

test("Apple web authorization code sign-in requires server credentials", async () => {
  assert.equal(appleWebAuthConfigured(), false);
  const response = await fetch(`${baseURL}/auth/apple`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ authorizationCode: "test-code" })
  });

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "Apple web sign-in is not configured"
  });
});

function account() {
  return { items: {}, appliedMutations: {}, eveningReminder: null };
}

function record(id, title, stamp = "2026-06-28T10:00:00.000Z") {
  return {
    id,
    fields: {
      title: { value: title, stamp, deviceID: "device-a" },
      createdAt: { value: stamp, stamp, deviceID: "device-a" }
    },
    completions: {}
  };
}

test("links new provider identities by verified email", () => {
  const database = { users: {}, identities: {}, sessions: {}, accounts: {} };
  const googleUser = upsertUser(database, "google", "google-123", {
    email: "Jim@example.com",
    name: "Jim Greco",
    profileImageURL: "https://example.com/photo.jpg"
  });
  const appleUser = upsertUser(database, "apple", "apple-456", {
    email: "jim@example.com",
    name: "jim@example.com"
  });

  assert.equal(appleUser.id, googleUser.id);
  assert.equal(database.identities["google:google-123"], googleUser.id);
  assert.equal(database.identities["apple:apple-456"], googleUser.id);
  assert.equal(database.users[googleUser.id].email, "jim@example.com");
  assert.equal(database.users[googleUser.id].name, "Jim Greco");
  assert.equal(database.users[googleUser.id].profileImageURL, "https://example.com/photo.jpg");
});

test("repairs previously split provider accounts with the same email", () => {
  const database = {
    users: {
      google: {
        id: "google",
        email: "jim@example.com",
        name: "Jim Greco",
        profileImageURL: "https://example.com/photo.jpg",
        createdAt: "2026-06-27T10:00:00.000Z"
      },
      apple: {
        id: "apple",
        email: "jim@example.com",
        name: "jim@example.com",
        profileImageURL: null,
        createdAt: "2026-06-28T10:00:00.000Z"
      }
    },
    identities: {
      "google:google-123": "google",
      "apple:apple-456": "apple"
    },
    sessions: {
      appleSession: { id: "apple-session", userId: "apple", expiresAt: "2026-09-28T10:00:00.000Z" }
    },
    accounts: {
      google: { items: { googleItem: record("googleItem", "Google item") }, groups: {}, appliedMutations: {}, eveningReminder: null },
      apple: { items: { appleItem: record("appleItem", "Apple item") }, groups: {}, appliedMutations: {}, eveningReminder: null }
    }
  };

  const user = upsertUser(database, "apple", "apple-456", {
    email: "jim@example.com",
    name: "jim@example.com"
  });

  assert.equal(user.id, "google");
  assert.equal(database.identities["apple:apple-456"], "google");
  assert.equal(database.sessions.appleSession.userId, "google");
  assert.equal(database.users.apple, undefined);
  assert.equal(database.accounts.apple, undefined);
  assert.deepEqual(
    materializeAccount(database.accounts.google).items.map((item) => item.title).sort(),
    ["Apple item", "Google item"]
  );
});

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
