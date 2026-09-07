const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('../../arcade/ui/node_modules/jsdom');
const ui = path.resolve(__dirname, '../ui');

test('wave reward pauses simulation and honey choice pays once',()=>{
  const g=game();g.api.finishWave(3);g.api.tick(0.01);assert.equal(g.api.leisure.choosing,true);
  const before=g.api.state();g.api.tick(100);assert.equal(g.api.state().prep,before.prep);
  g.api.chooseReward('honey');g.api.chooseReward('honey');assert.equal(g.api.state().honey,before.honey+40);
  assert.equal(g.api.leisure.choosing,false);g.close();
});
test('haste reward increases actual sentry rate for exactly the following wave',()=>{
  const g=game();g.api.select('sting');g.api.build({c:3,r:2});const t=g.api.state().towers[0];
  g.api.finishWave(3);g.api.tick(0.01);g.api.chooseReward('haste');g.api.startWave();
  assert.equal(g.api.towerStats(t).rate,1.7*1.2);g.api.startWave();assert.equal(g.api.towerStats(t).rate,1.7);g.close();
});
test('moving reserves both cells, keeps level, stops firing and completes after two seconds',()=>{
  const g=game();g.api.select('sting');g.api.build({c:3,r:2});const t=g.api.state().towers[0];t.level=3;
  g.api.move(t);g.api.startMove({c:5,r:2});assert.ok(t.moving);assert.equal(g.api.canBuild({c:3,r:2}),false);assert.equal(g.api.canBuild({c:5,r:2}),false);
  g.api.advanceMoves(1.9);assert.ok(t.moving);g.api.advanceMoves(0.1);assert.equal(t.moving,null);assert.equal(t.level,3);assert.equal(t.c,5);assert.equal(g.api.canBuild({c:3,r:2}),true);
  g.api.move(t);g.api.startMove({c:7,r:2});assert.equal(t.moving,null);g.close();
});
test('pumpkin harvests periodically, upgrades income, and stops while damaged or moved',()=>{
  const g=game();g.api.select('pumpkin');g.api.build({c:3,r:2});const t=g.api.state().towers[0];
  assert.equal(g.api.state().honey,120);g.api.tick(7.9);assert.equal(g.api.state().honey,120);g.api.tick(0.1);assert.equal(g.api.state().honey,130);
  g.api.chooseTower(t);g.w.document.getElementById('upBtn').click();assert.equal(t.level,2);
  const balance=g.api.state().honey;t.damaged=true;g.api.tick(4);assert.equal(t.harvest,0);assert.equal(g.api.state().honey,balance);
  t.damaged=false;g.api.move(t);g.api.startMove({c:5,r:2});g.api.tick(1);assert.equal(t.harvest,0);
  g.api.advanceMoves(1);g.api.tick(8);assert.equal(g.api.state().honey,balance+15);g.close();
});

test('flea charges half a second, lands once, and pollen cancels its only chance',()=>{
  const g=game(),{PATH,PTS,DIST}=g.api.route();
  const index=PATH.findIndex((_,i)=>g.w.HiveWorld.planJump(PATH,i,()=>0)?.charge===0.5);
  const flea=g.api.makeBug('flea',1);flea.dist=DIST[index];Object.assign(flea,PTS[index]);flea.jumpDelay=0;
  const random=g.w.Math.random;g.w.Math.random=()=>0;g.api.advanceJump(flea,0);g.w.Math.random=random;
  assert.equal(flea.jump.phase,'charge');g.api.advanceJump(flea,0.49);assert.equal(flea.jump.phase,'charge');
  g.api.advanceJump(flea,0.01);assert.equal(flea.jump.phase,'flight');const landing=flea.jump.to;
  g.api.advanceJump(flea,0.3);assert.equal(flea.dist,DIST[landing]);assert.equal(flea.jump,null);
  g.api.advanceJump(flea,100);assert.equal(flea.jump,null);assert.equal(flea.jumpUsed,true);
  const blocked=g.api.makeBug('flea',1);blocked.dist=DIST[3];Object.assign(blocked,PTS[3]);blocked.jumpUsed=true;
  blocked.jump={phase:'charge',charge:0.5,time:0,to:10,from:{...PTS[3]}};g.api.addBug(blocked);
  g.api.select('pollen');g.api.build({c:3,r:2});g.api.tick(0.05);
  assert.equal(blocked.jump,null);assert.equal(blocked.jumpUsed,true);g.close();
});
test('flea flies over portals without triggering them but landing on entry costs two',()=>{
  const g=game(),{PTS,DIST}=g.api.route();g.api.portals.step(6,PTS,DIST);const pair=g.api.portals.pair;
  const flea=g.api.makeBug('flea',1);flea.jumpUsed=true;flea.jump={phase:'flight',time:0,to:pair.entry+1,from:PTS[0]};
  g.api.advanceJump(flea,0.3);assert.equal(pair.remaining,4);assert.equal(flea.portalId,undefined);
  const landing=g.api.makeBug('flea',1);landing.jumpUsed=true;landing.jump={phase:'flight',time:0,to:pair.entry,from:PTS[0]};
  g.api.advanceJump(landing,0.3);assert.equal(pair.remaining,2);assert.equal(landing.dist,pair.to);assert.equal(landing.jumpUsed,true);g.close();
});

