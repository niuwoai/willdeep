const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('../../arcade/ui/node_modules/jsdom');
const ui = path.resolve(__dirname, '../ui');

function game() {
  const dom = new JSDOM(fs.readFileSync(path.join(ui, 'index.html'), 'utf8'), { runScripts: 'outside-only' });
  const w = dom.window;
  w.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, { get: (o, k) => o[k] || (() => {}), set: (o,k,v) => (o[k]=v,true) });
  w.matchMedia = () => ({ addEventListener() {} });
  w.requestAnimationFrame = () => {};
  const drawn = [];
  w.HiveSprites = { ready: Promise.resolve(), draw: (_, key) => drawn.push(key) };
  w.eval(fs.readFileSync(path.join(ui, 'systems.js'), 'utf8'));
  let source = fs.readFileSync(path.join(ui, 'game.js'), 'utf8');
  source = source.replace(/\}\)\(\);\s*$/, `window.testGame = { reset, build, canBuild, damage, makeBug, tick, drawBug, drawTowerGlyph, drawHive, towerStats, cellCenter, startWave, frame,
    select: key => selType = key, addBug: bug => bugs.push(bug),
    setVitals: (health, balance) => { hp=health; honey=balance; syncHud(); },
    animateHoney, syncHud, repair, gameOver,
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
test('all towers and enemies render their own image including hive', () => {
  const g = game();
  for (const key of ['sting','bomb','pollen','barb','drum']) g.api.drawTowerGlyph(10,10,key,2,0,1,true);
  for (const key of ['aphid','wasp','beetle','moth','spider','hornet']) g.api.drawBug(g.api.makeBug(key,1));
  g.api.drawHive();
  assert.equal(new Set(g.drawn).size,12);
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
  for(const type of ['aphid','wasp','beetle','moth','spider','hornet']){
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
