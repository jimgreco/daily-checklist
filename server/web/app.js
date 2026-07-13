(function () {
  "use strict";

  const app = document.getElementById("app");
  const STORAGE = {
    user: "dailyWeb.user",
    cache: "dailyWeb.cache",
    pending: "dailyWeb.pending",
    device: "dailyWeb.deviceID",
  };
  const state = {
    token: "",
    user: readJSON(STORAGE.user, null),
    items: readJSON(STORAGE.cache, { items: [] }).items || [],
    groups: readJSON(STORAGE.cache, { groups: [] }).groups || [],
    pending: readJSON(STORAGE.pending, []),
    deviceID: localStorage.getItem(STORAGE.device) || crypto.randomUUID(),
    selectedDate: startOfDay(new Date()),
    mode: "today",
    sort: "manual",
    search: "",
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
  const delayDailyMessage = "Daily items already appear tomorrow. Delay is only for items scheduled a few times a week.";
  const bringForwardDailyMessage = "Daily items already appear today. Bring forward is only for items scheduled a few times a week.";
  const templates = [
    { id: "morning", title: "Morning", groupName: "Morning Routine", items: ["Medication", "Vitamins", "Review today"] },
    { id: "evening", title: "Evening", groupName: "Evening Routine", items: ["Tidy up", "Prepare tomorrow", "Skincare"] },
    { id: "pet-care", title: "Pet care", groupName: "Pet Care", items: ["Food", "Fresh water", "Medication"] },
    { id: "household", title: "Household", groupName: "Household", items: ["Dishes", "Trash", "Quick reset"] },
  ];

  localStorage.setItem(STORAGE.device, state.deviceID);

  function readJSON(key, fallback) {
    try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
  }

  function escapeHTML(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[character]);
  }

  function icon(name, className = "") {
    const paths = {
      arrowDownUp: '<path d="m7 3-4 4 4 4"/><path d="M3 7h18"/><path d="m17 21 4-4-4-4"/><path d="M21 17H3"/>',
      chevronLeft: '<path d="m15 18-6-6 6-6"/>',
      chevronRight: '<path d="m9 18 6-6-6-6"/>',
      check: '<path d="M20 6 9 17l-5-5"/>',
      circle: '<circle cx="12" cy="12" r="8"/>',
      clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
      copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><rect x="4" y="4" width="12" height="12" rx="2"/>',
      folderClosed: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H10l2 2h6.5A2.5 2.5 0 0 1 21 9.5v7A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z"/>',
      folderOpen: '<path d="M3 18.5V7.5A2.5 2.5 0 0 1 5.5 5H10l2 2h6.5A2.5 2.5 0 0 1 21 9.5v1"/><path d="M4.2 19h13.9a2 2 0 0 0 1.9-1.4l1.3-4.1A1.2 1.2 0 0 0 20.1 12H8.6a2 2 0 0 0-1.9 1.4z"/>',
      minus: '<path d="M5 12h14"/>',
      pause: '<circle cx="12" cy="12" r="9"/><path d="M10 8v8"/><path d="M14 8v8"/>',
      pencil: '<path d="M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17v3z"/><path d="m14 7 3 3"/>',
      play: '<circle cx="12" cy="12" r="9"/><path d="m10 8 6 4-6 4z"/>',
      repeat: '<path d="m17 2 4 4-4 4"/><path d="M3 11V9a3 3 0 0 1 3-3h15"/><path d="m7 22-4-4 4-4"/><path d="M21 13v2a3 3 0 0 1-3 3H3"/>',
      search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
      skip: '<path d="m5 5 7 7-7 7"/><path d="M19 5v14"/>',
      startToday: '<path d="M17 17 7 7"/><path d="M15 7H7v8"/>',
      startTomorrow: '<path d="M7 17 17 7"/><path d="M9 7h8v8"/>',
      trash: '<path d="M4 7h16"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M6 7l1 14h10l1-14"/><path d="M9 7V4h6v3"/>',
      user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
      xCircle: '<circle cx="12" cy="12" r="9"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>',
      chart: '<path d="M4 19V9"/><path d="M10 19V5"/><path d="M16 19v-7"/><path d="M22 19V3"/>'
    };
    return `<svg class="icon ${className}" aria-hidden="true" focusable="false" viewBox="0 0 24 24">${paths[name] || ""}</svg>`;
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

  function isFutureDate(date) {
    return startOfDay(date) > startOfDay(new Date());
  }

  function groupByID(groupID) {
    return state.groups.find((group) => group.id === groupID) || null;
  }

  function normalizePauseWindows(windows = []) {
    const normalized = (Array.isArray(windows) ? windows : [])
      .filter((window) => /^\d{4}-\d{2}-\d{2}$/.test(window?.startDate || "")
        && (window.endDate == null || /^\d{4}-\d{2}-\d{2}$/.test(window.endDate))
        && (window.endDate == null || window.startDate <= window.endDate))
      .map((window) => ({ startDate: window.startDate, endDate: window.endDate ?? null }))
      .sort((left, right) => left.startDate.localeCompare(right.startDate));
    const merged = [];
    for (const window of normalized) {
      const last = merged[merged.length - 1];
      if (!last || (last.endDate != null && window.startDate > last.endDate)) {
        merged.push(window);
      } else if (last.endDate != null) {
        last.endDate = window.endDate == null ? null : (last.endDate > window.endDate ? last.endDate : window.endDate);
      }
    }
    return merged;
  }

  function pauseWindowsContain(windows, date) {
    const key = dateKey(startOfDay(date));
    return normalizePauseWindows(windows).some((window) => key >= window.startDate && (window.endDate == null || key <= window.endDate));
  }

  function pauseWindowsWithRange(windows, startDate, endDate) {
    return normalizePauseWindows([
      ...(windows || []),
      { startDate: dateKey(startOfDay(startDate)), endDate: dateKey(startOfDay(endDate)) }
    ]);
  }

  function pauseWindowsResumed(windows, date) {
    const key = dateKey(startOfDay(date));
    const previousKey = dateKey(addDays(startOfDay(date), -1));
    return normalizePauseWindows((windows || []).flatMap((window) => {
      if (!pauseWindowsContain([window], date)) return [window];
      if (window.startDate >= key) return [];
      return [{ ...window, endDate: previousKey }];
    }));
  }

  function pauseWindowsClearedOn(windows, key) {
    const previousKey = dateKey(addDays(dateFromInput(key), -1));
    const nextKey = dateKey(addDays(dateFromInput(key), 1));
    return normalizePauseWindows((windows || []).flatMap((window) => {
      if (!(key >= window.startDate && (window.endDate == null || key <= window.endDate))) return [window];
      const result = [];
      if (window.startDate < key) result.push({ startDate: window.startDate, endDate: previousKey });
      if (window.endDate == null) result.push({ startDate: nextKey, endDate: null });
      else if (key < window.endDate) result.push({ startDate: nextKey, endDate: window.endDate });
      return result;
    }));
  }

  function pauseWindowsForOneDay(windows, key) {
    return normalizePauseWindows([...(windows || []), { startDate: key, endDate: key }]);
  }

  function persistSession() {
    state.user ? localStorage.setItem(STORAGE.user, JSON.stringify(state.user)) : localStorage.removeItem(STORAGE.user);
  }

  function persistData() {
    localStorage.setItem(STORAGE.cache, JSON.stringify({ items: state.items, groups: state.groups }));
    localStorage.setItem(STORAGE.pending, JSON.stringify(state.pending));
  }

  function hasSession() { return Boolean(state.token || state.user); }

  function clearSession() {
    state.token = "";
    state.user = null;
    state.items = [];
    state.groups = [];
    state.pending = [];
    persistSession();
    persistData();
  }

  function applyAuth(auth) {
    state.token = auth.token || "";
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
    if (response.status === 401 && retry && path !== "/auth/refresh") {
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
    if (!refreshPromise) {
      refreshPromise = request("/auth/refresh", {
        method: "POST",
        body: JSON.stringify({}),
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
    if (state.mode === "archive") return Boolean(item.endedAt);
    if (state.mode === "all") return isActiveOnDate(item, date) || hasRecordedStateOnDate(item, date) || isPaused(item, date);
    const paused = isPaused(item, date);
    return (occursOnDate(item, date) || hasRecordedStateOnDate(item, date)) && (!paused || hasRecordedStateOnDate(item, date));
  }

  function isActiveOnDate(item, date) {
    const day = startOfDay(date);
    const first = startOfDay(new Date(item.startDate || item.createdAt));
    if (day < first) return false;
    if (item.endedAt && day >= startOfDay(new Date(item.endedAt))) return false;
    return true;
  }

  function isScheduledOnDate(item, date) {
    if (!isActiveOnDate(item, date)) return false;
    const day = startOfDay(date);
    const weekday = day.getDay() + 1;
    if (item.schedule === "weekdays") return weekday >= 2 && weekday <= 6;
    if (item.schedule === "weekends") return weekday === 1 || weekday === 7;
    if (item.schedule === "custom") return (item.customWeekdays || []).includes(weekday);
    return true;
  }

  function occursOnDate(item, date) {
    return isScheduledOnDate(item, date) && !isPaused(item, date);
  }

  function isGroupPaused(groupID, date) {
    const group = groupByID(groupID);
    return Boolean(group && pauseWindowsContain(group.pauseWindows, date));
  }

  function isPaused(item, date) {
    return pauseWindowsContain(item.pauseWindows, date) || (item.groupID && isGroupPaused(item.groupID, date));
  }

  function hasRecordedStateOnDate(item, date) {
    const key = dateKey(date);
    return (item.completedDates || []).includes(key)
      || (item.completionCounts?.[key] || 0) > 0
      || (item.skippedDates || []).includes(key)
      || (item.openDates || []).includes(key);
  }

  function complete(item) { return (item.completedDates || []).includes(dateKey(state.selectedDate)); }
  function skipped(item) { return (item.skippedDates || []).includes(dateKey(state.selectedDate)); }

  function quantity(item) {
    return Number.isInteger(item.quantity) && item.quantity > 0 ? Math.min(item.quantity, 99) : 1;
  }

  function completionCount(item, date = state.selectedDate) {
    const key = dateKey(date);
    const target = quantity(item);
    const count = item.completionCounts?.[key];
    if (Number.isInteger(count)) return Math.min(Math.max(0, count), target);
    return (item.completedDates || []).includes(key) ? target : 0;
  }

  function setCompletionCount(item, key, count) {
    const target = quantity(item);
    const next = Math.min(Math.max(0, count), target);
    item.completionCounts ||= {};
    item.completedDates ||= [];
    if (next > 0) item.completionCounts[key] = next;
    else delete item.completionCounts[key];
    if (next >= target) {
      if (!item.completedDates.includes(key)) item.completedDates.push(key);
    } else {
      item.completedDates = item.completedDates.filter((date) => date !== key);
    }
    return next;
  }

  function queueCompletion(item, key) {
    const count = completionCount(item, dateFromInput(key));
    state.pending.push(mutation("completion", {
      itemID: item.id,
      completionDate: key,
      completed: count >= quantity(item),
      completionCount: count
    }));
  }

  function visibleItems() {
    const query = state.search.trim().toLowerCase();
    const items = state.items
      .filter((item) => occurs(item, state.selectedDate))
      .filter((item) => !query
        || item.title.toLowerCase().includes(query)
        || String(item.notes || "").toLowerCase().includes(query));
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
      const labels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
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

  function delayedDaysOnDate(item, date) {
    const key = dateKey(date);
    if (!(item.openDates || []).includes(key)) return 0;
    if ((item.completedDates || []).includes(key) || (item.skippedDates || []).includes(key)) return 0;

    let cursor = startOfDay(date);
    let days = 0;
    while (true) {
      const previous = addDays(cursor, -1);
      if (!(item.skippedDates || []).includes(dateKey(previous))) break;
      days += 1;
      cursor = previous;
    }
    return days;
  }

  function renderTask(item) {
    const isComplete = complete(item);
    const isSkipped = skipped(item) && !isComplete;
    const isPausedForDate = isPaused(item, state.selectedDate);
    const count = completionCount(item);
    const target = quantity(item);
    const delayedDays = isPausedForDate ? 0 : delayedDaysOnDate(item, state.selectedDate);
    const delayedText = `${delayedDays} ${delayedDays === 1 ? "day" : "days"}`;
    return `<article class="task ${isComplete ? "complete" : ""} ${isSkipped ? "skipped" : ""} ${isPausedForDate ? "paused" : ""}">
      <button class="check" data-action="toggle" data-id="${item.id}" aria-label="${complete(item) ? "Mark incomplete" : "Mark complete"}">${complete(item) ? icon("check") : ""}</button>
      <div class="task-copy">
        <div class="task-title-line">
          <div class="task-title">${escapeHTML(item.title)}</div>
          ${target > 1 ? `<span class="quantity-chip">${count}/${target}</span>` : ""}
          ${delayedDays > 0 ? `<span class="status-badge delayed" aria-label="Delayed ${escapeHTML(delayedText)}">${icon("startTomorrow")} ${escapeHTML(delayedText)}</span>` : ""}
          ${isPausedForDate ? `<span class="status-badge paused" aria-label="Paused">${icon("pause")} Paused</span>` : ""}
        </div>
        <div class="task-meta">
          <span>${icon("repeat", "meta-icon")} ${escapeHTML(scheduleText(item))}</span>
          ${item.reminderMinutes == null ? "" : `<span>${icon("clock", "meta-icon")} ${escapeHTML(timeText(item.reminderMinutes))}</span>`}
          ${isSkipped ? "<span>Skipped today</span>" : ""}
        </div>
        ${item.notes ? `<p class="notes">${escapeHTML(item.notes)}</p>` : ""}
      </div>
      <div class="task-actions">
        ${isSkipped ? `<button class="mini-button" data-action="unskip" data-id="${item.id}">Undo</button>` : isPausedForDate ? `<button class="mini-button accent" data-action="resume" data-id="${item.id}">${icon("play")} Resume</button>` : !isComplete ? `<button class="mini-button accent" data-action="skip" data-id="${item.id}">Skip</button>` : ""}
        ${!isComplete && !isSkipped && !isPausedForDate ? `<button class="mini-button" data-action="pause" data-id="${item.id}">${icon("pause")} Pause</button>` : ""}
        ${!isComplete && !isSkipped && !isPausedForDate && isFutureDate(state.selectedDate) ? `<button class="mini-button" data-action="bring-forward" data-id="${item.id}">${icon("startToday")} Today</button>` : ""}
        ${!isComplete && !isSkipped && !isPausedForDate ? `<button class="mini-button" data-action="delay" data-id="${item.id}">Delay</button>` : ""}
        <button class="mini-button" data-action="history" data-id="${item.id}" aria-label="History for ${escapeHTML(item.title)}">History</button>
        ${state.mode === "archive" ? `<button class="mini-button danger" data-action="delete-item" data-id="${item.id}" aria-label="Delete ${escapeHTML(item.title)} permanently">Delete</button>` : ""}
        <button class="edit-button" data-action="edit" data-id="${item.id}" aria-label="Edit ${escapeHTML(item.title)}">${icon("pencil")}</button>
      </div>
    </article>`;
  }

  function renderGroup(name, items, groupID, realGroup, { allowsBulkActions = false, isCollapsed = false } = {}) {
    if (!items.length) return "";
    const groupPaused = realGroup && groupID ? isGroupPaused(groupID, state.selectedDate) : false;
    const todo = items.filter((item) => !complete(item) && !isPaused(item, state.selectedDate));
    const done = items.filter(complete);
    const ordered = realGroup && todo.length ? [...todo, ...done] : items;
    return `<section class="group">
      <div class="group-head">
        <div class="group-title">
          ${realGroup ? `<button class="folder-toggle" data-action="toggle-group" data-group="${groupID}" aria-label="${isCollapsed ? `Open ${escapeHTML(name)}` : `Close ${escapeHTML(name)}`}">${icon(isCollapsed ? "folderClosed" : "folderOpen")}</button>` : ""}
          <span class="group-name">${escapeHTML(name)}</span>
          <span>${groupProgress(items)}</span>
          ${groupPaused ? `<span class="status-badge paused">${icon("pause")} Paused</span>` : ""}
        </div>
        <div class="group-actions">
          ${allowsBulkActions && todo.length ? `<button class="complete-all" data-action="complete-group" data-group="${groupID || ""}">${icon("check")} All</button>` : ""}
          ${allowsBulkActions && realGroup ? (groupPaused
            ? `<button class="mini-button" data-action="resume-group" data-group="${groupID}">${icon("play")} Resume</button>`
            : `<button class="mini-button" data-action="pause-group" data-group="${groupID}">${icon("pause")} Pause</button>`) : ""}
        </div>
      </div>
      ${isCollapsed ? "" : `<div class="task-list">${ordered.length ? ordered.map(renderTask).join("") : `<div class="empty-group">No tasks</div>`}</div>`}
    </section>`;
  }

  function renderChecklist() {
    const items = visibleItems();
    const groups = [...state.groups].sort((a, b) => a.sortOrder - b.sortOrder);
    const known = new Set(groups.map((group) => group.id));
    const ungrouped = items.filter((item) => !item.groupID || !known.has(item.groupID));
    const remaining = items.filter((item) => !complete(item) && !skipped(item) && !isPaused(item, state.selectedDate)).length;
    const dateLabel = state.selectedDate.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" });
    const title = sameDay(state.selectedDate, new Date()) ? "Ritual Cue" : state.selectedDate.toLocaleDateString([], { month: "short", day: "numeric" });
    const hidesPausedExpected = state.mode === "today";
    const subtitle = state.mode === "archive"
      ? `${items.length} ${items.length === 1 ? "archived item" : "archived items"}.`
      : `${remaining} ${remaining === 1 ? "thing" : "things"} left today.`;
    const separatesSkipped = state.mode === "today";
    const isTodoItem = (item) => !complete(item)
      && (!hidesPausedExpected || !isPaused(item, state.selectedDate))
      && (!separatesSkipped || !skipped(item));
    const ungroupedTodo = ungrouped.filter(isTodoItem);
    const ungroupedSkipped = separatesSkipped ? ungrouped.filter((item) => skipped(item) && !complete(item)) : [];
    const ungroupedDone = ungrouped.filter(complete);
    const grouped = groups.map((group) => ({
      group,
      items: items.filter((item) => item.groupID === group.id)
    })).filter((entry) => entry.items.length);
    const todoBody = [
      renderGroup("Ungrouped", ungroupedTodo, "", false, { allowsBulkActions: true }),
      ...grouped.filter((entry) => entry.items.some(isTodoItem))
        .map((entry) => renderGroup(entry.group.name, entry.items.filter(isTodoItem), entry.group.id, true, { allowsBulkActions: true, isCollapsed: entry.group.isCollapsed === true }))
    ].join("");
    const skippedBody = [
      renderGroup("Ungrouped", ungroupedSkipped, "", false),
      ...grouped.filter((entry) => separatesSkipped && entry.items.some((item) => skipped(item) && !complete(item)))
        .map((entry) => renderGroup(entry.group.name, entry.items.filter((item) => skipped(item) && !complete(item)), entry.group.id, true, { isCollapsed: entry.group.isCollapsed === true }))
    ].join("");
    const completedBody = [
      renderGroup("Ungrouped", ungroupedDone, "", false),
      ...grouped.filter((entry) => entry.items.some(complete))
        .map((entry) => renderGroup(entry.group.name, entry.items.filter(complete), entry.group.id, true, { isCollapsed: entry.group.isCollapsed === true }))
    ].join("");
    const archiveBody = state.mode === "archive" ? [
      renderGroup("Ungrouped", ungrouped, "", false),
      ...grouped.map((entry) => renderGroup(entry.group.name, entry.items, entry.group.id, true, { isCollapsed: entry.group.isCollapsed === true }))
    ].join("") : "";

    app.innerHTML = `<div class="shell">
      <div class="topline">
        <div>
          <p class="eyebrow">${escapeHTML(dateLabel)}</p>
          <h1>${escapeHTML(title)}</h1>
          <p class="subtitle">${escapeHTML(subtitle)}</p>
        </div>
        <div>
          <div class="date-nav">
            <button class="circle-button" data-action="previous" aria-label="Previous day">${icon("chevronLeft")}</button>
            <button class="circle-button" data-action="next" aria-label="Next day">${icon("chevronRight")}</button>
          </div>
          <div class="date-nav account-nav">
            ${renderAccountButton()}
          </div>
        </div>
      </div>
      <div class="controls">
        <div class="segmented">
          <button class="${state.mode === "today" ? "active" : ""}" data-action="mode" data-mode="today">Today</button>
          <button class="${state.mode === "all" ? "active" : ""}" data-action="mode" data-mode="all">All items</button>
          <button class="${state.mode === "archive" ? "active" : ""}" data-action="mode" data-mode="archive">Archive</button>
        </div>
        <div class="toolbar">
          <button class="sort-button" data-action="sort">${icon("arrowDownUp")} ${state.sort === "manual" ? "Manual" : state.sort === "name" ? "Name" : "Time"}</button>
        </div>
        <label class="search-field"><span>${icon("search")}</span><input data-search placeholder="Search tasks" value="${escapeHTML(state.search)}"></label>
      </div>
      ${state.mode === "archive" ? `<div class="section-head"><span class="section-label">Archive</span></div>${archiveBody || `<div class="empty">No ended tasks.</div>`}` : `<div class="section-head">
        <span class="section-label">To do</span>
        ${remaining ? `<button class="complete-all" data-action="complete-all">${icon("check")} All&nbsp;&nbsp;${remaining}</button>` : ""}
      </div>
      ${todoBody || `<div class="empty">${completedBody ? "Everything is complete." : "Nothing is scheduled for this day."}</div>`}
      ${skippedBody ? `<div class="section-head"><span class="section-label">Skipped</span></div>${skippedBody}` : ""}
      ${completedBody ? `<div class="section-head"><span class="section-label">Completed</span></div>${completedBody}` : ""}`}
      <button class="fab" data-action="add" aria-label="Add checklist item">+</button>
      ${renderModal()}
      ${state.toast ? `<div class="toast">${escapeHTML(state.toast)}</div>` : ""}
    </div>`;
  }

  function renderAccountButton() {
    const photo = state.user?.profileImageURL;
    return `<button class="account-button" data-action="account" aria-label="Account">${
      photo ? `<img class="account-avatar" src="${escapeHTML(photo)}" alt="">` : icon("user")
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
        <button class="diagnostic-button" data-action="copy-diagnostics">Copy diagnostics</button>
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
    return { ...source, quantity: quantity(source), start, end, time };
  }

  function renderModal() {
    if (!state.modal) return "";
    if (state.modal.type === "account") {
      const displayName = state.user?.name || "Ritual Cue account";
      const email = state.user?.email || "";
      const photo = state.user?.profileImageURL;
      return `<div class="scrim" data-action="close"><section class="modal" data-modal>
        <h2>Account</h2>
        <div class="account-card">
          <div class="account-profile">
            <div class="account-photo">${photo ? `<img src="${escapeHTML(photo)}" alt="">` : icon("user")}</div>
            <strong>${escapeHTML(displayName)}</strong>
            <p>${escapeHTML(email)}</p>
          </div>
          <div class="account-panel">
            <button data-action="insights"><span>Routine insights</span><small>Private patterns from your last 21 days</small></button>
            <button data-action="export-data"><span>Export data</span><small>Copy a JSON backup</small></button>
            <button data-action="import-data"><span>Restore from export</span><small>Replace synced data with a JSON backup</small></button>
            <button data-action="copy-diagnostics"><span>Copy diagnostics</span><small>Copy build and sync details for support</small></button>
            <button data-action="privacy"><span>Privacy</span><small>Review data handling</small></button>
            <button data-action="support"><span>Support</span><small>Get help with Ritual Cue</small></button>
          </div>
          <div class="account-panel">
            <button class="danger" data-action="sign-out"><span>Sign out</span></button>
            <button class="danger" data-action="delete-account"><span>Delete account</span><small>Remove synced account data</small></button>
          </div>
          <input type="file" accept="application/json,.json" data-import-file hidden>
        </div>
        <div class="modal-actions"><span></span><button class="secondary" data-action="close">Done</button></div>
      </section></div>`;
    }
    if (state.modal.type === "insights") {
      return renderRoutineInsights(routineInsights());
    }
    if (state.modal.type === "history") {
      const item = state.modal.item;
      const historyEntries = historyFor(item);
      const calendarEntries = historyCalendarFor(historyEntries);
      return `<div class="scrim" data-action="close"><section class="modal" data-modal>
        <h2>${escapeHTML(item.title)}</h2>
        ${renderHistoryCalendar(calendarEntries)}
        <div class="history-list">
          ${historyEntries.map((entry) => `<div class="history-row">
            <span>${escapeHTML(entry.label)}</span>
            <div class="history-actions">
              ${canDelayHistoryState(entry.state) ? `<button class="history-delay" data-action="delay-history" data-id="${item.id}" data-date="${entry.key}" aria-label="Delay ${escapeHTML(entry.label)} to next day">${icon("startTomorrow")}</button>` : ""}
              ${canBringForwardHistoryState(entry.key, entry.state) ? `<button class="history-bring-forward" data-action="bring-forward-history" data-id="${item.id}" data-date="${entry.key}" aria-label="Bring ${escapeHTML(entry.label)} to today">${icon("startToday")}</button>` : ""}
              <select class="history-state ${entry.state.toLowerCase()}" data-history-state data-id="${item.id}" data-date="${entry.key}" aria-label="Change state for ${escapeHTML(entry.label)}">
                ${historyOptions(item, entry.key, entry.state)}
              </select>
            </div>
          </div>`).join("")}
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
      <label class="field">Quantity<input name="quantity" type="number" min="1" max="99" step="1" inputmode="numeric" value="${item.quantity}"></label>
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

  async function restoreSession() {
    if (state.token) return true;
    const refreshed = await refreshAccessToken();
    if (refreshed) await sync();
    render();
    return refreshed;
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

  async function signOut() {
    try {
      await request("/auth/logout", { method: "POST", body: JSON.stringify({}) }, false);
    } catch {}
    clearSession();
    state.modal = null;
    render();
  }

  async function exportData() {
    const response = await fetch("/api/export", {
      headers: state.token ? { Authorization: `Bearer ${state.token}` } : {}
    });
    if (response.status === 401 && await refreshAccessToken()) return exportData();
    if (!response.ok) throw new Error("Unable to export data.");
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "ritual-cue-export.json";
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  function webSyncState() {
    if (state.syncing) return "Syncing";
    if (state.pending.length) return "Changes pending";
    return hasSession() ? "Synced or cached" : "Signed out";
  }

  function diagnosticSummary() {
    return [
      "Ritual Cue Diagnostics",
      `Generated: ${new Date().toISOString()}`,
      "Surface: Web",
      `App Origin: ${location.origin}`,
      `Auth State: ${state.user ? "Signed in" : "Signed out"}`,
      `User ID: ${state.user?.id || "none"}`,
      `Device ID: ${state.deviceID}`,
      `Sync State: ${webSyncState()}`,
      `Pending Mutations: ${state.pending.length}`
    ].join("\n");
  }

  async function copyText(text) {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }
    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand("copy");
    textarea.remove();
  }

  async function copyDiagnostics() {
    await copyText(diagnosticSummary());
    showToast("Diagnostics copied.");
  }

  async function importDataFromFile(file) {
    if (!file) return;
    if (file.size > 2_000_000) throw new Error("That export file is too large.");
    let parsed;
    try {
      parsed = JSON.parse(await file.text());
    } catch {
      throw new Error("Select a valid Ritual Cue export.");
    }
    if (!confirm("Restore this Ritual Cue export? This replaces the synced checklist data on this account.")) return;
    const result = await request("/api/import", {
      method: "POST",
      body: JSON.stringify(parsed)
    });
    state.items = result.items || [];
    state.groups = result.groups || [];
    state.pending = [];
    state.modal = null;
    persistData();
    render();
    showToast("Export restored.");
  }

  async function deleteAccount(confirmed = false) {
    if (!confirmed && !confirm("Delete your Ritual Cue account and synced checklist data? This cannot be undone.")) return;
    const response = await fetch("/api/account", {
      method: "DELETE",
      headers: state.token ? { Authorization: `Bearer ${state.token}` } : {}
    });
    if (response.status === 401 && await refreshAccessToken()) return deleteAccount(true);
    if (!response.ok) throw new Error("Unable to delete account.");
    clearSession();
    state.modal = null;
    render();
  }

  function toggle(item) {
    const key = dateKey(state.selectedDate);
    item.completedDates ||= [];
    item.completionCounts ||= {};
    item.skippedDates ||= [];
    item.openDates ||= [];
    const wasSkipped = item.skippedDates.includes(key);
    const wasOpen = item.openDates.includes(key);
    if (complete(item)) {
      setCompletionCount(item, key, 0);
      if (!occursOnDate(item, state.selectedDate) && !item.openDates.includes(key)) item.openDates.push(key);
    } else {
      setCompletionCount(item, key, completionCount(item) + 1);
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      item.openDates = item.openDates.filter((date) => date !== key);
    }
    if (wasSkipped !== item.skippedDates.includes(key) || wasOpen !== item.openDates.includes(key)) {
      state.pending.push(mutation("upsert", {
        itemID: item.id,
        changedFields: ["skippedDates", "openDates"],
        item: { skippedDates: item.skippedDates, openDates: item.openDates }
      }));
    }
    queueCompletion(item, key);
    persistData();
    render();
    void sync();
  }

  function completeItems(items) {
    const key = dateKey(state.selectedDate);
    const changed = items.filter((item) => !complete(item));
    changed.forEach((item) => {
      item.completedDates ||= [];
      item.completionCounts ||= {};
      item.skippedDates = (item.skippedDates || []).filter((date) => date !== key);
      item.openDates = (item.openDates || []).filter((date) => date !== key);
      setCompletionCount(item, key, quantity(item));
      queueCompletion(item, key);
      state.pending.push(mutation("upsert", {
        itemID: item.id,
        changedFields: ["skippedDates", "openDates"],
        item: { skippedDates: item.skippedDates, openDates: item.openDates }
      }));
    });
    persistData();
    render();
    void sync();
  }

  function setSkipped(item, shouldSkip) {
    if (!item) return;
    const key = dateKey(state.selectedDate);
    item.skippedDates ||= [];
    item.openDates ||= [];
    item.completedDates ||= [];
    item.completionCounts ||= {};
    const wasCompletionCount = completionCount(item);
    if (shouldSkip) {
      if (!item.skippedDates.includes(key)) item.skippedDates.push(key);
      setCompletionCount(item, key, 0);
      item.openDates = item.openDates.filter((date) => date !== key);
      if (wasCompletionCount > 0) queueCompletion(item, key);
    } else {
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      if (!occursOnDate(item, state.selectedDate) && !item.openDates.includes(key)) item.openDates.push(key);
    }
    queue(mutation("upsert", {
      itemID: item.id,
      changedFields: ["skippedDates", "openDates"],
      item: { skippedDates: item.skippedDates, openDates: item.openDates }
    }));
  }

  function pauseItem(item, days = 7) {
    if (!item) return;
    const start = startOfDay(state.selectedDate);
    const end = addDays(start, Math.max(1, days) - 1);
    item.pauseWindows = pauseWindowsWithRange(item.pauseWindows, start, end);
    queue(mutation("upsert", {
      itemID: item.id,
      changedFields: ["pauseWindows"],
      item: { pauseWindows: item.pauseWindows }
    }));
  }

  function resumeItem(item) {
    if (!item) return;
    const next = pauseWindowsResumed(item.pauseWindows, state.selectedDate);
    if (JSON.stringify(normalizePauseWindows(item.pauseWindows)) === JSON.stringify(next)) return;
    item.pauseWindows = next;
    queue(mutation("upsert", {
      itemID: item.id,
      changedFields: ["pauseWindows"],
      item: { pauseWindows: item.pauseWindows }
    }));
  }

  function pauseGroup(groupID, days = 7) {
    const group = groupByID(groupID);
    if (!group) return;
    const start = startOfDay(state.selectedDate);
    const end = addDays(start, Math.max(1, days) - 1);
    group.pauseWindows = pauseWindowsWithRange(group.pauseWindows, start, end);
    queue(mutation("groupUpsert", {
      groupID: group.id,
      changedFields: ["pauseWindows"],
      group: { pauseWindows: group.pauseWindows }
    }));
  }

  function resumeGroup(groupID) {
    const group = groupByID(groupID);
    if (!group) return;
    const next = pauseWindowsResumed(group.pauseWindows, state.selectedDate);
    if (JSON.stringify(normalizePauseWindows(group.pauseWindows)) === JSON.stringify(next)) return;
    group.pauseWindows = next;
    queue(mutation("groupUpsert", {
      groupID: group.id,
      changedFields: ["pauseWindows"],
      group: { pauseWindows: group.pauseWindows }
    }));
  }

  function moveOpenItemDate(item, sourceDate, targetDate, successMessage) {
    item.completedDates ||= [];
    item.completionCounts ||= {};
    item.skippedDates ||= [];
    item.openDates ||= [];

    const sourceKey = dateKey(startOfDay(sourceDate));
    const targetKey = dateKey(startOfDay(targetDate));
    const wasSourceCompleted = item.completedDates.includes(sourceKey);
    const wasSourceCompletionCount = completionCount(item, sourceDate);
    const wasSourceSkipped = item.skippedDates.includes(sourceKey);
    const wasSourceOpen = item.openDates.includes(sourceKey);
    const wasTargetCompleted = item.completedDates.includes(targetKey);
    const wasTargetCompletionCount = completionCount(item, targetDate);
    const wasTargetSkipped = item.skippedDates.includes(targetKey);
    const wasTargetOpen = item.openDates.includes(targetKey);

    setCompletionCount(item, sourceKey, 0);
    setCompletionCount(item, targetKey, 0);
    if (!item.skippedDates.includes(sourceKey)) item.skippedDates.push(sourceKey);
    item.skippedDates = item.skippedDates.filter((date) => date !== targetKey);
    item.openDates = item.openDates.filter((date) => date !== sourceKey);
    if (!item.openDates.includes(targetKey)) item.openDates.push(targetKey);

    if (wasSourceCompletionCount > 0 || wasSourceCompleted || !wasSourceSkipped) {
      state.pending.push(mutation("completion", { itemID: item.id, completionDate: sourceKey, completed: false, completionCount: 0 }));
    }
    if (wasTargetCompletionCount > 0 || wasTargetCompleted) {
      state.pending.push(mutation("completion", { itemID: item.id, completionDate: targetKey, completed: false, completionCount: 0 }));
    }
    const skippedChanged = wasSourceSkipped !== item.skippedDates.includes(sourceKey)
      || wasTargetSkipped !== item.skippedDates.includes(targetKey);
    const openChanged = wasSourceOpen !== item.openDates.includes(sourceKey)
      || wasTargetOpen !== item.openDates.includes(targetKey);
    if (skippedChanged || openChanged) {
      state.pending.push(mutation("upsert", {
        itemID: item.id,
        changedFields: [
          ...(skippedChanged ? ["skippedDates"] : []),
          ...(openChanged ? ["openDates"] : [])
        ],
        item: { skippedDates: item.skippedDates, openDates: item.openDates }
      }));
    }
    persistData();
    showToast(successMessage);
    render();
    void sync();
  }

  function delayItem(item, fromDate = state.selectedDate) {
    if (!item) return;
    if (item.schedule === "everyDay") {
      showToast(delayDailyMessage);
      return;
    }
    moveOpenItemDate(item, fromDate, addDays(fromDate, 1), "Delayed to the next day.");
  }

  function bringForwardItem(item, fromDate = state.selectedDate) {
    if (!item) return;
    if (item.schedule === "everyDay") {
      showToast(bringForwardDailyMessage);
      return;
    }
    if (!isFutureDate(fromDate)) {
      showToast("Only future items can be brought forward to today.");
      return;
    }
    moveOpenItemDate(item, fromDate, new Date(), "Brought forward to today.");
  }

  function historyFor(item) {
    const today = startOfDay(state.selectedDate);
    return Array.from({ length: 21 }, (_, offset) => {
      const date = addDays(today, -offset);
      return historyEntryForDate(item, date);
    });
  }

  function routineInsights(days = 21) {
    const anchor = startOfDay(new Date());
    const completedDays = Array.from({ length: Math.max(1, days) }, (_, index) => addDays(anchor, -(index + 1)));
    let completedCheckIns = 0;
    let expectedCheckIns = 0;
    let recentCompleted = 0;
    let recentExpected = 0;
    let priorCompleted = 0;
    let priorExpected = 0;
    const missedWeekdays = new Map();

    state.items.forEach((item) => {
      completedDays.forEach((day, index) => {
        const historyState = historyStateForDate(item, day);
        const expected = ["Done", "Missed", "Open"].includes(historyState);
        if (!expected) return;
        expectedCheckIns += 1;
        if (historyState === "Done") completedCheckIns += 1;
        if (index < 7) {
          recentExpected += 1;
          if (historyState === "Done") recentCompleted += 1;
        } else if (index < 14) {
          priorExpected += 1;
          if (historyState === "Done") priorCompleted += 1;
        }
        if (["Missed", "Open"].includes(historyState)) {
          const weekday = day.getDay();
          missedWeekdays.set(weekday, (missedWeekdays.get(weekday) || 0) + 1);
        }
      });
    });

    const rate = (done, expected) => Math.round(done / expected * 100);
    const trend = recentExpected >= 3 && priorExpected >= 3
      ? rate(recentCompleted, recentExpected) - rate(priorCompleted, priorExpected)
      : null;
    const activeItems = state.items.filter((item) => !item.endedAt);
    const highlights = activeItems.map((item) => ({ title: item.title, count: insightStreak(item, anchor, days) }));
    const currentStreak = highlights.filter((entry) => entry.count > 0).sort(insightHighlightSort)[0] || null;
    const delays = activeItems.map((item) => ({
      title: item.title,
      count: Math.max(...Array.from({ length: days }, (_, offset) => {
        const day = addDays(anchor, -offset);
        return isPaused(item, day) ? 0 : delayedDaysOnDate(item, day);
      }))
    }));
    const longestDelay = delays.filter((entry) => entry.count > 0).sort(insightHighlightSort)[0] || null;
    const missedPattern = [...missedWeekdays.entries()]
      .map(([weekday, count]) => ({ weekday, count }))
      .sort((left, right) => right.count - left.count || left.weekday - right.weekday)[0] || null;

    return {
      completedCheckIns,
      expectedCheckIns,
      completionPercentage: expectedCheckIns ? rate(completedCheckIns, expectedCheckIns) : 0,
      hasEnoughData: expectedCheckIns >= 3,
      trend,
      currentStreak,
      missedWeekday: missedPattern?.count >= 2
        ? addDays(anchor, -(anchor.getDay() - missedPattern.weekday + 7) % 7).toLocaleDateString([], { weekday: "long" })
        : null,
      missedWeekdayCount: missedPattern?.count >= 2 ? missedPattern.count : 0,
      longestDelay
    };
  }

  function insightStreak(item, anchor, days) {
    let cursor = anchor;
    let streak = 0;
    if (historyStateForDate(item, cursor) !== "Done") cursor = addDays(cursor, -1);
    for (let inspected = 0; inspected < days; inspected += 1) {
      const historyState = historyStateForDate(item, cursor);
      if (historyState === "Done") streak += 1;
      else if (!["Off", "Paused"].includes(historyState)) return streak;
      cursor = addDays(cursor, -1);
    }
    return streak;
  }

  function insightHighlightSort(left, right) {
    return right.count - left.count || left.title.localeCompare(right.title);
  }

  function renderRoutineInsights(summary) {
    if (!summary.hasEnoughData) {
      return `<div class="scrim" data-action="close"><section class="modal" data-modal>
        <h2>Routine insights</h2>
        <p class="insights-privacy">Calculated in this browser from your last 21 days, excluding today. Nothing is sent to an analytics service.</p>
        <div class="insights-empty">
          <span class="insights-empty-icon">${icon("chart")}</span>
          <strong>Your patterns will appear here</strong>
          <p>Keep using your checklist normally. Insights begin after three scheduled check-ins have finished or passed.</p>
        </div>
        <div class="modal-actions"><span></span><button class="secondary" data-action="close">Done</button></div>
      </section></div>`;
    }

    const trendValue = summary.trend == null ? "Building" : summary.trend === 0 ? "Steady" : `${summary.trend > 0 ? "+" : ""}${summary.trend} pts`;
    const trendDetail = summary.trend == null ? "A little more history is needed." : "Last 7 days compared with the prior 7.";
    const streakValue = summary.currentStreak ? `${summary.currentStreak.count} ${summary.currentStreak.count === 1 ? "day" : "days"}` : "None yet";
    const missedValue = summary.missedWeekday || "No repeat";
    const missedDetail = summary.missedWeekday ? `${summary.missedWeekdayCount} open or missed check-ins` : "No weekday stands out yet.";
    const delayValue = summary.longestDelay?.title || "None";
    const delayDetail = summary.longestDelay
      ? `Moved forward ${summary.longestDelay.count} ${summary.longestDelay.count === 1 ? "day" : "days"}`
      : "No delayed routine in this window.";

    return `<div class="scrim" data-action="close"><section class="modal" data-modal>
      <h2>Routine insights</h2>
      <p class="insights-privacy">Calculated in this browser from your last 21 days, excluding today. Nothing is sent to an analytics service.</p>
      <div class="insights-completion">
        <strong>${summary.completionPercentage}%</strong>
        <span><b>Completion</b>${summary.completedCheckIns} of ${summary.expectedCheckIns} scheduled check-ins finished</span>
      </div>
      <div class="insights-grid">
        ${renderInsightCard("Current streak", streakValue, summary.currentStreak?.title || "A completed run will show here.")}
        ${renderInsightCard("7-day trend", trendValue, trendDetail)}
        ${renderInsightCard("Missed pattern", missedValue, missedDetail)}
        ${renderInsightCard("Longest delay", delayValue, delayDetail)}
      </div>
      <div class="modal-actions"><span></span><button class="secondary" data-action="close">Done</button></div>
    </section></div>`;
  }

  function renderInsightCard(title, value, detail) {
    return `<div class="insight-card"><span>${escapeHTML(title)}</span><strong>${escapeHTML(value)}</strong><small>${escapeHTML(detail)}</small></div>`;
  }

  function historyEntryForDate(item, date) {
    const day = startOfDay(date);
    return {
      date: day,
      day: day.getDate(),
      label: day.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" }),
      fullLabel: day.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", year: "numeric" }),
      key: dateKey(day),
      state: historyStateForDate(item, day)
    };
  }

  function historyStateForDate(item, date) {
    const key = dateKey(date);
    if ((item.completedDates || []).includes(key)) return "Done";
    if ((item.skippedDates || []).includes(key)) return "Skipped";
    if ((item.openDates || []).includes(key)) return "Open";
    if (isPaused(item, date)) return "Paused";
    if (isScheduledOnDate(item, date) && date < startOfDay(new Date())) return "Missed";
    if (isScheduledOnDate(item, date)) return "Open";
    return "Off";
  }

  function historyCalendarFor(historyEntries) {
    const chronological = [...historyEntries].reverse();
    if (!chronological.length) return [];

    const leading = chronological[0].date.getDay();
    const occupied = leading + chronological.length;
    const trailing = (7 - (occupied % 7)) % 7;

    return [
      ...Array.from({ length: leading }, (_, index) => ({ empty: true, id: `leading-${index}` })),
      ...chronological.map((entry) => ({ ...entry, id: entry.key })),
      ...Array.from({ length: trailing }, (_, index) => ({ empty: true, id: `trailing-${index}` }))
    ];
  }

  function renderHistoryCalendar(calendarEntries) {
    const weekdays = ["S", "M", "T", "W", "T", "F", "S"];
    return `<div class="history-calendar">
      <div class="history-calendar-title">${escapeHTML(historyCalendarTitle(calendarEntries))}</div>
      <div class="history-calendar-weekdays">
        ${weekdays.map((weekday) => `<span>${weekday}</span>`).join("")}
      </div>
      <div class="history-calendar-grid">
        ${calendarEntries.map((entry) => entry.empty
          ? `<div class="history-calendar-day empty" aria-hidden="true"></div>`
          : `<div class="history-calendar-day ${historyStateClass(entry.state)}" aria-label="${escapeHTML(entry.fullLabel)}, ${escapeHTML(entry.state)}">
              <span>${entry.day}</span>
              <span class="history-calendar-icon">${historyIcon(entry.state)}</span>
            </div>`).join("")}
      </div>
    </div>`;
  }

  function historyCalendarTitle(calendarEntries) {
    const dates = calendarEntries.filter((entry) => !entry.empty).map((entry) => dateFromInput(entry.key));
    const first = dates[0];
    const last = dates[dates.length - 1];
    if (!first || !last) return "History";
    if (first.getMonth() === last.getMonth() && first.getFullYear() === last.getFullYear()) {
      return last.toLocaleDateString([], { month: "long", year: "numeric" });
    }
    const startLabel = first.toLocaleDateString([], { month: "short" });
    const endLabel = last.toLocaleDateString([], { month: "short", year: "numeric" });
    return `${startLabel} - ${endLabel}`;
  }

  function historyStateClass(historyState) {
    return historyState.toLowerCase();
  }

  function historyIcon(historyState) {
    switch (historyState) {
      case "Done": return icon("check");
      case "Skipped": return icon("skip");
      case "Missed": return icon("xCircle");
      case "Open": return icon("circle");
      case "Paused": return icon("pause");
      default: return "";
    }
  }

  function canDelayHistoryState(historyState) {
    return historyState === "Open" || historyState === "Missed";
  }

  function canBringForwardHistoryState(key, historyState) {
    return historyState === "Open" && isFutureDate(dateFromInput(key));
  }

  function historyOptions(item, dateKeyValue, currentState) {
    const date = dateFromInput(dateKeyValue);
    const options = ["Done", "Open"];
    if (isScheduledOnDate(item, date) && date < startOfDay(new Date())) options.push("Missed");
    else if (!isScheduledOnDate(item, date)) options.push("Off");
    options.push("Paused");
    options.push("Skipped");
    return options.map((option) => (
      `<option value="${option.toLowerCase()}" ${option === currentState ? "selected" : ""}>${option}</option>`
    )).join("");
  }

  function setHistoryState(itemID, key, nextState) {
    const item = state.items.find((candidate) => candidate.id === itemID);
    if (!item) return;
    item.completedDates ||= [];
    item.completionCounts ||= {};
    item.skippedDates ||= [];
    item.openDates ||= [];
    item.pauseWindows ||= [];
    const wasCompleted = item.completedDates.includes(key);
    const wasCompletionCount = completionCount(item, dateFromInput(key));
    const wasSkipped = item.skippedDates.includes(key);
    const wasOpen = item.openDates.includes(key);
    const wasPauseWindows = JSON.stringify(normalizePauseWindows(item.pauseWindows));

    if (nextState === "done") {
      setCompletionCount(item, key, quantity(item));
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      item.openDates = item.openDates.filter((date) => date !== key);
      item.pauseWindows = pauseWindowsClearedOn(item.pauseWindows, key);
    } else if (nextState === "skipped") {
      setCompletionCount(item, key, 0);
      if (!item.skippedDates.includes(key)) item.skippedDates.push(key);
      item.openDates = item.openDates.filter((date) => date !== key);
      item.pauseWindows = pauseWindowsClearedOn(item.pauseWindows, key);
    } else if (nextState === "open") {
      setCompletionCount(item, key, 0);
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      if (!item.openDates.includes(key)) item.openDates.push(key);
      item.pauseWindows = pauseWindowsClearedOn(item.pauseWindows, key);
    } else if (nextState === "paused") {
      setCompletionCount(item, key, 0);
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      item.openDates = item.openDates.filter((date) => date !== key);
      item.pauseWindows = pauseWindowsForOneDay(item.pauseWindows, key);
    } else {
      setCompletionCount(item, key, 0);
      item.skippedDates = item.skippedDates.filter((date) => date !== key);
      item.openDates = item.openDates.filter((date) => date !== key);
      item.pauseWindows = pauseWindowsClearedOn(item.pauseWindows, key);
    }

    const isCompleted = item.completedDates.includes(key);
    const nextCompletionCount = completionCount(item, dateFromInput(key));
    const isSkipped = item.skippedDates.includes(key);
    const isOpen = item.openDates.includes(key);
    const pauseChanged = wasPauseWindows !== JSON.stringify(normalizePauseWindows(item.pauseWindows));
    if (wasCompleted === isCompleted && wasCompletionCount === nextCompletionCount && wasSkipped === isSkipped && wasOpen === isOpen && !pauseChanged) return;

    if (wasCompleted !== isCompleted || wasCompletionCount !== nextCompletionCount || (!isCompleted && (isSkipped || wasSkipped))) {
      state.pending.push(mutation("completion", {
        itemID: item.id,
        completionDate: key,
        completed: isCompleted,
        completionCount: nextCompletionCount
      }));
    }
    if (wasSkipped !== isSkipped || wasOpen !== isOpen || pauseChanged) {
      state.pending.push(mutation("upsert", {
        itemID: item.id,
        changedFields: [
          ...(wasSkipped !== isSkipped ? ["skippedDates"] : []),
          ...(wasOpen !== isOpen ? ["openDates"] : []),
          ...(pauseChanged ? ["pauseWindows"] : [])
        ],
        item: { skippedDates: item.skippedDates, openDates: item.openDates, pauseWindows: item.pauseWindows }
      }));
    }
    persistData();
    state.modal = { type: "history", item };
    render();
    void sync();
  }

  function toggleGroupCollapsed(groupID) {
    const group = state.groups.find((candidate) => candidate.id === groupID);
    if (!group) return;
    group.isCollapsed = group.isCollapsed !== true;
    queue(mutation("groupUpsert", {
      groupID: group.id,
      changedFields: ["isCollapsed"],
      group: { isCollapsed: group.isCollapsed }
    }));
  }

  function applyTemplate(templateID) {
    const template = templates.find((candidate) => candidate.id === templateID);
    if (!template) return;
    let group = state.groups.find((candidate) => candidate.name.toLowerCase() === template.groupName.toLowerCase());
    if (!group) {
      group = { id: crypto.randomUUID(), name: template.groupName, sortOrder: state.groups.length, isCollapsed: false, pauseWindows: [] };
      state.groups.push(group);
      state.pending.push(mutation("groupUpsert", {
        groupID: group.id,
        changedFields: ["name", "sortOrder", "isCollapsed", "pauseWindows"],
        group: { name: group.name, sortOrder: group.sortOrder, isCollapsed: group.isCollapsed, pauseWindows: group.pauseWindows }
      }));
    }
    const firstOrder = state.items.filter((item) => item.groupID === group.id).length;
    for (const [index, title] of template.items.entries()) {
    const item = {
        id: crypto.randomUUID(),
        title,
        notes: "",
        schedule: "everyDay",
        customWeekdays: [],
        reminderMinutes: null,
        quantity: 1,
        completedDates: [],
        completionCounts: {},
        skippedDates: [],
        openDates: [],
        createdAt: new Date().toISOString(),
        startDate: null,
        endedAt: null,
        groupID: group.id,
        sortOrder: firstOrder + index,
        pauseWindows: [],
      };
      state.items.push(item);
      state.pending.push(mutation("upsert", {
        itemID: item.id,
        changedFields: ["title","notes","schedule","customWeekdays","reminderMinutes","quantity","skippedDates","openDates","createdAt","startDate","endedAt","groupID","sortOrder","pauseWindows"],
        item
      }));
    }
    state.modal = null;
    persistData();
    render();
    void sync();
  }

  function permanentlyDeleteItem(itemID) {
    const item = state.items.find((candidate) => candidate.id === itemID);
    if (!item?.endedAt) return;
    if (!confirm(`Permanently delete "${item.title}"?`)) return;
    state.items = state.items.filter((candidate) => candidate.id !== itemID);
    queue(mutation("delete", { itemID }));
  }

  function saveEditor(form) {
    const data = new FormData(form);
    const existing = state.modal.item;
    let groupID = data.get("groupID") || null;
    if (groupID === "__new") {
      const name = prompt("Name this group");
      if (!name?.trim()) return;
      const group = { id: crypto.randomUUID(), name: name.trim(), sortOrder: state.groups.length, isCollapsed: false, pauseWindows: [] };
      state.groups.push(group);
      state.pending.push(mutation("groupUpsert", {
        groupID: group.id, changedFields: ["name", "sortOrder", "isCollapsed", "pauseWindows"],
        group: { name: group.name, sortOrder: group.sortOrder, isCollapsed: group.isCollapsed, pauseWindows: group.pauseWindows }
      }));
      groupID = group.id;
    }
    const reminder = String(data.get("reminder") || "");
    const [hours, minutes] = reminder ? reminder.split(":").map(Number) : [null, null];
    const customWeekdays = [...form.querySelectorAll(".weekday.active")].map((button) => Number(button.dataset.day));
    const startDate = localISO(data.get("startDate"));
    const lastDay = dateFromInput(data.get("endDate"));
    const endedAt = lastDay ? addDays(lastDay, 1).toISOString() : null;
    const parsedQuantity = Number(data.get("quantity"));
    const item = {
      id: existing?.id || crypto.randomUUID(),
      title: String(data.get("title")).trim(),
      notes: String(data.get("notes") || "").trim(),
      schedule: data.get("schedule"),
      customWeekdays,
      reminderMinutes: reminder ? hours * 60 + minutes : null,
      quantity: Number.isInteger(parsedQuantity) ? Math.min(Math.max(1, parsedQuantity), 99) : 1,
      completedDates: existing?.completedDates || [],
      completionCounts: existing?.completionCounts || {},
      skippedDates: existing?.skippedDates || [],
      openDates: existing?.openDates || [],
      createdAt: existing?.createdAt || new Date().toISOString(),
      startDate,
      endedAt,
      groupID,
      sortOrder: existing?.sortOrder ?? state.items.filter((candidate) => candidate.groupID === groupID).length,
      pauseWindows: existing?.pauseWindows || [],
    };
    if (!item.title) return;
    const index = state.items.findIndex((candidate) => candidate.id === item.id);
    if (index >= 0) state.items[index] = item; else state.items.push(item);
    state.modal = null;
    queue(mutation("upsert", {
      itemID: item.id,
      changedFields: ["title","notes","schedule","customWeekdays","reminderMinutes","quantity","skippedDates","openDates","createdAt","startDate","endedAt","groupID","sortOrder","pauseWindows"],
      item: {
        title: item.title, notes: item.notes, schedule: item.schedule,
        customWeekdays: item.customWeekdays, reminderMinutes: item.reminderMinutes, quantity: item.quantity,
        skippedDates: item.skippedDates, openDates: item.openDates,
        createdAt: item.createdAt, startDate: item.startDate, endedAt: item.endedAt,
        groupID: item.groupID, sortOrder: item.sortOrder, pauseWindows: item.pauseWindows
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
    if (action === "skip") setSkipped(state.items.find((item) => item.id === target.dataset.id), true);
    if (action === "unskip") setSkipped(state.items.find((item) => item.id === target.dataset.id), false);
    if (action === "pause") pauseItem(state.items.find((item) => item.id === target.dataset.id));
    if (action === "resume") resumeItem(state.items.find((item) => item.id === target.dataset.id));
    if (action === "delay") delayItem(state.items.find((item) => item.id === target.dataset.id));
    if (action === "bring-forward") bringForwardItem(state.items.find((item) => item.id === target.dataset.id));
    if (action === "delay-history") {
      delayItem(state.items.find((item) => item.id === target.dataset.id), dateFromInput(target.dataset.date));
    }
    if (action === "bring-forward-history") {
      bringForwardItem(state.items.find((item) => item.id === target.dataset.id), dateFromInput(target.dataset.date));
    }
    if (action === "history") {
      state.modal = { type: "history", item: state.items.find((item) => item.id === target.dataset.id) };
      render();
    }
    if (action === "delete-item") permanentlyDeleteItem(target.dataset.id);
    if (action === "complete-all") completeItems(visibleItems().filter((item) => !isPaused(item, state.selectedDate)));
    if (action === "complete-group") {
      const id = target.dataset.group || null;
      completeItems(visibleItems().filter((item) => (item.groupID || null) === id && !isPaused(item, state.selectedDate)));
    }
    if (action === "toggle-group") toggleGroupCollapsed(target.dataset.group);
    if (action === "pause-group") pauseGroup(target.dataset.group);
    if (action === "resume-group") resumeGroup(target.dataset.group);
    if (action === "account") { state.modal = { type: "account" }; render(); }
    if (action === "insights") { state.modal = { type: "insights" }; render(); }
    if (action === "sign-out") await signOut();
    if (action === "export-data") {
      try { await exportData(); } catch (error) { showToast(error.message); }
    }
    if (action === "import-data") {
      const input = app.querySelector("[data-import-file]");
      if (input) input.click();
    }
    if (action === "copy-diagnostics") {
      try { await copyDiagnostics(); } catch { showToast("Unable to copy diagnostics."); }
    }
    if (action === "delete-account") {
      try { await deleteAccount(); } catch (error) { showToast(error.message); }
    }
    if (action === "privacy") { location.href = "/privacy.html"; }
    if (action === "support") { location.href = "/support.html"; }
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
          method: "POST", body: JSON.stringify({ email: "dev@ritualcue.local", name: "Local Dev" })
        }, false));
        await sync();
      } catch (error) { showToast(error.message); }
    }
    if (action === "apple") {
      try { await signInApple(); } catch (error) { showToast(error.message); }
    }
  });

  app.addEventListener("change", (event) => {
    if (event.target.matches("[data-import-file]")) {
      const [file] = event.target.files || [];
      event.target.value = "";
      importDataFromFile(file).catch((error) => showToast(error.message));
      return;
    }
    if (event.target.matches("[data-history-state]")) {
      setHistoryState(event.target.dataset.id, event.target.dataset.date, event.target.value);
      return;
    }
    if (event.target.name === "schedule") {
      const custom = event.target.closest("form").querySelector("[data-custom-days]");
      custom.hidden = event.target.value !== "custom";
    }
  });

  app.addEventListener("input", (event) => {
    if (!event.target.matches("[data-search]")) return;
    state.search = event.target.value;
    render();
  });

  app.addEventListener("submit", (event) => {
    if (!event.target.matches("[data-editor]")) return;
    event.preventDefault();
    saveEditor(event.target);
  });

  render();
  void loadAuthConfig();
  void restoreSession();
  window.addEventListener("online", () => void sync());
  window.addEventListener("load", renderGoogleButton);
})();
