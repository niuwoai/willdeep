(function(root){
  'use strict';
  function snake(rows,start,end){
    const path=[];
    rows.forEach((row,index)=>{
      const from=index%2?end:start,to=index%2?start:end,step=from<to?1:-1;
      for(let c=from;;c+=step){path.push({c,r:row});if(c===to)break;}
      if(index<rows.length-1)path.push({c:to,r:row+1});
    });
    return path;
  }
  const garden=snake([1,3,5,7],0,12);
  // Keep the original garden's short final stretch and alternating inner turn.
  const original=[];
  for(let c=0;c<=12;c++)original.push({c,r:1});
  original.push({c:12,r:2},{c:12,r:3});
  for(let c=11;c>=1;c--)original.push({c,r:3});
  original.push({c:1,r:4},{c:1,r:5});
  for(let c=2;c<=12;c++)original.push({c,r:5});
  original.push({c:12,r:6},{c:12,r:7});
  for(let c=11;c>=4;c--)original.push({c,r:7});
  const MAPS=Object.freeze({
    garden:{name:'花园',description:'熟悉的蜿蜒花径 · 标准速度与护甲',path:original,speed:1,armor:0,ground:'#DDE6C8',pathColor:'#DCC387',decor:'flowers'},
    hollow:{name:'树洞',description:'五折树根长路 · 虫子护甲 +2，善用毒刺弩',path:snake([0,2,4,6,8],12,1),speed:1,armor:2,ground:'#C6BA98',pathColor:'#B98D55',decor:'roots'},
    pond:{name:'池塘',description:'沿水岸绕行 · 湿地使虫子移动速度降低 15%',path:garden.slice(0,-5),speed:0.85,armor:0,ground:'#BCDAD0',pathColor:'#D4C89B',decor:'water'}
  });
  const PORTAL_RULES=Object.freeze({first:6,minWait:9,waitRange:5,minLife:8,lifeRange:4,capacity:4});
  function createPortals(random=Math.random){
    let pair=null,wait=PORTAL_RULES.first,id=0;
    return {
      reset(){pair=null;wait=PORTAL_RULES.first;id=0;},
      step(dt,points,distances){
        if(pair){pair.age+=dt;if(pair.remaining===0)pair.closing+=dt;if(pair.age>=pair.life||pair.closing>=0.4){pair=null;wait=PORTAL_RULES.minWait+random()*PORTAL_RULES.waitRange;}return;}
        wait-=dt;
        if(wait>0 || points.length<14)return;
        const entry=3+Math.floor(random()*Math.max(1,Math.floor(points.length*0.5)-3));
        const firstExit=entry+5,lastExit=points.length-4;
        const exit=firstExit+Math.floor(random()*(lastExit-firstExit+1));
        pair={id:++id,entry,exit,entryPoint:points[entry],exitPoint:points[exit],from:distances[entry],to:distances[exit],age:0,life:PORTAL_RULES.minLife+random()*PORTAL_RULES.lifeRange,remaining:PORTAL_RULES.capacity,closing:0};
      },
      transport(bug,previousDistance){
        const cost=bug.portalCost||1;
        if(!pair || pair.remaining<cost || bug.portalId===pair.id || previousDistance>pair.from || bug.dist<pair.from)return false;
        bug.dist=pair.to+(bug.dist-pair.from);bug.portalId=pair.id;bug.teleportFlash=0.35;pair.remaining-=cost;return true;
      },
      get pair(){return pair;}
    };
  }
  const jumpPoint=p=>({x:p.c+0.5*(p.r&1),y:p.r*Math.sqrt(3)/2});
  function crossesGreen(from,to,path){
    const a=jumpPoint(from),b=jumpPoint(to),roads=new Set(path.map(p=>p.c+','+p.r));
    for(let step=1;step<16;step++){
      const x=a.x+(b.x-a.x)*step/16,y=a.y+(b.y-a.y)*step/16;
      let nearest=null,distance=Infinity;
      for(let r=0;r<9;r++)for(let c=0;c<14;c++){
        const p=jumpPoint({c,r}),d=(p.x-x)**2+(p.y-y)**2;
        if(d<distance){distance=d;nearest=c+','+r;}
      }
      if(!roads.has(nearest))return true;
    }
    return false;
  }
  function planJump(path,index,random=Math.random){
    const last=path.length-3,candidates=[],from=path[index];
    if(!from||index>=last)return null;
    for(let to=index+6;to<=Math.min(index+12,last);to++){
      const a=jumpPoint(from),b=jumpPoint(path[to]);
      if(Math.hypot(a.x-b.x,a.y-b.y)<=4 && crossesGreen(from,path[to],path))candidates.push(to);
    }
    if(candidates.length && random()<0.6)return {to:candidates[Math.floor(random()*candidates.length)],charge:0.5};
    for(let to=Math.min(index+3,last);to>index;to--){
      if(!crossesGreen(from,path[to],path))return {to,charge:0};
    }
    return null;
  }
  const api={MAPS,PORTAL_RULES,createPortals,planJump,crossesGreen};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.HiveWorld=api;
})(typeof window==='undefined'?globalThis:window);
