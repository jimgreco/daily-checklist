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
const refreshCookieMaxAgeSeconds = 10 * 365 * 86400;
const defaultAdminEmails = ["jgreco@gmail.com"];

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

function firstHeaderValue(value) {
  return headerValues(value)[0] || "";
}

function headerValues(value) {
  const values = Array.isArray(value) ? value : [value];
  return values.flatMap((entry) => String(entry || "").split(",").map((part) => part.trim()).filter(Boolean));
}

function trustedProxyHops() {
  const explicit = envValue("TRUST_PROXY_HOPS");
  if (explicit) {
    const hops = Number.parseInt(explicit, 10);
    return Number.isSafeInteger(hops) && hops > 0 ? Math.min(hops, 10) : 0;
  }
  return process.env.TRUST_PROXY === "true" ? 1 : 0;
}

function trustedForwardedValue(value) {
  const hops = trustedProxyHops();
  if (!hops) return "";
  const values = headerValues(value);
  if (!values.length) return "";
  return values[Math.max(0, values.length - hops)] || "";
}

function trustedRequestHost(request) {
  const forwardedHost = trustedForwardedValue(request.headers["x-forwarded-host"]);
  return forwardedHost || firstHeaderValue(request.headers.host) || null;
}

function trustedRequestProtocol(request) {
  const forwardedProtocol = trustedForwardedValue(request.headers["x-forwarded-proto"]).toLowerCase();
  return forwardedProtocol === "https" || forwardedProtocol === "http"
    ? forwardedProtocol
    : "http";
}

function trustedRequestOrigin(request) {
  const host = trustedRequestHost(request);
  if (!host) return null;
  const protocol = trustedRequestProtocol(request);
  return `${protocol}://${host}`;
}

function urlFromHeader(value) {
  const header = firstHeaderValue(value);
  if (!header) return null;
  try {
    return new URL(header);
  } catch {
    return null;
  }
}

function matchesTrustedOrigin(request, value) {
  const url = urlFromHeader(value);
  if (!url) return false;
  const expectedOrigin = trustedRequestOrigin(request);
  if (expectedOrigin && url.origin === expectedOrigin) return true;
  const expectedHost = trustedRequestHost(request);
  return Boolean(expectedHost && url.protocol === "https:" && url.host === expectedHost);
}

function isSameOriginWebRequest(request) {
  if (request.headers.origin) return matchesTrustedOrigin(request, request.headers.origin);
  if (request.headers.referer) return matchesTrustedOrigin(request, request.headers.referer);
  return firstHeaderValue(request.headers["sec-fetch-site"]).toLowerCase() !== "cross-site";
}

function refreshTokenFromBody(body) {
  return typeof body?.refreshToken === "string" ? body.refreshToken : "";
}

function rejectCrossOriginCookieAuth(request, response, body, cookieToken) {
  if (refreshTokenFromBody(body) || !cookieToken || isSameOriginWebRequest(request)) return false;
  send(response, 403, { error: "Forbidden" });
  return true;
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
    maxAge: refreshCookieMaxAgeSeconds,
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

function resetRateLimits() {
  rateBuckets.clear();
}

function clientIP(request) {
  const forwarded = trustedForwardedValue(request.headers["x-forwarded-for"]);
  if (forwarded) return forwarded;
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
    expiresAt: null
  };
  return { token: issueAccessToken(user, sessionID), refreshToken, user };
}

function adminEmails() {
  return new Set([...defaultAdminEmails, envValue("ADMIN_EMAILS"), envValue("DAILY_ADMIN_EMAILS")]
    .flatMap((value) => value.split(","))
    .map(normalizeEmail)
    .filter(Boolean));
}

function isAdminUser(user) {
  return Boolean(user && adminEmails().has(normalizeEmail(user.email)));
}

function disabledError() {
  return Object.assign(new Error("Account disabled"), { status: 403, quiet: true });
}

