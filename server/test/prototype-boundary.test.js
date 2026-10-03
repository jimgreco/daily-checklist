const test = require('node:test');
const assert = require('node:assert/strict');
const { applyMutation, materializeAccount, validSyncRequest, accountFromImportedChecklist } = require('../src/server');

const account = () => ({ items: {}, groups: {}, appliedMutations: {} });
const stamp = '2026-10-03T00:00:00.000Z';
const groupDelete = id => ({ id: 'synthetic-mutation', kind: 'groupDelete', groupID: id, stamp });

test('reserved object property names cannot enter sync IDs or imported groups', () => {
  for (const id of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', 'valueOf']) {
    assert.equal(validSyncRequest({ deviceID: 'synthetic-device', mutations: [groupDelete(id)] }), false, id);
    assert.equal(validSyncRequest({ deviceID: 'synthetic-device', mutations: [{ ...groupDelete('normal-group'), id }] }), false, id);
    assert.equal(validSyncRequest({ deviceID: 'synthetic-device', mutations: [{ id: 'normal-mutation', kind: 'delete', itemID: id, stamp }] }), false, id);
    assert.throws(() => accountFromImportedChecklist({ items: [], groups: [{ id, name: 'Synthetic group' }] }), /Invalid Ritual Cue export/);
  }
});

test('a synthetic group deletion cannot set Object.prototype.deleted or hide another account', () => {
  const first = account();
  const other = account();
  applyMutation(other, {
    id: 'create-other-group', kind: 'groupUpsert', groupID: 'other-group', stamp,
    changedFields: ['name'], group: { name: 'Other account group' }
  }, 'other-device');
  assert.equal(materializeAccount(other).groups.length, 1);
  try {
    const applied = applyMutation(first, groupDelete('__proto__'), 'synthetic-device');
    assert.equal(Object.hasOwn(Object.prototype, 'deleted'), false);
    assert.equal(applied, false);
    assert.equal(materializeAccount(other).groups.length, 1);
  } finally {
    // Baseline runs exercise the original bug only in this isolated process.
    delete Object.prototype.deleted;
  }
});

test('ordinary UUID and legacy IDs retain idempotent mutation behavior', () => {
  const state = account();
  const mutation = { id: '987eeefa-51ec-4f77-bc4b-0b1c3ea9fa91', kind: 'groupUpsert',
    groupID: 'legacy.group:1', stamp, group: { name: 'Synthetic' }, changedFields: ['name'] };
  assert.equal(validSyncRequest({ deviceID: 'synthetic-device', mutations: [mutation] }), true);
  assert.equal(applyMutation(state, mutation, 'synthetic-device'), true);
  assert.equal(applyMutation(state, mutation, 'synthetic-device'), true);
  assert.equal(materializeAccount(state).groups.length, 1);
});
