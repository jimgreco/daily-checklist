import test from 'node:test';
import assert from 'node:assert/strict';
import { policy, digest, readClient, audience, preflight, verifyUploaded, validateCertificate, validateProfile, validateBundle, releaseIdentity } from './asc-readonly.mjs';

const clone = value => structuredClone(value);
function fixture() {
  const p = clone(policy);
  p.testerEmailSha256 = digest('jim@example.invalid');
  const tester = { type: 'betaTesters', id: 'jim', attributes: { email: 'Jim@Example.Invalid', inviteType: 'EMAIL' } };
  const routes = {
    [`/v1/apps/${p.appId}`]: { data: { type: 'apps', id: p.appId, attributes: { bundleId: p.bundleId } } },
    [`/v1/apps/${p.appId}/betaGroups?limit=200`]: { data: p.groups.map(g => ({ type: 'betaGroups', id: g.id, attributes: { name: g.name, isInternalGroup: g.internal, publicLinkEnabled: false, hasAccessToAllBuilds: g.automatic } })) },
    [`/v1/betaTesters?filter[apps]=${p.appId}&limit=200`]: { data: [tester] },
    [`/v1/preReleaseVersions?filter[app]=${p.appId}&filter[platform]=IOS&limit=200`]: { data: [{ type: 'preReleaseVersions', id: 'ios-train', attributes: { platform: 'IOS', version: p.marketingVersion } }] },
    '/v1/preReleaseVersions/ios-train/builds?limit=200': { data: [{ type: 'builds', id: 'previous', attributes: { version: '1' } }] },
  };
  for (const group of p.groups) {
    routes[`/v1/betaGroups/${group.id}/betaTesters?limit=200`] = { data: group.testers ? [clone(tester)] : [] };
    routes[`/v1/betaGroups/${group.id}/builds?limit=200`] = { data: [] };
  }
  const client = {
    async get(path) { assert.ok(routes[path], `Unexpected API path: ${path}`); return clone(routes[path]); },
    async list(path) { return (await this.get(path)).data; },
  };
  return { p, routes, client, tester };
}
test('Apple client permits only same-origin GET and refuses redirects', async () => {
  const requests = [];
  const client = readClient(async (url, options) => {
    requests.push({ url, options });
    return { ok: true, json: async () => ({ data: [] }) };
  }, () => 'synthetic-token');
  await client.list('/v1/apps');
  assert.equal(requests[0].options.method, 'GET'); assert.equal(requests[0].options.redirect, 'error');
  for (const url of ['https://example.invalid/v1/apps', 'http://api.appstoreconnect.apple.com/v1/apps', 'https://user:password@api.appstoreconnect.apple.com/v1/apps', '/v2/apps', '/v1/apps#fragment']) {
    await assert.rejects(() => client.get(url));
  }
  assert.equal(requests.length, 1);
});
test('pagination checks every page and fails on loops or duplicate IDs', async () => {
  let count = 0;
  const client = readClient(async () => ({ ok: true, json: async () => ++count === 1
    ? { data: [{ id: 'a' }], links: { next: '/v1/page2' } } : { data: [{ id: 'b' }] } }), () => 'fake');
  assert.equal((await client.list('/v1/page1')).length, 2);
  const loop = readClient(async () => ({ ok: true, json: async () => ({ data: [], links: { next: '/v1/loop' } }) }), () => 'fake');
  await assert.rejects(() => loop.list('/v1/loop'), /pagination/);
  const duplicates = readClient(async () => ({ ok: true, json: async () => ({ data: [{ id: 'a' }, { id: 'a' }] }) }), () => 'fake');
  await assert.rejects(() => duplicates.list('/v1/apps'), /Duplicate/);
});
test('cross-origin next-page URL never receives authorization', async () => {
  let requests = 0;
  const client = readClient(async () => { requests++; return { ok: true, json: async () => ({ data: [], links: { next: 'https://example.invalid/v1/stolen' } }) }; }, () => 'fake');
  await assert.rejects(() => client.list('/v1/apps')); assert.equal(requests, 1);
});
test('API errors do not emit private response contents', async () => {
  const client = readClient(async () => ({ ok: false, status: 401, text: async () => 'private-response' }), () => 'fake');
  await assert.rejects(() => client.get('/v1/apps'), error => error.message.includes('401') && !error.message.includes('private-response'));
});
test('approved app-specific audience passes', async () => {
  const f = fixture(); assert.equal((await audience(f.client, f.p)).internalTesters, 1);
});
for (const change of ['app', 'group-id', 'extra-group', 'public', 'automatic', 'tester-count', 'tester-identity', 'app-tester']) {
  test(`audience fails closed on ${change}`, async () => {
    const f = fixture(), groups = f.routes[`/v1/apps/${f.p.appId}/betaGroups?limit=200`].data;
    const testers = f.routes[`/v1/betaGroups/${f.p.groups[0].id}/betaTesters?limit=200`].data;
    if (change === 'app') f.routes[`/v1/apps/${f.p.appId}`].data.attributes.bundleId = 'other.app';
    if (change === 'group-id') groups[0].id = 'changed';
    if (change === 'extra-group') groups.push(clone(groups[0]));
    if (change === 'public') groups[0].attributes.publicLinkEnabled = true;
    if (change === 'automatic') groups[0].attributes.hasAccessToAllBuilds = false;
    if (change === 'tester-count') testers.push(clone(testers[0]));
    if (change === 'tester-identity') testers[0].attributes.email = 'someone@example.invalid';
    if (change === 'app-tester') f.routes[`/v1/betaTesters?filter[apps]=${f.p.appId}&limit=200`].data.push({ ...f.tester, id: 'another' });
    await assert.rejects(() => audience(f.client, f.p));
  });
}
test('empty external/additional groups cannot silently acquire testers or builds', async () => {
  for (const group of policy.groups.filter(g => !g.testers)) {
    const f = fixture(); f.routes[`/v1/betaGroups/${group.id}/betaTesters?limit=200`].data.push(f.tester);
    await assert.rejects(() => audience(f.client, f.p));
    if (!group.internal) {
      const b = fixture(); b.routes[`/v1/betaGroups/${group.id}/builds?limit=200`].data.push({ id: 'unexpected' });
      await assert.rejects(() => audience(b.client, b.p));
    }
  }
});
test('build check accepts advancing iOS commit count only', async () => {
  const f = fixture(); assert.equal((await preflight(f.client, '3', 'a'.repeat(40), f.p)).build, '3');
  for (const version of ['3', '4', '1.2', 'unknown']) {
    f.routes['/v1/preReleaseVersions/ios-train/builds?limit=200'].data[0].attributes.version = version;
    await assert.rejects(() => preflight(f.client, '3', 'a'.repeat(40), f.p));
  }
});
test('compares builds within the pinned iOS marketing version', async () => {
  const f = fixture();
  f.routes[`/v1/preReleaseVersions?filter[app]=${f.p.appId}&filter[platform]=IOS&limit=200`].data.push({ type: 'preReleaseVersions', id: 'old', attributes: { platform: 'IOS', version: '0.9' } });
  f.routes['/v1/preReleaseVersions/old/builds?limit=200'] = { data: [{ type: 'builds', id: 'old-high', attributes: { version: '900' } }] };
  assert.equal((await preflight(f.client, '3', 'a'.repeat(40), f.p)).build, '3');
  f.routes['/v1/preReleaseVersions/ios-train/builds?limit=200'].data.push({ type: 'builds', id: 'same-train-high', attributes: { version: '4' } });
  await assert.rejects(() => preflight(f.client, '3', 'a'.repeat(40), f.p));
});
test('source and build identifiers are strict', () => {
  for (const pair of [['0', 'a'.repeat(40)], ['3', 'abc123'], ['3.1', 'a'.repeat(40)], ['3', 'A'.repeat(40)]]) assert.throws(() => releaseIdentity(...pair));
});
test('profile UUID, name, platform, state, type and expiry are pinned', () => {
  const target = policy.profiles.app, now = Date.parse('2026-10-03T00:00:00Z');
  const resource = { type: 'profiles', attributes: { uuid: target.uuid, name: target.name, profileType: 'IOS_APP_STORE', profileState: 'ACTIVE', platform: 'IOS', expirationDate: '2027-05-12T18:58:45Z' } };
  validateProfile(resource, target, now);
  for (const [key, value] of Object.entries({ uuid: 'wrong', name: 'new name', profileType: 'IOS_APP_DEVELOPMENT', profileState: 'INVALID', platform: 'MAC_OS', expirationDate: '2026-10-03T00:30:00Z' })) {
    const changed = clone(resource); changed.attributes[key] = value; assert.throws(() => validateProfile(changed, target, now));
  }
});
test('certificate uses pinned public bytes and rejects expired/inactive/wrong type', () => {
  const der = Buffer.from('synthetic-public-certificate'), p = { certificateSha256: digest(der) }, now = Date.parse('2026-10-03T00:00:00Z');
  const resource = { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', certificateContent: der.toString('base64'), expirationDate: '2027-05-12T18:58:45Z' } };
  validateCertificate(resource, der, now, p);
  for (const [key, value] of Object.entries({ certificateType: 'DEVELOPMENT', activated: false, expirationDate: '2020-01-01', certificateContent: 'different' })) {
    const changed = clone(resource); changed.attributes[key] = value; assert.throws(() => validateCertificate(changed, der, now, p));
  }
});
test('processing success requires intended version, internal-only audience and approved group', async () => {
  const f = fixture(), id = 'uploaded';
  f.routes['/v1/preReleaseVersions/ios-train/builds?limit=200'].data = [{ type: 'builds', id, attributes: { version: '3', processingState: 'VALID', expired: false, buildAudienceType: 'INTERNAL_ONLY' } }];
  f.routes[`/v1/betaGroups/${f.p.groups[0].id}/builds?limit=200`] = { data: [{ id, type: 'builds' }] };
  f.routes[`/v1/builds/${id}/individualTesters?limit=200`] = { data: [] };
  assert.equal((await verifyUploaded(f.client, '3', 'a'.repeat(40), f.p)).approvedGroupAttached, true);
  f.routes[`/v1/betaGroups/${f.p.groups[0].id}/builds?limit=200`].data = [];
  assert.equal(await verifyUploaded(f.client, '3', 'a'.repeat(40), f.p), null);
  f.routes['/v1/preReleaseVersions/ios-train/builds?limit=200'].data[0].attributes.buildAudienceType = 'APP_STORE_ELIGIBLE';
  await assert.rejects(() => verifyUploaded(f.client, '3', 'a'.repeat(40), f.p));
});

test('iOS profiles may belong to universal app IDs with optional seed metadata', () => {
  const target = policy.profiles.app;
  for (const platform of ['IOS', 'UNIVERSAL']) {
    for (const seedId of [policy.teamId, null, undefined]) {
      validateBundle({ type: 'bundleIds', attributes: { identifier: target.bundleId, platform, seedId } }, target);
    }
  }
});
test('bundle relationship rejects another app, platform or supplied team', () => {
  const target = policy.profiles.app;
  const resource = { type: 'bundleIds', attributes: { identifier: target.bundleId, platform: 'UNIVERSAL', seedId: policy.teamId } };
  for (const [key, value] of Object.entries({ identifier: 'other.app', platform: 'MAC_OS', seedId: 'OTHERTEAM' })) {
    const changed = clone(resource); changed.attributes[key] = value;
    assert.throws(() => validateBundle(changed, target), /metadata differs/);
  }
  assert.throws(() => validateBundle({ ...resource, type: 'profiles' }, target));
  const missingPlatform = clone(resource); delete missingPlatform.attributes.platform;
  assert.throws(() => validateBundle(missingPlatform, target));
});
