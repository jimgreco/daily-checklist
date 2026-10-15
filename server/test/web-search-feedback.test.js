const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function fixture({ items = [], carryovers = [], mode = 'today', search = 'morning', completedCollapsed = false } = {}) {
  const context = vm.createContext({
    state: { mode, search, completedCollapsed, groups: [], selectedDate: new Date(), sort: 'manual' },
    app: { innerHTML: '' }, visibleItems: () => items, carryoverItems: () => carryovers,
    sameDay: () => true, complete: item => item.done, skipped: item => item.skipped,
    isPaused: item => item.paused, escapeHTML: String, icon: () => '',
    renderCarryoverTask: () => '<article>Still open</article>',
    renderGroup: (name, rows) => rows.length ? '<article>Tasks</article>' : '',
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