function ensureUserCanSignIn(user) {
  if (user?.disabledAt) throw disabledError();
  return user;
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

function authenticatedUser(database, request) {
  const claims = authenticate(request);
  if (!claims) return { claims: null, user: null };
  const user = database.users[claims.userId] || null;
  return { claims, user };
}

function requireActiveUser(database, request) {
  const auth = authenticatedUser(database, request);
  if (!auth.claims) return { ...auth, error: { status: 401, message: "Unauthorized" } };
  if (!auth.user) return { ...auth, error: { status: 404, message: "User not found" } };
  if (auth.user.disabledAt) return { ...auth, error: { status: 403, message: "Account disabled" } };
  return auth;
}

function sendAuthError(response, error) {
  return send(response, error.status, { error: error.message });
}

function identityProviders(database, userID) {
  return Object.entries(database.identities || {})
    .filter(([, value]) => value === userID)
    .map(([key]) => key.split(":")[0])
    .filter(Boolean)
    .sort();
}

function maxISO(left, right) {
  if (!left) return right || null;
  if (!right) return left || null;
  return left > right ? left : right;
}

function accountSummary(account = {}) {
  let totalItems = 0;
  let activeItems = 0;
  let deletedItems = 0;
  let totalGroups = 0;
  let activeGroups = 0;
  let deletedGroups = 0;
  let completionRecords = 0;
  let completedRecords = 0;
  let lastActivityAt = null;

  for (const item of Object.values(account.items || {})) {
    totalItems += 1;
    if (item.deleted) deletedItems += 1; else activeItems += 1;
    lastActivityAt = maxISO(lastActivityAt, item.deleted?.stamp);
    for (const field of Object.values(item.fields || {})) lastActivityAt = maxISO(lastActivityAt, field?.stamp);
    for (const completion of Object.values(item.completions || {})) {
      completionRecords += 1;
      if (completion.value) completedRecords += 1;
      lastActivityAt = maxISO(lastActivityAt, completion.stamp);
    }
  }

  for (const group of Object.values(account.groups || {})) {
    totalGroups += 1;
    if (group.deleted) deletedGroups += 1; else activeGroups += 1;
    lastActivityAt = maxISO(lastActivityAt, group.deleted?.stamp);
    for (const field of Object.values(group.fields || {})) lastActivityAt = maxISO(lastActivityAt, field?.stamp);
  }

  for (const stamp of Object.values(account.appliedMutations || {})) lastActivityAt = maxISO(lastActivityAt, stamp);
  lastActivityAt = maxISO(lastActivityAt, account.eveningReminder?.stamp);

  return {
    totalItems,
    activeItems,
    deletedItems,
    totalGroups,
    activeGroups,
    deletedGroups,
    completionRecords,
    completedRecords,
    mutationCount: Object.keys(account.appliedMutations || {}).length,
    lastActivityAt
  };
}

function sessionIndex(database) {
  const now = new Date().toISOString();
  const counts = {};
  const activeCounts = {};
  const lastSessionExpiresAt = {};
  const byUser = {};
  let activeSessions = 0;
  for (const session of Object.values(database.sessions || {})) {
    if (!session?.userId) continue;
    const active = !session.expiresAt || session.expiresAt >= now;
    counts[session.userId] = (counts[session.userId] || 0) + 1;
    if (active) {
      activeCounts[session.userId] = (activeCounts[session.userId] || 0) + 1;
      activeSessions += 1;
    }
    lastSessionExpiresAt[session.userId] = maxISO(lastSessionExpiresAt[session.userId], session.expiresAt);
    byUser[session.userId] ||= [];
    byUser[session.userId].push({
      expiresAt: session.expiresAt || null,
      active
    });
  }
  for (const sessions of Object.values(byUser)) {
    sessions.sort((left, right) => {
      const leftExpiry = left.expiresAt || "9999-12-31T23:59:59.999Z";
      const rightExpiry = right.expiresAt || "9999-12-31T23:59:59.999Z";
      return rightExpiry.localeCompare(leftExpiry);
    });
  }
  return { counts, activeCounts, lastSessionExpiresAt, activeSessions, byUser };
}

function adminUserSummary(database, user, sessions = sessionIndex(database)) {
  const account = accountSummary(database.accounts?.[user.id]);
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    profileImageURL: user.profileImageURL || null,
    createdAt: user.createdAt || null,
    disabledAt: user.disabledAt || null,
    disabledBy: user.disabledBy || null,
    disabledReason: user.disabledReason || null,
    lastDisabledAt: user.lastDisabledAt || null,
    lastDisabledBy: user.lastDisabledBy || null,
    lastDisabledReason: user.lastDisabledReason || null,
    reenabledAt: user.reenabledAt || null,
    reenabledBy: user.reenabledBy || null,
    isAdmin: isAdminUser(user),
    providers: identityProviders(database, user.id),
    sessionCount: sessions.counts[user.id] || 0,
    activeSessionCount: sessions.activeCounts[user.id] || 0,
    lastSessionExpiresAt: sessions.lastSessionExpiresAt[user.id] || null,
    ...account
  };
}

