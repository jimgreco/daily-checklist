const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const jwt = require("jsonwebtoken");
const { OAuth2Client } = require("google-auth-library");
const appleSignin = require("apple-signin-auth");

const port = Number(process.env.PORT || 8787);
const dataFile = process.env.DATA_FILE || path.join(__dirname, "..", "data", "database.json");
const sessionSecret = process.env.SESSION_SECRET || "daily-local-development-secret-change-me";
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);
const webRoot = path.join(__dirname, "..", "web");
let writeQueue = Promise.resolve();

function emptyDatabase() {
  return { users: {}, identities: {}, sessions: {}, accounts: {} };
}

async function readDatabase() {
  try {
    return { ...emptyDatabase(), ...JSON.parse(await fs.readFile(dataFile, "utf8")) };
  } catch (error) {
    if (error.code === "ENOENT") return emptyDatabase();
    throw error;
  }
}

async function updateDatabase(operation) {
  const result = writeQueue.then(async () => {
    const database = await readDatabase();
    const value = await operation(database);
    await fs.mkdir(path.dirname(dataFile), { recursive: true });
    const temporary = `${dataFile}.${crypto.randomUUID()}.tmp`;
    await fs.writeFile(temporary, JSON.stringify(database, null, 2));
    await fs.rename(temporary, dataFile);
    return value;
  });
  writeQueue = result.catch(() => {});
  return result;
}

function send(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(body === undefined ? "" : JSON.stringify(body));
}

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8"
};

