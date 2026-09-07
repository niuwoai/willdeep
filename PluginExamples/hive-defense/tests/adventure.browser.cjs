const {chromium}=require('../../arcade/ui/node_modules/playwright');
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ui=path.resolve(__dirname,'../ui'),out=path.resolve(__dirname,'../../../build/ci/hive-defense');
const hooks=`window.hiveFixture={
  encounter(){selType='sting';build({c:3,r:2});wave=3;while(!bear.spawn(wave,towers))bear.reset();bear.walk(100,towers);renderBearNotice();},
  point(){return bear.target(motionPreference.matches);},
  snapshot(){return {hp,honey,prep,wave,paused,hits:bear.state?.hits,damaged:towers[0]?.damaged};},
  discover(){damage(makeBug('spider',1),10000,true);collection.repair(20);renderCollection();}
};})();`;
const server=http.createServer((req,res)=>{
  const name=new URL(req.url,'http://localhost').pathname;
  const file=path.resolve(ui,'.'+(name==='/'?'/index.html':name));
  if(!file.startsWith(ui+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.setHeader('Content-Type',({'.js':'text/javascript','.html':'text/html','.css':'text/css','.png':'image/png'})[path.extname(file)]||'text/plain');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; frame-src 'none'");
  const body=fs.readFileSync(file);res.end(file.endsWith('/game.js')?body.toString().replace(/\}\)\(\);\s*$/,hooks):body);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({channel:'chrome',headless:true});
  try{
    const page=await browser.newPage({viewport:{width:1280,height:1000}}),errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.clock.install();await page.clock.pauseAt(Date.now()+1000);
    await page.goto('http://127.0.0.1:'+server.address().port);await page.evaluate(()=>HiveSprites.ready);
    await page.locator('#startBtn').click();await page.evaluate(()=>hiveFixture.encounter());
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).damaged,true);
    // Open by clicking the bear at the damaged tower's actual map coordinates.
    const map=await page.locator('#map').boundingBox();
    await page.mouse.click(map.x+159.1*map.width/664,map.y+108*map.height/372);
    assert.equal(await page.locator('#bearPanel').isVisible(),true);
    const before=await page.evaluate(()=>hiveFixture.snapshot());await page.clock.runFor(1500);
    const frozen=await page.evaluate(()=>hiveFixture.snapshot());assert.equal(frozen.hp,before.hp);assert.equal(frozen.prep,before.prep);
    assert.equal(await page.locator('.hud').evaluate(e=>e.inert),true);
    async function hit(){
      const p=await page.evaluate(()=>hiveFixture.point()),r=await page.locator('#bearCanvas').boundingBox(),scale=Math.min(r.width/664,r.height/372);
      await page.mouse.click(r.x+(r.width-664*scale)/2+p.x*scale,r.y+(r.height-372*scale)/2+p.y*scale);
    }
    await hit();await hit();await page.locator('#bearExit').click();
    await page.locator('#bearOpen').click();assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).hits,2);
    await page.clock.runFor(50);fs.mkdirSync(out,{recursive:true});await page.screenshot({path:path.join(out,'bear-aim.png'),fullPage:true});
    await hit();await hit();await hit();const won=await page.evaluate(()=>hiveFixture.snapshot());
    assert.ok(won.honey-before.honey>=100&&won.honey-before.honey<=300);await hit();
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).honey,won.honey);
    await page.locator('#bearExit').click();assert.equal(await page.locator('.hud').evaluate(e=>e.inert),false);
    await page.mouse.click(map.x+159.1*map.width/664,map.y+108*map.height/372);
    await page.locator('#towerRepairBtn').click();const repaired=await page.evaluate(()=>hiveFixture.snapshot());
    assert.equal(repaired.damaged,false);assert.equal(repaired.honey,won.honey-12);
    await page.evaluate(()=>hiveFixture.discover());await page.locator('#bestiary summary').filter({hasText:'蜘蛛'}).click();
    await page.screenshot({path:path.join(out,'bear-collection.png'),fullPage:true});
    await page.reload();await page.evaluate(()=>HiveSprites.ready);
    assert.match(await page.locator('#beeGrowth').textContent(),/工具箱/);assert.match(await page.locator('#bestiary').textContent(),/蜘蛛有八条腿/);
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(out,'adventure-browser.json'),JSON.stringify({passed:true,checks:['map click opens canvas','simulation frozen','controls locked','pointer aim hits','exit retains hits','reward in bounds','reward paid once','repair charges 12','collection persists','growth persists','no runtime errors']},null,2));
    console.log('Adventure browser passed: 11 checks.');
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
