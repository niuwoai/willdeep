const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createBear,createCollection}=require('../ui/adventure.js');
test('bear respects wave gate, damages only one tower and keeps its level',()=>{
  const b=createBear(()=>0), towers=[{x:30,y:340,level:3},{x:90,y:340,level:1}];
  assert.equal(b.spawn(2,towers),false);assert.equal(b.spawn(3,towers),true);
  b.walk(1,towers);b.walk(100,towers);
  assert.equal(towers[0].damaged,true);assert.equal(towers[0].level,3);assert.equal(towers[1].damaged,undefined);
  assert.equal(b.spawn(6,towers),false);
});
test('misses do not count, closing retains hits, rewards include both bounds and pay once',()=>{
  for(const bound of [0,0.999999]){
    let random=0;const b=createBear(()=>random);
    b.spawn(3,[{x:90,y:100}]);b.open();
    assert.equal(b.shoot(0,0,true).hit,false);
    for(let i=0;i<4;i++)assert.equal(b.shoot(332,180,true).reward,0);
    b.close();b.open();assert.equal(b.state.hits,4);
    random=bound;assert.equal(b.shoot(332,180,true).reward,bound?300:100);
    assert.equal(b.shoot(332,180,true).reward,0);
    b.close();assert.equal(b.state,null);assert.equal(b.spawn(4,[{}]),false);
  }
});
test('selling target retargets safely and empty map does not crash',()=>{
  const b=createBear(()=>0),tower={x:40,y:300};b.spawn(3,[tower]);b.walk(1,[]);
  assert.equal(b.state.arrived,true);assert.equal(b.open(),true);
});
test('collection persists valid discoveries and repair growth without duplicate unlocks',()=>{
  let data=null;const storage={getItem:()=>data,setItem:(_,v)=>data=v};
  const c=createCollection(storage);assert.equal(c.unlock('spider'),true);assert.equal(c.unlock('spider'),false);
  c.repair(5);assert.equal(c.rank,1);c.repair(15);assert.equal(c.rank,2);
  const restored=createCollection(storage);assert.equal(restored.repairs,20);assert.equal(restored.has('spider'),true);
  data='{"repairs":-3,"seen":["bad","aphid"]}';const safe=createCollection(storage);
  assert.equal(safe.repairs,0);assert.equal(safe.has('bad'),false);assert.equal(safe.has('aphid'),true);
});
