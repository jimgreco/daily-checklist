const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  applyMutation,
  clientIP,
  appleWebAuthConfigured,
  cleanupStaleSessions,
  createSession,
  rateLimit,
  materializeAccount,
  refreshCookieMaxAgeSeconds,
  refreshSessionLifetimeSeconds,
  resetRateLimits,
  rotateRefreshSession,
  trustedProxyHops,
  upsertUser,
  validSyncRequest,
  stampWins
} = require("../src/server");
const { hasData } = require("../src/migrate-json-to-postgres");

let listener;
let baseURL;

function restoreEnv(name, value) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

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

async function devLogin(email, name = "Test User") {
  const response = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, name })
  });
  assert.equal(response.status, 200);
  const auth = await response.json();
  return {
    ...auth,
    cookie: response.headers.get("set-cookie")
  };
}

async function syncResponse(token, deviceID, mutations) {
  return fetch(`${baseURL}/api/sync`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`
    },
    body: JSON.stringify({ deviceID, mutations })
  });
}

async function syncDevice(token, deviceID, mutations = []) {
  const response = await syncResponse(token, deviceID, mutations);
  assert.equal(response.status, 200);
  return response.json();
}

test("serves the public landing page, web app, and auth configuration", async () => {
  const landing = await fetch(`${baseURL}/`);
  assert.equal(landing.status, 200);
  assert.match(landing.headers.get("content-type"), /^text\/html/);
  assert.match(landing.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.equal(landing.headers.get("x-frame-options"), "DENY");
  const landingHTML = await landing.text();
  assert.match(landingHTML, /Keep recurring routines from slipping/);
  assert.match(landingHTML, /href="\/app"/);
  assert.match(landingHTML, /https:\/\/apps\.apple\.com\/us\/app\/ritual-cue\/id6784239049/);

  const app = await fetch(`${baseURL}/app`);
  assert.equal(app.status, 200);
  assert.match(app.headers.get("content-type"), /^text\/html/);
  assert.match(await app.text(), /Ritual Cue/);

  const admin = await fetch(`${baseURL}/admin`);
  assert.equal(admin.status, 200);
  assert.match(admin.headers.get("content-type"), /^text\/html/);
  const adminHTML = await admin.text();
  assert.match(adminHTML, /Ritual Cue Admin/);
  assert.match(adminHTML, /https:\/\/accounts\.google\.com\/gsi\/client/);
  assert.match(adminHTML, /admin\.js\?v=20260705-admin-user-detail/);

  const config = await fetch(`${baseURL}/auth/config`);
  assert.equal(config.status, 200);
  assert.deepEqual(await config.json(), {
    google_client_id: null,
    apple_client_id: null
  });
});

test("serves public privacy and support pages", async () => {
  const privacy = await fetch(`${baseURL}/privacy.html`);
  assert.equal(privacy.status, 200);
  assert.match(privacy.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.match(await privacy.text(), /Ritual Cue does not sell personal data/);

  const support = await fetch(`${baseURL}/support.html`);
  assert.equal(support.status, 200);
  assert.match(support.headers.get("x-content-type-options"), /nosniff/);
  assert.match(await support.text(), /Privacy Requests/);
});

test("monitor sync probe requires its shared secret and leaves no checklist data behind", async () => {
  const previousMonitorToken = process.env.DAILY_MONITOR_TOKEN;
  process.env.DAILY_MONITOR_TOKEN = "test-monitor-secret";

  try {
    const rejected = await fetch(`${baseURL}/api/monitor/sync`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({})
    });
    assert.equal(rejected.status, 404);

    const response = await fetch(`${baseURL}/api/monitor/sync`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-ritual-cue-monitor-token": "test-monitor-secret"
      },
      body: JSON.stringify({})
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      acceptedMutationCount: 1,
      itemCount: 0,
      groupCount: 0
    });
  } finally {
    restoreEnv("DAILY_MONITOR_TOKEN", previousMonitorToken);
  }
});

test("monitor sync probe accepts the monitor header when no runtime token is configured", async () => {
  const previousMonitorToken = process.env.DAILY_MONITOR_TOKEN;
  delete process.env.DAILY_MONITOR_TOKEN;

  try {
    const rejected = await fetch(`${baseURL}/api/monitor/sync`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({})
    });
    assert.equal(rejected.status, 404);

    const response = await fetch(`${baseURL}/api/monitor/sync`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-ritual-cue-monitor-token": "repo-secret-held-by-actions"
      },
      body: JSON.stringify({})
    });
    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.ok, true);
    assert.equal(payload.acceptedMutationCount, 1);
    assert.equal(payload.itemCount, 0);
  } finally {
    restoreEnv("DAILY_MONITOR_TOKEN", previousMonitorToken);
  }
});

test("rate limits use direct addresses unless trusted proxy hops are explicit", () => {
  const previousTrustProxy = process.env.TRUST_PROXY;
  const previousTrustProxyHops = process.env.TRUST_PROXY_HOPS;
  const socketAddress = "198.51.100.10";

  try {
    delete process.env.TRUST_PROXY;
    delete process.env.TRUST_PROXY_HOPS;
    const directRequest = {
      headers: { "x-forwarded-for": "203.0.113.5" },
      socket: { remoteAddress: socketAddress }
    };
    assert.equal(trustedProxyHops(), 0);
    assert.equal(clientIP(directRequest), socketAddress);

    const directKey = `direct-${crypto.randomUUID()}`;
    assert.equal(rateLimit(directRequest, directKey, { limit: 1, windowMs: 60_000 }), null);
    assert.ok(rateLimit({
      headers: { "x-forwarded-for": "203.0.113.99" },
      socket: { remoteAddress: socketAddress }
    }, directKey, { limit: 1, windowMs: 60_000 }) > 0);

    process.env.TRUST_PROXY_HOPS = "1";
    const forwardedRequest = {
      headers: { "x-forwarded-for": "203.0.113.5, 198.51.100.20" },
      socket: { remoteAddress: "10.0.0.5" }
    };
    assert.equal(trustedProxyHops(), 1);
    assert.equal(clientIP(forwardedRequest), "198.51.100.20");

    const forwardedKey = `forwarded-${crypto.randomUUID()}`;
    assert.equal(rateLimit(forwardedRequest, forwardedKey, { limit: 1, windowMs: 60_000 }), null);
    assert.ok(rateLimit({
      headers: { "x-forwarded-for": "203.0.113.200, 198.51.100.20" },
      socket: { remoteAddress: "10.0.0.5" }
    }, forwardedKey, { limit: 1, windowMs: 60_000 }) > 0);

    delete process.env.TRUST_PROXY_HOPS;
    process.env.TRUST_PROXY = "true";
    assert.equal(trustedProxyHops(), 1);
    assert.equal(clientIP(forwardedRequest), "198.51.100.20");
  } finally {
    restoreEnv("TRUST_PROXY", previousTrustProxy);
    restoreEnv("TRUST_PROXY_HOPS", previousTrustProxyHops);
  }
});

test("dev sign-in sets an HttpOnly refresh cookie and logout clears it", async () => {
  const response = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "cookie-test@ritualcue.local", name: "Cookie Test" })
  });
  assert.equal(response.status, 200);
  const cookie = response.headers.get("set-cookie");
  assert.match(cookie, /daily_refresh=/);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Lax/);
  assert.match(cookie, new RegExp(`Max-Age=${refreshCookieMaxAgeSeconds}`));

  const logout = await fetch(`${baseURL}/auth/logout`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie
    },
    body: JSON.stringify({})
  });
  assert.equal(logout.status, 204);
  assert.match(logout.headers.get("set-cookie"), /Max-Age=0/);
});

test("refresh sessions rotate inside a bounded rolling 90-day window", () => {
  const now = Date.parse("2026-07-13T12:00:00.000Z");
  assert.equal(refreshSessionLifetimeSeconds, 90 * 86400);
  const database = { users: {}, identities: {}, sessions: {}, accounts: {} };
  const user = { id: "rolling-user", email: "rolling@ritualcue.local", name: "Rolling User" };
  database.users[user.id] = user;

  const created = createSession(database, user, now);
  const originalHash = crypto.createHash("sha256").update(created.refreshToken).digest("hex");
  assert.equal(
    database.sessions[originalHash].expiresAt,
    new Date(now + refreshSessionLifetimeSeconds * 1000).toISOString()
  );

  const refreshedAt = now + 30 * 86400 * 1000;
  const rotated = rotateRefreshSession(database, created.refreshToken, refreshedAt);
  assert.ok(rotated?.token);
  assert.equal(database.sessions[originalHash], undefined);
  const rotatedHash = crypto.createHash("sha256").update(rotated.refreshToken).digest("hex");
  assert.equal(
    database.sessions[rotatedHash].expiresAt,
    new Date(refreshedAt + refreshSessionLifetimeSeconds * 1000).toISOString()
  );
});

test("expired, disabled, deleted, and malformed refresh sessions are rejected and removed", () => {
  const now = Date.parse("2026-07-13T12:00:00.000Z");
  const cases = [
    {
      token: "expired-token",
      user: { id: "expired-user", email: "expired@ritualcue.local" },
      sessionUserID: "expired-user",
      expiresAt: new Date(now - 1).toISOString()
    },
    {
      token: "disabled-token",
      user: { id: "disabled-user", email: "disabled@ritualcue.local", disabledAt: new Date(now).toISOString() },
      sessionUserID: "disabled-user",
      expiresAt: new Date(now + 1000).toISOString()
    },
    {
      token: "deleted-token",
      user: null,
      sessionUserID: "deleted-user",
      expiresAt: new Date(now + 1000).toISOString()
    },
    {
      token: "malformed-token",
      user: { id: "malformed-user", email: "malformed@ritualcue.local" },
      sessionUserID: "malformed-user",
      expiresAt: "not-a-date"
    }
  ];

  for (const entry of cases) {
    const tokenHash = crypto.createHash("sha256").update(entry.token).digest("hex");
    const database = {
      users: entry.user ? { [entry.user.id]: entry.user } : {},
      identities: {},
      sessions: {
        [tokenHash]: { id: `${entry.sessionUserID}-session`, userId: entry.sessionUserID, expiresAt: entry.expiresAt }
      },
      accounts: {}
    };
    assert.equal(rotateRefreshSession(database, entry.token, now), null);
    assert.deepEqual(database.sessions, {});
  }
});

test("legacy non-expiring sessions gain a bounded expiry without forcing reauthentication", () => {
  const now = Date.parse("2026-07-13T12:00:00.000Z");
  const database = {
    users: { legacy: { id: "legacy", email: "legacy@ritualcue.local" } },
    identities: {},
    sessions: { legacyToken: { id: "legacy-session", userId: "legacy", expiresAt: null } },
    accounts: {}
  };

  assert.deepEqual(cleanupStaleSessions(database, now), { removed: 0, bounded: 1 });
  assert.equal(
    database.sessions.legacyToken.expiresAt,
    new Date(now + refreshSessionLifetimeSeconds * 1000).toISOString()
  );
});

test("cookie-backed refresh and logout reject cross-origin browser requests", async () => {
  const tlsTerminatedOrigin = `https://${new URL(baseURL).host}`;
  const refreshLogin = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `refresh-${crypto.randomUUID()}@ritualcue.local`, name: "Refresh Guard" })
  });
  assert.equal(refreshLogin.status, 200);
  const refreshCookie = refreshLogin.headers.get("set-cookie");

  const rejectedRefresh = await fetch(`${baseURL}/auth/refresh`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie: refreshCookie,
      origin: "https://evil.example"
    },
    body: JSON.stringify({})
  });
  assert.equal(rejectedRefresh.status, 403);
  assert.deepEqual(await rejectedRefresh.json(), { error: "Forbidden" });

  const sameOriginRefresh = await fetch(`${baseURL}/auth/refresh`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie: refreshCookie,
      origin: tlsTerminatedOrigin
    },
    body: JSON.stringify({})
  });
  assert.equal(sameOriginRefresh.status, 200);
  assert.match(sameOriginRefresh.headers.get("set-cookie"), /daily_refresh=/);

  const logoutLogin = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `logout-${crypto.randomUUID()}@ritualcue.local`, name: "Logout Guard" })
  });
  assert.equal(logoutLogin.status, 200);
  const logoutCookie = logoutLogin.headers.get("set-cookie");

  const rejectedLogout = await fetch(`${baseURL}/auth/logout`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie: logoutCookie,
      origin: "https://evil.example"
    },
    body: JSON.stringify({})
  });
  assert.equal(rejectedLogout.status, 403);
  assert.deepEqual(await rejectedLogout.json(), { error: "Forbidden" });

  const sameOriginLogout = await fetch(`${baseURL}/auth/logout`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie: logoutCookie,
      origin: baseURL
    },
    body: JSON.stringify({})
  });
  assert.equal(sameOriginLogout.status, 204);
  assert.match(sameOriginLogout.headers.get("set-cookie"), /Max-Age=0/);
});

