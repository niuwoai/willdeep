const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createRepair,createCounter}=require('../ui/systems.js');

test('repair preserves progress when stopped or short of honey',()=>{
  const r=createRepair();r.toggle(10,true);
  r.step(2,10,4);
  assert.equal(r.step(10,10,3).hp,10);
  assert.equal(r.progress,2);
  r.toggle(10,true);r.step(5,10,40);
  assert.equal(r.progress,2);
  r.toggle(10,true);
  assert.deepEqual(r.step(1,10,4),{hp:11,honey:0,repaired:1});
});
test('being hit halves repair temporarily and keeps earned progress',()=>{
  const r=createRepair();r.toggle(10,true);r.step(1,10,40);r.hit();
  assert.equal(r.step(3,10,40).hp,10);
  assert.equal(r.progress,2.5);
  assert.deepEqual(r.step(0.5,10,40),{hp:11,honey:36,repaired:1});
});
test('repair stops at full HP and charges only the missing point',()=>{
  const r=createRepair();r.toggle(19,true);
  assert.deepEqual(r.step(20,19,40),{hp:20,honey:36,repaired:1});
  assert.equal(r.active,false);assert.equal(r.progress,0);
});
test('repair cannot run on a destroyed or full hive',()=>{
  const r=createRepair();
  assert.equal(r.toggle(0,true),false);
  assert.equal(r.toggle(20,true),false);
  assert.equal(r.toggle(10,false),false);
});
test('retargeting a honey animation never loses rapid rewards or spending',()=>{
  const c=createCounter(220);
  assert.equal(c.set(226),6);
  const first=c.step(0.1);
  assert.ok(first>220 && first<226);
  assert.equal(c.set(232),6);
  assert.equal(c.step(0),first);
  c.set(172);
  const next=c.step(0.1);assert.ok(next<first && next>172);
  assert.equal(c.step(0.65),172);
  assert.equal(c.set(172),0);
});
test('reduced motion and reset snap to the exact authoritative balance',()=>{
  const c=createCounter(220);c.set(160);
  assert.equal(c.step(0,true),160);
  assert.equal(c.step(0.1,false),160);
  c.set(300);c.reset(220);
  assert.equal(c.step(0),220);
});
