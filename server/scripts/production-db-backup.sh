#!/usr/bin/env bash
set -euo pipefail

bucket="${1:-}"
local_retention_days="${2:-7}"

if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "A valid S3 backup bucket is required." >&2
  exit 1
fi
if [[ ! "$local_retention_days" =~ ^[1-9][0-9]*$ ]]; then
  echo "Local retention days must be a positive integer." >&2
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

backup_dir="$HOME/deploy/backups/daily"
mkdir -p "$backup_dir"

stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
filename="ritual-cue-$stamp.dump"
temporary_path="$backup_dir/$filename.tmp"
final_path="$backup_dir/$filename"
s3_key="daily-checklist/$filename"

cleanup() {
  rm -f "$temporary_path"
}
trap cleanup EXIT

docker-compose exec -T -e PGPASSWORD="$db_password" db \
  pg_dump -U admin -d daily_checklist --format=custom --compress=9 \
  < /dev/null > "$temporary_path"
test -s "$temporary_path"
docker-compose exec -T db pg_restore --list < "$temporary_path" > /dev/null

mv "$temporary_path" "$final_path"
chmod 600 "$final_path"

aws s3 cp "$final_path" "s3://$bucket/$s3_key" \
  --only-show-errors \
  --sse AES256

remote_size="$(aws s3api head-object \
  --bucket "$bucket" \
  --key "$s3_key" \
  --query ContentLength \
  --output text)"
if [[ ! "$remote_size" =~ ^[1-9][0-9]*$ ]]; then
  echo "Uploaded backup could not be verified." >&2
  exit 1
fi

find "$backup_dir" -type f -name 'ritual-cue-*.dump' -mtime +"$local_retention_days" -delete
echo "Ritual Cue database backup verified: s3://$bucket/$s3_key (${remote_size} bytes)"
