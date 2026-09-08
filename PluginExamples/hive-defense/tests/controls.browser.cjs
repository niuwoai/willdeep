const {chromium}=require('../../arcade/ui/node_modules/playwright');
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ui=path.resolve(__dirname,'../ui'),out=path.resolve(__dirname,'../../../build/ci/hive-controls');
const hooks=`window.controlsFixture={
 prepare(){hp=15;honey=100;bugs=[];spawnQueue=[];prep=1000;syncHud();},
 tower(){const p=cellCenter(3,2);towers=[{c:3,r:2,x:p.x,y:p.y,type:'sting',level:1,cd:0,angle:0}];bag.reset();bag.add('nectar');renderBag();},
 state(){return {active:repair.active,hp,honey,progress:repair.progress,armed:bag.armedKey,items:bag.items,selected:selTower?.type};}
};})();`;
const server=http.createServer((req,res)=>{
 const file=path.resolve(ui,'.'+(req.url==='/'?'/index.html':req.url));
 if(!file.startsWith(ui+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type',({'.js':'text/javascript','.css':'text/css','.html':'text/html','.png':'image/png'})[path.extname(file)]||'text/plain');
 const body=fs.readFileSync(file);res.end(file.endsWith('/game.js')?body.toString().replace(/\}\)\(\);\s*$/,hooks):body);
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try{
  fs.mkdirSync(out,{recursive:true});
  const page=await browser.newPage({viewport:{width:1280,height:800}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.clock.install();await page.goto('http://127.0.0.1:'+server.address().port);
  await page.evaluate(()=>window.HiveSprites.ready);await page.locator('#startBtn').click();
  await page.evaluate(()=>controlsFixture.prepare());
  await page.locator('#pauseBtn').click();await page.locator('#repairBtn').click();
  assert.equal(await page.evaluate(()=>controlsFixture.state().active),true);
  assert.match(await page.locator('#repairStatus').textContent(),/已待命/);
  await page.clock.runFor(1000);assert.equal(await page.evaluate(()=>controlsFixture.state().hp),15);
  await page.locator('#pauseBtn').click();await page.clock.runFor(3100);
  assert.equal(await page.evaluate(()=>controlsFixture.state().hp),16);
  await page.locator('#repairBtn').click();assert.equal(await page.evaluate(()=>controlsFixture.state().active),false);
  await page.evaluate(()=>controlsFixture.tower());await page.locator('[data-slot="0"]').click();
  assert.equal(await page.locator('[data-slot="0"]').evaluate(el=>document.activeElement===el),true);
  const map=await page.locator('#map').boundingBox();
  await page.mouse.click(map.x+(24+Math.sqrt(3)*26*3)/664*map.width,map.y+108/372*map.height);
  const selected=await page.evaluate(()=>controlsFixture.state());
  assert.equal(selected.armed,null);assert.equal(selected.selected,'sting');assert.deepEqual(selected.items,['nectar']);
  assert.equal(await page.locator('#infoBody').isVisible(),true);
  await page.locator('[data-slot="0"]').click();await page.locator('#cancelItem').click();
  assert.equal(await page.evaluate(()=>controlsFixture.state().armed),null);
  await page.locator('[data-slot="0"]').click();await page.locator('.card').first().click();
  assert.equal(await page.evaluate(()=>controlsFixture.state().armed),null);
  const tip=await page.locator('#tutorialTip').textContent();await page.locator('#tipNext').click();
  assert.notEqual(await page.locator('#tutorialTip').textContent(),tip);
  await page.locator('#tipPause').click();assert.equal(await page.locator('#tipPause').getAttribute('aria-pressed'),'true');
  for(const width of [1280,900]){
   await page.setViewportSize({width,height:800});
   for(const id of ['bagSlots','repairBtn','tutorialTip']){const r=await page.locator('#'+id).boundingBox();assert.ok(r.y+r.height<800,id+' stays visible at '+width);}
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
   await page.screenshot({path:path.join(out,'layout-'+width+'.png'),fullPage:true});
  }
  await page.emulateMedia({reducedMotion:'reduce'});
  assert.equal(await page.locator('#tutorialTip').evaluate(el=>getComputedStyle(el).animationName),'none');
  assert.deepEqual(errors,[]);fs.writeFileSync(path.join(out,'report.json'),JSON.stringify({passed:true,errors},null,2));
  console.log('PASS: paused repair dispatch/resume, item selection recovery, cancel, shop switch, tutorial and responsive layout');
 }finally{await browser.close();server.close();}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