test('new insects spawn in waves, heal or sprint, and unlock their cards',()=>{
  const g=game();
  for(const [type,wave] of [['ant',2],['grasshopper',4],['caterpillar',7]]){
    assert.ok(g.api.waveDef(wave).some(group=>group[0]===type));
    assert.ok(g.api.waveDef(21).some(group=>group[0]===type));
    const bug=g.api.makeBug(type,1);g.api.damage(bug,100000,true);assert.equal(g.api.collection.has(type),true);
  }
  const caterpillar=g.api.makeBug('caterpillar',1);caterpillar.hp=100;g.api.addBug(caterpillar);
  g.api.tick(1);assert.equal(caterpillar.hp,105.25);
  caterpillar.hp=209;g.api.tick(1);assert.equal(caterpillar.hp,210);
  const jumper=g.api.makeBug('grasshopper',1);jumper.wob=0;g.api.addBug(jumper);
  g.api.tick(0.1);assert.equal(jumper.dist,58*1.8*0.1);
  jumper.wob=10;const before=jumper.dist;g.api.tick(0.1);assert.ok(Math.abs(jumper.dist-before-5.8)<1e-9);
  g.close();
});

test('bear encounter freezes simulation, pays once and preserves manual pause',()=>{
  const g=game();g.api.select('sting');g.api.build({c:3,r:2});
  while(!g.api.bear.spawn(3,g.api.state().towers))g.api.bear.reset();
  g.w.document.getElementById('pauseBtn').click();g.api.openBear();
  const before=g.api.state();g.api.tick(100);
  assert.equal(g.api.state().prep,before.prep);
  const p=g.api.bear.head(false);g.api.aimAt(p.x,p.y);
  for(let i=0;i<6;i++)g.api.shootBear();
  assert.ok(g.api.state().honey>=before.honey+100 && g.api.state().honey<=before.honey+300);
  const paid=g.api.state().honey;g.api.shootBear();assert.equal(g.api.state().honey,paid);
  g.api.closeBear();assert.equal(g.api.state().paused,true);assert.equal(g.api.bear.state,null);g.close();
});
test('damaged tower stops firing and repair charges twenty percent without losing level',()=>{
  const g=game();g.api.select('sting');g.api.build({c:3,r:2});
  const tower=g.api.state().towers[0];tower.level=3;tower.damaged=true;tower.cd=0;
  const bug=g.api.makeBug('aphid',10);bug.dist=130;g.api.addBug(bug);g.api.tick(0.01);
  assert.equal(tower.cd,0);g.api.chooseTower(tower);
  const balance=g.api.state().honey;g.w.document.getElementById('towerRepairBtn').click();
  assert.equal(tower.damaged,false);assert.equal(tower.level,3);assert.equal(g.api.state().honey,balance-12);
  g.w.document.getElementById('towerRepairBtn').click();assert.equal(g.api.state().honey,balance-12);g.close();
});