test("JSON refresh tokens keep working for native clients without cookie-backed CSRF state", async () => {
  const login = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `native-${crypto.randomUUID()}@ritualcue.local`, name: "Native Guard" })
  });
  assert.equal(login.status, 200);
  const auth = await login.json();

  const refresh = await fetch(`${baseURL}/auth/refresh`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://evil.example"
    },
    body: JSON.stringify({ refreshToken: auth.refreshToken })
  });
  assert.equal(refresh.status, 200);
  assert.ok((await refresh.json()).token);
});

test("daily admin emails are additive with generic admin emails", async () => {
  const previousAdminEmails = process.env.ADMIN_EMAILS;
  const previousDailyAdminEmails = process.env.DAILY_ADMIN_EMAILS;
  process.env.ADMIN_EMAILS = "other-admin@ritualcue.local";
  process.env.DAILY_ADMIN_EMAILS = " jgreco@gmail.com ";

  try {
    const login = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "jgreco@gmail.com", name: "Jim Greco" })
    });
    assert.equal(login.status, 200);
    const auth = await login.json();

    const overview = await fetch(`${baseURL}/api/admin/overview`, {
      headers: { authorization: `Bearer ${auth.token}` }
    });
    assert.equal(overview.status, 200);
    const payload = await overview.json();
    assert.ok(payload.users.some((user) => user.email === "jgreco@gmail.com" && user.isAdmin));
  } finally {
    restoreEnv("ADMIN_EMAILS", previousAdminEmails);
    restoreEnv("DAILY_ADMIN_EMAILS", previousDailyAdminEmails);
  }
});

