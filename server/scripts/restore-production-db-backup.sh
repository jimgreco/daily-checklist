#!/usr/bin/env bash
set -euo pipefail

bucket="${1:-}"

if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "A valid S3 backup bucket is required." >&2
  exit 1
fi

cd "$HOME/deploy"

read_env() {
  local key="$1"
  local line value
  line="$(grep -E "^${key}=" .env | tail -n 1 || true)"
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

db_password="$(read_env DB_PASSWORD)"
if [ -z "$db_password" ]; then
  echo "DB_PASSWORD is missing from the production deploy environment." >&2
  exit 1
fi

newest_key="$(aws s3api list-objects-v2 \
  --bucket "$bucket" \
  --prefix 'daily-checklist/ritual-cue-' \
  --query 'reverse(sort_by(Contents,&LastModified))[0].Key' \
  --output text)"
if [ -z "$newest_key" ] || [ "$newest_key" = "None" ]; then
  echo "No Ritual Cue database backup was found in S3." >&2
  exit 1
fi

backup_dir="$HOME/deploy/backups/daily"
mkdir -p "$backup_dir"
temporary_path="$backup_dir/.restore-drill-$RANDOM-$$.dump"
restore_database="daily_restore_drill_$(date -u +%Y%m%d%H%M%S)_$RANDOM"
started_at="$(date -u +%s)"

cleanup() {
  docker-compose exec -T -e PGPASSWORD="$db_password" db \
    dropdb -U admin --if-exists "$restore_database" \
    < /dev/null > /dev/null 2>&1 || true
  rm -f "$temporary_path"
}
trap cleanup EXIT

aws s3 cp "s3://$bucket/$newest_key" "$temporary_path" --only-show-errors
test -s "$temporary_path"
docker-compose exec -T db pg_restore --list < "$temporary_path" > /dev/null

docker-compose exec -T -e PGPASSWORD="$db_password" db \
  createdb -U admin "$restore_database" < /dev/null
docker-compose exec -T -e PGPASSWORD="$db_password" db \
  pg_restore -U admin -d "$restore_database" --exit-on-error --no-owner --no-privileges \
  < "$temporary_path" > /dev/null

verification="$(docker-compose exec -T -e PGPASSWORD="$db_password" db \
  psql -U admin -d "$restore_database" -Atc \
  "SELECT count(*)::text || '|' || coalesce(bool_and(jsonb_typeof(data) = 'object'), false)::text FROM daily_app_state" \
  < /dev/null)"
if [ "$verification" != "1|true" ]; then
  echo "Restore verification failed for daily_app_state." >&2
  exit 1
fi

finished_at="$(date -u +%s)"
elapsed_seconds="$((finished_at - started_at))"
echo "Ritual Cue restore drill succeeded from $newest_key in ${elapsed_seconds}s."
