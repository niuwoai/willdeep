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
  let source = fs.readFileSync(path.join(ui, 'game.js'), 'utf8');
  source = source.replace(/\}\)\(\);\s*$/, `window.testGame = { reset, build, canBuild, damage, makeBug, tick, drawBug, drawTowerGlyph, drawHive, towerStats, cellCenter, startWave, frame,
    select: key => selType = key, addBug: bug => bugs.push(bug),
    state: () => ({towers, bugs, honey, hp, wave, paused, speed, running}) }; })();`);
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