test("jgreco@gmail.com is a default admin", async () => {
  const previousAdminEmails = process.env.ADMIN_EMAILS;
  const previousDailyAdminEmails = process.env.DAILY_ADMIN_EMAILS;
  delete process.env.ADMIN_EMAILS;
  delete process.env.DAILY_ADMIN_EMAILS;

  try {
    const login = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "jgreco@gmail.com", name: "Jim Greco" })
    });
    assert.equal(login.status, 200);
    const auth = await login.json();

    const overview = await fetch(`${baseURL}/api/admin/overview`, {
      headers: { authorization: `Bearer ${auth.token}` }
    });
    assert.equal(overview.status, 200);
  } finally {
    restoreEnv("ADMIN_EMAILS", previousAdminEmails);
    restoreEnv("DAILY_ADMIN_EMAILS", previousDailyAdminEmails);
  }
});

test("admin users can view stats and disable viewer accounts", async () => {
  const suffix = crypto.randomUUID();
  const adminEmail = `admin-${suffix}@ritualcue.local`;
  const viewerEmail = `viewer-${suffix}@ritualcue.local`;
  const previousAdminEmails = process.env.ADMIN_EMAILS;
  process.env.ADMIN_EMAILS = adminEmail;

  try {
    const adminLogin = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: adminEmail, name: "Admin User" })
    });
    assert.equal(adminLogin.status, 200);
    const adminAuth = await adminLogin.json();

    const viewerLogin = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: viewerEmail, name: "Viewer User" })
    });
    assert.equal(viewerLogin.status, 200);
    const viewerCookie = viewerLogin.headers.get("set-cookie");
    const viewerAuth = await viewerLogin.json();

    const forbidden = await fetch(`${baseURL}/api/admin/overview`, {
      headers: { authorization: `Bearer ${viewerAuth.token}` }
    });
    assert.equal(forbidden.status, 403);

    const forbiddenDetail = await fetch(`${baseURL}/api/admin/users/${viewerAuth.user.id}`, {
      headers: { authorization: `Bearer ${viewerAuth.token}` }
    });
    assert.equal(forbiddenDetail.status, 403);

    const forbiddenReenable = await fetch(`${baseURL}/api/admin/users/${viewerAuth.user.id}/reenable`, {
      method: "POST",
      headers: { authorization: `Bearer ${viewerAuth.token}` }
    });
    assert.equal(forbiddenReenable.status, 403);

    const sync = await fetch(`${baseURL}/api/sync`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${viewerAuth.token}`
      },
      body: JSON.stringify({
        deviceID: "viewer-device",
        mutations: [{
          id: `viewer-create-${suffix}`,
          itemID: `viewer-item-${suffix}`,
          kind: "upsert",
          stamp: "2026-07-02T12:00:00.000Z",
          changedFields: ["title", "createdAt"],
          item: { title: "Viewer item", createdAt: "2026-07-02T12:00:00.000Z" }
        }]
      })
    });
    assert.equal(sync.status, 200);

    const overview = await fetch(`${baseURL}/api/admin/overview`, {
      headers: { authorization: `Bearer ${adminAuth.token}` }
    });
    assert.equal(overview.status, 200);
    const payload = await overview.json();
    const viewer = payload.users.find((user) => user.email === viewerEmail);
    assert.ok(viewer);
    assert.equal(viewer.activeItems, 1);
    assert.equal(viewer.sessionCount, 1);
    assert.ok(payload.totals.totalUsers >= 2);

    const detail = await fetch(`${baseURL}/api/admin/users/${viewer.id}`, {
      headers: { authorization: `Bearer ${adminAuth.token}` }
    });
    assert.equal(detail.status, 200);
    const detailPayload = await detail.json();
    assert.equal(detailPayload.email, viewerEmail);
    assert.equal(detailPayload.activeItems, 1);
    assert.equal(detailPayload.sessionCount, 1);
    assert.equal(detailPayload.activeSessionCount, 1);
    assert.equal(detailPayload.providers.includes("dev"), true);
    assert.equal(detailPayload.recentSessions.length, 1);
    assert.equal(Object.hasOwn(detailPayload.recentSessions[0], "id"), false);
    assert.equal(Object.hasOwn(detailPayload.recentSessions[0], "tokenHash"), false);
    assert.deepEqual(detailPayload.auditEvents, []);

    const disabled = await fetch(`${baseURL}/api/admin/users/${viewer.id}/disable`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${adminAuth.token}`
      },
      body: JSON.stringify({ reason: "test disable" })
    });
    assert.equal(disabled.status, 200);
    const disabledPayload = await disabled.json();
    assert.equal(disabledPayload.user.disabledReason, "test disable");
    assert.equal(disabledPayload.user.sessionCount, 0);
    assert.equal(disabledPayload.user.auditEvents[0].type, "disabled");

    const afterDisable = await fetch(`${baseURL}/auth/me`, {
      headers: { authorization: `Bearer ${viewerAuth.token}` }
    });
    assert.equal(afterDisable.status, 403);

    const refresh = await fetch(`${baseURL}/auth/refresh`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        cookie: viewerCookie
      },
      body: JSON.stringify({})
    });
    assert.equal(refresh.status, 401);

    const repeatLogin = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: viewerEmail, name: "Viewer User" })
    });
    assert.equal(repeatLogin.status, 403);

    const reenabled = await fetch(`${baseURL}/api/admin/users/${viewer.id}/reenable`, {
      method: "POST",
      headers: { authorization: `Bearer ${adminAuth.token}` }
    });
    assert.equal(reenabled.status, 200);
    const reenabledPayload = await reenabled.json();
    assert.equal(reenabledPayload.user.disabledAt, null);
    assert.equal(reenabledPayload.user.disabledReason, null);
    assert.equal(reenabledPayload.user.reenabledBy, adminEmail);
    assert.ok(reenabledPayload.user.reenabledAt);
    assert.equal(reenabledPayload.user.auditEvents[0].type, "reenabled");
    assert.equal(reenabledPayload.user.auditEvents[1].type, "disabled");

    const afterReenableLogin = await fetch(`${baseURL}/auth/dev`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: viewerEmail, name: "Viewer User" })
    });
    assert.equal(afterReenableLogin.status, 200);
    const afterReenableAuth = await afterReenableLogin.json();
    const afterReenableMe = await fetch(`${baseURL}/auth/me`, {
      headers: { authorization: `Bearer ${afterReenableAuth.token}` }
    });
    assert.equal(afterReenableMe.status, 200);
  } finally {
    restoreEnv("ADMIN_EMAILS", previousAdminEmails);
    resetRateLimits();
  }
});

