const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function historyFixture() {
  const original = { id: 'routine', title: 'Original title', completedDates: [] };
  const state = { items: [original], modal: { type: 'history', item: original } };
  const context = vm.createContext({
    state, escapeHTML: String, icon: () => '',
    historyFor: item => [{ key: '2026-10-12', label: 'Oct 12', state: item.completedDates.includes('2026-10-12') ? 'Done' : 'Open' }],
    historyCalendarFor: entries => entries, renderHistoryCalendar: () => '', historyResolvedText: () => '',
    canDelayHistoryState: state => state === 'Open', canBringForwardHistoryState: () => false,
    historyOptions: (_item, _key, state) => `<option selected>${state}</option>`
  });
  vm.runInContext(source.slice(source.indexOf('  function renderModal()'), source.indexOf('  function render()')), context);
  return { state, context };
}

test('an open history sheet renders the latest synced title and progress', () => {
  const { state, context } = historyFixture();
  assert.match(context.renderModal(), /history-state open/);
  state.items = [{ id: 'routine', title: 'Synced title', completedDates: ['2026-10-12'] }];
  const html = context.renderModal();
  assert.match(html, /<h2>Synced title<\/h2>/);
  assert.match(html, /history-state done/);
  assert.doesNotMatch(html, /delay-history/);
  assert.doesNotMatch(html, /Original title/);
});

test('history dismisses when its item was removed by sync', () => {
  const { state, context } = historyFixture();
  state.items = [];
  assert.equal(context.renderModal(), '');
  assert.equal(state.modal, null);
});
