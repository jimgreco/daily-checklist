# Isolated Ritual Cue server release

Pushes validate the server; deployment is manual and serialized with all other shared-host work. Native TestFlight upload and App Store assets are separate manual choices. Do not run the Production Monitor as a read-only smoke test: it performs a synthetic database mutation and can send an alert webhook.

The helper `server/scripts/deploy-service.py` uses the running `deploy/daily` container's recorded Compose files. It requires Docker Compose v2 through `docker-compose`, Python 3, exactly one running Daily container, and unchanged effective service configuration. It compares the current Compose configuration hash and complete resolved environment with the running container in memory. Configuration values are never printed or saved. Existing `SESSION_SECRET` must meet the audited startup requirement, and the existing runtime must use production Postgres. Missing or changed configuration is a blocker for coordinated reconciliation; the helper never rewrites `.env` or creates credentials.

Before transfer/release, the coordinator must establish an existing rollback commit, current backup freshness, and exact intended source SHA. Use existing pinned SSH access. If `EC2_SSH_KNOWN_HOSTS` is absent, do not provision trust automatically or use the Actions deployment path. Local coordinator deployment through already pinned access is supported.

1. Fetch remote `main` and record its exact 40-character SHA. Ensure the exact-SHA validation jobs succeeded.
2. Write that SHA and a deployment timestamp into `server/src/deployment.json`. Transfer the source to `~/daily-checklist/server/`, excluding `node_modules`, `data`, and `.env*`. Do not overwrite user storage.
3. On the host, run `python3 ~/daily-checklist/server/scripts/deploy-service.py` for read-only preflight.
4. After coordinating the host slot, run the same command with `--release <exact-sha>`. It retains the current image under `ritual-cue-rollback:<new-sha>`, writes a non-secret recovery record, builds only `daily`, repeats preflight, and runs `up -d --no-deps --no-build daily`.
5. The helper verifies both the exact commit embedded in the running container and its read-only `/health` response. Independently verify public `/health`, `/app`, `/auth/config`, `/privacy.html`, and `/support.html`, along with the exact remote commit and workflow outcomes. Auth config inspection must report only presence/status, not private runtime values. Login and sync acceptance requiring a real account/device remain a separate handoff.

The helper does not start dependencies, migrate legacy JSON, create databases, change database grants, prune images, change network settings, or send provider requests. A process failure after replacement leaves the rollback image and `~/deploy/release-records/daily-<sha>.json` intact. It never automatically restores a database or retries a partially recorded release.

## Recovery

Inspect the non-secret recovery record. If replacement failed, retain all images and serialize rollback with the coordinator. Confirm current effective configuration has not drifted, then retag the record's `previousImage` as its `previousImageName` and invoke the record's Compose command with `up -d --no-deps --no-build daily`. Verify `/health` and that `/app/src/deployment.json` reports the record's `previousSha`. Those actions restore only the prior app image; they do not restore or alter user data. This audit introduces no database migration, so no database rollback is needed.

If the configuration guard fails, the current container changed during release, or the previous image/commit cannot be established, stop the affected release step and reconcile through the coordinator. Do not bypass the checks or restart shared services to make deployment proceed.
