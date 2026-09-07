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
  assert.equal(r.nextCost,6);
  assert.deepEqual(r.step(1,10,6),{hp:11,honey:0,repaired:1});
});
test('dispatch first prices rise 4 6 8 and each repair multiplies that dispatch price',()=>{
  const r=createRepair();
  for(const first of [4,6,8]){
    assert.equal(r.nextDispatchCost,first);r.toggle(10,true);
    assert.equal(r.nextCost,first);let result=r.step(3,10,100);
    assert.equal(result.honey,100-first);assert.equal(r.nextCost,first*2);
    result=r.step(3,result.hp,result.honey);assert.equal(result.honey,100-first*3);
    assert.equal(r.nextCost,first*3);r.stop();
  }
  r.reset();assert.equal(r.nextDispatchCost,4);assert.equal(r.dispatches,0);
});
test('expensive next point waits without spending or progressing',()=>{
  const r=createRepair();r.toggle(10,true);r.step(3,10,10);
  assert.equal(r.nextCost,8);assert.deepEqual(r.step(2,11,6),{hp:11,honey:6,repaired:0});
  assert.equal(r.progress,0);assert.deepEqual(r.step(3,11,8),{hp:12,honey:0,repaired:1});
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
