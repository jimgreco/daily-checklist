(function () {
  "use strict";

  const app = document.getElementById("app");
  const STORAGE = {
    token: "dailyWeb.token",
    refresh: "dailyWeb.refreshToken",
    user: "dailyWeb.user",
    cache: "dailyWeb.cache",
    pending: "dailyWeb.pending",
    device: "dailyWeb.deviceID",
  };
  const state = {
    token: localStorage.getItem(STORAGE.token) || "",
    refreshToken: localStorage.getItem(STORAGE.refresh) || "",
    user: readJSON(STORAGE.user, null),
    items: readJSON(STORAGE.cache, { items: [] }).items || [],
    groups: readJSON(STORAGE.cache, { groups: [] }).groups || [],
    pending: readJSON(STORAGE.pending, []),
    deviceID: localStorage.getItem(STORAGE.device) || crypto.randomUUID(),
    selectedDate: startOfDay(new Date()),
    mode: "today",
    sort: "manual",
    loaded: false,
    syncing: false,
    authLoaded: false,
    googleClientId: "",
    appleClientId: "",
    modal: null,
    toast: "",
  };
  let refreshPromise = null;
  let toastTimer = null;

  localStorage.setItem(STORAGE.device, state.deviceID);

  function readJSON(key, fallback) {
    try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
  }

  function escapeHTML(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[character]);
  }

  function startOfDay(date) {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
  }

  function dateKey(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    return `${year}-${month}-${day}`;
  }

  function dateFromInput(value) {
    if (!value) return null;
    const [year, month, day] = value.split("-").map(Number);
    return new Date(year, month - 1, day);
  }

  function localISO(value) {
    const date = typeof value === "string" ? dateFromInput(value) : value;
    return date ? date.toISOString() : null;
  }

  function addDays(date, days) {
    const next = new Date(date);
    next.setDate(next.getDate() + days);
    return startOfDay(next);
  }

  function sameDay(left, right) { return dateKey(left) === dateKey(right); }

  function persistSession() {
    state.token ? localStorage.setItem(STORAGE.token, state.token) : localStorage.removeItem(STORAGE.token);
    state.refreshToken ? localStorage.setItem(STORAGE.refresh, state.refreshToken) : localStorage.removeItem(STORAGE.refresh);
    state.user ? localStorage.setItem(STORAGE.user, JSON.stringify(state.user)) : localStorage.removeItem(STORAGE.user);
  }

  function persistData() {
    localStorage.setItem(STORAGE.cache, JSON.stringify({ items: state.items, groups: state.groups }));
    localStorage.setItem(STORAGE.pending, JSON.stringify(state.pending));
  }

  function hasSession() { return Boolean(state.token || state.refreshToken); }

  function clearSession() {
    state.token = "";
    state.refreshToken = "";
    state.user = null;
    state.items = [];
    state.groups = [];
    state.pending = [];
    persistSession();
    persistData();
  }

  function applyAuth(auth) {
    state.token = auth.token || "";
    state.refreshToken = auth.refreshToken || auth.refresh_token || "";
    state.user = auth.user || null;
    persistSession();
  }

  async function request(path, options = {}, retry = true) {
    const response = await fetch(path, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}),
        ...(options.headers || {}),
      },
    });
    if (response.status === 401 && retry && state.refreshToken && path !== "/auth/refresh") {
      if (await refreshAccessToken()) return request(path, options, false);
    }
    if (!response.ok) {
      let message = `HTTP ${response.status}`;
      try { message = (await response.json()).error || message; } catch {}
      throw new Error(message);
    }
    return response.status === 204 ? null : response.json();
  }

  async function refreshAccessToken() {
    if (!state.refreshToken) return false;
    if (!refreshPromise) {
      refreshPromise = request("/auth/refresh", {
        method: "POST",
        body: JSON.stringify({ refreshToken: state.refreshToken }),
      }, false).then((auth) => {
        applyAuth(auth);
        return true;
      }).catch(() => {
        clearSession();
        return false;
      }).finally(() => { refreshPromise = null; });
    }
    return refreshPromise;
  }

  function mutation(kind, values = {}) {
    return { id: crypto.randomUUID(), kind, stamp: new Date().toISOString(), ...values };
  }

  function queue(next) {
    state.pending.push(next);
    persistData();
    render();
    void sync();
  }

  async function sync() {
    if (!hasSession() || state.syncing) return;
    state.syncing = true;
    render();
    const sent = [...state.pending];
    try {
      const result = await request("/api/sync", {
        method: "POST",
        body: JSON.stringify({ deviceID: state.deviceID, mutations: sent }),
      });
      const accepted = new Set(result.acceptedMutationIDs || []);
      state.pending = state.pending.filter((entry) => !accepted.has(entry.id));
      state.items = result.items || [];
      state.groups = result.groups || [];
      state.loaded = true;
      persistData();
    } catch (error) {
      if (!hasSession()) showToast("Your session expired. Sign in again.");
    } finally {
      state.syncing = false;
      render();
    }
  }

  function occurs(item, date) {
    const day = startOfDay(date);
    const first = startOfDay(new Date(item.startDate || item.createdAt));
    if (day < first) return false;
    if (item.endedAt && day >= startOfDay(new Date(item.endedAt))) return false;
    if (state.mode === "all") return true;
    const weekday = day.getDay() + 1;
    if (item.schedule === "weekdays") return weekday >= 2 && weekday <= 6;
    if (item.schedule === "weekends") return weekday === 1 || weekday === 7;
    if (item.schedule === "custom") return (item.customWeekdays || []).includes(weekday);
    return true;
  }

  function complete(item) { return (item.completedDates || []).includes(dateKey(state.selectedDate)); }

  function visibleItems() {
    const items = state.items.filter((item) => occurs(item, state.selectedDate));
    return items.sort((left, right) => {
      if (state.sort === "name") return left.title.localeCompare(right.title);
      if (state.sort === "time") return (left.reminderMinutes ?? 9999) - (right.reminderMinutes ?? 9999);
      return (left.sortOrder ?? 9999) - (right.sortOrder ?? 9999)
        || new Date(left.createdAt) - new Date(right.createdAt);
    });
  }

  function scheduleText(item) {
    if (item.schedule === "weekdays") return "Weekdays";
    if (item.schedule === "weekends") return "Weekends";
    if (item.schedule === "custom") {
      const labels = ["S", "M", "T", "W", "T", "F", "S"];
      return (item.customWeekdays || []).map((day) => labels[day - 1]).join(" · ") || "Custom";
    }
    return "Every day";
  }

  function timeText(minutes) {
    if (minutes == null) return "";
    const date = new Date(2000, 0, 1, Math.floor(minutes / 60), minutes % 60);
    return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }

  function groupProgress(items) {
    const done = items.filter(complete).length;
    return done === items.length ? String(items.length) : `${done}/${items.length}`;
  }

  function canDeleteGroup(groupID) {
    return !state.items.some((item) => item.groupID === groupID && !item.endedAt);
  }

  function renderTask(item) {
    return `<article class="task ${complete(item) ? "complete" : ""}">
      <button class="check" data-action="toggle" data-id="${item.id}" aria-label="${complete(item) ? "Mark incomplete" : "Mark complete"}">${complete(item) ? "✓" : ""}</button>
      <div class="task-copy">
        <div class="task-title">${escapeHTML(item.title)}</div>
        <div class="task-meta">
          <span>↻ ${escapeHTML(scheduleText(item))}</span>
          ${item.reminderMinutes == null ? "" : `<span>♟ ${escapeHTML(timeText(item.reminderMinutes))}</span>`}
        </div>
        ${item.notes ? `<p class="notes">${escapeHTML(item.notes)}</p>` : ""}
      </div>
      <button class="edit-button" data-action="edit" data-id="${item.id}" aria-label="Edit ${escapeHTML(item.title)}">✎</button>
    </article>`;
  }

  function renderGroup(name, items, groupID, realGroup) {
    if (!items.length && !realGroup) return "";
    const todo = items.filter((item) => !complete(item));
    const done = items.filter(complete);
    const ordered = realGroup && todo.length ? [...todo, ...done] : items;
    const canDelete = realGroup && canDeleteGroup(groupID);
    return `<section class="group">
      <div class="group-head">
        <div class="group-title">${escapeHTML(name)}<span>${groupProgress(items)}</span>${realGroup ? `<button class="group-action group-title-action" data-action="rename-group" data-group="${groupID}" aria-label="Rename ${escapeHTML(name)}">✎</button>` : ""}</div>
        <div class="group-actions">
          ${todo.length ? `<button class="complete-all" data-action="complete-group" data-group="${groupID || ""}">✓ All</button>` : ""}
          ${canDelete ? `<button class="group-action danger" data-action="delete-group" data-group="${groupID}" aria-label="Delete ${escapeHTML(name)}">⌫</button>` : ""}
        </div>
      </div>
      <div class="task-list">${ordered.length ? ordered.map(renderTask).join("") : `<div class="empty-group">No tasks</div>`}</div>
    </section>`;
  }

  function renderChecklist() {
    const items = visibleItems();
    const groups = [...state.groups].sort((a, b) => a.sortOrder - b.sortOrder);
    const known = new Set(groups.map((group) => group.id));
    const ungrouped = items.filter((item) => !item.groupID || !known.has(item.groupID));
    const remaining = items.filter((item) => !complete(item)).length;
    const dateLabel = state.selectedDate.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" });
    const title = sameDay(state.selectedDate, new Date()) ? "Daily" : state.selectedDate.toLocaleDateString([], { month: "short", day: "numeric" });
    const ungroupedTodo = ungrouped.filter((item) => !complete(item));
    const ungroupedDone = ungrouped.filter(complete);
    const grouped = groups.map((group) => ({
      group,
      items: items.filter((item) => item.groupID === group.id)
    })).filter((entry) => entry.items.length || canDeleteGroup(entry.group.id));
    const todoBody = [
      renderGroup("Ungrouped", ungroupedTodo, "", false),
      ...grouped.filter((entry) => entry.items.some((item) => !complete(item)))
        .map((entry) => renderGroup(entry.group.name, entry.items, entry.group.id, true))
    ].join("");
    const completedBody = [
      renderGroup("Ungrouped", ungroupedDone, "", false),
      ...grouped.filter((entry) => entry.items.every(complete))
        .map((entry) => renderGroup(entry.group.name, entry.items, entry.group.id, true))
    ].join("");

    app.innerHTML = `<div class="shell">
      <div class="topline">
        <div>
          <p class="eyebrow">${escapeHTML(dateLabel)}</p>
          <h1>${escapeHTML(title)}</h1>
          <p class="subtitle">${remaining} ${remaining === 1 ? "thing" : "things"} left today.</p>
        </div>
        <div>
          <div class="date-nav">
            <button class="circle-button" data-action="previous" aria-label="Previous day">‹</button>
            <button class="circle-button" data-action="next" aria-label="Next day">›</button>
          </div>
          <div class="date-nav" style="justify-content:flex-end;margin-top:12px">
            ${renderAccountButton()}
          </div>
        </div>
      </div>
      <div class="controls">
        <div class="segmented">
          <button class="${state.mode === "today" ? "active" : ""}" data-action="mode" data-mode="today">Today</button>
          <button class="${state.mode === "all" ? "active" : ""}" data-action="mode" data-mode="all">All items</button>
        </div>
        <div class="toolbar"><button class="sort-button" data-action="sort">⇅ ${state.sort === "manual" ? "Manual" : state.sort === "name" ? "Name" : "Reminder time"}</button></div>
      </div>
      <div class="section-head">
        <span class="section-label">To do</span>
        ${remaining ? `<button class="complete-all" data-action="complete-all">✓ All&nbsp;&nbsp;${remaining}</button>` : ""}
      </div>
      ${todoBody || `<div class="empty">${completedBody ? "Everything is complete." : "Nothing is scheduled for this day."}</div>`}
      ${completedBody ? `<div class="section-head"><span class="section-label">Completed</span></div>${completedBody}` : ""}
      <div class="status">${state.syncing ? "Syncing…" : state.pending.length ? "Saved offline" : "Synced"}</div>
      <button class="fab" data-action="add" aria-label="Add checklist item">+</button>
      ${renderModal()}
      ${state.toast ? `<div class="toast">${escapeHTML(state.toast)}</div>` : ""}
    </div>`;
  }

  function renderAccountButton() {
    const photo = state.user?.profileImageURL;
    return `<button class="account-button" data-action="account" aria-label="Account">${
      photo ? `<img class="account-avatar" src="${escapeHTML(photo)}" alt="">` : "◉"
    }</button>`;
  }

  function renderAuth() {
    const local = ["localhost", "127.0.0.1", "::1"].includes(location.hostname);
    app.innerHTML = `<section class="auth-shell">
      <div class="auth-mark">✓</div>
      <h1>Keep your day in sync</h1>
      <p>Sign in to see the same checklists on the web and your phone. Your changes are cached for spotty connections.</p>
      <div class="auth-options">
        ${state.googleClientId ? `<div class="google-provider" data-google-host></div>` : ""}
        ${state.appleClientId ? `<button class="provider apple" data-action="apple">&nbsp; Continue with Apple</button>` : ""}
        ${local ? `<button class="dev-button" data-action="dev">Local dev sign in</button>` : ""}
      </div>
      <div class="auth-note">${state.authLoaded && !state.googleClientId && !state.appleClientId && !local ? "Web sign-in providers are not configured yet." : ""}</div>
      ${state.toast ? `<div class="toast">${escapeHTML(state.toast)}</div>` : ""}
    </section>`;
    renderGoogleButton();
  }

  function editorValues(item) {
    const source = item || {};
    const start = source.startDate ? dateKey(new Date(source.startDate)) : dateKey(state.selectedDate);
    const end = source.endedAt ? dateKey(addDays(new Date(source.endedAt), -1)) : "";
    const time = source.reminderMinutes == null ? "" :
      `${String(Math.floor(source.reminderMinutes / 60)).padStart(2, "0")}:${String(source.reminderMinutes % 60).padStart(2, "0")}`;
    return { ...source, start, end, time };
  }

  function renderModal() {
    if (!state.modal) return "";
    if (state.modal.type === "account") {
      return `<div class="scrim" data-action="close"><section class="modal" data-modal>
        <h2>Account</h2>
        <div class="account-card">
          <strong>${escapeHTML(state.user?.name || state.user?.email || "Daily account")}</strong>
          <p>${escapeHTML(state.user?.email || "")}</p>
          <p>Your checklist is synced between this website and the Daily app.</p>
          <button class="danger" data-action="sign-out">Sign out</button>
        </div>
        <div class="modal-actions"><span></span><button class="secondary" data-action="close">Done</button></div>
      </section></div>`;
    }
    const item = editorValues(state.modal.item);
    const schedule = item.schedule || "everyDay";
    const weekdays = new Set(item.customWeekdays || []);
    return `<div class="scrim" data-action="close"><form class="modal" data-modal data-editor>
      <h2>${state.modal.item ? "Edit item" : "New item"}</h2>
      <label class="field">Title<input name="title" required maxlength="120" value="${escapeHTML(item.title || "")}" autofocus></label>
      <label class="field">Notes<textarea name="notes" maxlength="2000">${escapeHTML(item.notes || "")}</textarea></label>
      <div class="field-row">
        <label class="field">Schedule<select name="schedule">
          ${[["everyDay","Every day"],["weekdays","Weekdays"],["weekends","Weekends"],["custom","Custom"]].map(([value,label]) => `<option value="${value}" ${schedule === value ? "selected" : ""}>${label}</option>`).join("")}
        </select></label>
        <label class="field">Reminder<input name="reminder" type="time" value="${item.time}"></label>
      </div>
      <div class="field" data-custom-days ${schedule === "custom" ? "" : "hidden"}>
        Days
        <div class="weekdays">${["S","M","T","W","T","F","S"].map((label,index) => `<button type="button" class="weekday ${weekdays.has(index + 1) ? "active" : ""}" data-action="weekday" data-day="${index + 1}">${label}</button>`).join("")}</div>
      </div>
      <label class="field">Group<select name="groupID">
        <option value="">No group</option>
        ${state.groups.map((group) => `<option value="${group.id}" ${item.groupID === group.id ? "selected" : ""}>${escapeHTML(group.name)}</option>`).join("")}
        <option value="__new">New group…</option>
      </select></label>
      <div class="field-row">
        <label class="field">Start date<input name="startDate" type="date" value="${item.start}"></label>
        <label class="field">Last day<input name="endDate" type="date" value="${item.end}"></label>
      </div>
      <div class="modal-actions">
        ${state.modal.item ? `<button type="button" class="danger" data-action="end-item">End item</button>` : "<span></span>"}
        <div><button type="button" class="secondary" data-action="close">Cancel</button><button class="primary" type="submit">Save</button></div>
      </div>
    </form></div>`;
  }

  function render() {
    hasSession() ? renderChecklist() : renderAuth();
  }

  function showToast(message) {
    state.toast = message;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { state.toast = ""; render(); }, 2600);
    render();
  }

  async function loadAuthConfig() {
    try {
      const config = await request("/auth/config", {}, false);
      state.googleClientId = config.google_client_id || config.googleClientId || "";
      state.appleClientId = config.apple_client_id || config.appleClientId || "";
    } catch {}
    state.authLoaded = true;
    render();
  }

  function renderGoogleButton() {
    const host = document.querySelector("[data-google-host]");
    if (!host || !state.googleClientId || !window.google?.accounts?.id) return;
    window.google.accounts.id.initialize({ client_id: state.googleClientId, callback: googleCredential });
    const width = Math.max(260, Math.round(host.getBoundingClientRect().width || 400));
    window.google.accounts.id.renderButton(host, {
      theme: "outline", size: "large", shape: "rectangular", text: "continue_with",
      logo_alignment: "center", width,
    });
  }

  async function googleCredential(response) {
    try {
      const auth = await request("/auth/google", {
        method: "POST", body: JSON.stringify({ idToken: response.credential })
      }, false);
      applyAuth(auth);
      await sync();
    } catch (error) { showToast(error.message); }
  }

  async function signInApple() {
    if (!window.AppleID?.auth || !state.appleClientId) throw new Error("Apple sign-in is not configured");
    window.AppleID.auth.init({
      clientId: state.appleClientId, scope: "name email", redirectURI: location.origin, usePopup: true
    });
    const response = await window.AppleID.auth.signIn();
    const authorization = response?.authorization || {};
    const name = response?.user?.name || {};
    const auth = await request("/auth/apple", {
      method: "POST",
      body: JSON.stringify({
        identityToken: authorization.id_token || null,
        authorizationCode: authorization.code || null,
        fullName: { givenName: name.firstName || null, familyName: name.lastName || null }
      })
    }, false);
    applyAuth(auth);
    await sync();
  }

  function toggle(item) {
    const key = dateKey(state.selectedDate);
    item.completedDates ||= [];
    const completed = !item.completedDates.includes(key);
    item.completedDates = completed ? [...item.completedDates, key] : item.completedDates.filter((date) => date !== key);
    queue(mutation("completion", { itemID: item.id, completionDate: key, completed }));
  }

  function completeItems(items) {
    const key = dateKey(state.selectedDate);
    const changed = items.filter((item) => !complete(item));
    changed.forEach((item) => {
      item.completedDates ||= [];
      item.completedDates.push(key);
      state.pending.push(mutation("completion", { itemID: item.id, completionDate: key, completed: true }));
    });
    persistData();
    render();
    void sync();
  }

  function renameGroup(groupID) {
    const group = state.groups.find((candidate) => candidate.id === groupID);
    if (!group) return;
    const name = prompt("Rename this group", group.name);
    const trimmed = name?.trim();
    if (!trimmed || trimmed === group.name) return;
    if (state.groups.some((candidate) => candidate.id !== groupID && candidate.name.toLowerCase() === trimmed.toLowerCase())) {
      showToast("A group with that name already exists.");
      return;
    }
    group.name = trimmed;
    state.pending = state.pending.filter((entry) => !(
      entry.kind === "groupUpsert"
        && entry.groupID === groupID
        && entry.changedFields?.length === 1
        && entry.changedFields[0] === "name"
    ));
    queue(mutation("groupUpsert", {
      groupID,
      changedFields: ["name"],
      group: { name: group.name, sortOrder: group.sortOrder }
    }));
  }

  function deleteGroup(groupID) {
    const group = state.groups.find((candidate) => candidate.id === groupID);
    if (!group || !canDeleteGroup(groupID)) return;
    if (!confirm(`Delete "${group.name}"?`)) return;
    state.groups = state.groups.filter((candidate) => candidate.id !== groupID);
    state.pending = state.pending.filter((entry) => entry.groupID !== groupID || (entry.kind !== "groupUpsert" && entry.kind !== "groupDelete"));
    queue(mutation("groupDelete", { groupID }));
  }

  function saveEditor(form) {
    const data = new FormData(form);
    const existing = state.modal.item;
    let groupID = data.get("groupID") || null;
    if (groupID === "__new") {
      const name = prompt("Name this group");
      if (!name?.trim()) return;
      const group = { id: crypto.randomUUID(), name: name.trim(), sortOrder: state.groups.length };
      state.groups.push(group);
      state.pending.push(mutation("groupUpsert", {
        groupID: group.id, changedFields: ["name", "sortOrder"],
        group: { name: group.name, sortOrder: group.sortOrder }
      }));
      groupID = group.id;
    }
    const reminder = String(data.get("reminder") || "");
    const [hours, minutes] = reminder ? reminder.split(":").map(Number) : [null, null];
    const customWeekdays = [...form.querySelectorAll(".weekday.active")].map((button) => Number(button.dataset.day));
    const startDate = localISO(data.get("startDate"));
    const lastDay = dateFromInput(data.get("endDate"));
    const endedAt = lastDay ? addDays(lastDay, 1).toISOString() : null;
    const item = {
      id: existing?.id || crypto.randomUUID(),
      title: String(data.get("title")).trim(),
      notes: String(data.get("notes") || "").trim(),
      schedule: data.get("schedule"),
      customWeekdays,
      reminderMinutes: reminder ? hours * 60 + minutes : null,
      completedDates: existing?.completedDates || [],
      createdAt: existing?.createdAt || new Date().toISOString(),
      startDate,
      endedAt,
      groupID,
      sortOrder: existing?.sortOrder ?? state.items.filter((candidate) => candidate.groupID === groupID).length,
    };
    if (!item.title) return;
    const index = state.items.findIndex((candidate) => candidate.id === item.id);
    if (index >= 0) state.items[index] = item; else state.items.push(item);
    state.modal = null;
    queue(mutation("upsert", {
      itemID: item.id,
      changedFields: ["title","notes","schedule","customWeekdays","reminderMinutes","createdAt","startDate","endedAt","groupID","sortOrder"],
      item: {
        title: item.title, notes: item.notes, schedule: item.schedule,
        customWeekdays: item.customWeekdays, reminderMinutes: item.reminderMinutes,
        createdAt: item.createdAt, startDate: item.startDate, endedAt: item.endedAt,
        groupID: item.groupID, sortOrder: item.sortOrder
      }
    }));
  }

  app.addEventListener("click", async (event) => {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    if (target.classList.contains("scrim") && event.target !== target) return;
    const action = target.dataset.action;
    if (action === "close") { state.modal = null; render(); }
    if (action === "previous") { state.selectedDate = addDays(state.selectedDate, -1); render(); }
    if (action === "next") { state.selectedDate = addDays(state.selectedDate, 1); render(); }
    if (action === "mode") { state.mode = target.dataset.mode; render(); }
    if (action === "sort") {
      state.sort = state.sort === "manual" ? "time" : state.sort === "time" ? "name" : "manual";
      render();
    }
    if (action === "add") { state.modal = { type: "editor", item: null }; render(); }
    if (action === "edit") {
      state.modal = { type: "editor", item: state.items.find((item) => item.id === target.dataset.id) };
      render();
    }
    if (action === "toggle") toggle(state.items.find((item) => item.id === target.dataset.id));
    if (action === "complete-all") completeItems(visibleItems());
    if (action === "complete-group") {
      const id = target.dataset.group || null;
      completeItems(visibleItems().filter((item) => (item.groupID || null) === id));
    }
    if (action === "rename-group") renameGroup(target.dataset.group);
    if (action === "delete-group") deleteGroup(target.dataset.group);
    if (action === "account") { state.modal = { type: "account" }; render(); }
    if (action === "sign-out") { clearSession(); state.modal = null; render(); }
    if (action === "weekday") { target.classList.toggle("active"); }
    if (action === "end-item") {
      const item = state.modal.item;
      item.endedAt = startOfDay(new Date()).toISOString();
      state.modal = null;
      queue(mutation("upsert", {
        itemID: item.id, changedFields: ["endedAt"], item: { endedAt: item.endedAt }
      }));
    }
    if (action === "dev") {
      try {
        applyAuth(await request("/auth/dev", {
          method: "POST", body: JSON.stringify({ email: "dev@daily.local", name: "Local Dev" })
        }, false));
        await sync();
      } catch (error) { showToast(error.message); }
    }
    if (action === "apple") {
      try { await signInApple(); } catch (error) { showToast(error.message); }
    }
  });

  app.addEventListener("change", (event) => {
    if (event.target.name === "schedule") {
      const custom = event.target.closest("form").querySelector("[data-custom-days]");
      custom.hidden = event.target.value !== "custom";
    }
  });

  app.addEventListener("submit", (event) => {
    if (!event.target.matches("[data-editor]")) return;
    event.preventDefault();
    saveEditor(event.target);
  });

  render();
  void loadAuthConfig();
  if (hasSession()) void sync();
  window.addEventListener("online", () => void sync());
  window.addEventListener("load", renderGoogleButton);
})();
