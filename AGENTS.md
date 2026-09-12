# Ritual Cue — Codex Guide

## Efficient Start

- Use supplied context once. Before code edits, inspect `git status --short --branch`,
  `git diff --stat`, and `git diff --cached --stat`, then relevant hunks. Preserve
  unrelated work and stage only the requested scope when committing.
- Start with the paths below and narrow `rg` searches. Batch independent reads;
  reuse installed dependencies and build caches unless a change invalidates them.
- Make routine reversible decisions and complete the authorized outcome. Avoid
  speculative cleanup, repeated permission questions, and unrelated work.
- Run meaningful checks for the changed surface once after edits settle, including
  the repository's required gates. Repeat only when new evidence invalidates them.
  Documentation-only edits need diff, link/path, and whitespace review.
- For requested releases, follow the current workflow and verify the final pushed
  SHA and applicable live results. Keep build, deployment, TestFlight upload, and
  physical-device evidence distinct. Report the outcome and actual verification.

## Local Pointers

- Native app, shared state, widget, and tests: `Daily/`, `DailyShared/`,
  `DailyWidget/`, `DailyTests/`; Xcode configuration: `project.yml`.
- Server/API: `server/src/`; browser UI: `server/web/`; tests:
  `server/test/` and `server/e2e/`. Keep web, native, and widget state consistent.
- Read the relevant `README.md` section for recurrence, offline merges, account
  data, and authentication before changing those contracts.
- Server changes: `npm --prefix server test`; browser journeys:
  `npm --prefix server run test:e2e`; native changes use the Xcode targets in
  `project.yml`. Preserve cached tools and run only relevant local checks.
- Publishing: `.github/workflows/publish.yml` and `docs/app-store-production.md`;
  backup/recovery: `docs/database-backups.md`. A Publish result includes both
  server deployment and iOS upload; inspect each applicable result.