test("authenticated users can export and delete account data", async () => {
  const login = await fetch(`${baseURL}/auth/dev`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "privacy-test@ritualcue.local", name: "Privacy Test" })
  });
  assert.equal(login.status, 200);
  const auth = await login.json();
  const sync = await fetch(`${baseURL}/api/sync`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${auth.token}`
    },
    body: JSON.stringify({
      deviceID: "privacy-device",
      mutations: [{
        id: "privacy-create",
        itemID: "privacy-item",
        kind: "upsert",
        stamp: "2026-06-30T12:00:00.000Z",
        changedFields: ["title", "createdAt"],
        item: { title: "Export me", createdAt: "2026-06-30T12:00:00.000Z" }
      }]
    })
  });
  assert.equal(sync.status, 200);

  const exported = await fetch(`${baseURL}/api/export`, {
    headers: { authorization: `Bearer ${auth.token}` }
  });
  assert.equal(exported.status, 200);
  assert.match(exported.headers.get("content-disposition"), /ritual-cue-export\.json/);
  assert.equal((await exported.json()).checklist.items[0].title, "Export me");

  const deleted = await fetch(`${baseURL}/api/account`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${auth.token}` }
  });
  assert.equal(deleted.status, 204);

  const afterDelete = await fetch(`${baseURL}/auth/me`, {
    headers: { authorization: `Bearer ${auth.token}` }
  });
  assert.equal(afterDelete.status, 404);
});

