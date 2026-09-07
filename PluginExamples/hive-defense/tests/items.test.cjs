const {test}=require('node:test'),assert=require('node:assert/strict');
const items=require('../ui/items.js');
const {RULES,ITEMS,pumpkinYield,sellRatio,hexNeighbours,neighbourCount,grade,rollDrop,createInventory,withered}=items;

test('pumpkin yield halves every 30 harvests, floors at 1, withers at 90',()=>{
  assert.equal(pumpkinYield(10,0,0,false),10);
  assert.equal(pumpkinYield(10,29,0,false),10);
  assert.equal(pumpkinYield(10,30,0,false),5);
  assert.equal(pumpkinYield(10,60,0,false),3);   // 2.5 → 3
  assert.equal(pumpkinYield(10,89,0,false),3);
  assert.equal(pumpkinYield(10,90,0,false),0);
  assert.equal(withered(90,false),true);
  // 一级花一生：300 + 150 + 90 = 540
  let total=0;for(let h=0;h<200;h++)total+=pumpkinYield(10,h,0,false);
  assert.equal(total,540);
  // 琥珀免疫一切
  assert.equal(pumpkinYield(10,500,6,true),10);
  assert.equal(withered(500,true),false);
});

test('adjacent pumpkins cut yield by 20% each, capped at 60%, and only on the hex ring',()=>{
  assert.equal(pumpkinYield(10,0,1,false),8);
  assert.equal(pumpkinYield(10,0,3,false),4);
  assert.equal(pumpkinYield(10,0,6,false),4);
  const me={c:3,r:2,type:'pumpkin'};
  const ring=hexNeighbours(3,2);assert.equal(ring.length,6);
  // 偶数行：左上是 (c-1,r-1)，奇数行会是 (c,r-1)
  assert.deepEqual(ring[2],{c:2,r:1});
  assert.deepEqual(hexNeighbours(3,3)[2],{c:3,r:2});
  const towers=[me,{c:2,r:2,type:'pumpkin'},{c:4,r:2,type:'sting'},{c:2,r:1,type:'pumpkin',harvests:95},{c:9,r:9,type:'pumpkin'}];
  // 一棵相邻活花算，相邻的哨塔不算，相邻的枯萎花不算，远处的不算
  assert.equal(neighbourCount(me,towers),1);
});

test('sell ratio follows fatigue and drops to nothing when withered',()=>{
  assert.equal(sellRatio(0,false),0.6);
  assert.equal(sellRatio(30,false),0.3);
  assert.equal(sellRatio(60,false),0.15);
  assert.equal(sellRatio(90,false),0);
  assert.equal(sellRatio(90,true),0.6);
});

test('bear grade depends on misses, escaping drops nothing',()=>{
  assert.equal(grade(0,false),'perfect');
  assert.equal(grade(2,false),'clean');
  assert.equal(grade(3,false),'plain');
  assert.equal(grade(0,true),'none');
  assert.equal(rollDrop('none',()=>0),null);
});

test('drop table respects rarity per grade and the paw bumps one tier',()=>{
  const isRarity=(key,r)=>ITEMS[key].rarity===r;
  // 完美：random<0.3 出史诗，否则稀有
  assert.ok(isRarity(rollDrop('perfect',()=>0.1),'epic'));
  assert.ok(isRarity(rollDrop('perfect',()=>0.5),'rare'));
  // 干净：一半稀有一半普通
  assert.ok(isRarity(rollDrop('clean',()=>0.2),'rare'));
  assert.ok(isRarity(rollDrop('clean',()=>0.9),'common'));
  // 一般：只有普通
  for(const r of [0,0.5,0.99])assert.ok(isRarity(rollDrop('plain',()=>r),'common'));
  // 熊掌印：一般 → 干净，完美不再上调
  assert.ok(isRarity(rollDrop('plain',()=>0.2,true),'rare'));
  assert.ok(isRarity(rollDrop('perfect',()=>0.5,true),'rare'));
  // 稀有度池子齐全
  assert.deepEqual(items.BY_RARITY.common.sort(),['bomb','nectar','wax']);
  assert.deepEqual(items.BY_RARITY.rare.sort(),['edict','horn','paw']);
  assert.deepEqual(items.BY_RARITY.epic,['amber']);
});

test('inventory holds six, arms one at a time, and consumes the armed slot',()=>{
  const bag=createInventory();
  for(let i=0;i<RULES.slots;i++)assert.equal(bag.add('nectar'),true);
  assert.equal(bag.full,true);assert.equal(bag.add('bomb'),false);assert.equal(bag.add('nope'),false);
  assert.equal(bag.arm(2),true);assert.equal(bag.armed,2);assert.equal(bag.armedKey,'nectar');
  assert.equal(bag.arm(2),false);assert.equal(bag.armed,-1);
  bag.arm(5);assert.equal(bag.consume(),'nectar');assert.equal(bag.items.length,5);assert.equal(bag.armed,-1);
  assert.equal(bag.consume(),null);
  bag.reset();assert.equal(bag.items.length,0);
});
