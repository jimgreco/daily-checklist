const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

function loadServer(secret, environment = 'production') {
  const env = { ...process.env, NODE_ENV: environment, DATABASE_URL: 'postgresql://localhost/ritual_audit_test' };
  delete env.SESSION_SECRET;
  if (secret !== undefined) env.SESSION_SECRET = secret;
  // Requiring the module opens no listener and does not connect to Postgres.
  return spawnSync(process.execPath, ['-e', 'require("./src/server")'], {
    cwd: path.join(__dirname, '..'), env, encoding: 'utf8'
  });
}

for (const secret of [undefined, '', 'short', 'daily-local-development-secret-change-me', ' '.repeat(40)]) {
  test(`production rejects ${secret === undefined ? 'missing' : secret.trim() ? 'unsafe' : 'blank'} signing secret`, () => {
    const result = loadServer(secret);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /SESSION_SECRET/);
  });
}

test('production accepts a configured signing secret without starting services', () => {
  assert.equal(loadServer('synthetic-test-only-secret-with-more-than-32-characters').status, 0);
});

test('local development can retain its explicit development default', () => {
  assert.equal(loadServer(undefined, 'test').status, 0);
});

test('monitor access fails closed and requires an exact configured token', (t) => {
  const { hasMonitorToken } = require('../src/server');
  const before = [process.env.MONITOR_TOKEN, process.env.DAILY_MONITOR_TOKEN];
  t.after(() => {
    ['MONITOR_TOKEN', 'DAILY_MONITOR_TOKEN'].forEach((name, index) => {
      if (before[index] === undefined) delete process.env[name];
      else process.env[name] = before[index];
    });
  });
  delete process.env.MONITOR_TOKEN;
  delete process.env.DAILY_MONITOR_TOKEN;
  const request = (value) => ({ headers: { 'x-ritual-cue-monitor-token': value } });
  assert.equal(hasMonitorToken(request('arbitrary-header')), false);
  process.env.DAILY_MONITOR_TOKEN = 'synthetic-test-token';
  assert.equal(hasMonitorToken(request('synthetic-test-token')), true);
  assert.equal(hasMonitorToken(request('wrong-token')), false);
  assert.equal(hasMonitorToken(request('')), false);
  process.env.MONITOR_TOKEN = 'synthetic-generic-token';
  assert.equal(hasMonitorToken(request('synthetic-test-token')), false);
  assert.equal(hasMonitorToken(request('synthetic-generic-token')), true);
});

test('weekly summary access fails closed and accepts only the hashed bearer token', (t) => {
  const crypto = require('node:crypto');
  const { hasWeeklySummaryToken } = require('../src/server');
  const names = ['WEEKLY_SUMMARY_TOKEN_SHA256', 'WEEKLY_SUMMARY_EMAIL'];
  const before = names.map((name) => process.env[name]);
  t.after(() => {
    names.forEach((name, index) => {
      if (before[index] === undefined) delete process.env[name];
      else process.env[name] = before[index];
    });
  });
  names.forEach((name) => delete process.env[name]);
  const token = 'synthetic-weekly-summary-token';
  const digest = crypto.createHash('sha256').update(token).digest('hex');
  const request = (authorization) => ({ headers: authorization === undefined ? {} : { authorization } });
  assert.equal(hasWeeklySummaryToken(request(`Bearer ${token}`)), false);
  process.env.WEEKLY_SUMMARY_TOKEN_SHA256 = digest;
  assert.equal(hasWeeklySummaryToken(request(`Bearer ${token}`)), false, 'email is also required');
  process.env.WEEKLY_SUMMARY_EMAIL = 'owner@example.test';
  assert.equal(hasWeeklySummaryToken(request(`Bearer ${token}`)), true);
  assert.equal(hasWeeklySummaryToken(request(`Bearer ${digest}`)), false);
  assert.equal(hasWeeklySummaryToken(request('Bearer wrong')), false);
  assert.equal(hasWeeklySummaryToken(request(token)), false);
  assert.equal(hasWeeklySummaryToken(request()), false);
  process.env.WEEKLY_SUMMARY_TOKEN_SHA256 = 'not-a-sha256-digest';
  assert.equal(hasWeeklySummaryToken(request(`Bearer ${token}`)), false);
});