async function sendWebFile(response, relativePath) {
  const resolved = path.resolve(webRoot, relativePath);
  if (!resolved.startsWith(`${path.resolve(webRoot)}${path.sep}`)) return false;
  try {
    const body = await fs.readFile(resolved);
    response.writeHead(200, {
      "content-type": contentTypes[path.extname(resolved)] || "application/octet-stream",
      "cache-control": path.basename(resolved) === "index.html" ? "no-cache" : "public, max-age=300",
      "x-content-type-options": "nosniff"
    });
    response.end(body);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

async function readJSON(request) {
  let raw = "";
  for await (const chunk of request) {
    raw += chunk;
    if (raw.length > 2_000_000) throw Object.assign(new Error("Payload too large"), { status: 413 });
  }
  try {
    return JSON.parse(raw || "{}");
  } catch {
    throw Object.assign(new Error("Invalid JSON"), { status: 400 });
  }
}

function hash(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function newID() {
  return crypto.randomUUID();
}

function issueAccessToken(user, sessionID) {
  return jwt.sign(
    { userId: user.id, email: user.email, sessionId: sessionID },
    sessionSecret,
    { expiresIn: "15m", issuer: "daily-api", audience: "daily-ios" }
  );
}

function createSession(database, user) {
  const sessionID = newID();
  const refreshToken = crypto.randomBytes(48).toString("base64url");
  database.sessions[hash(refreshToken)] = {
    id: sessionID,
    userId: user.id,
    expiresAt: new Date(Date.now() + 90 * 86400_000).toISOString()
  };
  return { token: issueAccessToken(user, sessionID), refreshToken, user };
}

function upsertUser(database, provider, providerID, profile) {
  const identityKey = `${provider}:${providerID}`;
  let user = database.users[database.identities[identityKey]];
  if (!user) {
    user = {
      id: newID(),
      email: profile.email.toLowerCase(),
      name: profile.name || profile.email,
      createdAt: new Date().toISOString()
    };
    database.users[user.id] = user;
    database.identities[identityKey] = user.id;
  } else {
    user.email = profile.email.toLowerCase();
    if (profile.name) user.name = profile.name;
  }
  return user;
}

function authenticate(request) {
  const match = request.headers.authorization?.match(/^Bearer (.+)$/);
  if (!match) return null;
  try {
    return jwt.verify(match[1], sessionSecret, { issuer: "daily-api", audience: "daily-ios" });
  } catch {
    return null;
  }
}

function stampWins(incoming, current) {
  if (!current) return true;
  if (incoming.stamp !== current.stamp) return incoming.stamp > current.stamp;
  return incoming.deviceID > current.deviceID;
}

const itemFields = ["title", "notes", "schedule", "customWeekdays", "reminderMinutes", "createdAt", "startDate", "endedAt", "groupID", "sortOrder"];
const groupFields = ["name", "sortOrder"];

function applyMutation(account, mutation, deviceID) {
  if (!mutation?.id || !mutation.kind || !mutation.stamp) return false;
  account.appliedMutations ||= {};
  if (account.appliedMutations[mutation.id]) return true;
  account.appliedMutations[mutation.id] = mutation.stamp;

  if (mutation.kind === "eveningReminder") {
    const incoming = {
      value: mutation.eveningReminderMinutes ?? null,
      stamp: mutation.stamp,
      deviceID
    };
    if (stampWins(incoming, account.eveningReminder)) account.eveningReminder = incoming;
    return true;
  }

  if (mutation.kind === "groupUpsert" && mutation.groupID && mutation.group) {
    account.groups ||= {};
    const record = account.groups[mutation.groupID] ||= { id: mutation.groupID, fields: {} };
    const changed = new Set(mutation.changedFields || groupFields);
    for (const field of groupFields) {
      if (!changed.has(field)) continue;
      const incoming = {
        value: mutation.group[field] ?? null,
        stamp: mutation.stamp,
        deviceID
      };
      if (stampWins(incoming, record.fields[field])) record.fields[field] = incoming;
    }
    return true;
  }

  if (!mutation.itemID) return false;
  account.items ||= {};
  const record = account.items[mutation.itemID] ||= { id: mutation.itemID, fields: {}, completions: {} };

  if (mutation.kind === "delete") {
    const incoming = { stamp: mutation.stamp, deviceID };
    if (stampWins(incoming, record.deleted)) record.deleted = incoming;
    return true;
  }

  // Deletions are permanent tombstones. An unaware stale device cannot recreate an item.
  if (record.deleted) return true;

  if (mutation.kind === "completion" && mutation.completionDate) {
    const incoming = {
      value: Boolean(mutation.completed),
      stamp: mutation.stamp,
      deviceID
    };
    if (stampWins(incoming, record.completions[mutation.completionDate])) {
      record.completions[mutation.completionDate] = incoming;
    }
    return true;
  }

  if (mutation.kind === "upsert" && mutation.item) {
    const changed = new Set(mutation.changedFields || itemFields);
    for (const field of itemFields) {
      if (!changed.has(field)) continue;
      const incoming = {
        value: mutation.item[field] ?? null,
        stamp: mutation.stamp,
        deviceID
      };
      if (stampWins(incoming, record.fields[field])) record.fields[field] = incoming;
    }
    return true;
  }
  return false;
}

function materializeAccount(account) {
  const items = Object.values(account.items || {})
    .filter((record) => !record.deleted)
    .map((record) => {
      const value = {};
      for (const field of itemFields) value[field] = record.fields[field]?.value ?? null;
      return {
        id: record.id,
        title: value.title || "Untitled",
        notes: value.notes || "",
        schedule: value.schedule || "everyDay",
        customWeekdays: value.customWeekdays || [],
        reminderMinutes: value.reminderMinutes,
        startDate: value.startDate,
        endedAt: value.endedAt,
        groupID: value.groupID,
        sortOrder: value.sortOrder,
        completedDates: Object.entries(record.completions || {})
          .filter(([, state]) => state.value)
          .map(([date]) => date),
        createdAt: value.createdAt || new Date().toISOString()
      };
    })
    .sort((left, right) => {
      if (left.sortOrder != null && right.sortOrder != null && left.sortOrder !== right.sortOrder) {
        return left.sortOrder - right.sortOrder;
      }
      if (left.sortOrder != null) return -1;
      if (right.sortOrder != null) return 1;
      return left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id);
    });
  const groups = Object.values(account.groups || {})
    .map((record) => ({
      id: record.id,
      name: record.fields.name?.value || "Untitled group",
      sortOrder: record.fields.sortOrder?.value ?? 0
    }))
    .sort((left, right) => left.sortOrder - right.sortOrder || left.name.localeCompare(right.name));
  return {
    items,
    groups,
    eveningReminderMinutes: account.eveningReminder?.value ?? 1200
  };
}

function validSyncRequest(body) {
  return body
    && typeof body.deviceID === "string"
    && /^[a-z0-9-]{8,80}$/i.test(body.deviceID)
    && Array.isArray(body.mutations)
    && body.mutations.length <= 5000;
}

async function handleAuth(request, response, pathname) {
  const body = request.method === "POST" ? await readJSON(request) : {};

  if (pathname === "/auth/config" && request.method === "GET") {
    return send(response, 200, {
      google_client_id: process.env.GOOGLE_WEB_CLIENT_ID?.trim() || null,
      apple_client_id: process.env.APPLE_WEB_CLIENT_ID?.trim() || null
    });
  }

  if (pathname === "/auth/dev" && request.method === "POST") {
    if (process.env.NODE_ENV === "production") return send(response, 404, { error: "Not found" });
    const auth = await updateDatabase((database) => {
      const user = upsertUser(database, "dev", body.email || "dev@daily.local", {
        email: body.email || "dev@daily.local",
        name: body.name || "Local Dev"
      });
      return createSession(database, user);
    });
    return send(response, 200, auth);
  }

  if (pathname === "/auth/google" && request.method === "POST") {
    if (!body.idToken) return send(response, 400, { error: "idToken required" });
    const audiences = [process.env.GOOGLE_CLIENT_ID, process.env.GOOGLE_WEB_CLIENT_ID].filter(Boolean);
    if (!audiences.length) return send(response, 503, { error: "Google Sign-In is not configured" });
    const ticket = await googleClient.verifyIdToken({ idToken: body.idToken, audience: audiences });
    const payload = ticket.getPayload();
    if (!payload?.sub || !payload.email) return send(response, 401, { error: "Invalid Google token" });
    const auth = await updateDatabase((database) => {
      const user = upsertUser(database, "google", payload.sub, {
        email: payload.email,
        name: payload.name || payload.email
      });
      return createSession(database, user);
    });
    return send(response, 200, auth);
  }

  if (pathname === "/auth/apple" && request.method === "POST") {
    if (!body.identityToken) return send(response, 400, { error: "identityToken required" });
    const audiences = [process.env.APPLE_BUNDLE_ID, process.env.APPLE_WEB_CLIENT_ID].filter(Boolean);
    if (!audiences.length) return send(response, 503, { error: "Apple Sign-In is not configured" });
    let payload;
    for (const audience of audiences) {
      try {
        payload = await appleSignin.verifyIdToken(body.identityToken, { audience, ignoreExpiration: false });
        break;
      } catch {}
    }
    if (!payload?.sub) return send(response, 401, { error: "Invalid Apple token" });
    const email = payload.email || `${payload.sub}@privaterelay.appleid.com`;
    const providedName = [body.fullName?.givenName, body.fullName?.familyName].filter(Boolean).join(" ");
    const auth = await updateDatabase((database) => {
      const user = upsertUser(database, "apple", payload.sub, { email, name: providedName || email });
      return createSession(database, user);
    });
    return send(response, 200, auth);
  }

  if (pathname === "/auth/refresh" && request.method === "POST") {
    const tokenHash = hash(body.refreshToken || "");
    const auth = await updateDatabase((database) => {
      const session = database.sessions[tokenHash];
      if (!session || session.expiresAt < new Date().toISOString()) return null;
      delete database.sessions[tokenHash];
      const user = database.users[session.userId];
      return user ? createSession(database, user) : null;
    });
    return auth ? send(response, 200, auth) : send(response, 401, { error: "Invalid refresh token" });
  }

  if (pathname === "/auth/me" && request.method === "GET") {
    const claims = authenticate(request);
    if (!claims) return send(response, 401, { error: "Unauthorized" });
    const database = await readDatabase();
    const user = database.users[claims.userId];
    return user ? send(response, 200, user) : send(response, 404, { error: "User not found" });
  }
  return false;
}

const server = http.createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (request.method === "GET" && pathname === "/health") {
      return send(response, 200, { ok: true });
    }
    if (pathname.startsWith("/auth/")) {
      const handled = await handleAuth(request, response, pathname);
      if (handled !== false) return;
    }
    if (request.method === "POST" && pathname === "/api/sync") {
      const claims = authenticate(request);
      if (!claims) return send(response, 401, { error: "Unauthorized" });
      const body = await readJSON(request);
      if (!validSyncRequest(body)) return send(response, 422, { error: "Invalid sync request" });
      const result = await updateDatabase((database) => {
        const account = database.accounts[claims.userId] ||= {
          items: {},
          groups: {},
          appliedMutations: {},
          eveningReminder: null
        };
        const acceptedMutationIDs = [];
        for (const mutation of body.mutations) {
          if (applyMutation(account, mutation, body.deviceID)) acceptedMutationIDs.push(mutation.id);
        }
        return { ...materializeAccount(account), acceptedMutationIDs };
      });
      return send(response, 200, result);
    }
    if (request.method === "GET") {
      const relativePath = pathname === "/" ? "index.html" : pathname.slice(1);
      if (await sendWebFile(response, relativePath)) return;
    }
    return send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    return send(response, error.status || 500, { error: error.message || "Internal server error" });
  }
});

if (require.main === module) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`Daily server listening on http://0.0.0.0:${port}`);
  });
}

module.exports = {
  server,
  applyMutation,
  materializeAccount,
  validSyncRequest,
  stampWins
};