function userAuditEvents(user) {
  const events = [];
  const disabledAt = user.disabledAt || user.lastDisabledAt;
  if (disabledAt) {
    events.push({
      type: "disabled",
      at: disabledAt,
      actor: user.disabledBy || user.lastDisabledBy || null,
      reason: user.disabledReason || user.lastDisabledReason || null
    });
  }
  if (user.reenabledAt) {
    events.push({
      type: "reenabled",
      at: user.reenabledAt,
      actor: user.reenabledBy || null,
      reason: null
    });
  }
  return events.sort((left, right) => String(right.at || "").localeCompare(String(left.at || "")));
}

function adminUserDetail(database, userID) {
  const user = database.users?.[userID];
  if (!user) return null;
  const sessions = sessionIndex(database);
  return {
    ...adminUserSummary(database, user, sessions),
    recentSessions: (sessions.byUser[user.id] || []).slice(0, 20),
    auditEvents: userAuditEvents(user)
  };
}

function adminOverview(database) {
  const users = Object.values(database.users || {}).sort((left, right) => {
    const leftCreated = left.createdAt || "";
    const rightCreated = right.createdAt || "";
    return rightCreated.localeCompare(leftCreated) || left.email.localeCompare(right.email);
  });
  const sessions = sessionIndex(database);
  const userRows = users.map((user) => adminUserSummary(database, user, sessions));

  const totals = userRows.reduce((memo, user) => {
    memo.totalItems += user.totalItems;
    memo.activeItems += user.activeItems;
    memo.deletedItems += user.deletedItems;
    memo.totalGroups += user.totalGroups;
    memo.activeGroups += user.activeGroups;
    memo.deletedGroups += user.deletedGroups;
    memo.completionRecords += user.completionRecords;
    memo.completedRecords += user.completedRecords;
    memo.mutationCount += user.mutationCount;
    return memo;
  }, {
    totalUsers: userRows.length,
    activeUsers: userRows.filter((user) => !user.disabledAt).length,
    disabledUsers: userRows.filter((user) => user.disabledAt).length,
    activeSessions: sessions.activeSessions,
    identityCount: Object.keys(database.identities || {}).length,
    totalItems: 0,
    activeItems: 0,
    deletedItems: 0,
    totalGroups: 0,
    activeGroups: 0,
    deletedGroups: 0,
    completionRecords: 0,
    completedRecords: 0,
    mutationCount: 0
  });

  return { generatedAt: new Date().toISOString(), totals, users: userRows };
}

