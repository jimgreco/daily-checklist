(function () {
  "use strict";

  const app = document.getElementById("admin");
  const state = {
    token: "",
    user: null,
    overview: null,
    selectedUserID: "",
    userDetail: null,
    detailLoading: false,
    search: "",
    loading: true,
    error: "",
    authLoaded: false,
    googleClientId: "",
    appleClientId: ""
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
    state.user = auth.user || null;
  }

  function applyAuth(auth) {
    state.token = auth.token || "";
    state.user = auth.user || null;
  }

  async function loadAuthConfig() {
    try {
      const config = await request("/auth/config");
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
      logo_alignment: "center", width
    });
  }

  async function googleCredential(response) {
    try {
      applyAuth(await request("/auth/google", {
        method: "POST",
        body: JSON.stringify({ idToken: response.credential })
      }));
      await loadOverview();
    } catch (error) {
      state.error = error.message;
      render();
    }
  }

  async function signInApple() {
    if (!window.AppleID?.auth || !state.appleClientId) throw new Error("Apple sign-in is not configured");
    window.AppleID.auth.init({
      clientId: state.appleClientId, scope: "name email", redirectURI: location.origin, usePopup: true
    });
    const response = await window.AppleID.auth.signIn();
    const authorization = response?.authorization || {};
    const name = response?.user?.name || {};
    applyAuth(await request("/auth/apple", {
      method: "POST",
      body: JSON.stringify({
        identityToken: authorization.id_token || null,
        authorizationCode: authorization.code || null,
        fullName: { givenName: name.firstName || null, familyName: name.lastName || null }
      })
    }));
    await loadOverview();
  }

  async function loadOverview() {
    state.loading = true;
    state.error = "";
    render();
    try {
      if (!state.token) await restoreSession();
      state.overview = await request("/api/admin/overview");
      if (state.selectedUserID) {
        try {
          state.userDetail = await request(`/api/admin/users/${encodeURIComponent(state.selectedUserID)}`);
        } catch (error) {
          if (error.message !== "User not found") throw error;
          state.selectedUserID = "";
          state.userDetail = null;
        }
      }
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

  function renderActionButtons(user, { includeDetails = true } = {}) {
    if (!user) return "";
    const id = escapeHTML(user.id);
    const disableButton = `<button class="mini-button danger" data-action="disable" data-id="${id}" ${user.disabledAt || user.isAdmin ? "disabled" : ""}>Disable</button>`;
    const reenableButton = `<button class="mini-button accent" data-action="reenable" data-id="${id}" ${user.disabledAt ? "" : "disabled"}>Re-enable</button>`;
    return `${includeDetails ? `<button class="mini-button" data-action="view" data-id="${id}">Details</button>` : ""}
      ${user.disabledAt ? reenableButton : disableButton}`;
  }

  function renderDetailMetric(label, value) {
    return `<div class="admin-detail-metric"><span>${escapeHTML(label)}</span><strong>${escapeHTML(value)}</strong></div>`;
  }

  function renderAuditEvents(events = []) {
    if (!events.length) return `<li class="admin-muted">No audit events</li>`;
    return events.map((event) => {
      const label = event.type === "reenabled" ? "Re-enabled" : "Disabled";
      const actor = event.actor ? ` by ${escapeHTML(event.actor)}` : "";
      const reason = event.reason ? `<small>${escapeHTML(event.reason)}</small>` : "";
      return `<li><strong>${label}</strong><span>${formatDate(event.at)}${actor}</span>${reason}</li>`;
    }).join("");
  }

  function renderSessions(sessions = []) {
    if (!sessions.length) return `<li class="admin-muted">No sessions</li>`;
    return sessions.map((session) => {
      const status = session.active ? "Active" : "Expired";
      return `<li><strong>${status}</strong><span>${formatDate(session.expiresAt)}</span></li>`;
    }).join("");
  }

  function renderUserDetail() {
    if (!state.selectedUserID) return "";
    if (state.detailLoading) {
      return `<section class="admin-detail"><div class="admin-detail-loading"><strong>Loading user</strong></div></section>`;
    }
    const user = state.userDetail;
    if (!user) return "";
    const status = user.disabledAt ? "Disabled" : "Active";
    const lastActivity = user.lastActivityAt || user.createdAt;
    const providerList = (user.providers || []).join(", ") || "No provider";
    return `<section class="admin-detail" aria-label="User detail">
      <div class="admin-detail-head">
        <div class="admin-user">
          <strong>${escapeHTML(user.name || user.email || "Unknown")}</strong>
          <span>${escapeHTML(user.email || "")}</span>
          <small>${escapeHTML(user.id)}</small>
        </div>
        <div class="admin-row-actions">
          ${renderActionButtons(user, { includeDetails: false })}
          <button class="mini-button" data-action="close-detail">Close</button>
        </div>
      </div>
      <section class="admin-detail-grid">
        ${renderDetailMetric("Status", status)}
        ${renderDetailMetric("Providers", providerList)}
        ${renderDetailMetric("Signed up", formatDate(user.createdAt))}
        ${renderDetailMetric("Activity", formatDate(lastActivity))}
        ${renderDetailMetric("Items", `${formatNumber(user.activeItems)} active / ${formatNumber(user.totalItems)} total`)}
        ${renderDetailMetric("Groups", `${formatNumber(user.activeGroups)} active / ${formatNumber(user.totalGroups)} total`)}
        ${renderDetailMetric("Completions", formatNumber(user.completedRecords))}
        ${renderDetailMetric("Sessions", `${formatNumber(user.activeSessionCount)} active / ${formatNumber(user.sessionCount)} total`)}
      </section>
      ${user.disabledAt ? `<p class="admin-detail-note">Disabled ${formatDate(user.disabledAt)}${user.disabledBy ? ` by ${escapeHTML(user.disabledBy)}` : ""}${user.disabledReason ? `: ${escapeHTML(user.disabledReason)}` : ""}</p>` : ""}
      <div class="admin-detail-lists">
        <section>
          <h2>Audit</h2>
          <ul>${renderAuditEvents(user.auditEvents)}</ul>
        </section>
        <section>
          <h2>Recent sessions</h2>
          <ul>${renderSessions(user.recentSessions)}</ul>
        </section>
      </div>
    </section>`;
  }

  function renderAuthGate() {
    const forbidden = state.error === "Forbidden";
    return `<section class="admin-shell admin-center">
      <p class="eyebrow">Admin</p>
      <h1>Ritual Cue</h1>
      <p>${forbidden ? "This signed-in account is not allowed to view admin data." : "Sign in to an admin account before opening the dashboard."}</p>
      <div class="auth-options">
        ${state.googleClientId ? `<div class="google-provider" data-google-host></div>` : ""}
        ${state.appleClientId ? `<button class="provider apple" data-action="apple">&nbsp; Continue with Apple</button>` : ""}
      </div>
      <div class="auth-note">${state.authLoaded && !state.googleClientId && !state.appleClientId ? "Web sign-in providers are not configured yet." : ""}</div>
      <div class="admin-actions">
        <a class="secondary admin-link" href="/app">Open app</a>
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
        <div class="admin-row-actions">${renderActionButtons(user)}</div>
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
      ${renderUserDetail()}
    </section>`;
  }

  function render() {
    if (state.loading) {
      app.innerHTML = `<div class="launch"><div class="launch-mark">R</div><strong>Loading admin</strong></div>`;
      return;
    }
    if (state.error) {
      app.innerHTML = renderAuthGate();
      renderGoogleButton();
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

  async function reenableUser(id) {
    if (!confirm("Re-enable this account?")) return;
    await request(`/api/admin/users/${encodeURIComponent(id)}/reenable`, { method: "POST" });
    await loadOverview();
  }

  async function viewUser(id) {
    state.selectedUserID = id;
    state.userDetail = null;
    state.detailLoading = true;
    render();
    try {
      state.userDetail = await request(`/api/admin/users/${encodeURIComponent(id)}`);
    } catch (error) {
      state.error = error.message;
    } finally {
      state.detailLoading = false;
      render();
    }
  }

  app.addEventListener("click", (event) => {
    const target = event.target.closest("[data-action]");
    if (!target) return;
    if (target.dataset.action === "refresh") void loadOverview();
    if (target.dataset.action === "close-detail") {
      state.selectedUserID = "";
      state.userDetail = null;
      render();
    }
    if (target.dataset.action === "view") {
      void viewUser(target.dataset.id);
    }
    if (target.dataset.action === "apple") {
      void signInApple().catch((error) => {
        state.error = error.message;
        render();
      });
    }
    if (target.dataset.action === "disable") {
      void disableUser(target.dataset.id).catch((error) => {
        state.error = error.message;
        render();
      });
    }
    if (target.dataset.action === "reenable") {
      void reenableUser(target.dataset.id).catch((error) => {
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

  window.addEventListener("load", renderGoogleButton);
  void loadAuthConfig();
  void loadOverview();
})();
