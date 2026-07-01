const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const jwt = require("jsonwebtoken");
const { OAuth2Client } = require("google-auth-library");
const appleSignin = require("apple-signin-auth");
const { createStore } = require("./database");

const port = Number(process.env.PORT || 8787);
const sessionSecret = process.env.SESSION_SECRET || "daily-local-development-secret-change-me";
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);
const webRoot = path.join(__dirname, "..", "web");
const store = createStore();
const isProduction = process.env.NODE_ENV === "production";
const refreshCookieName = "daily_refresh";

function securityHeaders() {
  return {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "same-origin",
    "permissions-policy": "camera=(), microphone=(), geolocation=()",
    "cross-origin-opener-policy": "same-origin-allow-popups",
    "content-security-policy": [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "script-src 'self' https://accounts.google.com https://appleid.cdn-apple.com",
      "style-src 'self' 'unsafe-inline' https://accounts.google.com",
      "img-src 'self' https: data:",
      "connect-src 'self'",
      "frame-src https://accounts.google.com https://appleid.apple.com"
    ].join("; ")
  };
}

function send(response, status, body, headers = {}) {
  response.writeHead(status, {
    ...securityHeaders(),
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...headers
  });
  response.end(body === undefined ? "" : JSON.stringify(body));
}

function noContent(response, headers = {}) {
  response.writeHead(204, {
    ...securityHeaders(),
    "cache-control": "no-store",
    ...headers
  });
  response.end();
}

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json; charset=utf-8"
};

