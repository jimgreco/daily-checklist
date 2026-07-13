# Production database backups

Ritual Cue stores synchronized account state in the `daily_checklist` Postgres database. The database contains a single `daily_app_state` row whose `data` column is JSONB. Production uses two backup layers:

1. AWS Data Lifecycle Manager takes a crash-consistent snapshot of the EC2 root volume daily and retains seven snapshots.
2. The `Production Database Backup` workflow creates a compressed Postgres custom-format dump and uploads it directly to private S3 storage.

The logical dump is the preferred recovery source because it can be inspected and restored into a disposable database without replacing the EC2 volume.

## Schedule and retention

- Backup workflow: daily at 09:17 UTC and on demand.
- Freshness check: daily at 11:13 UTC and on demand.
- Maximum acceptable backup age: `DAILY_DB_BACKUP_MAX_AGE_HOURS`, currently 26 hours.
- Local emergency copies: `~/deploy/backups/daily`, retained for seven days.
- S3 logical dumps: `s3://${DAILY_DB_BACKUP_S3_BUCKET}/daily-checklist/`, retained for 90 days.
- EBS snapshots: retained for seven days by the `Daily Backup for Consolidated Server` DLM policy.

The S3 bucket has public access blocked, default AES-256 server-side encryption, versioning, a TLS-only bucket policy, and lifecycle cleanup. The EC2 instance role is limited to listing the `daily-checklist/` prefix and reading or writing objects under that prefix.

## Inspection and alerts

List recent workflow runs:

```sh
gh run list --workflow "Production Database Backup" --limit 10
gh run list --workflow "Production Database Backup Check" --limit 10
```

Inspect the newest S3 object without downloading user data:

```sh
bucket="$(gh variable get DAILY_DB_BACKUP_S3_BUCKET)"
aws s3api list-objects-v2 \
  --bucket "$bucket" \
  --prefix daily-checklist/ritual-cue- \
  --query 'reverse(sort_by(Contents,&LastModified))[:10].[Key,LastModified,Size]' \
  --output table
```

Backup, freshness-check, and restore-drill failures create or update an open GitHub issue with an `[Ops]` title and link to the failed run. If `DAILY_MONITOR_WEBHOOK_URL` is configured, the same failure is also sent to that webhook. Treat a stale or failed backup as a production incident.

## Run a backup or restore drill

```sh
gh workflow run "Production Database Backup"
gh workflow run "Production Database Backup Check"
gh workflow run "Production Database Restore Drill"
```

The restore drill downloads the newest S3 dump, creates a uniquely named temporary database in the production Postgres container, restores with `pg_restore --exit-on-error`, and verifies that `daily_app_state` contains exactly one object-valued JSONB row. Its cleanup trap drops the temporary database and removes the downloaded file. It never writes to `daily_checklist`.

## Manual logical restore

Prefer the restore-drill workflow before any production recovery. To inspect a dump manually on the EC2 host:

```sh
cd ~/deploy
bucket="ritual-cue-db-backups-931115508693-us-east-2"
key="$(aws s3api list-objects-v2 \
  --bucket "$bucket" \
  --prefix daily-checklist/ritual-cue- \
  --query 'reverse(sort_by(Contents,&LastModified))[0].Key' \
  --output text)"
aws s3 cp "s3://$bucket/$key" /tmp/ritual-cue-restore.dump --only-show-errors

docker-compose exec -T db createdb -U admin daily_restore_candidate
docker-compose exec -T db pg_restore \
  -U admin \
  -d daily_restore_candidate \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  < /tmp/ritual-cue-restore.dump
docker-compose exec -T db psql -U admin -d daily_restore_candidate -c \
  "SELECT count(*), bool_and(jsonb_typeof(data) = 'object') FROM daily_app_state;"
rm -f /tmp/ritual-cue-restore.dump
```

Do not restore directly over `daily_checklist`. First validate a disposable database, record the selected backup timestamp and expected recovery point, and explicitly choose a cutover plan. For a full-instance loss, restore the newest DLM snapshot to a replacement EBS volume, start Postgres, then run the same `daily_app_state` verification.

## Recovery targets

- Recovery point objective: no more than 24 hours of synchronized data.
- Recovery time objective: restore service within 30 minutes after backup access and a healthy Postgres host are available.

Workflow output may include object names, timestamps, sizes, and verification results. It must not print database credentials, refresh tokens, or JSONB user content.
