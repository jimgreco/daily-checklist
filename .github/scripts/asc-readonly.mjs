#!/usr/bin/env node
// Existing Apple resources only. This client intentionally exposes GET only.
import { createHash, createPrivateKey, sign, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const policy = JSON.parse(readFileSync(new URL('./release-policy.json', import.meta.url)));
export const digest = value => createHash('sha256').update(value).digest('hex');
const check = (ok, message) => { if (!ok) throw new Error(message); };
const validUntil = (value, now) => typeof value === 'string' && Number.isFinite(Date.parse(value)) && Date.parse(value) > now + 3600000;
const origin = 'https://api.appstoreconnect.apple.com';
export function token(env = process.env) {
  const kid = env.APP_STORE_CONNECT_KEY_ID, iss = env.APP_STORE_CONNECT_ISSUER_ID, path = env.APP_STORE_CONNECT_API_KEY_PATH;
  check(kid && iss && path, 'Existing app-specific App Store Connect authentication is required.');
  const now = Math.floor(Date.now() / 1000);
  const b64 = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const input = `${b64({ alg: 'ES256', kid, typ: 'JWT' })}.${b64({ iss, aud: 'appstoreconnect-v1', iat: now, exp: now + 600 })}`;
  try {
    return `${input}.${sign('sha256', Buffer.from(input), { key: createPrivateKey(readFileSync(path)), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  } catch { throw new Error('Existing app-specific API authentication could not be loaded.'); }
}
export function readClient(fetcher = fetch, auth = token) {
  async function get(path) {
    const url = new URL(path, `${origin}/v1/`);
    check(url.origin === origin && url.pathname.startsWith('/v1/') && !url.username && !url.password && !url.hash, 'Untrusted Apple read URL.');
    let response;
    try { response = await fetcher(url.href, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(30000), headers: { Authorization: `Bearer ${auth()}`, Accept: 'application/json' } }); }
    catch { throw new Error('Apple read failed; no changes attempted.'); }
    check(response.ok, `Apple read rejected (${response.status}) at ${url.pathname}; no changes attempted.`);
    return response.json();
  }
  async function list(path) {
    const rows = [], seen = new Set();
    while (path) {
      check(typeof path === 'string' && !seen.has(path) && seen.size < 100, 'Invalid Apple pagination.');
      seen.add(path);
      const response = await get(path);
      check(Array.isArray(response.data), 'Missing Apple resource collection.');
      rows.push(...response.data); path = response.links?.next;
    }
    check(new Set(rows.map(row => row.id)).size === rows.length, 'Duplicate Apple resource identifiers.');
    return rows;
  }
  return { get, list };
}

export function validateCertificate(resource, der, now = Date.now(), p = policy) {
  const a = resource?.attributes;
  check(resource?.type === 'certificates' && ['DISTRIBUTION', 'IOS_DISTRIBUTION'].includes(a?.certificateType)
    && a.activated !== false && validUntil(a.expirationDate, now), 'Existing distribution certificate is unavailable, inactive, or expired.');
  check(typeof a.certificateContent === 'string' && digest(Buffer.from(a.certificateContent, 'base64')) === p.certificateSha256
    && digest(der) === p.certificateSha256, 'Signing certificate differs from the approved identity.');
}
export function validateProfile(resource, target, now = Date.now()) {
  const a = resource?.attributes;
  check(resource?.type === 'profiles' && a?.uuid?.toLowerCase() === target.uuid && a.name === target.name
    && a.profileType === 'IOS_APP_STORE' && a.profileState === 'ACTIVE' && a.platform === 'IOS'
    && validUntil(a.expirationDate, now), 'Pinned existing iOS profile is missing, changed, inactive, or expired.');
}
export function validateBundle(resource, target, p = policy) {
  const a = resource?.attributes;
  // Apple BundleIdPlatform includes UNIVERSAL. The pinned profile itself must
  // still be IOS_APP_STORE/IOS; decoded profile and certificate prove the team.
  // seedId is optional metadata; if supplied it must match the pinned prefix.
  check(resource?.type === 'bundleIds' && a?.identifier === target.bundleId
    && ['IOS', 'UNIVERSAL'].includes(a.platform) && (a.seedId == null || a.seedId === p.teamId),
    'Existing profile bundle metadata differs: ' + JSON.stringify({ type: resource?.type, identifier: a?.identifier, platform: a?.platform, seedId: a?.seedId }));
}
export async function existingProfile(client, name, der, now = Date.now(), p = policy) {
  const target = p.profiles[name]; check(target, 'Target outside the approved iOS release.');
  const rows = await client.list(`/v1/profiles?filter[name]=${encodeURIComponent(target.name)}&fields[profiles]=name,uuid&limit=200`);
  const matches = rows.filter(row => row.attributes?.uuid?.toLowerCase() === target.uuid);
  check(matches.length === 1, 'Exactly one pinned existing profile is required; no profile will be created.');
  const id = encodeURIComponent(matches[0].id);
  const profile = (await client.get(`/v1/profiles/${id}`)).data;
  validateProfile(profile, target, now);
  const bundle = (await client.get(`/v1/profiles/${id}/bundleId`)).data;
  validateBundle(bundle, target, p);
  const certificates = await client.list(`/v1/profiles/${id}/certificates?limit=200`);
  check(certificates.length === 1, 'Profile must contain exactly the approved signing certificate.');
  // Read the certificate resource now: a stale cached profile alone is insufficient.
  const certificate = (await client.get(`/v1/certificates/${encodeURIComponent(certificates[0].id)}`)).data;
  validateCertificate(certificate, der, now, p);
  const cert = new X509Certificate(der);
  check(validUntil(cert.validTo, now) && Date.parse(cert.validFrom) <= now && !cert.ca
    && cert.subject.split('\n').includes(`OU=${p.teamId}`), 'Local public signing certificate is invalid.');
  check(typeof profile.attributes.profileContent === 'string' && profile.attributes.profileContent.length > 0, 'Profile content unavailable.');
  return Buffer.from(profile.attributes.profileContent, 'base64');
}
export function isApprovedTester(tester, p = policy) {
  return tester?.type === 'betaTesters' && typeof tester.attributes?.email === 'string'
    && digest(tester.attributes.email.trim().toLowerCase()) === p.testerEmailSha256
    && tester.attributes.inviteType !== 'PUBLIC_LINK';
}
export async function audience(client, p = policy) {
  const app = (await client.get(`/v1/apps/${p.appId}`)).data;
  check(app?.type === 'apps' && app.id === p.appId && app.attributes?.bundleId === p.bundleId, 'App Store app identity differs.');
  const groups = await client.list(`/v1/apps/${p.appId}/betaGroups?limit=200`);
  check(groups.length === p.groups.length && groups.every(g => p.groups.some(e => e.id === g.id)), 'TestFlight groups changed.');
  let jim;
  for (const expected of p.groups) {
    const group = groups.find(g => g.id === expected.id), a = group.attributes;
    check(group.type === 'betaGroups' && a?.name === expected.name && a.isInternalGroup === expected.internal
      && Object.hasOwn(a, 'publicLinkEnabled') && [false, null].includes(a.publicLinkEnabled)
      && !a.publicLink && !a.publicLinkId && a.hasAccessToAllBuilds === expected.automatic, 'TestFlight group scope or automatic distribution changed: ' + JSON.stringify({ id: group.id, name: a?.name, internal: a?.isInternalGroup, publicLinkEnabledPresent: !!a && Object.hasOwn(a, 'publicLinkEnabled'), publicLinkEnabled: a?.publicLinkEnabled, hasPublicLink: !!a?.publicLink, hasPublicLinkId: !!a?.publicLinkId, automatic: a?.hasAccessToAllBuilds, expected }));
    const testers = await client.list(`/v1/betaGroups/${expected.id}/betaTesters?limit=200`);
    check(testers.length === expected.testers, 'TestFlight tester count changed.');
    if (expected.testers) {
      check(testers.length === 1 && isApprovedTester(testers[0], p), 'TestFlight tester identity changed.'); jim = testers[0].id;
    }
    if (!expected.internal) check((await client.list(`/v1/betaGroups/${expected.id}/builds?limit=200`)).length === 0, 'Excluded external group has builds.');
  }
  const all = await client.list(`/v1/betaTesters?filter[apps]=${p.appId}&limit=200`);
  check(all.length === 1 && all[0].id === jim && isApprovedTester(all[0], p), 'App-level audience is not only the approved tester.');
  return { appId: p.appId, internalTesters: 1, externalTesters: 0 };
}
export async function iosBuilds(client, p = policy) {
  const trains = await client.list(`/v1/preReleaseVersions?filter[app]=${p.appId}&filter[platform]=IOS&limit=200`);
  const builds = [];
  for (const train of trains) {
    check(train.type === 'preReleaseVersions' && train.attributes?.platform === 'IOS', 'Unexpected version-train platform.');
    const rows = await client.list(`/v1/preReleaseVersions/${encodeURIComponent(train.id)}/builds?limit=200`);
    for (const row of rows) builds.push({ ...row, marketingVersion: train.attributes.version });
  }
  return builds;
}
export function releaseIdentity(build, sha) {
  check(/^[1-9][0-9]*$/.test(String(build)) && /^[0-9a-f]{40}$/.test(sha), 'Positive build number and full source SHA required.');
}
export async function preflight(client, build, sha, p = policy) {
  releaseIdentity(build, sha);
  const scope = await audience(client, p);
  // Apple's build identity is scoped by app, platform and marketing-version train.
  // Historical 1.0 releases used eight-digit numbers; newer trains use Git counts.
  const builds = (await iosBuilds(client, p)).filter(b => b.marketingVersion === p.marketingVersion);
  const rejected = builds.filter(b => b.type !== 'builds' || !/^[1-9][0-9]*$/.test(b.attributes?.version)
    || BigInt(b.attributes.version) >= BigInt(build));
  check(!rejected.length, 'iOS build preflight rejected existing metadata: ' + JSON.stringify(rejected.slice(0, 10).map(b => ({ type: b.type, build: b.attributes?.version, marketingVersion: b.marketingVersion }))) + `; total rejected=${rejected.length}.`);
  return { ...scope, sha, build: String(build), checkedAt: new Date().toISOString(), existingIOSBuilds: builds.length };
}
export async function verifyUploaded(client, build, sha, p = policy) {
  releaseIdentity(build, sha); await audience(client, p);
  const matches = (await iosBuilds(client, p)).filter(b => b.marketingVersion === p.marketingVersion && b.attributes?.version === String(build));
  check(matches.length <= 1, 'Uploaded build identity is ambiguous.');
  if (!matches.length || matches[0].attributes.processingState === 'PROCESSING') return null;
  const b = matches[0];
  check(b.marketingVersion === p.marketingVersion && b.attributes.processingState === 'VALID'
    && b.attributes.expired === false && b.attributes.buildAudienceType === 'INTERNAL_ONLY', 'Uploaded build failed processing or is not the intended internal-only iOS version.');
  // Apple supports GET betaGroups/{id}/builds, not GET builds/{id}/betaGroups.
  // audience() above already proved the complete app group set is exactly pinned.
  const groups = [];
  for (const group of p.groups) {
    const groupBuilds = await client.list(`/v1/betaGroups/${group.id}/builds?limit=200`);
    if (groupBuilds.some(row => row.id === b.id)) groups.push({ id: group.id });
  }
  check(groups.every(g => p.groups.some(e => e.internal && e.id === g.id)), 'Uploaded build has an unapproved group.');
  const testers = await client.list(`/v1/builds/${encodeURIComponent(b.id)}/individualTesters?limit=200`);
  check(testers.length <= 1 && testers.every(t => isApprovedTester(t, p)), 'Uploaded build has an unapproved individual tester.');
  if (!groups.some(g => g.id === p.groups.find(e => e.testers === 1).id)) return null;
  return { sha, build, appId: p.appId, processing: 'VALID', audience: 'INTERNAL_ONLY', approvedGroupAttached: true };
}
function arg(name) {
  const i = process.argv.indexOf(`--${name}`); check(i >= 0 && process.argv[i + 1], `Missing --${name}.`); return process.argv[i + 1];
}
async function main() {
  const client = readClient(), mode = process.argv[2];
  if (mode === 'profiles') {
    const der = readFileSync(arg('certificate-der'));
    const output = arg('directory');
    for (const name of Object.keys(policy.profiles)) {
      const content = await existingProfile(client, name, der);
      writeFileSync(`${output}/${name}.mobileprovision`, content, { mode: 0o600, flag: 'wx' });
    }
    console.log('Approved existing profiles retrieved without Apple resource changes.');
  } else if (mode === 'preflight') {
    const sha = arg('sha'), build = arg('build');
    check(execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() === sha, 'Checkout SHA changed.');
    check(execFileSync('git', ['rev-list', '--count', 'HEAD'], { encoding: 'utf8' }).trim() === build, 'Build does not match full Git history.');
    console.log(JSON.stringify(await preflight(client, build, sha)));
  } else if (mode === 'verify-upload') {
    for (let attempt = 0; attempt < 40; attempt++) {
      const result = await verifyUploaded(client, arg('build'), arg('sha'));
      if (result) { console.log(JSON.stringify(result)); return; }
      await new Promise(resolve => setTimeout(resolve, 15000));
    }
    throw new Error('Upload occurred but processing/group availability is unverified. Inspect Apple before any retry.');
  } else throw new Error('Expected profiles, preflight, or verify-upload.');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => { console.error(error.message); process.exitCode = 1; });
