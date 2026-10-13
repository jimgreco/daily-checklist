const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function fixture() {
  const stale = { id: 'routine', title: 'Old title', scheduleRevision: 1, endedAt: null };
  const current = { ...stale, title: 'Latest title', scheduleRevision: 4, completedDates: ['2026-10-12'] };
  const state = { items: [current], modal: { type: 'editor', item: stale } };
  const queued = [], snapshots = [], messages = [];
  const context = vm.createContext({
    state,
    startOfDay: date => date,
    normalizedScheduleRevision: value => value || 0,
    snapshotOutstandingOccurrences: item => snapshots.push(item),
    carryoverForItem: item => item.hasCarryover ? { occurrences: ['new-open-occurrence'] } : null,
    mutation: (kind, values) => ({ kind, ...values }), queue: value => queued.push(value),
    render() {}, showToast: message => messages.push(message)
  });
  vm.runInContext(source.slice(source.indexOf('  function endItem('), source.indexOf('  function resolveCarryoverAndEnd(')), context);
  return { context, state, stale, current, queued, snapshots, messages };
}

test('ending from a stale editor updates the current item and increments its latest revision', () => {
  const { context, state, stale, current, queued, snapshots } = fixture();
  context.requestEndItem(stale);
  assert.ok(current.endedAt);
  assert.equal(current.scheduleRevision, 5);
  assert.deepEqual(current.completedDates, ['2026-10-12']);
  assert.equal(stale.endedAt, null);
  assert.equal(snapshots[0], current);
  assert.equal(queued[0].item.scheduleRevision, 5);
  assert.equal(state.modal, null);
});

test('ending from a stale editor asks to resolve still-open work that arrived in sync', () => {
  const { context, state, stale, current, queued, snapshots } = fixture();
  current.hasCarryover = true;
  context.requestEndItem(stale);
  assert.equal(state.modal.type, 'endCarryover');
  assert.equal(state.modal.itemID, current.id);
  assert.equal(current.endedAt, null);
  assert.equal(queued.length, 0);
  assert.equal(snapshots.length, 0);
});

test('ending an item removed by sync does not enqueue an outdated mutation', () => {
  const { context, state, stale, queued, messages } = fixture();
  state.items = [];
  context.requestEndItem(stale);
  assert.equal(state.modal, null);
  assert.equal(queued.length, 0);
  assert.deepEqual(messages, ['This item is no longer available.']);
});