async function sendWebFile(response, relativePath) {
  const resolved = path.resolve(webRoot, relativePath);
  if (!resolved.startsWith(`${path.resolve(webRoot)}${path.sep}`)) return false;
  try {
    const body = await fs.readFile(resolved);
    response.writeHead(200, {
      ...securityHeaders(),
      "content-type": contentTypes[path.extname(resolved)] || "application/octet-stream",
      "cache-control": path.basename(resolved) === "index.html" ? "no-cache" : "public, max-age=300"
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

function parseCookies(request) {
  const header = request.headers.cookie || "";
  return Object.fromEntries(header.split(";").map((cookie) => {
    const [name, ...parts] = cookie.trim().split("=");
    return [name, decodeURIComponent(parts.join("=") || "")];
  }).filter(([name]) => name));
}

function serializeCookie(name, value, options = {}) {
  const parts = [`${name}=${encodeURIComponent(value)}`];
  if (options.maxAge != null) parts.push(`Max-Age=${options.maxAge}`);
  parts.push(`Path=${options.path || "/"}`);
  parts.push(`SameSite=${options.sameSite || "Lax"}`);
  if (options.httpOnly !== false) parts.push("HttpOnly");
  if (options.secure !== false && isProduction) parts.push("Secure");
  return parts.join("; ");
}

function refreshCookie(refreshToken) {
  return serializeCookie(refreshCookieName, refreshToken, {
    maxAge: 90 * 86400,
    httpOnly: true,
    sameSite: "Lax"
  });
}

function clearRefreshCookie() {
  return serializeCookie(refreshCookieName, "", {
    maxAge: 0,
    httpOnly: true,
    sameSite: "Lax"
  });
}

const rateBuckets = new Map();

function clientIP(request) {
  if (process.env.TRUST_PROXY === "true") {
    const forwarded = String(request.headers["x-forwarded-for"] || "").split(",")[0].trim();
    if (forwarded) return forwarded;
  }
  return request.socket.remoteAddress || "unknown";
}

function rateLimit(request, key, { limit, windowMs }) {
  const bucketKey = `${key}:${clientIP(request)}`;
  const now = Date.now();
  const bucket = rateBuckets.get(bucketKey);
  if (!bucket || bucket.resetAt <= now) {
    rateBuckets.set(bucketKey, { count: 1, resetAt: now + windowMs });
    return null;
  }
  bucket.count += 1;
  if (bucket.count <= limit) return null;
  return Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
}

function enforceRateLimit(request, response, key, options) {
  const retryAfter = rateLimit(request, key, options);
  if (!retryAfter) return false;
  send(response, 429, { error: "Too many requests. Try again shortly." }, { "retry-after": String(retryAfter) });
  return true;
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

function normalizeEmail(email) {
  return String(email || "").trim().toLowerCase();
}

function safeProfileImageURL(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  try {
    const url = new URL(raw);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function chooseCanonicalUser(users) {
  return users
    .filter(Boolean)
    .sort((left, right) => {
      const leftCreated = left.createdAt || "";
      const rightCreated = right.createdAt || "";
      return leftCreated.localeCompare(rightCreated) || left.id.localeCompare(right.id);
    })[0];
}

function mergeStateMap(target = {}, source = {}) {
  for (const [key, incoming] of Object.entries(source)) {
    if (stampWins(incoming, target[key])) target[key] = incoming;
  }
  return target;
}

function mergeChecklistRecords(target, source) {
  target.fields = mergeStateMap(target.fields, source.fields);
  target.completions = mergeStateMap(target.completions, source.completions);
  if (source.deleted && stampWins(source.deleted, target.deleted)) target.deleted = source.deleted;
  return target;
}

function mergeGroupRecords(target, source) {
  target.fields = mergeStateMap(target.fields, source.fields);
  if (source.deleted && stampWins(source.deleted, target.deleted)) target.deleted = source.deleted;
  return target;
}

function mergeAccount(database, targetUserID, sourceUserID) {
  if (targetUserID === sourceUserID) return;

  const source = database.accounts[sourceUserID];
  if (source) {
    const target = database.accounts[targetUserID] ||= {
      items: {},
      groups: {},
      appliedMutations: {},
      eveningReminder: null
    };
    target.items ||= {};
    target.groups ||= {};
    target.appliedMutations ||= {};

    for (const [itemID, sourceItem] of Object.entries(source.items || {})) {
      target.items[itemID] = target.items[itemID]
        ? mergeChecklistRecords(target.items[itemID], sourceItem)
        : sourceItem;
    }
    for (const [groupID, sourceGroup] of Object.entries(source.groups || {})) {
      target.groups[groupID] = target.groups[groupID]
        ? mergeGroupRecords(target.groups[groupID], sourceGroup)
        : sourceGroup;
    }
    target.appliedMutations = { ...source.appliedMutations, ...target.appliedMutations };
    if (source.eveningReminder && stampWins(source.eveningReminder, target.eveningReminder)) {
      target.eveningReminder = source.eveningReminder;
    }
    delete database.accounts[sourceUserID];
  }

  for (const session of Object.values(database.sessions || {})) {
    if (session.userId === sourceUserID) session.userId = targetUserID;
  }
  for (const [identityKey, userID] of Object.entries(database.identities || {})) {
    if (userID === sourceUserID) database.identities[identityKey] = targetUserID;
  }
  delete database.users[sourceUserID];
}

function updateUserProfile(user, profile, email) {
  const existingNameWasEmail = normalizeEmail(user.name) === normalizeEmail(user.email);
  const profileName = profile.name || "";
  const profileNameIsEmail = normalizeEmail(profileName) === email;
  user.email = email;
  if (!user.name || existingNameWasEmail || (profileName && !profileNameIsEmail)) {
    user.name = profileName || email;
  }
  const profileImageURL = safeProfileImageURL(profile.profileImageURL);
  if (profileImageURL) user.profileImageURL = profileImageURL;
  user.profileImageURL ||= null;
}

function upsertUser(database, provider, providerID, profile) {
  const identityKey = `${provider}:${providerID}`;
  const email = normalizeEmail(profile.email);
  const identityUser = database.users[database.identities[identityKey]];
  const emailUsers = Object.values(database.users).filter((candidate) => normalizeEmail(candidate.email) === email);
  let user = chooseCanonicalUser([...emailUsers, identityUser]);

  if (!user) {
    user = {
      id: newID(),
      email,
      name: profile.name || profile.email,
      profileImageURL: safeProfileImageURL(profile.profileImageURL),
      createdAt: new Date().toISOString()
    };
    database.users[user.id] = user;
  } else {
    updateUserProfile(user, profile, email);
    for (const duplicate of emailUsers) mergeAccount(database, user.id, duplicate.id);
    if (identityUser) mergeAccount(database, user.id, identityUser.id);
  }
  database.identities[identityKey] = user.id;
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

function envValue(name) {
  return process.env[name]?.trim() || "";
}

function appleWebPrivateKey() {
  const privateKey = envValue("APPLE_WEB_PRIVATE_KEY");
  if (privateKey) return privateKey.replace(/\\n/g, "\n");
  const encoded = envValue("APPLE_WEB_PRIVATE_KEY_BASE64");
  if (!encoded) return "";
  try {
    return Buffer.from(encoded, "base64").toString("utf8").trim();
  } catch {
    return "";
  }
}

function appleWebConfig() {
  return {
    clientID: envValue("APPLE_WEB_CLIENT_ID"),
    teamID: envValue("APPLE_TEAM_ID"),
    keyIdentifier: envValue("APPLE_WEB_KEY_ID"),
    privateKey: appleWebPrivateKey(),
    redirectUri: envValue("APPLE_WEB_REDIRECT_URI") || "https://ritualcue.com"
  };
}

function appleWebAuthConfigured() {
  const config = appleWebConfig();
  return Boolean(config.clientID && config.teamID && config.keyIdentifier && config.privateKey);
}

async function exchangeAppleAuthorizationCode(code) {
  const config = appleWebConfig();
  if (!appleWebAuthConfigured()) {
    throw Object.assign(new Error("Apple web sign-in is not configured"), { status: 503, quiet: true });
  }
  const clientSecret = appleSignin.getClientSecret({
    clientID: config.clientID,
    teamID: config.teamID,
    keyIdentifier: config.keyIdentifier,
    privateKey: config.privateKey
  });
  const tokenResponse = await appleSignin.getAuthorizationToken(code, {
    clientID: config.clientID,
    redirectUri: config.redirectUri,
    clientSecret
  });
  if (!tokenResponse?.id_token) {
    console.error("Apple token exchange failed", tokenResponse);
    throw Object.assign(new Error("Invalid Apple authorization code"), { status: 401 });
  }
  return tokenResponse.id_token;
}

function stampWins(incoming, current) {
  if (!current) return true;
  if (incoming.stamp !== current.stamp) return incoming.stamp > current.stamp;
  return incoming.deviceID > current.deviceID;
}

const itemFields = ["title", "notes", "schedule", "customWeekdays", "reminderMinutes", "skippedDates", "createdAt", "startDate", "endedAt", "groupID", "sortOrder"];
const groupFields = ["name", "sortOrder"];

function validID(value) {
  return typeof value === "string" && /^[a-z0-9._:-]{1,120}$/i.test(value);
}

function validISODate(value, { nullable = true } = {}) {
  if (value == null) return nullable;
  return typeof value === "string" && !Number.isNaN(Date.parse(value)) && value.length <= 40;
}

function validDateKey(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function validFiniteNumber(value, { nullable = true, min = -1_000_000, max = 1_000_000 } = {}) {
  if (value == null) return nullable;
  return typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;
}

function validWeekdays(value) {
  return Array.isArray(value)
    && value.length <= 7
    && value.every((day) => Number.isInteger(day) && day >= 1 && day <= 7)
    && new Set(value).size === value.length;
}

function validChangedFields(value, allowed) {
  return value == null || (
    Array.isArray(value)
    && value.length <= allowed.length
    && value.every((field) => allowed.includes(field))
  );
}

function validItemPayload(item = {}) {
  return item && typeof item === "object"
    && (item.title == null || (typeof item.title === "string" && item.title.length <= 120))
    && (item.notes == null || (typeof item.notes === "string" && item.notes.length <= 2000))
    && (item.schedule == null || ["everyDay", "weekdays", "weekends", "custom"].includes(item.schedule))
    && (item.customWeekdays == null || validWeekdays(item.customWeekdays))
    && validFiniteNumber(item.reminderMinutes, { nullable: true, min: 0, max: 1439 })
    && (item.skippedDates == null || (
      Array.isArray(item.skippedDates)
      && item.skippedDates.length <= 5000
      && item.skippedDates.every(validDateKey)
    ))
    && validISODate(item.createdAt)
    && validISODate(item.startDate)
    && validISODate(item.endedAt)
    && (item.groupID == null || validID(item.groupID))
    && validFiniteNumber(item.sortOrder);
}

function validGroupPayload(group = {}) {
  return group && typeof group === "object"
    && (group.name == null || (typeof group.name === "string" && group.name.length <= 120))
    && validFiniteNumber(group.sortOrder);
}

function validMutation(mutation) {
  if (!mutation || typeof mutation !== "object") return false;
  if (!validID(mutation.id) || !validISODate(mutation.stamp, { nullable: false })) return false;
  if (mutation.kind === "eveningReminder") {
    return mutation.eveningReminderMinutes == null
      || (Number.isInteger(mutation.eveningReminderMinutes)
        && mutation.eveningReminderMinutes >= 0
        && mutation.eveningReminderMinutes <= 1439);
  }
  if (mutation.kind === "groupUpsert") {
    return validID(mutation.groupID)
      && validChangedFields(mutation.changedFields, groupFields)
      && validGroupPayload(mutation.group);
  }
  if (mutation.kind === "groupDelete") return validID(mutation.groupID);
  if (!validID(mutation.itemID)) return false;
  if (mutation.kind === "delete") return true;
  if (mutation.kind === "completion") {
    return validDateKey(mutation.completionDate) && typeof mutation.completed === "boolean";
  }
  if (mutation.kind === "upsert") {
    return validChangedFields(mutation.changedFields, itemFields) && validItemPayload(mutation.item);
  }
  return false;
}

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
    if (record.deleted) return true;
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

  if (mutation.kind === "groupDelete" && mutation.groupID) {
    account.groups ||= {};
    const record = account.groups[mutation.groupID] ||= { id: mutation.groupID, fields: {} };
    const incoming = { stamp: mutation.stamp, deviceID };
    if (stampWins(incoming, record.deleted)) record.deleted = incoming;
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
        skippedDates: value.skippedDates || [],
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
    .filter((record) => !record.deleted)
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
    && body.mutations.length <= 5000
    && body.mutations.every(validMutation);
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
    if (enforceRateLimit(request, response, "auth-dev", { limit: 10, windowMs: 15 * 60_000 })) return true;
    if (process.env.NODE_ENV === "production") return send(response, 404, { error: "Not found" });
    const auth = await store.update((database) => {
      const user = upsertUser(database, "dev", body.email || "dev@daily.local", {
        email: body.email || "dev@daily.local",
        name: body.name || "Local Dev"
      });
      return createSession(database, user);
    });
    return send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) });
  }

  if (pathname === "/auth/google" && request.method === "POST") {
    if (enforceRateLimit(request, response, "auth-google", { limit: 20, windowMs: 15 * 60_000 })) return true;
    if (!body.idToken) return send(response, 400, { error: "idToken required" });
    const audiences = [process.env.GOOGLE_CLIENT_ID, process.env.GOOGLE_WEB_CLIENT_ID].filter(Boolean);
    if (!audiences.length) return send(response, 503, { error: "Google Sign-In is not configured" });
    const ticket = await googleClient.verifyIdToken({ idToken: body.idToken, audience: audiences });
    const payload = ticket.getPayload();
    if (!payload?.sub || !payload.email) return send(response, 401, { error: "Invalid Google token" });
    const auth = await store.update((database) => {
      const user = upsertUser(database, "google", payload.sub, {
        email: payload.email,
        name: payload.name || payload.email,
        profileImageURL: payload.picture || body.profileImageURL || null
      });
      return createSession(database, user);
    });
    return send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) });
  }

  if (pathname === "/auth/apple" && request.method === "POST") {
    if (enforceRateLimit(request, response, "auth-apple", { limit: 20, windowMs: 15 * 60_000 })) return true;
    const identityToken = body.identityToken || (body.authorizationCode
      ? await exchangeAppleAuthorizationCode(body.authorizationCode)
      : null);
    if (!identityToken) return send(response, 400, { error: "identityToken or authorizationCode required" });
    const audiences = [process.env.APPLE_BUNDLE_ID, process.env.APPLE_WEB_CLIENT_ID].filter(Boolean);
    if (!audiences.length) return send(response, 503, { error: "Apple Sign-In is not configured" });
    let payload;
    for (const audience of audiences) {
      try {
        payload = await appleSignin.verifyIdToken(identityToken, { audience, ignoreExpiration: false });
        break;
      } catch {}
    }
    if (!payload?.sub) return send(response, 401, { error: "Invalid Apple token" });
    const email = payload.email || `${payload.sub}@privaterelay.appleid.com`;
    const providedName = [body.fullName?.givenName, body.fullName?.familyName].filter(Boolean).join(" ");
    const auth = await store.update((database) => {
      const user = upsertUser(database, "apple", payload.sub, { email, name: providedName || email });
      return createSession(database, user);
    });
    return send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) });
  }

  if (pathname === "/auth/refresh" && request.method === "POST") {
    if (enforceRateLimit(request, response, "auth-refresh", { limit: 60, windowMs: 15 * 60_000 })) return true;
    const cookieToken = parseCookies(request)[refreshCookieName];
    const refreshToken = body.refreshToken || cookieToken || "";
    const tokenHash = hash(refreshToken);
    const auth = await store.update((database) => {
      const session = database.sessions[tokenHash];
      if (!session || session.expiresAt < new Date().toISOString()) return null;
      delete database.sessions[tokenHash];
      const user = database.users[session.userId];
      return user ? createSession(database, user) : null;
    });
    return auth
      ? send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) })
      : send(response, 401, { error: "Invalid refresh token" }, { "set-cookie": clearRefreshCookie() });
  }

  if (pathname === "/auth/logout" && request.method === "POST") {
    const cookieToken = parseCookies(request)[refreshCookieName];
    const refreshToken = body.refreshToken || cookieToken || "";
    if (refreshToken) {
      await store.update((database) => {
        delete database.sessions[hash(refreshToken)];
        return null;
      });
    }
    return noContent(response, { "set-cookie": clearRefreshCookie() });
  }

  if (pathname === "/auth/me" && request.method === "GET") {
    const claims = authenticate(request);
    if (!claims) return send(response, 401, { error: "Unauthorized" });
    const database = await store.read();
    const user = database.users[claims.userId];
    return user ? send(response, 200, user) : send(response, 404, { error: "User not found" });
  }
  return false;
}

