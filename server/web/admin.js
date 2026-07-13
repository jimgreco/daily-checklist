(function () {
  "use strict";

  const app = document.getElementById("admin");
  const state = {
    token: "",
    user: null,
    overview: null,
    runtimeStatus: null,
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
      [state.overview, state.runtimeStatus] = await Promise.all([
        request("/api/admin/overview"),
        request("/api/admin/status")
      ]);
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
      const labels = {
        account_disabled: "Account disabled",
        account_reenabled: "Account re-enabled",
        account_deleted: "Account deleted",
        account_export_requested: "Export requested",
        auth_sign_in: "Signed in",
        auth_provider_linked: "Sign-in provider linked",
        auth_rate_limit_exceeded: "Authentication rate limit exceeded",
        admin_snapshot_downloaded: "Admin snapshot downloaded",
        admin_user_snapshot_downloaded: "User snapshot downloaded"
      };
      const label = labels[event.action] || String(event.action || "Audit event").replaceAll("_", " ");
      const actor = event.actor?.email ? ` by ${escapeHTML(event.actor.email)}` : "";
      const target = event.target?.email ? `<small>Target: ${escapeHTML(event.target.email)}</small>` : "";
      const reason = event.reason ? `<small>${escapeHTML(event.reason)}</small>` : "";
      return `<li><strong>${escapeHTML(label)}</strong><span>${formatDate(event.timestamp)}${actor}</span>${target}${reason}</li>`;
    }).join("");
  }

  function configuredBadge(configured) {
    return `<span class="admin-badge ${configured ? "ok" : "danger"}">${configured ? "Configured" : "Missing"}</span>`;
  }

  function renderRuntimeStatus() {
    const status = state.runtimeStatus;
    if (!status) return "";
    const allowlistSources = (status.adminAllowlist?.sources || [])
      .filter((source) => source.configured)
      .map((source) => source.name)
      .join(", ") || "None";
    return `<section class="admin-operations" aria-label="Production status">
      <div class="admin-section-head">
        <div><p class="eyebrow">Production</p><h2>Deployment status</h2></div>
        <div class="admin-snapshot-actions">
          <button class="mini-button accent" data-action="snapshot" data-mode="sanitized">Download sanitized snapshot</button>
          <button class="mini-button" data-action="snapshot" data-mode="full">Download full snapshot</button>
        </div>
      </div>
      <div class="admin-config-grid">
        ${renderDetailMetric("Server version", status.server?.version || "Unknown")}
        ${renderDetailMetric("Build", status.server?.buildHash || "Unknown")}
        ${renderDetailMetric("Deployed", formatDate(status.server?.deployedAt))}
        ${renderDetailMetric("Database", `${status.database?.provider || "Unknown"} · ${status.database?.ok ? "Healthy" : "Unavailable"}`)}
        <div class="admin-detail-metric"><span>Google native</span>${configuredBadge(status.oauth?.google?.nativeConfigured)}</div>
        <div class="admin-detail-metric"><span>Google web</span>${configuredBadge(status.oauth?.google?.webConfigured)}</div>
        <div class="admin-detail-metric"><span>Apple native</span>${configuredBadge(status.oauth?.apple?.nativeConfigured)}</div>
        <div class="admin-detail-metric"><span>Apple web</span>${configuredBadge(status.oauth?.apple?.webConfigured)}</div>
        <div class="admin-detail-metric"><span>Monitor</span>${configuredBadge(status.monitor?.configured)}</div>
        ${renderDetailMetric("Admin allowlist", `${status.adminAllowlist?.entryCount || 0} via ${allowlistSources}`)}
      </div>
      <nav class="admin-status-links" aria-label="Production checks">
        <a href="${escapeHTML(status.links?.health || "/health")}" target="_blank" rel="noreferrer">Health</a>
        <a href="${escapeHTML(status.links?.support || "/support.html")}" target="_blank" rel="noreferrer">Support</a>
        <a href="${escapeHTML(status.links?.privacy || "/privacy.html")}" target="_blank" rel="noreferrer">Privacy</a>
      </nav>
    </section>`;
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
          <button class="mini-button accent" data-action="user-snapshot" data-id="${escapeHTML(user.id)}">Download snapshot</button>
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

      ${renderRuntimeStatus()}

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
      <section class="admin-audit-log" aria-label="Recent audit events">
        <div class="admin-section-head"><div><p class="eyebrow">Operations</p><h2>Recent audit events</h2></div></div>
        <ul>${renderAuditEvents(overview.recentAuditEvents)}</ul>
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
      renderGoogleButton();
      return;
    }
    renderDashboard();
  }

  async function download(path) {
    const response = await fetch(path, {
      headers: state.token ? { Authorization: `Bearer ${state.token}` } : {}
    });
    if (!response.ok) {
      let message = `HTTP ${response.status}`;
      try { message = (await response.json()).error || message; } catch {}
      throw new Error(message);
    }
    const disposition = response.headers.get("content-disposition") || "";
    const filename = disposition.match(/filename="([^"]+)"/)?.[1] || "ritual-cue-snapshot.json";
    const url = URL.createObjectURL(await response.blob());
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    await loadOverview();
  }

  async function downloadSnapshot(mode) {
    if (mode === "full" && !confirm("Download a full app-state snapshot containing user account and checklist data?")) return;
    await download(`/api/admin/snapshot?mode=${encodeURIComponent(mode)}`);
  }

  async function downloadUserSnapshot(id) {
    if (!confirm("Download this user's account and checklist snapshot for support?")) return;
    await download(`/api/admin/users/${encodeURIComponent(id)}/snapshot`);
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
    if (target.dataset.action === "snapshot") {
      void downloadSnapshot(target.dataset.mode || "sanitized").catch((error) => {
        state.error = error.message;
        render();
      });
    }
    if (target.dataset.action === "user-snapshot") {
      void downloadUserSnapshot(target.dataset.id).catch((error) => {
        state.error = error.message;
        render();
      });
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
