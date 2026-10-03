const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Execute the production session/sync functions with deterministic transport and
// persistence fixtures. Full DOM/browser journeys remain in the Playwright suite.
function fixture() {
  const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');
  const pending = [];
  const context = vm.createContext({
    state: { token: 'token-A', user: { id: 'A' }, accountID: 'A', sessionGeneration: 0,
      signingOut: false, syncing: false, pending: [], items: [], groups: [], deviceID: 'synthetic-device' },
    refreshPromise: null,
    fetch: (path, options) => new Promise(resolve => pending.push({ path, options, resolve })),
    persistSession() {}, persistData() {}, render() {}, showToast() {},
    normalizeChecklistItems: items => items, normalizedQuietHours: value => value
  });
  vm.runInContext(source.slice(source.indexOf('  function hasSession()'), source.indexOf('  function occurs(item')), context);
  vm.runInContext(source.slice(source.indexOf('  async function signOut()'), source.indexOf('  async function exportData()')), context);
  vm.runInContext(source.slice(source.indexOf('  async function deleteAccount('), source.indexOf('  function toggle(item)')), context);
  return { context, pending };
}
const response = (body, status = 200) => ({ status, ok: status < 400, json: async () => body });
const turn = () => new Promise(resolve => setImmediate(resolve));

test('old-account sync response cannot populate a new account cache', async () => {
  const { context: c, pending } = fixture();
  const sync = c.sync();
  c.applyAuth({ token: 'token-B', user: { id: 'B' } });
  pending.shift().resolve(response({ items: [{ id: 'private-A' }], acceptedMutationIDs: [] }));
  await sync;
  assert.equal(c.state.accountID, 'B');
  assert.equal(c.state.items.length, 0);
});

test('a stale 401 never retries the previous account mutation with the new token', async () => {
  const { context: c, pending } = fixture();
  c.state.pending = [{ id: 'private-A-mutation' }];
  const sync = c.sync();
  c.applyAuth({ token: 'token-B', user: { id: 'B' } });
  pending.shift().resolve(response({}, 401));
  await turn();
  // Any refresh/retry here could replay account A's queued body as account B.
  assert.equal(pending.length, 0);
  await sync;
});

test('sync acknowledgements preserve newer optimistic edits until acknowledged', async () => {
  const { context: c, pending } = fixture();
  c.state.pending = [{ id: 'sent' }];
  const sync = c.sync();
  c.state.pending.push({ id: 'new-edit' });
  c.state.items = [{ id: 'item', title: 'Edited during request' }];
  pending.shift().resolve(response({ items: [{ id: 'item', title: 'Old' }], acceptedMutationIDs: ['sent'] }));
  await sync;
  assert.equal(c.state.items[0].title, 'Edited during request');
  assert.equal(c.state.pending[0].id, 'new-edit');
  // Finish the scheduled follow-up with its authoritative acknowledgement.
  pending.shift()?.resolve(response({ items: c.state.items, acceptedMutationIDs: ['new-edit'] }));
  await turn();
});

test('sign-out waits for an in-flight refresh before revoking its resulting cookie', async () => {
  const { context: c, pending } = fixture();
  const refresh = c.refreshAccessToken();
  const signOut = c.signOut();
  assert.equal(c.state.user, null);
  assert.equal(pending.length, 1);
  pending.shift().resolve(response({ token: 'late-token-A', user: { id: 'A' } }));
  await refresh;
  await turn();
  assert.equal(c.state.user, null);
  assert.equal(pending[0]?.path, '/auth/logout');
  pending.shift().resolve(response(null, 204));
  await signOut;
  assert.equal(c.state.user, null);
  assert.equal(c.state.signingOut, false);
});

test('account deletion never refreshes and retries against a different account', async () => {
  const { context: c, pending } = fixture();
  const deletion = c.deleteAccount(true);
  c.applyAuth({ token: 'token-B', user: { id: 'B' } });
  pending.shift().resolve(response({}, 401));
  await assert.rejects(deletion, /account changed/);
  assert.equal(pending.length, 0);
  assert.equal(c.state.accountID, 'B');
});

test('same-account refresh still retries with the newly rotated access token', async () => {
  const { context: c, pending } = fixture();
  const operation = c.request('/api/sync', { method: 'POST', body: '{}' });
  pending.shift().resolve(response({}, 401));
  await turn();
  assert.equal(pending[0]?.path, '/auth/refresh');
  pending.shift().resolve(response({ token: 'new-token-A', user: { id: 'A' } }));
  await turn();
  assert.equal(pending[0]?.path, '/api/sync');
  assert.equal(pending[0]?.options.headers.Authorization, 'Bearer new-token-A');
  pending.shift().resolve(response({ ok: true }));
  assert.equal((await operation).ok, true);
});