test("authenticated users can import valid exports and reject malformed exports", async () => {
  const auth = await devLogin(`import-test-${Date.now()}@ritualcue.local`, "Import Test");
  await syncDevice(auth.token, "import-device", [{
    id: "import-old-create",
    itemID: "11111111-1111-4111-8111-111111111111",
    kind: "upsert",
    stamp: "2026-07-05T12:00:00.000Z",
    changedFields: ["title", "createdAt"],
    item: { title: "Replace me", createdAt: "2026-07-05T12:00:00.000Z" }
  }]);

  const malformed = await fetch(`${baseURL}/api/import`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${auth.token}`
    },
    body: JSON.stringify({ checklist: { items: "not-an-array" } })
  });
  assert.equal(malformed.status, 422);
  assert.match((await malformed.json()).error, /Invalid Ritual Cue export/);

  const restored = await fetch(`${baseURL}/api/import`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${auth.token}`
    },
    body: JSON.stringify({
      exportedAt: "2026-07-06T12:00:00.000Z",
      user: { id: "ignored", email: "ignored@example.com", name: "Ignored" },
      checklist: {
        groups: [{
          id: "22222222-2222-4222-8222-222222222222",
          name: "Restored Group",
          sortOrder: 1,
          isCollapsed: false,
          pauseWindows: []
        }],
        items: [{
          id: "33333333-3333-4333-8333-333333333333",
          title: "Restore me",
          notes: "Imported note",
          schedule: "everyDay",
          customWeekdays: [],
          reminderMinutes: 540,
          quantity: 2,
          completedDates: [],
          completionCounts: { "2026-07-06": 1 },
          skippedDates: [],
          openDates: [],
          createdAt: "2026-07-06T12:00:00.000Z",
          startDate: null,
          endedAt: null,
          groupID: "22222222-2222-4222-8222-222222222222",
          sortOrder: 1,
          pauseWindows: []
        }],
        eveningReminderMinutes: 1170,
        notificationGroupFilter: {
          mode: "include",
          groupIDs: ["22222222-2222-4222-8222-222222222222"]
        }
      }
    })
  });
  assert.equal(restored.status, 200);
  const imported = await restored.json();
  assert.deepEqual(imported.acceptedMutationIDs, []);
  assert.equal(imported.items.length, 1);
  assert.equal(imported.items[0].title, "Restore me");
  assert.equal(imported.items[0].completionCounts["2026-07-06"], 1);
  assert.equal(imported.groups[0].name, "Restored Group");
  assert.equal(imported.eveningReminderMinutes, 1170);
  assert.deepEqual(imported.notificationGroupFilter, {
    mode: "include",
    groupIDs: ["22222222-2222-4222-8222-222222222222"]
  });

  const synced = await syncDevice(auth.token, "import-viewer");
  assert.equal(synced.items.length, 1);
  assert.equal(synced.items[0].title, "Restore me");
  assert.deepEqual(synced.notificationGroupFilter, imported.notificationGroupFilter);
  assert.equal(synced.items.some((item) => item.title === "Replace me"), false);
});

