# Ritual Cue

A native iPhone and mobile web checklist for repeatable tasks, with offline caching, server sync, per-item reminders, and an evening unfinished-task alert.

## Run

```sh
cd server
npm start
```

In another terminal:

```sh
xcodegen generate
open Daily.xcodeproj
```

The debug iOS build connects to `http://127.0.0.1:8787`, which works from the iOS Simulator. Set `API_BASE_URL` to an HTTPS deployment before running on a physical device.

The server hosts the public marketing site at `http://127.0.0.1:8787/` and the mobile web app at `http://127.0.0.1:8787/app`. On localhost, use **Local dev sign in**. In production, the website and API share the same origin.

Local development can run without Postgres and will use `server/data/database.json`. Production requires Postgres:

```sh
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/daily_checklist npm start
```

## Proxy and rate-limit IPs

Local development defaults to `TRUST_PROXY_HOPS=0`, so forwarded headers are ignored and rate limits key off the direct socket address.

Production should set `TRUST_PROXY_HOPS` to the exact number of trusted reverse-proxy hops in front of the Node server. The production proxy must overwrite or append `X-Forwarded-For`, `X-Forwarded-Host`, and `X-Forwarded-Proto`, and the Node port should not be directly reachable from the public internet. Behind one trusted TLS/reverse-proxy hop, use:

```sh
TRUST_PROXY_HOPS=1
```

`TRUST_PROXY=true` is still accepted as a one-hop compatibility setting, but `TRUST_PROXY_HOPS` is preferred because it documents the expected topology.

## Authentication setup

The authentication contract mirrors CubbyLog:

- Google: create an iOS OAuth client for bundle ID `com.jimgreco.dailychecklist`. Set `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` in `project.yml`, and set the same client ID as `GOOGLE_CLIENT_ID` on the server.
- Apple: enable Sign in with Apple for `com.jimgreco.dailychecklist` in the Apple Developer portal and set `APPLE_BUNDLE_ID=com.jimgreco.dailychecklist` on the server.
- Web Google: create a Web OAuth client with `https://ritualcue.com` as an Authorized JavaScript origin and set `GOOGLE_WEB_CLIENT_ID`. This is separate from the iOS client.
- Web Apple: create a Sign in with Apple Services ID for `ritualcue.com`, configure `https://ritualcue.com` as its return URL, and set `APPLE_WEB_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_WEB_KEY_ID`, and `APPLE_WEB_PRIVATE_KEY_BASE64`.
- Set a strong, persistent `SESSION_SECRET` on the server. See `server/.env.example`.
- Set `ADMIN_EMAILS=jgreco@gmail.com` to allow the admin page at `/admin`.

Provider tokens are exchanged for Ritual Cue's own short-lived access token and rotating refresh token. Refresh tokens are stored in the iOS Keychain.

On the web, the rotating refresh token is stored in an `HttpOnly` cookie so the user stays signed in without exposing the refresh token to JavaScript. The iOS app stores refresh tokens in Keychain and is designed to keep users signed in across app launches.

## Admin operations

The admin dashboard at `/admin` shows the deployed server version and commit, deployment time, database health, OAuth configuration states, monitor configuration, admin-allowlist sources, and links to public health/support/privacy checks. It never returns configuration values or token material.

Admins can download a sanitized operational snapshot, a full app-state snapshot, or a single user's support snapshot. Sanitized snapshots pseudonymize users and omit checklist content. Full and per-user snapshots can contain user/checklist data, but all snapshot modes exclude authentication sessions, refresh-token hashes, token values, and secret configuration. Downloads are rate-limited and audited.

Audit events are stored with the app state in Postgres and retained across server restarts. The recent-event panel records admin disable/re-enable operations, account exports/deletions, sign-ins/provider links, authentication rate-limit spikes, and admin snapshot downloads without recording credentials or raw client IP addresses. When an account is deleted, its identifier remains on the deletion trail but email addresses are removed from all retained events for that user.

## Privacy and account management

Ritual Cue stores checklist items, groups, completion history, reminder settings, sync metadata, and account identity fields returned by Google or Apple. The iOS app keeps an offline cache in app documents storage, and the web app keeps an offline cache in browser storage.

Signed-in users can export their synced checklist data, restore from a Ritual Cue JSON export, and delete their server-side account from the Account screen. Restoring from an export replaces the signed-in account's synced checklist data with the imported checklist; malformed or oversized files are rejected before anything is changed. The diagnostics action copies build, sync, device, and API-origin details for support without including tokens or checklist content. The public web support pages are served at:

- `https://ritualcue.com/privacy.html`
- `https://ritualcue.com/support.html`

Keep App Store Connect privacy answers aligned with `Daily/PrivacyInfo.xcprivacy` and `docs/app-store-privacy.md`.

## Monitoring

`.github/workflows/monitor.yml` runs every five minutes and checks production `/health`, `/privacy.html`, and `/support.html`. The monitor uses `vars.DAILY_PRODUCTION_BASE_URL` when set, otherwise it checks `https://ritualcue.com`.

