(function () {
  "use strict";

  const app = document.getElementById("admin");
  const state = {
    token: "",
    overview: null,
    search: "",
    loading: true,
    error: ""
  };

  function escapeHTML(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[character]);
  }

  function formatNumber(value) {
    return new Intl.NumberFormat().format(Number(value || 0));
  }

  function formatDate(value) {
    if (!value) return "Never";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "Unknown";
    return date.toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
  }

  function matchesSearch(user) {
    const query = state.search.trim().toLowerCase();
    if (!query) return true;
    return [user.name, user.email, user.id, ...(user.providers || [])]
      .some((value) => String(value || "").toLowerCase().includes(query));
  }

  async function request(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}),
        ...(options.headers || {})
      }
    });
    if (!response.ok) {
      let message = `HTTP ${response.status}`;
      try { message = (await response.json()).error || message; } catch {}
      throw new Error(message);
    }
    return response.status === 204 ? null : response.json();
  }

  async function restoreSession() {
    const auth = await request("/auth/refresh", {
      method: "POST",
      body: JSON.stringify({})
    });
    state.token = auth.token || "";
  }

  async function loadOverview() {
    state.loading = true;
    state.error = "";
    render();
    try {
      if (!state.token) await restoreSession();
      state.overview = await request("/api/admin/overview");
    } catch (error) {
      state.error = error.message;
    } finally {
      state.loading = false;
      render();
    }
  }

  function renderStat(label, value) {
    return `<div class="admin-stat"><span>${escapeHTML(label)}</span><strong>${formatNumber(value)}</strong></div>`;
  }

  function renderAuthGate() {
    const forbidden = state.error === "Forbidden";
    return `<section class="admin-shell admin-center">
      <p class="eyebrow">Admin</p>
      <h1>Ritual Cue</h1>
      <p>${forbidden ? "This signed-in account is not allowed to view admin data." : "Sign in to an admin account before opening the dashboard."}</p>
      <div class="admin-actions">
        <a class="primary admin-link" href="/app">Open app</a>
        <button class="secondary" data-action="refresh">Retry</button>
      </div>
    </section>`;
  }

  function renderUser(user) {
    const status = user.disabledAt ? "Disabled" : "Active";
    const lastActivity = user.lastActivityAt || user.createdAt;
    return `<tr>
      <td>
        <div class="admin-user">
          <strong>${escapeHTML(user.name || user.email || "Unknown")}</strong>
          <span>${escapeHTML(user.email || "")}</span>
          <small>${escapeHTML((user.providers || []).join(", ") || "No provider")}</small>
        </div>
      </td>
      <td><span class="admin-badge ${user.disabledAt ? "danger" : "ok"}">${status}</span></td>
      <td>${formatDate(user.createdAt)}</td>
      <td>${formatDate(lastActivity)}</td>
      <td>${formatNumber(user.activeItems)} / ${formatNumber(user.totalItems)}</td>
      <td>${formatNumber(user.completedRecords)}</td>
      <td>${formatNumber(user.sessionCount)}</td>
      <td>
        <button class="mini-button danger" data-action="disable" data-id="${escapeHTML(user.id)}" ${user.disabledAt || user.isAdmin ? "disabled" : ""}>Disable</button>
      </td>
    </tr>`;
  }

  function renderDashboard() {
    const overview = state.overview;
    const users = (overview.users || []).filter(matchesSearch);
    app.innerHTML = `<section class="admin-shell">
      <div class="topline">
        <div>
          <p class="eyebrow">Admin</p>
          <h1>Ritual Cue</h1>
          <p class="subtitle">Generated ${formatDate(overview.generatedAt)}</p>
        </div>
        <button class="secondary" data-action="refresh">Refresh</button>
      </div>

      <section class="admin-stats" aria-label="Stats">
        ${renderStat("Users", overview.totals.totalUsers)}
        ${renderStat("Active", overview.totals.activeUsers)}
        ${renderStat("Disabled", overview.totals.disabledUsers)}
        ${renderStat("Sessions", overview.totals.activeSessions)}
        ${renderStat("Items", overview.totals.activeItems)}
        ${renderStat("Completions", overview.totals.completedRecords)}
        ${renderStat("Groups", overview.totals.activeGroups)}
        ${renderStat("Mutations", overview.totals.mutationCount)}
      </section>

      <div class="admin-toolbar">
        <label class="search-field">
          <input data-search value="${escapeHTML(state.search)}" placeholder="Search users">
        </label>
      </div>

      <section class="admin-table-wrap">
        <table class="admin-table">
          <thead>
            <tr>
              <th>User</th>
              <th>Status</th>
              <th>Signed up</th>
              <th>Activity</th>
              <th>Items</th>
              <th>Done</th>
              <th>Sessions</th>
              <th></th>
            </tr>
          </thead>
          <tbody>${users.map(renderUser).join("") || `<tr><td colspan="8" class="admin-empty">No users match this search.</td></tr>`}</tbody>
        </table>
      </section>
    </section>`;
  }

  function render() {
    if (state.loading) {
      app.innerHTML = `<div class="launch"><div class="launch-mark">R</div><strong>Loading admin</strong></div>`;
      return;
    }
    if (state.error) {
      app.innerHTML = renderAuthGate();
      return;
    }
    renderDashboard();
  }

  async function disableUser(id) {
    const reason = prompt("Reason for disabling this account?") || "";
    if (!confirm("Disable this account and revoke its sessions?")) return;
    await request(`/api/admin/users/${encodeURIComponent(id)}/disable`, {
      method: "POST",
      body: JSON.stringify({ reason })
    });
    await loadOverview();
  }

  app.addEventListener("click", (event) => {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    if (target.dataset.action === "refresh") void loadOverview();
    if (target.dataset.action === "disable") {
      void disableUser(target.dataset.id).catch((error) => {
        state.error = error.message;
        render();
      });
    }
  });

  app.addEventListener("input", (event) => {
    if (!event.target.matches("[data-search]")) return;
    state.search = event.target.value;
    render();
  });

  void loadOverview();
})();
