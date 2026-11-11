# Isolated Ritual Cue server release

Every push to `main` validates and then releases the server; a manual Release run on `main` with the `server` checkbox does the same for the dispatched commit. The `server` job in `.github/workflows/release.yml` (after `verify`) calls the shared reusable workflow `jimgreco/release-tools/.github/workflows/server-release.yml`, pinned by commit (`ff61f1c6a6eb51ea982246473203bcc903ce8153`, also passed as `tools_ref`). The release manifest is `.github/release/server.json`; its format and the full procedure are documented in release-tools' `server/README.md`. App Store listing assets remain manual choices. Do not run the Production Monitor as a read-only smoke test: it performs a synthetic database mutation and can send an alert webhook.

What a release does:

1. Build the exact-commit ARM64 image from `server/` and push it to `ghcr.io/jimgreco/daily-checklist:<sha>`. A prebuild step writes `server/src/deployment.json` (`buildHash` = the commit, `deployedAt` = build time) into the image; `/api/admin/status` reports it. A non-empty `DEPLOYMENT_SHA` in the runtime environment still overrides it.
2. Over the pinned SSH connection (`EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`, `EC2_SSH_KNOWN_HOSTS` in the `production` environment), run release-tools' `release.py` on the host. It takes the shared release locks, rebuilds the Compose invocation recorded on the running `deploy/daily` container (profile `daily`) and refuses on any configuration drift, pulls the image with the host's existing registry login, and writes `~/deploy/releases/daily-image-<sha>.json`, which changes only `daily.image`. Older `~/deploy/daily-image-<sha>.json` overrides written by the retired `deploy-service.py` helper are dropped from the chain; every other overlay (database runtime, logging, infrastructure) stays.
3. Tag the previous image for rollback, take a verified `pg_dump` of `daily_checklist` (must contain `daily_app_state`) into `~/deploy/backups/daily/`, and recreate only `daily` with `--no-deps --no-build`.
4. Inside the container, require the running build to equal the released commit and the read-only `/health` to answer `{"ok": true}`. On failure it rolls back to the previous image automatically.

Release records are kept in `~/deploy/release-records/daily-<sha>.json`. The release never migrates the database (the container only checks the schema contract on startup; migrations stay a separate owner step), starts dependencies, edits `.env` or shared Compose files, creates roles, or prunes images. Independently verify public `/health`, `/app`, `/auth/config`, `/privacy.html` and `/support.html` after a release; login and sync acceptance needing a real account/device remain a separate handoff.

## Weekly summary endpoint

`GET /api/weekly-summary?week=<monday>` is a read-only report for the weekly-review routine (contract: `weekly-review/docs/weekly-summary-contract.md`). It reads two runtime variables:

| Variable | Meaning |
|---|---|
| `WEEKLY_SUMMARY_TOKEN_SHA256` | Lowercase hex SHA-256 of the routine's bearer token. The plaintext token is never stored on the server. |
| `WEEKLY_SUMMARY_EMAIL` | The one account the endpoint reports on, matched case-insensitively. |

If either is unset, the route answers 404, so shipping the code is inert. The route accepts only this token (never a user session JWT), is rate-limited per client, and uses `store.read()` only: no audit events, sessions, or account changes.

Enabling it is a separate owner step, not part of a release. Generate the token with `openssl rand -base64 32 | tr -d '=+/' | cut -c1-40`, put `printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1` and the email into the live `deploy/daily` Compose environment, and recreate the container so the running environment matches. Because the release drift guard fails on any difference between the configured and running Compose model, do not edit the Compose environment without recreating the container, and do not combine this with a release. Store `$TOKEN` only in the weekly-review routine's environment.

## Recovery

A failed health check rolls back automatically. For a later manual rollback, inspect `~/deploy/release-records/daily-<sha>.json`: it records the previous container, image ID, rollback tag and the Compose file chain. Serialize with any other host release, then recreate `daily` from the recorded `previousFiles` chain with `up -d --no-deps --no-build daily`, or re-run the Release workflow for the previous good commit. That restores only the prior app image; it does not restore or alter user data.

If the configuration guard fails or the live container changed during a release, stop and reconcile the host first. Do not bypass the checks or restart shared services to make a release proceed.
