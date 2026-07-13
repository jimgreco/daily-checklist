#!/usr/bin/env bash
set -euo pipefail

bucket="${1:-}"
max_age_hours="${2:-26}"

if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "A valid S3 backup bucket is required." >&2
  exit 1
fi
if [[ ! "$max_age_hours" =~ ^[1-9][0-9]*$ ]]; then
  echo "Maximum backup age must be a positive integer." >&2
  exit 1
fi

read -r newest_key newest_timestamp newest_size < <(
  aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --prefix 'daily-checklist/ritual-cue-' \
    --query 'reverse(sort_by(Contents,&LastModified))[0].[Key,LastModified,Size]' \
    --output text
)

if [ -z "${newest_key:-}" ] || [ "$newest_key" = "None" ] || [[ ! "${newest_size:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "No non-empty Ritual Cue database backup was found in S3." >&2
  exit 1
fi

newest_epoch="$(date -u -d "$newest_timestamp" +%s)"
now_epoch="$(date -u +%s)"
age_seconds="$((now_epoch - newest_epoch))"
max_age_seconds="$((max_age_hours * 3600))"
if [ "$age_seconds" -lt 0 ] || [ "$age_seconds" -gt "$max_age_seconds" ]; then
  echo "Newest Ritual Cue database backup is outside the ${max_age_hours}-hour freshness window." >&2
  exit 1
fi

age_minutes="$((age_seconds / 60))"
echo "Newest Ritual Cue database backup is fresh: $newest_key (${age_minutes} minutes old, ${newest_size} bytes)"
