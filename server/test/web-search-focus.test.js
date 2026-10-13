const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../web/app.js'),'utf8');

function fixture({signedIn=true,focused=true}={}) {
  let currentSearch;
  const document = {activeElement:null};
  const search = {value:'review',selectionStart:3,selectionEnd:3,
    matches: selector=>selector==='[data-search]',
    focus(){document.activeElement=this;},
  };
  currentSearch=search;
  if(focused) document.activeElement=search;
  const context=vm.createContext({
    state:{modal:null},renderedEditorModal:null,document,hasSession:()=>signedIn,
    app:{querySelector:selector=>selector==='[data-search]'?currentSearch:null},
    renderChecklist(){
      document.activeElement=null;
      currentSearch={replaceWith(node){currentSearch=node;}};
    },
    renderAuth(){document.activeElement=null;currentSearch=null;},
    updateEditorScheduleControls(){},
  });
  vm.runInContext(source.slice(source.indexOf('  function render()'),source.indexOf('  function showToast(')),context);
  return {context,document,search,current:()=>currentSearch};
}

test('filter and sync redraws preserve the focused search control and its insertion point',()=>{
  const {context,document,search,current}=fixture();
  context.render();
  assert.equal(document.activeElement,search);
  assert.equal(current(),search);
  assert.equal(search.value,'review');
  assert.equal(search.selectionStart,3);
  assert.equal(search.selectionEnd,3);
  context.render();
  assert.equal(document.activeElement,search);
  assert.equal(current(),search);
});

test('an inactive search does not steal focus during a redraw',()=>{
  const {context,document,search,current}=fixture({focused:false});
  context.render();
  assert.equal(document.activeElement,null);
  assert.notEqual(current(),search);
});

test('an expired session does not reinsert private search text into the sign-in screen',()=>{
  const {context,document,current}=fixture({signedIn:false});
  context.render();
  assert.equal(document.activeElement,null);
  assert.equal(current(),null);
});

test('clearing search resets a retained focused input and leaves it ready to type again', () => {
  const { context, document, search, current } = fixture();
  context.state.search = 'review';
  vm.runInContext(source.slice(source.indexOf('  function clearSearch('), source.indexOf('  function renderChecklist(')), context);
  context.clearSearch();
  assert.equal(context.state.search, '');
  assert.equal(current().value, '');
  assert.equal(document.activeElement, search);
});