function game() {
  const dom = new JSDOM(fs.readFileSync(path.join(ui, 'index.html'), 'utf8'), { runScripts: 'outside-only', url:'https://hive.test', pretendToBeVisual:true });
  const w = dom.window;
  w.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, { get: (o, k) => o[k] || (() => {}), set: (o,k,v) => (o[k]=v,true) });
  w.matchMedia = () => ({ addEventListener() {} });
  w.requestAnimationFrame = () => {};
  const drawn = [];
  w.HiveSprites = { ready: Promise.resolve(), draw: (_, key) => drawn.push(key) };
  w.eval(fs.readFileSync(path.join(ui, 'systems.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(ui, 'adventure.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(ui, 'world.js'), 'utf8'));
  w.eval(fs.readFileSync(path.join(ui, 'leisure.js'), 'utf8'));
  let source = fs.readFileSync(path.join(ui, 'game.js'), 'utf8');
  source = source.replace(/\}\)\(\);\s*$/, `window.testGame = { reset, build, canBuild, damage, makeBug, tick, drawBug, drawTowerGlyph, drawHive, towerStats, cellCenter, startWave, frame,
    select: key => selType = key, addBug: bug => bugs.push(bug),
    setVitals: (health, balance) => { hp=health; honey=balance; syncHud(); },
    animateHoney, syncHud, repair, gameOver, bear, openBear, closeBear, shootBear, collection, startGame, configureMap, portals, waveDef, advanceJump,
    route:()=>({PATH,PTS,DIST}), leisure, chooseReward, startMove, advanceMoves,
    move:t=>moveSelection=t,
    finishWave:n=>{wave=n;bugs=[];spawnQueue=[];prep=0;},
    addShot:s=>shots.push(s),
    chooseTower:t=>{selTower=t;renderInfo();}, aimAt:(x,y)=>aim={x,y},
    state: () => ({towers, bugs, honey, hp, wave, paused, speed, running, prep, texts}) }; })();`);
  w.eval(source);
  w.document.getElementById('startBtn').click();
  return { w, api: w.testGame, drawn, close: () => w.close() };
}

test('building charges honey and rejects occupied/path cells', () => {
  const g = game();
  g.api.select('sting');
  g.api.build({c:3,r:2});
  assert.equal(g.api.state().honey, 160);
  assert.equal(g.api.state().towers.length, 1);
  assert.equal(g.api.canBuild({c:3,r:2}), false);
  g.close();
});
test('map rules affect real enemies and speed cycles through four times',()=>{
  const g=game();g.api.startGame('hollow');assert.equal(g.api.makeBug('aphid',1).armor,2);
  g.api.startGame('pond');assert.equal(g.api.makeBug('aphid',1).speed,64*0.85);
  for(const speed of [2,3,4,1]){g.w.document.getElementById('speedBtn').click();assert.equal(g.api.state().speed,speed);}
  g.close();
});
test('four times combat does not accelerate bear demolition',()=>{
  const g=game();g.api.select('sting');g.api.build({c:3,r:2});
  while(!g.api.bear.spawn(3,g.api.state().towers))g.api.bear.reset();
  for(let i=0;i<3;i++)g.w.document.getElementById('speedBtn').click();
  for(let i=1;i<=41;i++)g.api.frame(i*50);
  assert.ok(Math.abs(g.api.bear.state.demolition-2)<0.001);
  assert.equal(!!g.api.state().towers[0].damaged,false);g.close();
});
test('pollen slow adds twenty five percent to actual splash damage',()=>{
  for(const slowed of [false,true]){
    const g=game(),bug=g.api.makeBug('aphid',10);bug.speed=0;bug.slowUntil=slowed?2:0;
    g.api.addBug(bug);g.api.addShot({target:bug,x:bug.x,y:bug.y,sp:460,dmg:20,splash:44,c:'#C0703A'});
    const before=bug.hp;g.api.tick(0.01);assert.equal(before-bug.hp,slowed?25:20);g.close();
  }
});
test('all towers and enemies render their own image including hive', () => {
  const g = game();
  for (const key of ['sting','bomb','pollen','barb','drum','pumpkin']) g.api.drawTowerGlyph(10,10,key,2,0,1,true);
  for (const key of ['aphid','wasp','beetle','moth','spider','hornet','ant','caterpillar','grasshopper','flea']) g.api.drawBug(g.api.makeBug(key,1));
  g.api.drawHive();
  assert.equal(new Set(g.drawn).size,17);
  g.close();
});
test('spider death produces two small spider sprites and pays once', () => {
  const g = game();
  const bug = g.api.makeBug('spider',1);
  g.api.damage(bug,10000,true);
  const state = g.api.state();
  assert.equal(state.bugs.length,2);
  assert.ok(state.bugs.every(b => b.sprite === 'spider' && b.r < bug.r));
  assert.equal(state.honey,220 + bug.bounty);
  g.api.damage(bug,10000,true);
  assert.equal(g.api.state().honey,state.honey);
  g.close();
});
test('pause, speed, waves and combat remain functional', () => {
  const g = game();
  g.w.document.getElementById('pauseBtn').click();
  assert.equal(g.api.state().paused,true);
  g.w.document.getElementById('pauseBtn').click();
  g.w.document.getElementById('speedBtn').click();
  assert.equal(g.api.state().speed,2);
  g.w.document.getElementById('callBtn').click();
  assert.equal(g.api.state().wave,1);
  for(let i=0;i<800;i++) g.api.tick(0.05);
  assert.ok(g.api.state().hp < 20);
  g.close();
});

