const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function fixture() {
  const state = {
    selectedDate: new Date(2026, 9, 17), mode: 'all', sort: 'name', search: 'review',
    modal: { type: 'date' }, items: [{ id: 'synthetic-task', completedDates: ['2026-10-17'] }],
    pending: [{ id: 'synthetic-mutation' }], accountID: 'synthetic-account',
  };
  let renders = 0;
  let focused = false;
  const context = vm.createContext({
    state, render() { renders += 1; },
    app: { querySelector() { return { focus() { focused = true; } }; } },
  });
  vm.runInContext(source.slice(source.indexOf('  function startOfDay('), source.indexOf('  const recurrenceOrdinals')), context);
  vm.runInContext(source.slice(source.indexOf('  function selectChecklistDate('), source.indexOf('  function renderChecklist(')), context);
  return { context, state, renders: () => renders, focused: () => focused };
}

test('jumping to leap day preserves filters, account and unsynced task progress', () => {
  const { context, state, renders, focused } = fixture();
  const previous = JSON.stringify({ items: state.items, pending: state.pending });
  assert.equal(context.selectChecklistDate('2040-02-29'), true);
  assert.equal(context.dateKey(state.selectedDate), '2040-02-29');
  assert.equal(state.selectedDate.getHours(), 0);
  assert.equal(state.mode, 'all');
  assert.equal(state.sort, 'name');
  assert.equal(state.search, 'review');
  assert.equal(state.accountID, 'synthetic-account');
  assert.equal(JSON.stringify({ items: state.items, pending: state.pending }), previous);
  assert.equal(state.modal, null);
  assert.equal(renders(), 1);
  assert.equal(focused(), true);
});

test('empty and impossible date drafts leave the selected date and picker unchanged', () => {
  const { context, state, renders } = fixture();
  const previous = state.selectedDate;
  const modal = state.modal;
  for (const value of ['', '2041-02-29', '2040-13-01', '2040-04-31', 'not-a-date']) {
    assert.equal(context.selectChecklistDate(value), false);
    assert.equal(state.selectedDate, previous);
    assert.equal(state.modal, modal);
  }
  assert.equal(renders(), 0);
});

test('Back to today restores Today scope without clearing search or offline data', () => {
  const { context, state } = fixture();
  context.selectChecklistDate('2040-02-29');
  const previous = JSON.stringify({ items: state.items, pending: state.pending });
  context.selectToday();
  assert.equal(context.dateKey(state.selectedDate), context.dateKey(new Date()));
  assert.equal(state.mode, 'today');
  assert.equal(state.search, 'review');
  assert.equal(state.sort, 'name');
  assert.equal(JSON.stringify({ items: state.items, pending: state.pending }), previous);
});
