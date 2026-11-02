# Ritual Cue — coding handoff

Snapshot: **2026-11-02 UTC**. This is a takeover map, not release authorization. Recheck Git status, the requested scope and current runtime before acting. Existing AGENTS.md and linked contract/runbooks remain applicable. Older dated status notes are evidence from their stated date, not current permissions.

## Purpose and architecture

Ritual Cue manages recurring checklists/routines with quantities, carryover and reminders.

SwiftUI Daily app, shared model and widget; Node server plus browser UI and PostgreSQL. Web/native/widget states share recurrence and offline-merge contracts.

## Locations and current work

- Usual local workspace: `/Users/jgreco/code/daily-checklist`.
- Source inspected for this handoff: `/Users/jgreco/Documents/Codex/2026-10-25/task/integration-2026-10-30/ritual`.
- Existing repository: [jimgreco/daily-checklist](https://github.com/jimgreco/daily-checklist); default branch `main`, verified source head `8d9735de24359d4b92c061cdac6ac3a2fee5b246`.
- Documentation branch: `docs/agent-handoff-2026-11-02`, based on that head; application code was not changed.
- Primary checkout is at `2aefcf0b5e0a1629a68877602ccec79b906f23b3` on `main` and differs from remote main. Do not reset it or assume it contains released features; use the inspected source or a new isolated checkout.

## Code and guide map

- [Daily](../Daily)
- [DailyShared](../DailyShared)
- [DailyWidget](../DailyWidget)
- [DailyTests](../DailyTests)
- [server/src](../server/src)
- [server/web](../server/web)
- [server/test](../server/test)
- [project.yml](../project.yml)

Read the relevant existing guide before changing its contract:

- [README.md](../README.md)
- [docs/server-release.md](server-release.md)
- [docs/database-runtime-access.md](database-runtime-access.md)
- [docs/database-backups.md](database-backups.md)
- [docs/native-testflight-existing-assets.md](native-testflight-existing-assets.md)

## Local setup and dependencies

Commands below are source-verified entry points, **not commands executed during this documentation pass**. Use disposable local data. Read the command comments and linked setup guide before running migrations, creating fixtures or starting listeners. Reuse prepared environments where suitable.

- `npm --prefix server ci`
- `cp server/.env.example server/.env  # local database only`
- `npm --prefix server run db:migrate  # separate local migration-owner URL`
- `npm --prefix server start`
- `xcodegen generate  # native project from project.yml`

Configuration names/locations only; never copy secret values into source, terminal output or handoff documents:

- `DATABASE_URL`
- `MIGRATION_DATABASE_URL`
- `SESSION_SECRET`
- `GOOGLE_CLIENT_ID`
- `APPLE_BUNDLE_ID`
- `APPLE_WEB_CLIENT_ID`
- `APPLE_WEB_REDIRECT_URI`

Use existing lockfiles/manifests; do not upgrade dependencies to perform a handoff. For native work, select an actually installed Xcode SDK/simulator from the checked-in project configuration.

## Tests and verification

- `npm --prefix server test`
- `npm --prefix server run test:e2e`
- `Native edits: Daily scheme unit/UI checks and actual widget/app inspection; use project.yml for target names.`

Documentation-only changes require path/link, accuracy, diff and secret-exclusion review; do not run heavyweight builds or production smoke mutations for prose changes. Application tests were not rerun in this pass. Past test/release evidence below retains its original date. UI changes still require actual rendered inspection, and synthetic tests do not prove real provider/device acceptance.

## Decisions and constraints

- Copy remaining checklist and editable routine duplication already ship; copies use fresh identity/history and retain relevant cadence/quantity/reminder inputs.
- Startup checks the schema only. Migration adoption/DDL uses separate credentials, never runtime DATABASE_URL.
- Publish is a multi-stage workflow; distinguish image publication, server activation, native upload and store assets.

## Release state and workflow effects

- Web/API: deployed and verified **2026-11-02**, source `8d9735de24359d4b92c061cdac6ac3a2fee5b246`. Exact revision/readiness and scoped activation were recorded; this documentation pass did not redeploy.
- Web run: [recorded workflow](https://github.com/jimgreco/daily-checklist/actions/runs/41445552869); result `success`.
- Native: version **1.3**, build **149**, source `8d9735de24359d4b92c061cdac6ac3a2fee5b246`. **Available in TestFlight**, processing/audience verified November 2 for exactly **1 existing internal tester**; external/public distribution excluded. [Verification evidence](https://github.com/jimgreco/daily-checklist/actions/runs/41079030398). No public App Store release was performed.
- Main Publish can include automatic native upload and image publication. Server activation/store assets have separate controls; inspect each job, not only the overall run.

Recent exact-source GitHub results observed November 2 (workflow purpose matters):

- [Publish run 41445552869](https://github.com/jimgreco/daily-checklist/actions/runs/41445552869): `completed` / `success`.
- [Production Monitor run 41405086984](https://github.com/jimgreco/daily-checklist/actions/runs/41405086984): `completed` / `success`.
- [Production Database Backup Check run41329642490](https://github.com/jimgreco/daily-checklist/actions/runs/41329642490): `completed` / `success`.

The handoff is published on a documentation feature branch, not main. Current checked-in GitHub push triggers are main-only (or absent). Blog hosting branch settings were separately checked. No native release, image publication or server deployment is intended from this documentation push.

## Known gaps and next safe work

- No new release blocker in the November 2 receipt. Preserve notification callback threading, date/carryover semantics and per-account merges.
- Backups/restore drills and server mutations are not documentation validation; do not run them without the applicable release scope.

Before the next task, verify source HEAD, dirty/staged work and the selected subsystem; read only the relevant guide. Check whether a listed idea is already implemented in another branch before rebuilding it. Preserve unrelated work and paused experiments. Release/permission/data changes require the applicable current authorization.
