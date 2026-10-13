const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function renderGroup(items, options = {}) {
  const context = vm.createContext({
    state: { selectedDate: new Date(2026, 9, 12) },
    complete: item => item.done,
    isPaused: item => item.paused,
    isGroupPaused: () => false,
    escapeHTML: String,
    icon: () => '',
    groupProgress: () => '0/2',
    renderTask: item => `<article data-id="${item.id}"></article>`,
  });
  vm.runInContext(source.slice(source.indexOf('  function renderGroup('), source.indexOf('  function renderChecklist(')), context);
  return context.renderGroup('Morning', items, 'morning', true, options);
}

function rows(html) {
  return [...html.matchAll(/<article data-id="([^"]+)"/g)].map(match => match[1]);
}

test('mixed groups keep paused tasks reachable in All items and Archive', () => {
  const items = [
    { id: 'paused', paused: true },
    { id: 'active' },
    { id: 'done', done: true },
    { id: 'paused-done', paused: true, done: true },
  ];
  for (const allowsBulkActions of [true, false]) {
    const html = renderGroup(items, { allowsBulkActions });
    assert.deepEqual(rows(html), ['active', 'paused', 'done', 'paused-done']);
    assert.equal(html.includes('data-action="complete-group"'), allowsBulkActions);
  }
});

test('groups containing only paused items retain manual order without a complete-all action', () => {
  const html = renderGroup([{ id: 'paused-second', paused: true }, { id: 'paused-first', paused: true }], { allowsBulkActions: true });
  assert.deepEqual(rows(html), ['paused-second', 'paused-first']);
  assert.equal(html.includes('data-action="complete-group"'), false);
});

test('collapsed mixed groups keep their rows hidden until expanded', () => {
  assert.deepEqual(rows(renderGroup([{ id: 'active' }, { id: 'paused', paused: true }], { isCollapsed: true })), []);
});