test("two-client sync merges offline conflicts and preserves deletion tombstones", async () => {
  resetRateLimits();
  const suffix = crypto.randomUUID();
  const auth = await devLogin(`sync-${suffix}@ritualcue.local`, "Sync Test");
  const groupID = `group-${suffix}`;
  const itemID = `item-${suffix}`;
  const completionDate = "2026-07-10";

  const created = await syncDevice(auth.token, "sync-device-a", [
    {
      id: `create-group-${suffix}`,
      groupID,
      kind: "groupUpsert",
      stamp: "2026-07-10T10:00:00.000Z",
      changedFields: ["name", "sortOrder", "isCollapsed"],
      group: { name: "Home", sortOrder: 0, isCollapsed: false }
    },
    {
      id: `create-item-${suffix}`,
      itemID,
      kind: "upsert",
      stamp: "2026-07-10T10:01:00.000Z",
      changedFields: [
        "title", "notes", "schedule", "customWeekdays", "reminderMinutes",
        "quantity", "createdAt", "groupID", "sortOrder", "skippedDates",
        "openDates", "pauseWindows"
      ],
      item: {
        title: "Water plants",
        notes: "Kitchen shelf",
        schedule: "everyDay",
        customWeekdays: [],
        reminderMinutes: null,
        quantity: 3,
        createdAt: "2026-07-10T09:00:00.000Z",
        groupID,
        sortOrder: 0,
        skippedDates: [],
        openDates: [],
        pauseWindows: []
      }
    }
  ]);
  assert.equal(created.acceptedMutationIDs.length, 2);

  const initialDeviceB = await syncDevice(auth.token, "sync-device-b");
  assert.equal(initialDeviceB.items[0].title, "Water plants");
  assert.equal(initialDeviceB.groups[0].name, "Home");

  await syncDevice(auth.token, "sync-device-a", [
    {
      id: `device-a-title-${suffix}`,
      itemID,
      kind: "upsert",
      stamp: "2026-07-10T10:03:00.000Z",
      changedFields: ["title"],
      item: { title: "Water balcony plants" }
    },
    {
      id: `device-a-group-name-${suffix}`,
      groupID,
      kind: "groupUpsert",
      stamp: "2026-07-10T10:04:00.000Z",
      changedFields: ["name"],
      group: { name: "Plant care" }
    },
    {
      id: `device-a-partial-${suffix}`,
      itemID,
      kind: "completion",
      stamp: "2026-07-10T10:05:00.000Z",
      completionDate,
      completed: false,
      completionCount: 2
    }
  ]);

  const mergedDeviceB = await syncDevice(auth.token, "sync-device-b", [
    {
      id: `device-b-stale-title-${suffix}`,
      itemID,
      kind: "upsert",
      stamp: "2026-07-10T10:02:00.000Z",
      changedFields: ["title"],
      item: { title: "Water stale plants" }
    },
    {
      id: `device-b-group-collapse-${suffix}`,
      groupID,
      kind: "groupUpsert",
      stamp: "2026-07-10T10:04:00.000Z",
      changedFields: ["isCollapsed"],
      group: { isCollapsed: true }
    },
    {
      id: `device-b-stale-partial-${suffix}`,
      itemID,
      kind: "completion",
      stamp: "2026-07-10T10:04:30.000Z",
      completionDate,
      completed: false,
      completionCount: 1
    }
  ]);

  assert.equal(mergedDeviceB.items.length, 1);
  assert.equal(mergedDeviceB.items[0].title, "Water balcony plants");
  assert.deepEqual(mergedDeviceB.items[0].completionCounts, { [completionDate]: 2 });
  assert.deepEqual(mergedDeviceB.items[0].completedDates, []);
  assert.equal(mergedDeviceB.groups[0].name, "Plant care");
  assert.equal(mergedDeviceB.groups[0].isCollapsed, true);

  const mergedDeviceA = await syncDevice(auth.token, "sync-device-a");
  assert.deepEqual(mergedDeviceA.items, mergedDeviceB.items);
  assert.deepEqual(mergedDeviceA.groups, mergedDeviceB.groups);

  await syncDevice(auth.token, "sync-device-a", [
    {
      id: `delete-item-${suffix}`,
      itemID,
      kind: "delete",
      stamp: "2026-07-10T10:06:00.000Z"
    },
    {
      id: `delete-group-${suffix}`,
      groupID,
      kind: "groupDelete",
      stamp: "2026-07-10T10:06:00.000Z"
    }
  ]);

  const afterStaleResurrection = await syncDevice(auth.token, "sync-device-b", [
    {
      id: `resurrect-item-${suffix}`,
      itemID,
      kind: "upsert",
      stamp: "2026-07-10T10:07:00.000Z",
      changedFields: ["title"],
      item: { title: "Resurrected plant task" }
    },
    {
      id: `resurrect-group-${suffix}`,
      groupID,
      kind: "groupUpsert",
      stamp: "2026-07-10T10:07:00.000Z",
      changedFields: ["name"],
      group: { name: "Resurrected group" }
    }
  ]);

  assert.deepEqual(afterStaleResurrection.items, []);
  assert.deepEqual(afterStaleResurrection.groups, []);
});

