# Isolated Ritual Cue server release

Every push to `main` validates and then deploys the server through the guarded helper below; a manual Publish run with `deploy_server=true` does the same for an explicit SHA. Runs are serialized by the Publish concurrency group, and the helper's preflight still blocks on configuration drift or a missing rollback revision. App Store listing assets remain manual choices. Do not run the Production Monitor as a read-only smoke test: it performs a synthetic database mutation and can send an alert webhook.

The helper `server/scripts/deploy-service.py` uses the running `deploy/daily` container's recorded Compose files. It requires Docker Compose v2 through `docker-compose`, Python 3, exactly one running Daily container, and unchanged effective service configuration. It compares the current Compose configuration hash and complete resolved environment with the running container in memory. Configuration values are never printed or saved. Existing `SESSION_SECRET` must meet the audited startup requirement, and the existing runtime must use production Postgres. Missing or changed configuration is a blocker for coordinated reconciliation; the helper never rewrites `.env` or creates credentials.

Compose 2.26.1 removes `depends_on` before hashing a container created with `up --no-deps`. For that exact Compose version and an empty live dependency label, the guard also accepts the native hash after removing only `daily.depends_on` in memory. It first proves that passing the full resolved model through stdin reproduces the original hash. All other service fields and the separate complete-environment comparison remain required; an unknown version or a lossy model conversion fails closed. No Compose file is rewritten.

Before transfer/release, the coordinator must establish an existing rollback commit, current backup freshness, and exact intended source SHA. Use existing pinned SSH access. If `EC2_SSH_KNOWN_HOSTS` is absent, do not provision trust automatically or use the Actions deployment path. Local coordinator deployment through already pinned access is supported.

The rollback commit normally comes from the running container's `deployment.json`. Older coordinated images without that file may use the exact `org.opencontainers.image.revision` label read from the running image's immutable ID. Missing or invalid revisions, malformed metadata, and failed metadata reads remain blockers. The recovery record identifies which source established the rollback commit.

1. Fetch remote `main` and record its exact 40-character SHA. Ensure the exact-SHA validation jobs succeeded.
2. Write that SHA and a deployment timestamp into `server/src/deployment.json`. Transfer the source to `~/daily-checklist/server/`, excluding `node_modules`, `data`, and `.env*`. Do not overwrite user storage.
3. On the host, run `python3 ~/daily-checklist/server/scripts/deploy-service.py` for read-only preflight.
4. After coordinating the host slot, run the same command with `--release <exact-sha>`. It retains the current image under `ritual-cue-rollback:<new-sha>` and writes a non-secret recovery record. A new `daily-image-<sha>.json` override lets Compose build only `daily` under `ritual-cue-release:<sha>`, even when the existing overlays pin an immutable image ID. Before replacement, the new override is pinned to the built image's immutable ID. Both resolved models must differ from the original only in `daily.image`; existing overlays are never rewritten. The helper repeats live preflight, then runs `up -d --no-deps --no-build daily` with the added image override.
5. The helper verifies both the exact commit embedded in the running container and its read-only `/health` response. Independently verify public `/health`, `/app`, `/auth/config`, `/privacy.html`, and `/support.html`, along with the exact remote commit and workflow outcomes. Auth config inspection must report only presence/status, not private runtime values. Login and sync acceptance requiring a real account/device remain a separate handoff.

The helper does not start dependencies, migrate legacy JSON, create databases, change database grants, prune images, change network settings, or send provider requests. A process failure after replacement leaves the rollback image and `~/deploy/release-records/daily-<sha>.json` intact. It never automatically restores a database or retries a partially recorded release.

## Weekly summary endpoint

`GET /api/weekly-summary?week=<monday>` is a read-only report for the weekly-review routine (contract: `weekly-review/docs/weekly-summary-contract.md`). It reads two runtime variables:

| Variable | Meaning |
|---|---|
| `WEEKLY_SUMMARY_TOKEN_SHA256` | Lowercase hex SHA-256 of the routine's bearer token. The plaintext token is never stored on the server. |
| `WEEKLY_SUMMARY_EMAIL` | The one account the endpoint reports on, matched case-insensitively. |

If either is unset, the route answers 404, so shipping the code is inert. The route accepts only this token (never a user session JWT), is rate-limited per client, and uses `store.read()` only: no audit events, sessions, or account changes.

Enabling it is a separate owner step, not part of a release. Generate the token with `openssl rand -base64 32 | tr -d '=+/' | cut -c1-40`, put `printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1` and the email into the live `deploy/daily` Compose environment, and recreate the container so the running environment matches. Because `deploy-service.py` fails on any difference between the configured and running environment, do not edit the Compose environment without recreating the container, and do not combine this with a release. Store `$TOKEN` only in the weekly-review routine's environment.

## Recovery

Inspect the non-secret recovery record. If replacement failed, retain all images and serialize rollback with the coordinator. Confirm current effective configuration has not drifted. If `previousImageName` is a mutable tag, retag `previousImage` as that name; if it is already the same immutable image ID, no retag is needed. Invoke the record's original `compose` command (without the new image override) with `up -d --no-deps --no-build daily`. Verify `/health`, the restored immutable image ID, and the record's `previousSha` using its recorded metadata or image-label source. Those actions restore only the prior app image; they do not restore or alter user data. This audit introduces no database migration, so no database rollback is needed.

If the configuration guard fails, the current container changed during release, or the previous image/commit cannot be established, stop the affected release step and reconcile through the coordinator. Do not bypass the checks or restart shared services to make deployment proceed.
