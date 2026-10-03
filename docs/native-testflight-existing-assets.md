# Existing-assets-only iOS TestFlight release

This path uploads only the iOS app and its approved extensions to the existing App Store Connect record. `release-policy.json` pins the existing profile UUIDs and public certificate fingerprint, app identity, production origin, marketing version, and Jim-only internal audience verified on 2026-10-03. Empty existing groups are allowed only as explicitly listed. Every Apple preflight request is GET. Missing or changed signing assets, audience, build history, or authentication stop the release; they never trigger account repair.

The workflow imports this repository's existing signing identity into a temporary runner keychain. It downloads the pinned existing profiles, verifies live certificate/profile resources and decoded entitlements, preserves any cached profile with the same UUID, and signs/exports manually without provisioning-update flags. Export is restricted to internal TestFlight, preserves the exact Git-count build number, and embeds the full source SHA. The exported app and all approved extensions must match the expected source, build, version, platform, signing identity, profiles, and required entitlements. Current signing state, audience, and build availability are rechecked immediately before the sole binary upload.

Ownership was cleared on 2026-10-03. Main pushes automatically run the guarded iOS upload path. Any new commit changes the source SHA and Git-count build, and the workflow rechecks current signing state, approved audience, and build availability before upload. Manual dispatch is also available with the existing upload input.

## Local checks

```sh
node --test .github/scripts/release-guard-tests.mjs
PYTHONDONTWRITEBYTECODE=1 python3 .github/scripts/test_release.py
actionlint .github/workflows/publish.yml
git diff --check
```

Tests use synthetic in-memory responses and temporary files. They neither read real private keys nor contact Apple. Passing these tests does not prove current Apple validity, accepted version-train status, successful signing, successful upload, tester availability, or device acceptance. The actual authenticated GET checks and final artifact verification must pass during release. A successful uploader response is followed by a separate processing/internal-group availability check; if that times out, inspect the existing Apple build before retrying.

## Authentication and scope

Use only this app's existing configured credentials. Do not create profiles, certificates, capabilities, testers, public links, or API access, copy another app's secrets, accept new terms, change groups, submit App Store metadata, or submit for App Store review. If Apple requests any such action, stop the affected release and report that exact prerequisite. No server deployment is part of this native workflow change.

Ritual authentication remains unverified. The existing Publish native job declares the `production` environment; repository-level secret absence alone does not establish environment-level availability. Do not add or copy credentials. If existing app-specific configuration is unavailable, Jim must use the already signed-in Xcode account/Organizer through a secure local handoff, with automatic signing disabled and current approved profiles/certificate and audience confirmed before upload. Do not extract the account token or private key.

If upload succeeds but Apple processing verification stops, run the manual **Verify existing TestFlight build** workflow with the exact uploaded build number and full original source SHA. It authenticates with this app’s existing API configuration and makes GET requests only; it has no signing or upload step. It verifies source ancestry/count and the same pinned app, audience, internal-only processing and group availability. Do not rerun the upload to check processing.
