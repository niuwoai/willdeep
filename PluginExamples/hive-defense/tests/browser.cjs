const { chromium } = require('../../arcade/ui/node_modules/playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const out = path.resolve(__dirname, '../../../build/ci/hive-defense');

(async () => {
  fs.mkdirSync(out, {recursive:true});
  const browser = await chromium.launch({channel:'chrome', headless:true,timeout:30000});
  console.log('Browser launched');
  try {
    const page = await browser.newPage({viewport:{width:1280,height:900}});
    const errors=[];
    page.on('pageerror', e => errors.push(e.message));
    const entry = process.env.HIVE_ENTRY || path.resolve(__dirname,'../ui/index.html');
    await page.goto(pathToFileURL(entry).href);
    console.log('Page loaded');
    await page.evaluate(() => window.HiveSprites.ready);
    console.log('Sprites loaded');
    const images = await page.evaluate(async () => {
      return Promise.all(window.HiveSprites.keys.map(key => new Promise(resolve => {
        const image = new Image();
        image.onload=()=>resolve({key, width:image.naturalWidth});
        image.src='assets/'+key+'.png';
      })));
    });
    assert.equal(images.length,12);
    assert.ok(images.every(x=>x.width>0));
    await page.locator('#startBtn').click();
    await page.locator('.card').first().click();
    const bounds = await page.locator('#map').boundingBox();
    const clickCell = async (c,r) => page.mouse.click(bounds.x + (24+Math.sqrt(3)*26*(c+0.5*(r&1)))/664*bounds.width, bounds.y+(30+39*r)/372*bounds.height);
    await clickCell(3,2);
    await clickCell(3,2);
    await page.locator('#upBtn').click();
    await page.locator('#pauseBtn').click();
    assert.equal(await page.locator('#pauseBtn').textContent(),'继续');
    await page.locator('#pauseBtn').click();
    await page.locator('#speedBtn').click();
    await page.locator('#callBtn').click();
    await page.waitForTimeout(4500);
    await page.screenshot({path:path.join(out,'game-light.png'),fullPage:true});
    await page.emulateMedia({colorScheme:'dark'});
    await page.screenshot({path:path.join(out,'game-dark.png'),fullPage:true});
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(out,'browser.json'),JSON.stringify({status:'passed',images,errors},null,2));
    console.log('Browser passed: 12 images, build/upgrade, pause/resume, speed, wave, light/dark screenshots; no runtime errors.');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1});
