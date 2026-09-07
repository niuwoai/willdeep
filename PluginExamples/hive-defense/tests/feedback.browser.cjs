const {chromium}=require('../../arcade/ui/node_modules/playwright');
const http=require('node:http');
const fs=require('node:fs');
const path=require('node:path');
const assert=require('node:assert/strict');
const ui=path.resolve(__dirname,'../ui');
const out=path.resolve(__dirname,'../../../build/ci/hive-defense');
// Only the test server exposes fixtures; the shipped game has no test hooks.
const hooks=`window.hiveFixture={
  prepare(health,balance){hp=health;honey=balance;bugs=[];spawnQueue=[];prep=13;syncHud();},
  reward(){damage(makeBug('aphid',1),10000,true);},
  build(){selType='sting';build({c:3,r:2});},
  snapshot(){return {hp,honey,progress:repair.progress,active:repair.active,display:Number(honeyEl.textContent)};}
};})();`;
const server=http.createServer((req,res)=>{
  const pathname=new URL(req.url,'http://localhost').pathname;
  const file=path.resolve(ui,'.'+(pathname==='/'?'/index.html':pathname));
  if(!file.startsWith(ui+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  const ext=path.extname(file);
  res.setHeader('Content-Type',({'.js':'text/javascript','.html':'text/html','.css':'text/css','.png':'image/png'})[ext]||'text/plain');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'");
  const body=fs.readFileSync(file);
  res.end(file.endsWith('/game.js')?body.toString().replace(/\}\)\(\);\s*$/,hooks):body);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({channel:'chrome',headless:true,timeout:30000});
  try{
    fs.mkdirSync(out,{recursive:true});
    const page=await browser.newPage({viewport:{width:1280,height:1000}});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.clock.install({time:new Date('2026-09-07T12:00:00Z')});
    await page.clock.pauseAt(new Date('2026-09-07T12:00:01Z'));
    await page.goto('http://127.0.0.1:'+server.address().port);
    await page.evaluate(()=>window.HiveSprites.ready);
    const click=id=>page.evaluate(id=>document.getElementById(id).click(),id);
    const snapshot=()=>page.evaluate(()=>window.hiveFixture.snapshot());
    await click('startBtn');
    await page.evaluate(()=>window.hiveFixture.prepare(15,40));
    await page.clock.runFor(700);
    await click('repairBtn');
    await page.clock.runFor(2900);
    assert.equal((await snapshot()).hp,15);
    await page.clock.runFor(150);
    assert.equal((await snapshot()).hp,16);
    assert.equal((await snapshot()).honey,36);
    await click('pauseBtn');
    const paused=await snapshot();
    await page.clock.runFor(2000);
    assert.equal((await snapshot()).progress,paused.progress);
    await click('pauseBtn');
    await page.evaluate(()=>window.hiveFixture.prepare(16,3));
    const waiting=await snapshot();
    await page.clock.runFor(1000);
    assert.equal((await snapshot()).progress,waiting.progress);
    assert.match(await page.locator('#repairStatus').textContent(),/等待蜂蜜/);
    await page.evaluate(()=>window.hiveFixture.reward());
    await page.clock.runFor(500);
    assert.ok((await snapshot()).progress>waiting.progress);
    await page.screenshot({path:path.join(out,'repair-active.png'),fullPage:true});
    await click('repairBtn');
    await page.evaluate(()=>window.hiveFixture.prepare(16,100));
    await page.clock.runFor(700);
    await page.evaluate(()=>window.hiveFixture.reward());
    assert.equal((await snapshot()).honey,106);
    assert.equal((await snapshot()).display,100);
    await page.clock.runFor(100);
    const animated=await snapshot();
    assert.ok(animated.display>100&&animated.display<106);
    assert.notEqual(await page.locator('#honey').evaluate(el=>el.style.transform),'scale(1)');
    await page.screenshot({path:path.join(out,'honey-earning.png'),fullPage:true});
    await page.evaluate(()=>{window.hiveFixture.reward();window.hiveFixture.build();});
    assert.equal((await snapshot()).honey,52);
    await page.clock.runFor(700);
    assert.equal((await snapshot()).display,52);
    await page.emulateMedia({reducedMotion:'reduce',colorScheme:'dark'});
    await page.evaluate(()=>window.hiveFixture.reward());
    await page.clock.runFor(32);
    assert.equal((await snapshot()).display,(await snapshot()).honey);
    assert.equal(await page.locator('#honey').evaluate(el=>getComputedStyle(el).transform),'none');
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(out,'feedback-browser.json'),JSON.stringify({status:'passed',checks:['gradual repair','per-point payment','pause','insufficient honey','reward resumes repair','counter interpolation','rapid reward and spending','reduced motion','CSP'],errors},null,2));
    console.log('Feedback browser: all 9 checks passed');
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