test("two-client sync rejects deleted and disabled account sessions", async () => {
  resetRateLimits();
  const deleteSuffix = crypto.randomUUID();
  const deleteEmail = `delete-sync-${deleteSuffix}@ritualcue.local`;
  const deleteDeviceA = await devLogin(deleteEmail, "Delete Sync");
  const deleteDeviceB = await devLogin(deleteEmail, "Delete Sync");

  await syncDevice(deleteDeviceA.token, "delete-device-a", [{
    id: `delete-sync-create-${deleteSuffix}`,
    itemID: `delete-sync-item-${deleteSuffix}`,
    kind: "upsert",
    stamp: "2026-07-10T11:00:00.000Z",
    changedFields: ["title", "createdAt"],
    item: {
      title: "Delete me",
      createdAt: "2026-07-10T11:00:00.000Z"
    }
  }]);

  const deleted = await fetch(`${baseURL}/api/account`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${deleteDeviceA.token}` }
  });
  assert.equal(deleted.status, 204);

  const afterDelete = await syncResponse(deleteDeviceB.token, "delete-device-b", []);
  assert.equal(afterDelete.status, 404);
  assert.deepEqual(await afterDelete.json(), { error: "User not found" });

  const disableSuffix = crypto.randomUUID();
  const adminEmail = `disable-admin-${disableSuffix}@ritualcue.local`;
  const viewerEmail = `disable-viewer-${disableSuffix}@ritualcue.local`;
  const previousAdminEmails = process.env.ADMIN_EMAILS;
  process.env.ADMIN_EMAILS = adminEmail;

  try {
    const admin = await devLogin(adminEmail, "Disable Admin");
    const viewerDeviceA = await devLogin(viewerEmail, "Disable Viewer");
    const viewerDeviceB = await devLogin(viewerEmail, "Disable Viewer");

    await syncDevice(viewerDeviceA.token, "disabled-device-a", [{
      id: `disabled-sync-create-${disableSuffix}`,
      itemID: `disabled-sync-item-${disableSuffix}`,
      kind: "upsert",
      stamp: "2026-07-10T12:00:00.000Z",
      changedFields: ["title", "createdAt"],
      item: {
        title: "Disable me",
        createdAt: "2026-07-10T12:00:00.000Z"
      }
    }]);

    const disabled = await fetch(`${baseURL}/api/admin/users/${viewerDeviceA.user.id}/disable`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${admin.token}`
      },
      body: JSON.stringify({ reason: "sync integration test" })
    });
    assert.equal(disabled.status, 200);

    const afterDisable = await syncResponse(viewerDeviceB.token, "disabled-device-b", []);
    assert.equal(afterDisable.status, 403);
    assert.deepEqual(await afterDisable.json(), { error: "Account disabled" });
  } finally {
    restoreEnv("ADMIN_EMAILS", previousAdminEmails);
    resetRateLimits();
  }
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
  return { items: {}, groups: {}, appliedMutations: {}, eveningReminder: null, notificationGroupFilter: null };
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
  assert.equal(validSyncRequest({
    deviceID: "device-1234",
    mutations: [{
      id: "filter-ok",
      kind: "notificationGroupFilter",
      stamp: "2026-07-12T10:00:00.000Z",
      notificationGroupFilter: { mode: "exclude", groupIDs: ["group-a"] }
    }]
  }), true);
  assert.equal(validSyncRequest({
    deviceID: "device-1234",
    mutations: [{
      id: "filter-bad-mode",
      kind: "notificationGroupFilter",
      stamp: "2026-07-12T10:00:00.000Z",
      notificationGroupFilter: { mode: "sometimes", groupIDs: ["group-a"] }
    }]
  }), false);
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

test("completion counts materialize partial quantity progress", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title", "quantity"],
    item: { title: "Vitamins", quantity: 3 }
  }, "device-a");
  applyMutation(state, {
    id: "partial",
    itemID: "item-1",
    kind: "completion",
    stamp: "2026-06-24T12:00:00.000Z",
    completionDate: "2026-06-24",
    completed: false,
    completionCount: 2
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.equal(item.quantity, 3);
  assert.deepEqual(item.completedDates, []);
  assert.deepEqual(item.completionCounts, { "2026-06-24": 2 });
});

test("skipped dates sync independently from completion history", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title", "skippedDates"],
    item: { title: "Pills", skippedDates: ["2026-06-24"] }
  }, "device-a");
  applyMutation(state, {
    id: "done",
    itemID: "item-1",
    kind: "completion",
    stamp: "2026-06-24T12:00:00.000Z",
    completionDate: "2026-06-25",
    completed: true
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.deepEqual(item.skippedDates, ["2026-06-24"]);
  assert.deepEqual(item.completedDates, ["2026-06-25"]);
});

