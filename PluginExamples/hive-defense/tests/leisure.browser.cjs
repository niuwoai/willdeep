const {chromium}=require('../../arcade/ui/node_modules/playwright');
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ui=path.resolve(__dirname,'../ui'),out=path.resolve(__dirname,'../../../build/ci/hive-defense');
const hooks=`window.leisureFixture={
  baseSetup(){startGame('garden');honey=10000;hp=15;['sting','bomb','pumpkin'].forEach(type=>{selType=type;for(let r=0;r<ROWS;r++)for(let c=0;c<COLS;c++)if(canBuild({c,r})){build({c,r});return;}});syncHud();},
  royal(){startGame('garden');honey=20000;selType='royal';for(let r=0;r<ROWS;r++)for(let c=0;c<COLS;c++){if(canBuild({c,r})&&royalPlacement({c,r},'royal')){build({c,r});return;}}},
  unlock(){baseLevel=4;renderInfo();},
  quiet(){bugs=[];spawnQueue=[{at:100000,type:'aphid',scale:1}];prep=0;},
  finish(n){wave=n;bugs=[];spawnQueue=[];prep=0;},
  prepare(health,balance){hp=health;honey=balance;syncHud();},
  damaged(value){towers[0].damaged=value;renderInfo();},
  skit(){startGame('garden');selType='pollen';build({c:3,r:2});const b=makeBug('flea',1);b.dist=DIST[3];Object.assign(b,PTS[3]);b.jumpUsed=true;b.jump={phase:'charge',charge:.5,time:0,to:10,from:PTS[3]};bugs=[b];spawnQueue=[{at:10000,type:'aphid',scale:1}];},
  state(){return {hp,honey,prep,choosing:leisure.choosing,credits:repair.credits,flowers:leisure.flowers.map(f=>f.age),towers:towers.map(t=>({c:t.c,r:t.r,level:t.level,harvest:t.harvest||0,moving:!!t.moving})),texts:texts.map(t=>t.s),tumble:bugs[0]?.tumble};}
};})();`;
const server=http.createServer((req,res)=>{
  const name=new URL(req.url,'http://localhost').pathname,file=path.resolve(ui,'.'+(name==='/'?'/index.html':name));
  if(!file.startsWith(ui+path.sep)||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
  res.setHeader('Content-Type',({'.js':'text/javascript','.html':'text/html','.css':'text/css','.png':'image/png'})[path.extname(file)]||'text/plain');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'");
  const body=fs.readFileSync(file);res.end(file.endsWith('/game.js')?body.toString().replace(/\}\)\(\);\s*$/,hooks):body);
});
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const browser=await chromium.launch({channel:'chrome',headless:true});
  try{
    const page=await browser.newPage({viewport:{width:1280,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.clock.install();await page.clock.pauseAt(Date.now()+1000);
    await page.goto('http://127.0.0.1:'+server.address().port);await page.evaluate(()=>HiveSprites.ready);await page.locator('#startBtn').click();
    const state=()=>page.evaluate(()=>leisureFixture.state());
    for(const n of [1,2,3]){await page.evaluate(n=>leisureFixture.finish(n),n);await page.clock.runFor(50);}
    assert.equal((await state()).choosing,true);assert.equal((await state()).flowers.filter(a=>a===3).length,2);
    const prep=(await state()).prep;await page.clock.runFor(1000);assert.equal((await state()).prep,prep);
    fs.mkdirSync(out,{recursive:true});await page.screenshot({path:path.join(out,'reward-choice.png'),fullPage:true});
    await page.locator('[data-reward="repair"]').click();assert.equal((await state()).credits,1);
    await page.evaluate(()=>{leisureFixture.quiet();leisureFixture.prepare(18,0);});await page.locator('#repairBtn').click();
    await page.clock.runFor(2900);assert.equal((await state()).hp,18);await page.clock.runFor(150);assert.equal((await state()).hp,19);assert.equal((await state()).honey,0);assert.equal((await state()).credits,0);
    await page.locator('#repairBtn').click();await page.evaluate(()=>leisureFixture.prepare(20,500));
    await page.locator('.card').filter({hasText:'南瓜花'}).click();
    const rect=await page.locator('#map').boundingBox();
    const cell=async(c,r)=>page.mouse.click(rect.x+(24+Math.sqrt(3)*26*(c+.5*(r&1)))/664*rect.width,rect.y+(30+39*r)/372*rect.height);
    await cell(3,2);assert.equal((await state()).honey,400);
    await page.clock.runFor(7900);assert.equal((await state()).honey,400);await page.clock.runFor(150);assert.equal((await state()).honey,410);
    await page.evaluate(()=>leisureFixture.unlock());await page.locator('#upBtn').click();assert.equal((await state()).towers[0].level,2);const upgraded=(await state()).honey;
    await page.locator('#pauseBtn').click();const stopped=(await state()).towers[0].harvest;await page.clock.runFor(8000);assert.equal((await state()).towers[0].harvest,stopped);
    await page.locator('#pauseBtn').click();await page.locator('#moveBtn').click();await cell(5,2);
    await page.clock.runFor(900);assert.equal((await state()).towers[0].moving,true);assert.equal((await state()).towers[0].harvest,stopped);
    await page.screenshot({path:path.join(out,'pumpkin-moving.png'),fullPage:true});
    await page.clock.runFor(1200);assert.equal((await state()).towers[0].c,5);assert.equal((await state()).towers[0].moving,false);assert.equal(await page.locator('#moveBtn').isDisabled(),true);
    await page.clock.runFor(8000);assert.equal((await state()).honey,upgraded+15);
    await page.evaluate(()=>leisureFixture.damaged(true));const damaged=(await state()).honey;await page.clock.runFor(8000);assert.equal((await state()).honey,damaged);
    await page.evaluate(()=>leisureFixture.damaged(false));await page.screenshot({path:path.join(out,'pumpkin-garden.png'),fullPage:true});
    await page.evaluate(()=>leisureFixture.skit());await page.clock.runFor(50);assert.ok((await state()).texts.includes('阿嚏！'));assert.ok((await state()).tumble>0);
    await page.evaluate(()=>{leisureFixture.royal();leisureFixture.unlock();});assert.equal((await state()).honey,18000);
    await page.locator('#upBtn').click();assert.equal((await state()).honey,13000);
    await page.locator('#upBtn').click();assert.equal((await state()).honey,3000);
    assert.equal(await page.locator('#upBtn').isDisabled(),true);assert.ok((await page.locator('#infoRows').innerText()).includes('1/2'));
    await page.clock.runFor(50);await page.screenshot({path:path.join(out,'royal-tower.png'),fullPage:true});
    await page.evaluate(()=>leisureFixture.baseSetup());assert.equal(await page.locator('#upBtn').isDisabled(),true);
    const baseHoney=(await state()).honey;await page.locator('#baseUpgradeBtn').click();
    assert.equal((await state()).honey,baseHoney-300);assert.equal((await state()).hp,15);
    assert.ok((await page.locator('#baseTitle').textContent()).includes('Lv.2'));
    await page.locator('#upBtn').click();assert.equal((await state()).towers.at(-1).level,2);assert.equal(await page.locator('#upBtn').isDisabled(),true);
    assert.deepEqual(errors,[]);
    const checks=['three-wave choices','choice freezes timer','flowers mature','repair coupon time and free point','pumpkin costs 100','periodic harvest','upgrade income','pause stops production','moving stops production','move keeps level and destination','one move per wave','damaged stops production','sneeze and tumble','no runtime errors'];
    checks.push('royal build and two upgrades with max level');
    checks.push('base upgrade unlocks tower level without healing');
    fs.writeFileSync(path.join(out,'leisure-browser.json'),JSON.stringify({passed:true,checks},null,2));console.log('Leisure browser passed: '+checks.length+' checks.');
  }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
