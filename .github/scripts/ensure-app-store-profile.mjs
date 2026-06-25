#!/usr/bin/env node
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const API = 'https://api.appstoreconnect.apple.com/v1';

function argument(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index < 0 || !process.argv[index + 1]) throw new Error(`Missing --${name}`);
  return process.argv[index + 1];
}

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function token() {
  const keyId = process.env.APP_STORE_CONNECT_KEY_ID;
  const issuerId = process.env.APP_STORE_CONNECT_ISSUER_ID;
  const keyPath = process.env.APP_STORE_CONNECT_API_KEY_PATH;
  if (!keyId || !issuerId || !keyPath) {
    throw new Error('App Store Connect API credentials are required.');
  }

  const now = Math.floor(Date.now() / 1000);
  const input = `${base64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))}.${base64url(JSON.stringify({
    iss: issuerId,
    aud: 'appstoreconnect-v1',
    iat: now,
    exp: now + 1200,
  }))}`;
  const signature = sign('sha256', Buffer.from(input), {
    key: createPrivateKey(readFileSync(keyPath, 'utf8')),
    dsaEncoding: 'ieee-p1363',
  });
  return `${input}.${base64url(signature)}`;
}

async function request(authToken, method, path, body) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${authToken}`,
      Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : undefined;
  if (!response.ok) {
    const detail = payload?.errors?.map((error) => error.detail ?? error.title).join('\n');
    throw new Error(`${method} ${path} failed (${response.status}): ${detail || text}`);
  }
  return payload;
}

async function pages(authToken, path) {
  const values = [];
  let next = path;
  while (next) {
    const response = await request(authToken, 'GET', next);
    values.push(...(response.data ?? []));
    const nextURL = response.links?.next;
    next = nextURL ? `${new URL(nextURL).pathname}${new URL(nextURL).search}` : '';
  }
  return values;
}

async function ensureBundle(authToken, identifier) {
  const found = await request(
    authToken,
    'GET',
    `/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&filter[platform]=IOS&limit=1`,
  );
  if (found.data?.[0]) return found.data[0];
  const created = await request(authToken, 'POST', '/bundleIds', {
    data: {
      type: 'bundleIds',
      attributes: { identifier, name: 'Daily', platform: 'IOS' },
    },
  });
  return created.data;
}

async function ensureCapability(authToken, bundleId, capabilityType) {
  const capabilities = await pages(
    authToken,
    `/bundleIds/${bundleId}/bundleIdCapabilities?fields[bundleIdCapabilities]=capabilityType`,
  );
  if (capabilities.some((value) => value.attributes?.capabilityType === capabilityType)) return;
  await request(authToken, 'POST', '/bundleIdCapabilities', {
    data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundleId } } },
    },
  });
}

async function matchingCertificate(authToken, certificatePath) {
  const localHash = createHash('sha256').update(readFileSync(certificatePath)).digest('hex');
  const certificates = await pages(
    authToken,
    '/certificates?fields[certificates]=certificateType,displayName,certificateContent,activated,expirationDate&limit=200',
  );
  const match = certificates.find((certificate) => {
    const type = certificate.attributes?.certificateType;
    const content = certificate.attributes?.certificateContent;
    return ['DISTRIBUTION', 'IOS_DISTRIBUTION'].includes(type)
      && certificate.attributes?.activated !== false
      && content
      && createHash('sha256').update(Buffer.from(content, 'base64')).digest('hex') === localHash;
  });
  if (!match) throw new Error('The imported distribution certificate was not found in App Store Connect.');
  return match;
}

async function createProfile(authToken, name, bundleId, certificateId) {
  const created = await request(authToken, 'POST', '/profiles', {
    data: {
      type: 'profiles',
      attributes: { name, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundleId } },
        certificates: { data: [{ type: 'certificates', id: certificateId }] },
      },
    },
  });
  const profile = await request(
    authToken,
    'GET',
    `/profiles/${created.data.id}?fields[profiles]=name,uuid,profileContent`,
  );
  return profile.data;
}

async function main() {
  const bundleIdentifier = argument('bundle-id');
  const profileName = argument('profile-name');
  const certificatePath = argument('certificate-der');
  const output = argument('output');
  const authToken = token();

  const bundle = await ensureBundle(authToken, bundleIdentifier);
  await ensureCapability(authToken, bundle.id, 'APPLE_ID_AUTH');
  const certificate = await matchingCertificate(authToken, certificatePath);
  const profile = await createProfile(authToken, profileName, bundle.id, certificate.id);
  const content = profile.attributes?.profileContent;
  if (!content) throw new Error('App Store Connect did not return provisioning profile content.');
  writeFileSync(output, Buffer.from(content, 'base64'));
  console.log(`Created ${profileName} for ${bundleIdentifier}.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
