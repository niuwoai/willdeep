(function(root){
  'use strict';
  // 南瓜花疲劳与道具系统的纯逻辑。数值以 docs/PUMPKIN_FATIGUE_AND_ITEMS_DESIGN.md 为准；
  // 这里不碰 DOM，Node 里直接测。
  const RULES=Object.freeze({
    slots:6,
    fatigueEvery:30, witherAfter:90,
    neighbourPenalty:0.2, maxNeighbourPenalty:0.6,
    sellRatio:0.6,
    bearHoney:50, epicChance:0.3, cleanRareChance:0.5,
    fullBagHoney:Object.freeze({common:80,rare:300,epic:600}),
    pawChance:0.8, pawGap:2,
    hornSeconds:15, edictBonus:0.3,
    bombRadius:90, bombSlow:0.6, bombSeconds:4
  });
  const ITEMS=Object.freeze({
    nectar:{name:'蜜露瓶',rarity:'common',glyph:'🍯',target:'pumpkin',detail:'一棵南瓜花疲劳归零，枯萎的也能救活'},
    bomb:{name:'花粉炸弹',rarity:'common',glyph:'💥',target:'map',detail:'落点 90 范围内虫子减速 60%，持续 4 秒'},
    wax:{name:'蜡封',rarity:'common',glyph:'🕯️',target:'hiveOrTower',detail:'点受损塔免费修好；点别处则蜂巢 +1 生命'},
    horn:{name:'工蜂号角',rarity:'rare',glyph:'📯',target:'none',detail:'15 秒内南瓜花产蜜间隔减半，疲劳也跟着快'},
    edict:{name:'蜂王令',rarity:'rare',glyph:'👑',target:'none',detail:'下一波所有攻击塔伤害 +30%'},
    paw:{name:'熊掌印',rarity:'rare',glyph:'🐾',target:'none',detail:'狗熊更常来、掉落上调一档，持续到局末；它每次都会拆塔'},
    amber:{name:'琥珀',rarity:'epic',glyph:'🟠',target:'pumpkin',detail:'一棵南瓜花永久免疫疲劳与邻减'}
  });
  const BY_RARITY=Object.freeze({
    common:Object.keys(ITEMS).filter(k=>ITEMS[k].rarity==='common'),
    rare:Object.keys(ITEMS).filter(k=>ITEMS[k].rarity==='rare'),
    epic:Object.keys(ITEMS).filter(k=>ITEMS[k].rarity==='epic')
  });
  const GRADES=['none','plain','clean','perfect'];

  // ===== 南瓜花 =====
  function halvings(harvests){return Math.floor(Math.max(0,harvests)/RULES.fatigueEvery);}
  function withered(harvests,amber){return !amber&&harvests>=RULES.witherAfter;}
  function fatigueMultiplier(harvests,amber){return amber?1:Math.pow(0.5,halvings(harvests));}
  function neighbourMultiplier(count,amber){return amber?1:1-Math.min(RULES.maxNeighbourPenalty,Math.max(0,count)*RULES.neighbourPenalty);}
  // 单次产蜜：基础值 × 疲劳 × 邻减，取整后至少 1；枯萎为 0。
  function pumpkinYield(baseIncome,harvests,neighbours,amber){
    if(withered(harvests,amber))return 0;
    return Math.max(1,Math.round(baseIncome*fatigueMultiplier(harvests,amber)*neighbourMultiplier(neighbours,amber)));
  }
  // 出售折率：60% × 0.5^减半次数；枯萎为 0。
  function sellRatio(harvests,amber){
    if(withered(harvests,amber))return 0;
    return RULES.sellRatio*(amber?1:Math.pow(0.5,halvings(harvests)));
  }
  // odd-r 偏移六边形网格的六个相邻格。
  function hexNeighbours(c,r){
    const odd=r&1;
    return [[c-1,r],[c+1,r],[c-(odd?0:1),r-1],[c+(odd?1:0),r-1],[c-(odd?0:1),r+1],[c+(odd?1:0),r+1]].map(([nc,nr])=>({c:nc,r:nr}));
  }
  function neighbourCount(tower,towers){
    return hexNeighbours(tower.c,tower.r).filter(n=>towers.some(o=>o!==tower&&o.type==='pumpkin'&&o.c===n.c&&o.r===n.r&&!withered(o.harvests||0,o.amber))).length;
  }

  // ===== 狗熊评级与掉落 =====
  function grade(misses,escaped){
    if(escaped)return 'none';
    if(misses<=0)return 'perfect';
    if(misses<=2)return 'clean';
    return 'plain';
  }
  function bump(g){return GRADES[Math.min(GRADES.length-1,Math.max(0,GRADES.indexOf(g)+1))];}
  function pick(list,random){return list[Math.floor(random()*list.length)];}
  // 按评级掉一件；熊掌印生效时整体上调一档，完美不再上调。
  function rollDrop(g,random=Math.random,paw=false){
    if(g==='none')return null;
    const tier=paw?bump(g):g;
    if(tier==='perfect')return random()<RULES.epicChance?pick(BY_RARITY.epic,random):pick(BY_RARITY.rare,random);
    if(tier==='clean')return random()<RULES.cleanRareChance?pick(BY_RARITY.rare,random):pick(BY_RARITY.common,random);
    return pick(BY_RARITY.common,random);
  }

  // ===== 背包 =====
  function createInventory(){
    let items=[],armed=-1;
    return {
      get items(){return items.slice();},
      get armed(){return armed;},
      get full(){return items.length>=RULES.slots;},
      add(key){if(!Object.hasOwn(ITEMS,key)||items.length>=RULES.slots)return false;items.push(key);return true;},
      arm(index){if(index<0||index>=items.length)return false;armed=armed===index?-1:index;return armed>=0;},
      disarm(){armed=-1;},
      get armedKey(){return armed>=0?items[armed]:null;},
      consume(index=armed){if(index<0||index>=items.length)return null;const key=items.splice(index,1)[0];armed=-1;return key;},
      reset(){items=[];armed=-1;}
    };
  }

  const api={RULES,ITEMS,BY_RARITY,halvings,withered,fatigueMultiplier,neighbourMultiplier,pumpkinYield,sellRatio,hexNeighbours,neighbourCount,grade,rollDrop,createInventory};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.HiveItems=api;
})(typeof window==='undefined'?globalThis:window);
