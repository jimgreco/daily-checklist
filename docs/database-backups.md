# Production database backups

Ritual Cue stores synchronized account state in the `daily_checklist` Postgres database. Production uses two backup layers:

1. **Nightly off-server dump.** The shared backup in `jimgreco/consolidated-deploy` (`scripts/backup-pilot`, systemd timer `backup-pilot-daily-checklist` at 02:55 UTC on the host) takes a verified `pg_dump` and uploads it to the versioned, encrypted S3 backup bucket under `daily-checklist/`. `daily-checklist/manifests/latest.json` names the newest dump.
2. **EBS snapshots.** AWS Data Lifecycle Manager snapshots the EC2 root volume daily and keeps seven.

The backup checks the database's exact table list before dumping; if a release adds or removes a table, update `scripts/backup-pilot/tables.json` in `consolidated-deploy`, or the backup stops.

## Alerts

The hourly `backup-pilot-freshness.yml` workflow in `consolidated-deploy` fails, and GitHub emails the owner, when the newest `daily-checklist` backup is missing, unverified or more than 26 hours old.

## Restoring

Restore into a disposable database first, verify it, then decide whether to promote it. Never restore over production without accepting the data-loss window.

1. Read `daily-checklist/manifests/latest.json` from the backup bucket to find the newest archive and its SHA-256.
2. Download the archive, check its SHA-256, and copy it to the host.
3. Create a temporary database and run `pg_restore --no-owner` into it, then check `daily_app_state` before deciding anything.

Dumps written by the older per-app workflow (prefix `daily-checklist/ritual-cue-`) remain in S3 until their lifecycle expires.
