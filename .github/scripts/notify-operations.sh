#!/usr/bin/env bash
set -euo pipefail

title="${1:-Ritual Cue production operation failed}"
summary="${2:-A production operation failed.}"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
body="${summary}

Workflow run: ${run_url}"

export OPS_ISSUE_TITLE="$title"
issue_number="$(gh issue list --state open --limit 100 --json number,title | node -e '
  let input = "";
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    const issues = JSON.parse(input || "[]");
    const match = issues.find((issue) => issue.title === process.env.OPS_ISSUE_TITLE);
    if (match) process.stdout.write(String(match.number));
  });
')"

if [ -n "$issue_number" ]; then
  gh issue comment "$issue_number" --body "$body"
else
  gh issue create --title "$title" --body "$body"
fi

if [ -n "${OPERATIONS_ALERT_WEBHOOK_URL:-}" ]; then
  export OPS_ALERT_TEXT="$title
$body"
  payload="$(node -e '
    const text = process.env.OPS_ALERT_TEXT;
    process.stdout.write(JSON.stringify({ text, content: text }));
  ')"
  curl -fsS -m 10 \
    -H 'content-type: application/json' \
    -d "$payload" \
    "$OPERATIONS_ALERT_WEBHOOK_URL" > /dev/null || true
fi
