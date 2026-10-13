const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');

function fixture() {
  const current = { id:'routine', title:'Saved title' };
  const form = { scrollTop: 240, values:{title:'Unsaved title',notes:'Unsaved notes',endDate:'2026-10-15',quantity:'3'} };
  const state = {items:[current],modal:{type:'endCarryover',itemID:current.id,returnEditor:{form,scrollTop:240}}};
  let rendered = 0, restored = null, updated = null;
  const context = vm.createContext({
    state, render() { rendered += 1; },
    app: { querySelector: () => ({replaceWith(form) { restored = form; }}) },
    updateEditorScheduleControls: form => { updated = form; }
  });
  vm.runInContext(source.slice(source.indexOf('  function cancelEndCarryover('), source.indexOf('  function resolveCarryoverAndEnd(')), context);
  return {context,state,current,form,getResult:()=>({rendered,restored,updated})};
}

test('cancelling end resolution restores the same unsaved editor controls and scroll position', () => {
  const {context,state,current,form,getResult} = fixture();
  form.scrollTop = 0; // Detaching a scrolled form must not lose its return position.
  context.cancelEndCarryover();
  assert.equal(state.modal.type, 'editor');
  assert.equal(state.modal.item, current);
  assert.equal(getResult().restored, form);
  assert.equal(getResult().updated, form);
  assert.equal(form.values.title, 'Unsaved title');
  assert.equal(form.values.notes, 'Unsaved notes');
  assert.equal(form.values.endDate, '2026-10-15');
  assert.equal(form.values.quantity, '3');
  assert.equal(form.scrollTop, 240);
});

test('cancelling cannot bring back an editor for an item removed during the prompt', () => {
  const {context,state,getResult} = fixture();
  state.items = [];
  context.cancelEndCarryover();
  assert.equal(state.modal, null);
  assert.equal(getResult().restored, null);
});

test('a prompt without an editor draft still opens the current saved item on cancel', () => {
  const {context,state,current,getResult} = fixture();
  delete state.modal.returnEditor;
  context.cancelEndCarryover();
  assert.equal(state.modal.item, current);
  assert.equal(getResult().restored, null);
  assert.equal(getResult().rendered, 1);
});
