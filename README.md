# Daily

A native iPhone and mobile web checklist for repeatable daily tasks, with offline caching, server sync, per-item reminders, and an evening unfinished-task alert.

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

## Authentication setup

The authentication contract mirrors CubbyLog:

- Google: create an iOS OAuth client for bundle ID `com.jimgreco.dailychecklist`. Set `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` in `project.yml`, and set the same client ID as `GOOGLE_CLIENT_ID` on the server.
- Apple: enable Sign in with Apple for `com.jimgreco.dailychecklist` in the Apple Developer portal and set `APPLE_BUNDLE_ID=com.jimgreco.dailychecklist` on the server.
- Web Google: create a Web OAuth client with `https://ritualcue.com` as an Authorized JavaScript origin and set `GOOGLE_WEB_CLIENT_ID`. This is separate from the iOS client.
- Web Apple: create a Sign in with Apple Services ID for `ritualcue.com`, configure `https://ritualcue.com` as its return URL, and set `APPLE_WEB_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_WEB_KEY_ID`, and `APPLE_WEB_PRIVATE_KEY_BASE64`.
- Set a strong, persistent `SESSION_SECRET` on the server. See `server/.env.example`.

Provider tokens are exchanged for Daily's own short-lived access token and rotating refresh token. Refresh tokens are stored in the iOS Keychain.

On the web, the rotating refresh token is stored in an `HttpOnly` cookie so the user stays signed in without exposing the refresh token to JavaScript. The iOS app stores refresh tokens in Keychain and is designed to keep users signed in across app launches.

## Privacy and account management

Daily stores checklist items, groups, completion history, reminder settings, sync metadata, and account identity fields returned by Google or Apple. The iOS app keeps an offline cache in app documents storage, and the web app keeps an offline cache in browser storage.

Signed-in users can export their synced checklist data and delete their server-side account from the Account screen. The public web support pages are served at:

- `https://ritualcue.com/privacy.html`
- `https://ritualcue.com/support.html`

Keep App Store Connect privacy answers aligned with `Daily/PrivacyInfo.xcprivacy` and `docs/app-store-privacy.md`.

## Monitoring

`.github/workflows/monitor.yml` runs every five minutes and checks production `/health`, `/privacy.html`, and `/support.html`. The monitor uses `vars.DAILY_PRODUCTION_BASE_URL` when set, otherwise it checks `https://ritualcue.com`.

Add `DAILY_MONITOR_WEBHOOK_URL` as a repository secret to send failure notifications to a Slack-compatible or Discord-compatible incoming webhook. GitHub Actions failure notifications still work without the webhook.

## Offline and conflict behavior

The local cache is authoritative while offline. Every add, edit, completion, deletion, and evening-alert change is appended to a durable mutation queue. After authentication and whenever connectivity returns, queued mutations are uploaded.

The server merges item fields independently using timestamp plus device-ID ordering, merges completion state separately for each calendar date, deduplicates mutations, and keeps deletion tombstones so a stale device cannot recreate deleted tasks.

## Publishing

Every push to `main` runs `.github/workflows/publish.yml`:

- tests and container-builds the Node server;
- deploys `server/` to the shared EC2 host, ensures the `daily_checklist` Postgres database exists, migrates the old `daily-data/database.json` file into Postgres if Postgres is still empty, and rebuilds the `daily` Docker Compose service;
- builds the iOS app, creates a current App Store provisioning profile, archives, and uploads to TestFlight.

Manual Publish runs can also upload source-controlled App Store listing metadata and deterministic screenshots to the editable App Store Connect version. See `docs/app-store-production.md`.

Repository secrets required:

- EC2: `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `EC2_SSH_KNOWN_HOSTS`, `DAILY_SESSION_SECRET`
- OAuth/runtime: `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_IOS_REVERSED_CLIENT_ID`, `GOOGLE_WEB_CLIENT_ID`, `APPLE_WEB_CLIENT_ID`, `APPLE_WEB_KEY_ID`, `APPLE_WEB_PRIVATE_KEY_BASE64`, `IOS_API_BASE_URL`
- Apple delivery: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`, `IOS_DIST_CERT_P12`, `IOS_DIST_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`

Optional runtime secret:

- `DAILY_DATABASE_URL` overrides the default shared Postgres URL `postgresql://admin:${DB_PASSWORD}@db:5432/daily_checklist`.

Before the first upload, create the Daily app record in App Store Connect for bundle ID `com.jimgreco.dailychecklist`. The workflow can register the bundle ID and provisioning profile, but Apple does not expose app-record creation through the same provisioning API.