async function requireAdmin(request, response) {
  const database = await store.read();
  const auth = requireActiveUser(database, request);
  if (auth.error) {
    sendAuthError(response, auth.error);
    return null;
  }
  if (!isAdminUser(auth.user)) {
    send(response, 403, { error: "Forbidden" });
    return null;
  }
  return { database, ...auth };
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

const itemFields = ["title", "notes", "schedule", "customWeekdays", "reminderMinutes", "quantity", "skippedDates", "openDates", "createdAt", "startDate", "endedAt", "groupID", "sortOrder", "pauseWindows"];
const groupFields = ["name", "sortOrder", "isCollapsed", "pauseWindows"];

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

function validPauseWindows(value) {
  return value == null || (
    Array.isArray(value)
    && value.length <= 500
    && value.every((window) => (
      window
      && typeof window === "object"
      && validDateKey(window.startDate)
      && (window.endDate == null || validDateKey(window.endDate))
      && (window.endDate == null || window.startDate <= window.endDate)
    ))
  );
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
    && (item.quantity == null || (Number.isInteger(item.quantity) && item.quantity >= 1 && item.quantity <= 99))
    && (item.skippedDates == null || (
      Array.isArray(item.skippedDates)
      && item.skippedDates.length <= 5000
      && item.skippedDates.every(validDateKey)
    ))
    && (item.openDates == null || (
      Array.isArray(item.openDates)
      && item.openDates.length <= 5000
      && item.openDates.every(validDateKey)
    ))
    && validISODate(item.createdAt)
    && validISODate(item.startDate)
    && validISODate(item.endedAt)
    && (item.groupID == null || validID(item.groupID))
    && validFiniteNumber(item.sortOrder)
    && validPauseWindows(item.pauseWindows);
}

function validGroupPayload(group = {}) {
  return group && typeof group === "object"
    && (group.name == null || (typeof group.name === "string" && group.name.length <= 120))
    && validFiniteNumber(group.sortOrder)
    && (group.isCollapsed == null || typeof group.isCollapsed === "boolean")
    && validPauseWindows(group.pauseWindows);
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
    return validDateKey(mutation.completionDate)
      && typeof mutation.completed === "boolean"
      && (mutation.completionCount == null
        || (Number.isInteger(mutation.completionCount)
          && mutation.completionCount >= 0
          && mutation.completionCount <= 99));
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
      count: Number.isInteger(mutation.completionCount) ? mutation.completionCount : null,
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
      const quantity = Number.isInteger(value.quantity) && value.quantity > 0 ? Math.min(value.quantity, 99) : 1;
      const completionCounts = Object.fromEntries(
        Object.entries(record.completions || {})
          .map(([date, state]) => [date, Math.min(Math.max(0, state.count ?? (state.value ? quantity : 0)), quantity)])
          .filter(([, count]) => count > 0)
      );
      return {
        id: record.id,
        title: value.title || "Untitled",
        notes: value.notes || "",
        schedule: value.schedule || "everyDay",
        customWeekdays: value.customWeekdays || [],
        reminderMinutes: value.reminderMinutes,
        quantity,
        skippedDates: value.skippedDates || [],
        openDates: value.openDates || [],
        startDate: value.startDate,
        endedAt: value.endedAt,
        groupID: value.groupID,
        sortOrder: value.sortOrder,
        pauseWindows: value.pauseWindows || [],
        completedDates: Object.entries(record.completions || {})
          .filter(([, state]) => state.value)
          .map(([date]) => date),
        completionCounts,
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
      sortOrder: record.fields.sortOrder?.value ?? 0,
      isCollapsed: record.fields.isCollapsed?.value === true,
      pauseWindows: record.fields.pauseWindows?.value || []
    }))
    .sort((left, right) => left.sortOrder - right.sortOrder || left.name.localeCompare(right.name));
  return {
    items,
    groups,
    eveningReminderMinutes: account.eveningReminder?.value ?? 1200
  };
}

function emptyAccount() {
  return {
    items: {},
    groups: {},
    appliedMutations: {},
    eveningReminder: null
  };
}

function accountForUser(database, userID) {
  database.accounts[userID] ||= emptyAccount();
  return database.accounts[userID];
}

function syncAccount(database, userID, body) {
  const account = accountForUser(database, userID);
  const acceptedMutationIDs = [];
  for (const mutation of body.mutations) {
    if (applyMutation(account, mutation, body.deviceID)) acceptedMutationIDs.push(mutation.id);
  }
  return { ...materializeAccount(account), acceptedMutationIDs };
}

function monitorToken() {
  return envValue("MONITOR_TOKEN") || envValue("DAILY_MONITOR_TOKEN");
}

function hasMonitorToken(request) {
  const expected = monitorToken();
  const provided = firstHeaderValue(request.headers["x-ritual-cue-monitor-token"]);
  if (!provided) return false;
  if (!expected) return true;
  const expectedBytes = Buffer.from(expected);
  const providedBytes = Buffer.from(provided);
  return expectedBytes.length === providedBytes.length
    && crypto.timingSafeEqual(expectedBytes, providedBytes);
}

