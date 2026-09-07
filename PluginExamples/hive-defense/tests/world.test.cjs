const {test}=require('node:test'),assert=require('node:assert/strict');
const {MAPS,createPortals}=require('../ui/world.js');
test('three maps have distinct continuous paths and stay inside the board',()=>{
  assert.equal(new Set(Object.values(MAPS).map(m=>JSON.stringify(m.path))).size,3);
  for(const map of Object.values(MAPS)){
    assert.equal(new Set(map.path.map(p=>p.c+','+p.r)).size,map.path.length);
    map.path.forEach((p,i)=>{
      assert.ok(p.c>=0&&p.c<14&&p.r>=0&&p.r<9);
      if(i){const q=map.path[i-1];assert.equal(Math.abs(p.c-q.c)+Math.abs(p.r-q.r),1);}
    });
  }
});
test('portals jump forward once, never teleport bugs that already passed, then expire and recur',()=>{
  for(const random of [()=>0,()=>0.99999]){
    const p=createPortals(random),points=MAPS.garden.path,dist=points.map((_,i)=>i*40);
    p.step(6,points,dist);const pair=p.pair;assert.ok(pair.to>pair.from);assert.ok(pair.exit<points.length-1);
    const bug={dist:pair.from+2};assert.equal(p.transport(bug,pair.from-1),true);assert.equal(bug.dist,pair.to+2);
    assert.equal(p.transport(bug,pair.from-1),false);
    const passed={dist:pair.to+10};assert.equal(p.transport(passed,pair.from+1),false);
    p.step(12,points,dist);assert.equal(p.pair,null);p.step(14,points,dist);assert.ok(p.pair);
    p.reset();assert.equal(p.pair,null);
  }
});
test('each portal admits at most two distinct bugs even in the same frame',()=>{
  const portals=createPortals(()=>0),points=MAPS.garden.path,dist=points.map((_,i)=>i*40);
  portals.step(6,points,dist);const pair=portals.pair;
  const bugs=Array.from({length:5},()=>({dist:pair.from+1}));
  assert.equal(portals.transport(bugs[0],pair.from-1),true);
  assert.equal(portals.transport(bugs[0],pair.from-1),false);
  assert.equal(pair.remaining,1);
  assert.equal(portals.transport(bugs[1],pair.from-1),true);
  for(const bug of bugs.slice(2)){assert.equal(portals.transport(bug,pair.from-1),false);assert.equal(bug.dist,pair.from+1);}
  assert.equal(pair.remaining,0);portals.step(0.4,points,dist);assert.equal(portals.pair,null);
  portals.step(9,points,dist);assert.equal(portals.pair.remaining,2);
});
