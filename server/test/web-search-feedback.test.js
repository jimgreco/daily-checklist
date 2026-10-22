const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function fixture({ items = [], carryovers = [], mode = 'today', search = 'morning', completedCollapsed = false, remainingOnly = false } = {}) {
  const context = vm.createContext({
    state: { mode, search, completedCollapsed, remainingOnly, groups: [], selectedDate: new Date(), sort: 'manual' },
    app: { innerHTML: '' }, visibleItems: () => items, carryoverItems: () => carryovers,
    sameDay: () => true, complete: item => item.done, skipped: item => item.skipped,
    isPaused: item => item.paused, escapeHTML: String, icon: () => '',
    renderCarryoverTask: () => '<article>Still open</article>',
    renderGroup: (name, rows) => rows.map(item => `<article data-row="${item.id || 'task'}">Tasks</article>`).join(''),
    renderAccountButton: () => '', renderModal: () => '',
  });
  vm.runInContext(source.slice(source.indexOf('  function renderSearchFeedback('), source.indexOf('  function renderAccountButton(')), context);
  context.renderChecklist();
  return context.app.innerHTML;
}

test('search counts active, completed, skipped and still-open results without counting hidden paused tasks', () => {
  const html = fixture({ items: [{}, { done: true }, { skipped: true }, { paused: true }], carryovers: [{}] });
  assert.match(html, /4 matching tasks/);
  assert.match(html, /data-action="clear-search"/);
});

for (const mode of ['all', 'archive']) {
  test(`${mode} search counts paused tasks too`, () => {
    assert.match(fixture({ mode, items: [{ paused: true }] }), /1 matching task</);
  });
}

test('no-match feedback replaces unrelated schedule emptiness messaging', () => {
  const html = fixture();
  assert.match(html, /0 matching tasks/);
  assert.match(html, /No matching rituals/);
  assert.match(html, /Try a different task name or note/);
  assert.doesNotMatch(html, /Nothing is scheduled|Everything is complete/);
});

test('ordinary empty schedules retain their existing message when no search is active', () => {
  const html = fixture({ search: '  ' });
  assert.doesNotMatch(html, /matching tasks|No matching rituals|Clear search/);
  assert.match(html, /Nothing is scheduled/);
});

test('completed collapse preserves count and expands matching results during search', () => {
  const items = [{ done: true }, { done: true }, {}];
  const hidden = fixture({ items, search: '', completedCollapsed: true });
  assert.match(hidden, /Completed · 2/);
  assert.match(hidden, /id="completed-tasks" hidden/);
  assert.match(hidden, /aria-expanded="false"/);
  const searching = fixture({ items, search: 'morning', completedCollapsed: true });
  assert.match(searching, /3 matching tasks/);
  assert.match(searching, /id="completed-tasks">/);
  assert.doesNotMatch(searching, /data-action="toggle-completed"/);
  const expanded = fixture({ items, search: '', completedCollapsed: false });
  assert.match(expanded, /aria-expanded="true"/);
  assert.doesNotMatch(expanded, /id="completed-tasks" hidden/);
});
test('archive and empty completed sections never offer the collapse control', () => {
  assert.doesNotMatch(fixture({ mode: 'archive', items: [{ done: true }], search: '' }), /toggle-completed/);
  assert.doesNotMatch(fixture({ items: [{}], search: '' }), /toggle-completed/);
});


test('remaining focus excludes completed, skipped and paused rows while retaining unfinished quantities and carryovers', () => {
  const html = fixture({ remainingOnly: true, items: [
    { id: 'open' }, { id: 'partial', count: 1, quantity: 3 },
    { id: 'done', done: true }, { id: 'skipped', skipped: true }, { id: 'paused', paused: true },
  ], carryovers: [{}] });
  assert.match(html, /3 matching tasks/);
  assert.match(html, /data-row="open"/);
  assert.match(html, /data-row="partial"/);
  assert.match(html, /Still open/);
  assert.doesNotMatch(html, /data-row="(?:done|skipped|paused)"/);
  assert.match(html, /data-action="toggle-remaining" aria-pressed="true"/);
});

test('remaining focus has a clear empty state and combines with search', () => {
  const items = [{ done: true }, { skipped: true }];
  const empty = fixture({ remainingOnly: true, search: '', items });
  assert.match(empty, /No remaining tasks for this day/);
  assert.doesNotMatch(empty, /Nothing is scheduled|toggle-completed/);
  const searching = fixture({ remainingOnly: true, search: 'done', items });
  assert.match(searching, /0 matching tasks/);
  assert.match(searching, /No matching rituals/);
});

for (const mode of ['all', 'archive']) {
  test(`remaining focus does not filter ${mode} or offer its control`, () => {
    const html = fixture({ mode, remainingOnly: true, items: [{ id: 'done', done: true }, { id: 'paused', paused: true }] });
    assert.match(html, /2 matching tasks/);
    assert.match(html, /data-row="done"/);
    assert.match(html, /data-row="paused"/);
    assert.doesNotMatch(html, /data-action="toggle-remaining"/);
  });
}


test('remaining focus distinguishes an empty schedule from actionable still-open work', () => {
  const html = fixture({ remainingOnly: true, search: '', items: [{ done: true }], carryovers: [{}] });
  assert.match(html, /Still open/);
  assert.match(html, /No scheduled tasks remaining for this day/);
  assert.doesNotMatch(html, /No remaining tasks for this day/);
});