function runMonitorSyncProbe(database) {
  const now = new Date().toISOString();
  const user = upsertUser(database, "monitor", "production-sync", {
    email: "monitor@ritualcue.local",
    name: "Production Monitor"
  });
  const account = accountForUser(database, user.id);
  const mutation = {
    id: `monitor-${crypto.randomUUID()}`,
    itemID: "monitor-probe",
    kind: "upsert",
    stamp: now,
    changedFields: ["title", "createdAt", "endedAt"],
    item: {
      title: "Production monitor probe",
      createdAt: now,
      endedAt: now
    }
  };
  const syncBody = {
    deviceID: "production-monitor",
    mutations: [mutation]
  };
  if (!validSyncRequest(syncBody)) throw Object.assign(new Error("Invalid monitor sync probe"), { status: 500 });
  const result = syncAccount(database, user.id, syncBody);
  delete account.items[mutation.itemID];
  delete account.appliedMutations[mutation.id];
  const materialized = materializeAccount(account);
  return {
    ok: true,
    acceptedMutationCount: result.acceptedMutationIDs.length,
    itemCount: materialized.items.length,
    groupCount: materialized.groups.length
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
      const user = upsertUser(database, "dev", body.email || "dev@ritualcue.local", {
        email: body.email || "dev@ritualcue.local",
        name: body.name || "Local Dev"
      });
      return createSession(database, ensureUserCanSignIn(user));
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
      return createSession(database, ensureUserCanSignIn(user));
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
      return createSession(database, ensureUserCanSignIn(user));
    });
    return send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) });
  }

  if (pathname === "/auth/refresh" && request.method === "POST") {
    if (enforceRateLimit(request, response, "auth-refresh", { limit: 60, windowMs: 15 * 60_000 })) return true;
    const cookieToken = parseCookies(request)[refreshCookieName];
    if (rejectCrossOriginCookieAuth(request, response, body, cookieToken)) return true;
    const refreshToken = refreshTokenFromBody(body) || cookieToken || "";
    const tokenHash = hash(refreshToken);
    const auth = await store.update((database) => {
      const session = database.sessions[tokenHash];
      if (!session) return null;
      delete database.sessions[tokenHash];
      const user = database.users[session.userId];
      return user && !user.disabledAt ? createSession(database, user) : null;
    });
    return auth
      ? send(response, 200, auth, { "set-cookie": refreshCookie(auth.refreshToken) })
      : send(response, 401, { error: "Invalid refresh token" }, { "set-cookie": clearRefreshCookie() });
  }

  if (pathname === "/auth/logout" && request.method === "POST") {
    const cookieToken = parseCookies(request)[refreshCookieName];
    if (rejectCrossOriginCookieAuth(request, response, body, cookieToken)) return true;
    const refreshToken = refreshTokenFromBody(body) || cookieToken || "";
    if (refreshToken) {
      await store.update((database) => {
        delete database.sessions[hash(refreshToken)];
        return null;
      });
    }
    return noContent(response, { "set-cookie": clearRefreshCookie() });
  }

  if (pathname === "/auth/me" && request.method === "GET") {
    const database = await store.read();
    const auth = requireActiveUser(database, request);
    return auth.error ? sendAuthError(response, auth.error) : send(response, 200, auth.user);
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
    if (request.method === "GET" && pathname === "/api/admin/overview") {
      const admin = await requireAdmin(request, response);
      if (!admin) return;
      return send(response, 200, adminOverview(admin.database));
    }
    const adminUserMatch = pathname.match(/^\/api\/admin\/users\/([^/]+)$/);
    if (request.method === "GET" && adminUserMatch) {
      const admin = await requireAdmin(request, response);
      if (!admin) return;
      const detail = adminUserDetail(admin.database, decodeURIComponent(adminUserMatch[1]));
      return detail ? send(response, 200, detail) : send(response, 404, { error: "User not found" });
    }
    if (request.method === "POST" && pathname === "/api/monitor/sync") {
      if (enforceRateLimit(request, response, "api-monitor-sync", { limit: 30, windowMs: 15 * 60_000 })) return;
      if (!hasMonitorToken(request)) return send(response, 404, { error: "Not found" });
      await readJSON(request);
      const result = await store.update((database) => runMonitorSyncProbe(database));
      return send(response, 200, result);
    }
    const disableMatch = pathname.match(/^\/api\/admin\/users\/([^/]+)\/disable$/);
    if (request.method === "POST" && disableMatch) {
      if (enforceRateLimit(request, response, "api-admin-disable", { limit: 20, windowMs: 15 * 60_000 })) return;
      const admin = await requireAdmin(request, response);
      if (!admin) return;
      const userID = decodeURIComponent(disableMatch[1]);
      if (userID === admin.user.id) return send(response, 422, { error: "Admins cannot disable their own account" });
      const body = await readJSON(request);
      const result = await store.update((database) => {
        const user = database.users[userID];
        if (!user) return null;
        user.disabledAt ||= new Date().toISOString();
        user.disabledBy ||= admin.user.email;
        user.disabledReason = String(body.reason || "").trim().slice(0, 240) || null;
        delete user.reenabledAt;
        delete user.reenabledBy;
        for (const [tokenHash, session] of Object.entries(database.sessions || {})) {
          if (session.userId === userID) delete database.sessions[tokenHash];
        }
        return adminUserDetail(database, userID);
      });
      return result ? send(response, 200, { user: result }) : send(response, 404, { error: "User not found" });
    }
    const reenableMatch = pathname.match(/^\/api\/admin\/users\/([^/]+)\/reenable$/);
    if (request.method === "POST" && reenableMatch) {
      if (enforceRateLimit(request, response, "api-admin-reenable", { limit: 20, windowMs: 15 * 60_000 })) return;
      const admin = await requireAdmin(request, response);
      if (!admin) return;
      const userID = decodeURIComponent(reenableMatch[1]);
      const result = await store.update((database) => {
        const user = database.users[userID];
        if (!user) return null;
        if (user.disabledAt) {
          user.lastDisabledAt = user.disabledAt;
          user.lastDisabledBy = user.disabledBy || null;
          user.lastDisabledReason = user.disabledReason || null;
        }
        delete user.disabledAt;
        delete user.disabledBy;
        delete user.disabledReason;
        user.reenabledAt = new Date().toISOString();
        user.reenabledBy = admin.user.email;
        return adminUserDetail(database, userID);
      });
      return result ? send(response, 200, { user: result }) : send(response, 404, { error: "User not found" });
    }
    if (request.method === "POST" && pathname === "/api/sync") {
      if (enforceRateLimit(request, response, "api-sync", { limit: 240, windowMs: 15 * 60_000 })) return;
      const database = await store.read();
      const authCheck = requireActiveUser(database, request);
      if (authCheck.error) return sendAuthError(response, authCheck.error);
      const body = await readJSON(request);
      if (!validSyncRequest(body)) return send(response, 422, { error: "Invalid sync request" });
      const result = await store.update((database) => {
        const auth = requireActiveUser(database, request);
        if (auth.error) throw Object.assign(new Error(auth.error.message), { status: auth.error.status, quiet: true });
        return syncAccount(database, auth.claims.userId, body);
      });
      return send(response, 200, result);
    }
    if (request.method === "GET" && pathname === "/api/export") {
      if (enforceRateLimit(request, response, "api-export", { limit: 30, windowMs: 15 * 60_000 })) return;
      const database = await store.read();
      const auth = requireActiveUser(database, request);
      if (auth.error) return sendAuthError(response, auth.error);
      const account = database.accounts[auth.claims.userId] || {
        items: {},
        groups: {},
        appliedMutations: {},
        eveningReminder: null
      };
      return send(response, 200, {
        exportedAt: new Date().toISOString(),
        user: auth.user,
        checklist: materializeAccount(account)
      }, {
        "content-disposition": "attachment; filename=\"ritual-cue-export.json\""
      });
    }
    if (request.method === "DELETE" && pathname === "/api/account") {
      if (enforceRateLimit(request, response, "api-delete-account", { limit: 5, windowMs: 60 * 60_000 })) return;
      await store.update((database) => {
        const auth = requireActiveUser(database, request);
        if (auth.error) throw Object.assign(new Error(auth.error.message), { status: auth.error.status, quiet: true });
        delete database.accounts[auth.claims.userId];
        delete database.users[auth.claims.userId];
        for (const [identity, userID] of Object.entries(database.identities || {})) {
          if (userID === auth.claims.userId) delete database.identities[identity];
        }
        for (const [tokenHash, session] of Object.entries(database.sessions || {})) {
          if (session.userId === auth.claims.userId) delete database.sessions[tokenHash];
        }
        return null;
      });
      return noContent(response, { "set-cookie": clearRefreshCookie() });
    }
    if (request.method === "GET") {
      const relativePath = pathname === "/"
        ? "landing.html"
        : (pathname === "/app" || pathname === "/app/" ? "index.html"
          : (pathname === "/admin" || pathname === "/admin/" ? "admin.html" : pathname.slice(1)));
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
    console.log(`Ritual Cue server listening on http://0.0.0.0:${port}`);
  });
}

module.exports = {
  server,
  applyMutation,
  materializeAccount,
  validSyncRequest,
  stampWins,
  refreshCookieMaxAgeSeconds,
  appleWebAuthConfigured,
  upsertUser,
  adminOverview,
  adminUserDetail,
  clientIP,
  rateLimit,
  resetRateLimits,
  trustedProxyHops
};
