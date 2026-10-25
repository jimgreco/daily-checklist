const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');
function fixture() {
 const today=new Date(2026,9,25);
 const context=vm.createContext({state:{mode:'today',selectedDate:today,search:'review'},Date,
  visibleItems:()=>[{title:'Water',quantity:3,count:1},{title:'Done',done:true},{title:'Skipped',skipped:true},{title:'Paused',paused:true}],
  carryoverItems:()=>[{item:{title:'Plants',quantity:2},occurrences:[{scheduledDate:'2026-10-24',occurrence:{completionCount:1}},{scheduledDate:'2026-10-25',occurrence:{completionCount:0}}]}],
  complete:i=>i.done,skipped:i=>i.skipped,isPaused:i=>i.paused,quantity:i=>i.quantity||1,completionCount:i=>i.count||0,
  dateKey:()=> '2026-10-25', sameDay:()=>true, dateFromInput:v=>new Date(v+'T12:00:00')});
 vm.runInContext(source.slice(source.indexOf('  function remainingChecklistSummary()'),source.indexOf('  function renderChecklist()')),context);
 return context;
}
test('handoff preserves partial quantities, each carryover date, and excludes resolved rows',()=>{
 const c=fixture();const text=c.remainingChecklistSummary();
 assert.match(text,/Filtered by: review/);assert.match(text,/- \[ \] Water \(2 of 3 remaining\)/);
 assert.match(text,/Plants \(1 of 2 remaining\) — due 2026-10-24/);
 assert.match(text,/Plants \(2 of 2 remaining\) — due 2026-10-25/);
 assert.doesNotMatch(text,/Done|Skipped|Paused/);
 assert.equal(c.state.search,'review');
});
test('historical day has no current carryovers; empty and non-scheduled views stay explicit',()=>{
 const c=fixture();c.sameDay=()=>false;c.visibleItems=()=>[];
 assert.equal(c.remainingChecklistSummary(),'Ritual Cue — Remaining for 2026-10-25\nFiltered by: review\n\nNothing remaining.');
 c.state.mode='all';assert.equal(c.remainingChecklistSummary(),'');
 c.state.mode='archive';assert.equal(c.remainingChecklistSummary(),'');
});
test('legacy clipboard failure is reported rather than announcing a copy',async()=>{
 const textarea={style:{},setAttribute(){},select(){},remove(){this.removed=true;}};
 const c=vm.createContext({navigator:{},document:{createElement:()=>textarea,body:{appendChild(){}},execCommand:()=>false}});
 vm.runInContext(source.slice(source.indexOf('  async function copyText('),source.indexOf('  async function copyDiagnostics(')),c);
 await assert.rejects(c.copyText('summary'),/Clipboard unavailable/);assert.equal(textarea.removed,true);
});