test("open dates sync independently from completion and skip history", () => {
  const state = account();
  applyMutation(state, {
    id: "create",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T10:00:00.000Z",
    changedFields: ["title", "openDates"],
    item: { title: "Pills", openDates: ["2026-06-24"] }
  }, "device-a");
  applyMutation(state, {
    id: "skip",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-24T12:00:00.000Z",
    changedFields: ["skippedDates"],
    item: { skippedDates: ["2026-06-25"] }
  }, "device-a");

  const item = materializeAccount(state).items[0];
  assert.deepEqual(item.openDates, ["2026-06-24"]);
  assert.deepEqual(item.skippedDates, ["2026-06-25"]);
});

test("rejects invalid skipped date payloads", () => {
  assert.equal(validSyncRequest({
    deviceID: "device-1234",
    mutations: [{
      id: "bad-skip",
      itemID: "item-1",
      kind: "upsert",
      stamp: "2026-06-24T10:00:00.000Z",
      changedFields: ["skippedDates"],
      item: { skippedDates: ["06/24/2026"] }
    }]
  }), false);
});

test("rejects invalid open date payloads", () => {
  assert.equal(validSyncRequest({
    deviceID: "device-1234",
    mutations: [{
      id: "bad-open",
      itemID: "item-1",
      kind: "upsert",
      stamp: "2026-06-24T10:00:00.000Z",
      changedFields: ["openDates"],
      item: { openDates: ["06/24/2026"] }
    }]
  }), false);
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

test("group collapsed state syncs independently", () => {
  const state = account();
  applyMutation(state, {
    id: "group-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["name", "sortOrder"],
    group: { name: "Home", sortOrder: 0 }
  }, "device-a");
  applyMutation(state, {
    id: "collapse-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:05:00.000Z",
    changedFields: ["isCollapsed"],
    group: { isCollapsed: true }
  }, "device-b");

  const group = materializeAccount(state).groups[0];
  assert.equal(group.name, "Home");
  assert.equal(group.sortOrder, 0);
  assert.equal(group.isCollapsed, true);
});

test("pause windows sync for items and groups", () => {
  const state = account();
  applyMutation(state, {
    id: "group-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["name", "pauseWindows"],
    group: {
      name: "Home",
      pauseWindows: [{ startDate: "2026-07-10", endDate: "2026-07-16" }]
    }
  }, "device-a");
  applyMutation(state, {
    id: "item-1",
    itemID: "item-1",
    kind: "upsert",
    stamp: "2026-06-25T10:01:00.000Z",
    changedFields: ["title", "groupID", "pauseWindows"],
    item: {
      title: "Water plants",
      groupID: "group-home",
      pauseWindows: [{ startDate: "2026-07-11", endDate: "2026-07-11" }]
    }
  }, "device-a");

  const materialized = materializeAccount(state);
  assert.deepEqual(materialized.groups[0].pauseWindows, [{ startDate: "2026-07-10", endDate: "2026-07-16" }]);
  assert.deepEqual(materialized.items[0].pauseWindows, [{ startDate: "2026-07-11", endDate: "2026-07-11" }]);
});

test("group deletions tombstone empty groups", () => {
  const state = account();
  applyMutation(state, {
    id: "group-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:00:00.000Z",
    changedFields: ["name", "sortOrder"],
    group: { name: "Home", sortOrder: 0 }
  }, "device-a");
  applyMutation(state, {
    id: "delete-home",
    groupID: "group-home",
    kind: "groupDelete",
    stamp: "2026-06-25T10:01:00.000Z"
  }, "device-a");
  applyMutation(state, {
    id: "stale-rename-home",
    groupID: "group-home",
    kind: "groupUpsert",
    stamp: "2026-06-25T10:00:30.000Z",
    changedFields: ["name"],
    group: { name: "House", sortOrder: 0 }
  }, "device-b");

  assert.deepEqual(materializeAccount(state).groups, []);
});

test("notification group filter syncs with last-writer wins", () => {
  const state = account();
  applyMutation(state, {
    id: "filter-include",
    kind: "notificationGroupFilter",
    stamp: "2026-07-12T10:00:00.000Z",
    notificationGroupFilter: { mode: "include", groupIDs: ["group-morning"] }
  }, "device-a");
  applyMutation(state, {
    id: "filter-exclude",
    kind: "notificationGroupFilter",
    stamp: "2026-07-12T10:05:00.000Z",
    notificationGroupFilter: { mode: "exclude", groupIDs: ["group-night", "group-morning", "group-night"] }
  }, "device-b");
  applyMutation(state, {
    id: "filter-stale",
    kind: "notificationGroupFilter",
    stamp: "2026-07-12T10:01:00.000Z",
    notificationGroupFilter: { mode: "all", groupIDs: ["group-stale"] }
  }, "device-a");

  assert.deepEqual(materializeAccount(state).notificationGroupFilter, {
    mode: "exclude",
    groupIDs: ["group-morning", "group-night"]
  });
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

test("JSON migration data detection protects existing Postgres state", () => {
  assert.equal(hasData({ users: {}, identities: {}, sessions: {}, accounts: {} }), false);
  assert.equal(hasData({ users: { user: { id: "user" } }, identities: {}, sessions: {}, accounts: {} }), true);
  assert.equal(hasData({ users: {}, identities: {}, sessions: {}, accounts: { user: { items: {} } } }), true);
});
