# Daily

A native iPhone checklist for repeatable daily tasks, with offline caching, server sync, per-item reminders, and an evening unfinished-task alert.

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

## Authentication setup

The authentication contract mirrors CubbyLog:

- Google: create an iOS OAuth client for bundle ID `com.jimgreco.dailychecklist`. Set `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` in `project.yml`, and set the same client ID as `GOOGLE_CLIENT_ID` on the server.
- Apple: enable Sign in with Apple for `com.jimgreco.dailychecklist` in the Apple Developer portal and set `APPLE_BUNDLE_ID=com.jimgreco.dailychecklist` on the server.
- Set a strong, persistent `SESSION_SECRET` on the server. See `server/.env.example`.

Provider tokens are exchanged for Daily's own short-lived access token and rotating refresh token. Refresh tokens are stored in the iOS Keychain.

## Offline and conflict behavior

The local cache is authoritative while offline. Every add, edit, completion, deletion, and evening-alert change is appended to a durable mutation queue. After authentication and whenever connectivity returns, queued mutations are uploaded.

The server merges item fields independently using timestamp plus device-ID ordering, merges completion state separately for each calendar date, deduplicates mutations, and keeps deletion tombstones so a stale device cannot recreate deleted tasks.

## Publishing

Every push to `main` runs `.github/workflows/publish.yml`:

- tests and container-builds the Node server;
- deploys `server/` to the shared EC2 host and rebuilds the `daily` Docker Compose service;
- builds the iOS app, creates a current App Store provisioning profile, archives, and uploads to TestFlight.

Repository secrets required:

- EC2: `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `EC2_SSH_KNOWN_HOSTS`, `DAILY_SESSION_SECRET`
- OAuth/runtime: `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_IOS_REVERSED_CLIENT_ID`, `IOS_API_BASE_URL`
- Apple delivery: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY`, `IOS_DIST_CERT_P12`, `IOS_DIST_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`

Before the first upload, create the Daily app record in App Store Connect for bundle ID `com.jimgreco.dailychecklist`. The workflow can register the bundle ID and provisioning profile, but Apple does not expose app-record creation through the same provisioning API.
