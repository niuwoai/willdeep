(function(root){
  'use strict';
  const RULES=Object.freeze({rewardEvery:3,honeyGift:40,haste:1.2,moveSeconds:2,flowerMaturity:3,maxFlowers:8,flowerRange:85,flowerBonus:0.05,maxBonus:0.15});
  // 四张卡每次展示三张：parcel 排第一位，random 取 0 时被抽掉，旧用例的三张不变。
  const CARDS=Object.freeze({parcel:{title:'神秘包裹',detail:'随机一件普通道具'},honey:{title:'蜂蜜小罐',detail:'立即获得 40 蜂蜜'},repair:{title:'维修优惠券',detail:'下一点基地维修免费，仍需维修时间'},haste:{title:'忙碌的工蜂',detail:'下一波工蜂哨塔射速提高 20%'}});
  function createLeisure(random=Math.random){
    let flowers=[],cleared=0,choosing=false,queuedHaste=false,hasteWave=-1,moved=false,offered=[];
    function plant(cells){
      if(flowers.length>=RULES.maxFlowers)return;
      const free=cells.filter(c=>!flowers.some(f=>f.c===c.c&&f.r===c.r));
      const nearby=free.filter(c=>flowers.some(f=>Math.hypot(c.x-f.x,c.y-f.y)<55));
      const pool=nearby.length?nearby:free;if(!pool.length)return;
      flowers.push({...pool[Math.floor(random()*pool.length)],age:0});
    }
    return {
      reset(cells){flowers=[];cleared=0;choosing=false;queuedHaste=false;hasteWave=-1;moved=false;offered=[];plant(cells);plant(cells);},
      clear(wave,cells){
        if(wave<=cleared)return false;cleared=wave;
        flowers.forEach(f=>f.age=Math.min(RULES.flowerMaturity,f.age+1));
        if(wave%2===0)plant(cells);
        if(wave%RULES.rewardEvery===0){choosing=true;const keys=Object.keys(CARDS);keys.splice(Math.floor(random()*keys.length),1);offered=keys;}
        return true;
      },
      start(wave){moved=false;hasteWave=queuedHaste?wave:-1;queuedHaste=false;},
      choose(key){if(!choosing||!offered.includes(key))return false;choosing=false;if(key==='haste')queuedHaste=true;return true;},
      consumeMove(){if(moved)return false;moved=true;return true;},
      bonus(tower){return Math.min(RULES.maxBonus,flowers.filter(f=>f.age>=RULES.flowerMaturity&&Math.hypot(f.x-tower.x,f.y-tower.y)<=RULES.flowerRange).length*RULES.flowerBonus);},
      haste(wave){return hasteWave===wave?RULES.haste:1;},
      get flowers(){return flowers;},get choosing(){return choosing;},get offered(){return offered.slice();},get moved(){return moved;},get queuedHaste(){return queuedHaste;}
    };
  }
  const api={RULES,CARDS,createLeisure};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.HiveLeisure=api;
})(typeof window==='undefined'?globalThis:window);
