(function(root){
  'use strict';
  const RULES = Object.freeze({firstWave:3, waveGap:3, chance:0.55, minDemolition:3, demolitionRange:3, hits:5, headRadius:29, headOffset:-48, bearSize:210, repairFraction:0.2, combo:1.25});
  const FACTS = Object.freeze({
    aphid:['成群出现，蜂胶炮擅长应对','蚜虫会吸食植物汁液。'],
    wasp:['用工蜂哨塔持续攻击','黄蜂也会捕食其他小虫。'],
    beetle:['护甲很厚，试试毒刺弩','甲虫的前翅像一副硬盔甲。'],
    moth:['速度快，先用花粉减速','许多飞蛾喜欢在夜间活动。'],
    spider:['会分裂，准备范围攻击','蜘蛛有八条腿，不属于昆虫。'],
    hornet:['强壮首领，组合多种塔','大黄蜂属于胡蜂家族。']
  });
  function createBear(random = Math.random){
    let bear = null, lastWave = 0, elapsed = 0;
    return {
      reset(){ bear=null; lastWave=0; elapsed=0; },
      spawn(wave,towers){
        const candidates=towers.filter(t=>!t.damaged);
        if(bear || wave<RULES.firstWave || wave-lastWave<RULES.waveGap || !candidates.length) return false;
        lastWave=wave;
        if(random()>=RULES.chance) return false;
        const target=candidates[Math.floor(random()*candidates.length)];
        bear={x:target.x,y:target.y,target,arrived:false,active:false,hits:0,reward:0,demolition:0,duration:RULES.minDemolition+random()*RULES.demolitionRange};
        elapsed=0; return true;
      },
      walk(dt,towers){
        if(!bear || bear.active || bear.arrived) return false;
        if(!towers.includes(bear.target)){bear.arrived=true;return false;}
        bear.demolition=Math.min(bear.duration,bear.demolition+dt);
        if(bear.demolition>=bear.duration){
          bear.arrived=true;
          bear.target.damaged=true;return true;
        }
        return false;
      },
      open(){if(!bear)return false;bear.active=true;return true;},
      close(){if(bear?.reward)bear=null;else if(bear)bear.active=false;},
      step(dt){if(bear?.active && !bear.reward)elapsed+=dt;},
      target(reduced){return {x:332+(reduced?0:Math.sin(elapsed*0.8)*210),y:228};},
      head(reduced){const p=this.target(reduced);return {x:p.x+8,y:p.y+RULES.headOffset};},
      shoot(x,y,reduced){
        if(!bear?.active || bear.reward)return {hit:false,reward:0};
        const p=this.head(reduced);
        if(Math.hypot(x-p.x,y-p.y)>RULES.headRadius)return {hit:false,reward:0};
        bear.hits++;
        if(bear.hits>=RULES.hits)bear.reward=100+Math.floor(random()*201);
        return {hit:true,reward:bear.reward};
      },
      get state(){return bear;},
      get active(){return !!bear?.active;}
    };
  }
  function createCollection(storage){
    const key='hive-defense.collection.v1';
    let repairs=0,seen=new Set();
    try{
      const data=JSON.parse(storage?.getItem(key)||'null');
      if(data){repairs=Number.isSafeInteger(data.repairs)&&data.repairs>=0?data.repairs:0;seen=new Set(Array.isArray(data.seen)?data.seen.filter(k=>Object.hasOwn(FACTS,k)):[]);}
    }catch(error){console.warn('Hive collection could not be loaded',error.name);}
    function save(){try{storage?.setItem(key,JSON.stringify({repairs,seen:[...seen]}));}catch(error){console.warn('Hive collection could not be saved',error.name);}}
    return {
      unlock(type){if(!Object.hasOwn(FACTS,type)||seen.has(type))return false;seen.add(type);save();return true;},
      repair(count){repairs+=count;save();},
      has(type){return seen.has(type);},
      get repairs(){return repairs;},
      get rank(){return repairs>=20?2:repairs>=5?1:0;}
    };
  }
  const api={RULES,FACTS,createBear,createCollection};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.HiveAdventure=api;
})(typeof window==='undefined'?globalThis:window);