Add `DAILY_MONITOR_WEBHOOK_URL` as a repository secret to send failure notifications to a Slack-compatible or Discord-compatible incoming webhook. GitHub Actions failure notifications still work without the webhook.

## Offline and conflict behavior

The local cache is authoritative while offline. Every add, edit, completion, deletion, and evening-alert change is appended to a durable mutation queue. After authentication and whenever connectivity returns, queued mutations are uploaded.

The server merges item fields independently using timestamp plus device-ID ordering, merges completion state separately for each calendar date, deduplicates mutations, and keeps deletion tombstones so a stale device cannot recreate deleted tasks.

## Checklist state model

Each checklist item has a schedule plus per-date state sets. The schedule answers whether the item naturally occurs on a date. The per-date sets record user intent for dates that have been touched.

Schedules support daily, weekday, selected-weekday, anchored day/week intervals, and monthly rules by day number or ordinal weekday. Monthly day 29–31 rules use the last available day in shorter months. Advanced rules are stored in the optional `recurrence` field, so items created before flexible recurrence continue using their existing schedule unchanged.

- `completedDates`: the item is Done on that date.
- `skippedDates`: the item was intentionally skipped on that date.
- `openDates`: the item is explicitly Open on that date, even if the schedule would otherwise make it Off.

Per-date state is exclusive. For a given date, an item should not remain in more than one of `completedDates`, `skippedDates`, or `openDates`. State precedence is:

1. Done when the date is in `completedDates`.
2. Skipped when the date is in `skippedDates`.
3. Open when the date is in `openDates`.
4. Missed when the item occurs by schedule on a past date and has no recorded state.
5. Open when the item occurs by schedule today or in the future and has no recorded state.
6. Off when the item does not occur by schedule and has no recorded state.

`Missed` and `Off` are derived states. They are not stored directly. Moving a date to `Missed` or `Off` clears recorded state for that date so the schedule can speak for itself again.

`Open` is stored only when it needs to override the schedule. This matters when an item is normally Off for a date but the user changes it to Open, or when a completed/skipped item on an Off date is changed back to Open. Once that explicitly opened date is marked Done or Skipped, the Open marker is removed and the Done or Skipped record becomes the source of truth.

Visibility and streaks use the same tracked-day rule: a date counts for an item when the item either occurs by schedule or has any recorded state on that date. Recorded state can extend the tracked window earlier than the item's creation/start date, which lets manually backfilled Off -> Open -> Done history show up in streaks.

## Publishing

Every push to `main` runs `.github/workflows/publish.yml`:

- tests and container-builds the Node server;
- deploys `server/` to the shared EC2 host, ensures the `daily_checklist` Postgres database exists, migrates the old `daily-data/database.json` file into Postgres if Postgres is still empty, and rebuilds the `daily` Docker Compose service;
- builds the iOS app, creates a current App Store provisioning profile, archives, and uploads to TestFlight.

Manual Publish runs can also upload source-controlled App Store listing metadata and deterministic screenshots to the editable App Store Connect version. See `docs/app-store-production.md`.

Production database protection includes daily encrypted S3 logical dumps, a separate freshness monitor, disposable restore drills, and daily EBS snapshots. See [`docs/database-backups.md`](docs/database-backups.md) for schedules, alerts, inspection, and recovery steps.

Repository secrets required:

- EC2: `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `EC2_SSH_KNOWN_HOSTS`, `DAILY_SESSION_SECRET`
- OAuth/runtime: `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_IOS_REVERSED_CLIENT_ID`, `GOOGLE_WEB_CLIENT_ID`, `APPLE_WEB_CLIENT_ID`, `APPLE_WEB_KEY_ID`, `APPLE_WEB_PRIVATE_KEY_BASE64`, `IOS_API_BASE_URL`; the deploy sets `ADMIN_EMAILS=jgreco@gmail.com` and `DAILY_ADMIN_EMAILS=jgreco@gmail.com`
- Apple delivery: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`, `IOS_DIST_CERT_P12`, `IOS_DIST_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`

Optional runtime secret:

- `DAILY_DATABASE_URL` overrides the default shared Postgres URL `postgresql://admin:${DB_PASSWORD}@db:5432/daily_checklist`.

Backup repository variables:

- `DAILY_DB_BACKUP_S3_BUCKET` names the private S3 bucket used by the production backup and restore workflows.
- `DAILY_DB_BACKUP_MAX_AGE_HOURS` controls the freshness check and defaults to 26 hours.

Before the first upload, create the Ritual Cue app record in App Store Connect for bundle ID `com.jimgreco.dailychecklist`. The workflow can register the bundle ID and provisioning profile, but Apple does not expose app-record creation through the same provisioning API.

The iOS app and widget extension use the App Group `group.com.jimgreco.dailychecklist`. Enable App Groups for both `com.jimgreco.dailychecklist` and `com.jimgreco.dailychecklist.widget` in Apple Developer, assign that group to both App IDs, then rerun publish so the generated profiles include the shared container entitlement.