test('real balance changes immediately while displayed honey animates', () => {
  const g = game();
  g.api.select('sting'); g.api.build({c:3,r:2});
  assert.equal(g.api.state().honey,160);
  assert.equal(g.w.document.getElementById('honey').textContent,'220');
  g.api.animateHoney(0.1);
  const midway=Number(g.w.document.getElementById('honey').textContent);
  assert.ok(midway>160 && midway<220);
  g.api.animateHoney(0.65);
  assert.equal(g.w.document.getElementById('honey').textContent,'160');
  g.close();
});

test('every enemy death shows honey text and duplicate kills never pay twice', () => {
  const g = game();
  for(const type of ['aphid','wasp','beetle','moth','spider','hornet','ant','caterpillar','grasshopper','flea']){
    const bug=g.api.makeBug(type,1), before=g.api.state().honey;
    g.api.damage(bug,100000,true);
    g.api.damage(bug,100000,true);
    assert.equal(g.api.state().honey,before+bug.bounty);
    assert.ok(g.api.state().texts.some(t=>t.s===`+${bug.bounty} 蜂蜜`));
  }
  g.api.animateHoney(1);
  assert.equal(Number(g.w.document.getElementById('honey').textContent),g.api.state().honey);
  g.close();
});

test('repair button restores one point gradually and spends four honey', () => {
  const g = game();
  g.api.setVitals(15,40);
  g.w.document.getElementById('repairBtn').click();
  for(let i=0;i<59;i++) g.api.tick(0.05);
  assert.equal(g.api.state().hp,15);
  assert.equal(g.api.state().honey,40);
  g.api.tick(0.05);
  assert.equal(g.api.state().hp,16);
  assert.equal(g.api.state().honey,36);
  g.close();
});

test('pause and restart do not repair or leak old display values', () => {
  const g = game();
  g.api.setVitals(12,40);
  g.w.document.getElementById('repairBtn').click();
  g.w.document.getElementById('pauseBtn').click();
  for(let i=1;i<=200;i++)g.api.frame(i*50);
  assert.equal(g.api.state().hp,12);
  assert.equal(g.api.repair.progress,0);
  g.api.gameOver();
  assert.equal(g.api.repair.active,false);
  g.w.document.getElementById('startBtn').click();
  assert.equal(g.w.document.getElementById('mapChoices').hidden,false);
  g.w.document.getElementById('startBtn').click();
  assert.equal(g.api.state().hp,20);
  assert.equal(g.api.state().honey,220);
  assert.equal(g.w.document.getElementById('honey').textContent,'220');
  g.close();
});

test('an active repair can be stopped while the game is paused', () => {
  const g=game();g.api.setVitals(15,40);
  g.w.document.getElementById('repairBtn').click();g.api.tick(1);
  g.w.document.getElementById('pauseBtn').click();
  g.w.document.getElementById('repairBtn').click();
  assert.equal(g.api.repair.active,false);
  assert.equal(g.api.repair.progress,1);
  g.close();
});
