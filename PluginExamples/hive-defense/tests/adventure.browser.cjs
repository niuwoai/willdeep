const {chromium}=require('../../arcade/ui/node_modules/playwright');
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ui=path.resolve(__dirname,'../ui'),out=path.resolve(__dirname,'../../../build/ci/hive-defense');
const hooks=`window.hiveFixture={
  encounter(){selType='sting';build({c:3,r:2});wave=3;leisure.clear(3,[]);leisure.choose('honey');while(!bear.spawn(wave,towers))bear.reset();renderBearNotice();},
  point(){return bear.head(motionPreference.matches);},
  body(){return bear.target(motionPreference.matches);},
  snapshot(){return {hp,honey,prep,wave,paused,running,currentMap,hits:bear.state?.hits,demolition:bear.state?.demolition,duration:bear.state?.duration,damaged:!!towers[0]?.damaged};},
  choose(){running=false;chooseMap();},
  portal(){portals.reset();portals.step(6,PTS,DIST);bugs=Array.from({length:5},()=>{const b=makeBug('aphid',10);b.dist=portals.pair.from-1;return b;});spawnQueue=[];return {from:portals.pair.from,to:portals.pair.to};},
  bugs(){return bugs.map(b=>({dist:b.dist,portalId:b.portalId}));},
  damageBase(){hp=12;honey=100;bugs=[];spawnQueue=[];prep=13;syncHud();},
  flea(){
    portals.reset();towers=[];selTower=null;renderInfo();spawnQueue=[];
    const index=PATH.findIndex((_,i)=>HiveWorld.planJump(PATH,i,()=>0)?.charge===0.5);
    const b=makeBug('flea',1);b.dist=DIST[index];Object.assign(b,PTS[index]);b.jumpDelay=0;
    const random=Math.random;Math.random=()=>0;advanceJump(b,0);Math.random=random;bugs=[b];return b.dist;
  },
  jumping(){const b=bugs[0];return {dist:b.dist,used:b.jumpUsed,phase:b.jump?.phase};},
  discover(){for(const k of ['spider','ant','caterpillar','grasshopper'])damage(makeBug(k,1),10000,true);collection.repair(20);renderCollection();}
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
    fs.mkdirSync(out,{recursive:true});
    await page.clock.runFor(50);await page.screenshot({path:path.join(out,'map-picker.png'),fullPage:true});
    await page.clock.runFor(2800);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).running,false);
    await page.clock.runFor(300);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).running,true);
    await page.evaluate(()=>hiveFixture.choose());await page.locator('[data-map="hollow"]').click();
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).currentMap,'hollow');await page.clock.runFor(50);
    await page.screenshot({path:path.join(out,'map-hollow.png'),fullPage:true});
    await page.evaluate(()=>hiveFixture.choose());await page.locator('[data-map="pond"]').click();
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).currentMap,'pond');await page.clock.runFor(50);
    await page.screenshot({path:path.join(out,'map-pond.png'),fullPage:true});
    await page.evaluate(()=>hiveFixture.choose());
    await page.locator('#startBtn').click();await page.evaluate(()=>hiveFixture.encounter());
    await page.clock.runFor(1500);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).damaged,false);
    await page.screenshot({path:path.join(out,'bear-demolition.png'),fullPage:true});
    const attack=await page.evaluate(()=>hiveFixture.snapshot());assert.ok(attack.duration>=3&&attack.duration<=6);
    await page.clock.runFor(Math.ceil((attack.duration-attack.demolition)*1000)+100);
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).damaged,true);
    // Open by clicking the bear at the damaged tower's actual map coordinates.
    const map=await page.locator('#map').boundingBox();
    await page.mouse.click(map.x+159.1*map.width/664,map.y+108*map.height/372);
    assert.equal(await page.locator('#bearPanel').isVisible(),true);
    const scene=await page.locator('#bearCanvas').boundingBox();
    assert.ok(Math.abs(scene.width-map.width)<2 && Math.abs(scene.height-map.height)<2,'aiming scene should fill the map area');
    const before=await page.evaluate(()=>hiveFixture.snapshot());await page.clock.runFor(1500);
    const frozen=await page.evaluate(()=>hiveFixture.snapshot());assert.equal(frozen.hp,before.hp);assert.equal(frozen.prep,before.prep);
    assert.equal(await page.locator('.hud').evaluate(e=>e.inert),true);
    async function hit(body=false){
      const p=await page.evaluate(body=>body?hiveFixture.body():hiveFixture.point(),body),r=await page.locator('#bearCanvas').boundingBox(),scale=Math.min(r.width/664,r.height/372);
      await page.mouse.click(r.x+(r.width-664*scale)/2+p.x*scale,r.y+(r.height-372*scale)/2+p.y*scale);
    }
    await hit(true);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).hits,0);
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
    const gate=await page.evaluate(()=>hiveFixture.portal());await page.clock.runFor(100);
    const transported=await page.evaluate(()=>hiveFixture.bugs());
    assert.equal(transported.filter(b=>b.dist>=gate.to).length,4);
    assert.equal(transported.filter(b=>!b.portalId).length,1);
    await page.screenshot({path:path.join(out,'portal-active.png'),fullPage:true});
    for(const label of ['2×','3×','4×','1×']){await page.locator('#speedBtn').click();assert.equal(await page.locator('#speedBtn').textContent(),label);}
    await page.evaluate(()=>hiveFixture.damageBase());await page.locator('#repairBtn').click();
    assert.match(await page.locator('#repairStatus').textContent(),/第 1 点 4 蜂蜜/);
    await page.clock.runFor(3100);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).honey,96);
    assert.match(await page.locator('#repairStatus').textContent(),/第 2 点 8 蜂蜜/);
    await page.clock.runFor(3000);assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).honey,88);
    await page.locator('#repairBtn').click();assert.match(await page.locator('#repairBtn').textContent(),/首点 6 蜂蜜/);
    await page.locator('#repairBtn').click();await page.clock.runFor(3000);
    assert.equal((await page.evaluate(()=>hiveFixture.snapshot())).honey,82);
    await page.locator('#repairBtn').click();
    await page.evaluate(()=>hiveFixture.discover());await page.locator('#bestiary summary').filter({hasText:'蜘蛛'}).click();
    await page.screenshot({path:path.join(out,'bear-collection.png'),fullPage:true});
    const jumpStart=await page.evaluate(()=>hiveFixture.flea());await page.clock.runFor(200);
    assert.equal((await page.evaluate(()=>hiveFixture.jumping())).phase,'charge');
    await page.screenshot({path:path.join(out,'flea-charge.png'),fullPage:true});
    await page.clock.runFor(350);assert.equal((await page.evaluate(()=>hiveFixture.jumping())).phase,'flight');
    await page.clock.runFor(400);const landed=await page.evaluate(()=>hiveFixture.jumping());assert.ok(landed.dist>jumpStart);assert.equal(landed.used,true);assert.equal(landed.phase,undefined);
    await page.reload();await page.evaluate(()=>HiveSprites.ready);
    assert.match(await page.locator('#beeGrowth').textContent(),/工具箱/);assert.match(await page.locator('#bestiary').textContent(),/蜘蛛有八条腿/);
    assert.deepEqual(errors,[]);
    const checks=['3 second automatic map','manual hollow','manual pond','3-6 second demolition','map click opens canvas','simulation frozen','controls locked','body shot misses','head shot hits','exit retains hits','reward in bounds','reward paid once','repair charges 12','portal transports exactly four of five small bugs','4x speed cycle','repair charges 4 then 8','next dispatch charges 6','collection persists including new insects','growth persists','scene matches map dimensions','flea charge flight and landing','no runtime errors'];
    fs.writeFileSync(path.join(out,'adventure-browser.json'),JSON.stringify({passed:true,checks},null,2));
    console.log('Adventure browser passed: '+checks.length+' checks.');
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
