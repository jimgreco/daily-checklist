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