const server = http.createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (request.method === "GET" && pathname === "/health") {
      await store.health();
      return send(response, 200, { ok: true });
    }
    if (pathname.startsWith("/auth/")) {
      const handled = await handleAuth(request, response, pathname);
      if (handled !== false) return;
    }
    if (request.method === "POST" && pathname === "/api/sync") {
      if (enforceRateLimit(request, response, "api-sync", { limit: 240, windowMs: 15 * 60_000 })) return;
      const claims = authenticate(request);
      if (!claims) return send(response, 401, { error: "Unauthorized" });
      const body = await readJSON(request);
      if (!validSyncRequest(body)) return send(response, 422, { error: "Invalid sync request" });
      const result = await store.update((database) => {
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
    if (request.method === "GET" && pathname === "/api/export") {
      if (enforceRateLimit(request, response, "api-export", { limit: 30, windowMs: 15 * 60_000 })) return;
      const claims = authenticate(request);
      if (!claims) return send(response, 401, { error: "Unauthorized" });
      const database = await store.read();
      const user = database.users[claims.userId];
      if (!user) return send(response, 404, { error: "User not found" });
      const account = database.accounts[claims.userId] || {
        items: {},
        groups: {},
        appliedMutations: {},
        eveningReminder: null
      };
      return send(response, 200, {
        exportedAt: new Date().toISOString(),
        user,
        checklist: materializeAccount(account)
      }, {
        "content-disposition": "attachment; filename=\"daily-checklist-export.json\""
      });
    }
    if (request.method === "DELETE" && pathname === "/api/account") {
      if (enforceRateLimit(request, response, "api-delete-account", { limit: 5, windowMs: 60 * 60_000 })) return;
      const claims = authenticate(request);
      if (!claims) return send(response, 401, { error: "Unauthorized" });
      await store.update((database) => {
        delete database.accounts[claims.userId];
        delete database.users[claims.userId];
        for (const [identity, userID] of Object.entries(database.identities || {})) {
          if (userID === claims.userId) delete database.identities[identity];
        }
        for (const [tokenHash, session] of Object.entries(database.sessions || {})) {
          if (session.userId === claims.userId) delete database.sessions[tokenHash];
        }
        return null;
      });
      return noContent(response, { "set-cookie": clearRefreshCookie() });
    }
    if (request.method === "GET") {
      const relativePath = pathname === "/"
        ? "landing.html"
        : (pathname === "/app" || pathname === "/app/" ? "index.html" : pathname.slice(1));
      if (await sendWebFile(response, relativePath)) return;
    }
    return send(response, 404, { error: "Not found" });
  } catch (error) {
    if (!error.quiet && (!error.status || error.status >= 500)) console.error(error);
    const status = error.status || 500;
    const message = status >= 500 && isProduction
      ? "Internal server error"
      : error.message || "Internal server error";
    return send(response, status, { error: error.expose === false ? "Internal server error" : message });
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
  stampWins,
  appleWebAuthConfigured,
  upsertUser
};
