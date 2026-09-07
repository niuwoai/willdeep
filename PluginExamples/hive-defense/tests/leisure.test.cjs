const {test}=require('node:test'),assert=require('node:assert/strict');
const {createLeisure}=require('../ui/leisure.js');
const cells=Array.from({length:12},(_,c)=>({c,r:0,x:c*40,y:0}));
test('reward appears every third cleared wave and can only be claimed once',()=>{
  const l=createLeisure(()=>0);l.reset(cells);assert.equal(l.haste(0),1);
  for(let wave=1;wave<=3;wave++){l.start(wave);l.clear(wave,cells);assert.equal(l.choosing,wave===3);}
  assert.equal(l.choose('bad'),false);assert.equal(l.choose('haste'),true);assert.equal(l.choose('honey'),false);
  assert.equal(l.clear(3,cells),false);assert.equal(l.choosing,false);
  l.start(4);assert.equal(l.haste(4),1.2);l.start(5);assert.equal(l.haste(5),1);
});
test('flowers mature after three clears, grant capped nearby bonus, and reset on new game',()=>{
  const l=createLeisure(()=>0);l.reset(cells);const tower={x:40,y:0};assert.equal(l.bonus(tower),0);
  for(let wave=1;wave<=3;wave++)l.clear(wave,cells);
  assert.equal(l.flowers.filter(f=>f.age===3).length,2);assert.equal(l.bonus(tower),0.1);
  assert.equal(l.bonus({x:1000,y:1000}),0);
  for(let wave=4;wave<=30;wave++)l.clear(wave,cells);
  assert.equal(l.flowers.length,8);assert.ok(l.bonus(tower)<=0.15);l.reset(cells);assert.equal(l.bonus(tower),0);
});
test('move quota is once per wave and is restored only at wave start',()=>{
  const l=createLeisure(()=>0);l.reset(cells);assert.equal(l.consumeMove(),true);assert.equal(l.consumeMove(),false);
  l.clear(1,cells);assert.equal(l.consumeMove(),false);l.start(2);assert.equal(l.consumeMove(),true);
});
test('three of four cards are offered and only an offered card can be chosen',()=>{
  const l=createLeisure(()=>0);l.reset(cells);
  for(let wave=1;wave<=3;wave++)l.clear(wave,cells);
  assert.deepEqual(l.offered,['honey','repair','haste']);
  assert.equal(l.choose('parcel'),false);assert.equal(l.choosing,true);
  const p=createLeisure(()=>0.9);p.reset(cells);
  for(let wave=1;wave<=3;wave++)p.clear(wave,cells);
  assert.deepEqual(p.offered,['parcel','honey','repair']);
  assert.equal(p.choose('parcel'),true);assert.equal(p.choosing,false);
});
