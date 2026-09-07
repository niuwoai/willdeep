(function(root){
  'use strict';
  const RULES = Object.freeze({maxHP:20, repairCost:4, dispatchIncrease:2, repairSeconds:3, hurtSeconds:3, restSeconds:13, counterSeconds:0.65});

  function createCounter(initial){
    let value = initial, from = initial, target = initial, elapsed = RULES.counterSeconds;
    return {
      reset(next){ value = from = target = next; elapsed = RULES.counterSeconds; },
      set(next){
        if(next === target) return 0;
        const delta = next - target;
        from = value; target = next; elapsed = 0;
        return delta;
      },
      step(dt, reducedMotion){
        if(reducedMotion){ elapsed = RULES.counterSeconds; value = from = target; return target; }
        elapsed = Math.min(RULES.counterSeconds, elapsed + Math.max(0, dt));
        const t = elapsed / RULES.counterSeconds;
        value = from + (target - from) * (1 - Math.pow(1 - t, 3));
        return Math.round(value);
      },
      get target(){ return target; }
    };
  }

  function createRepair(){
    let active = false, progress = 0, hurt = 0, dispatches=0, firstCost=RULES.repairCost, completed=0;
    const nextCost=()=>firstCost*(completed+1);
    return {
      reset(){ active = false; progress = 0; hurt = 0; dispatches=0;firstCost=RULES.repairCost;completed=0; },
      stop(){ active = false; },
      toggle(hp, allowed){
        if(allowed && hp > 0 && hp < RULES.maxHP){
          if(!active){dispatches++;firstCost=RULES.repairCost+(dispatches-1)*RULES.dispatchIncrease;completed=0;}
          active = !active;
        }
        return active;
      },
      hit(){ hurt = RULES.hurtSeconds; },
      step(dt, hp, honey){
        const slowed = Math.min(dt, hurt);
        hurt = Math.max(0, hurt - dt);
        let repaired = 0;
        if(active && hp > 0 && hp < RULES.maxHP && honey >= nextCost()){
          progress += dt - slowed / 2;
          while(progress + 1e-9 >= RULES.repairSeconds && hp < RULES.maxHP && honey >= nextCost()){
            progress = Math.max(0, progress - RULES.repairSeconds);
            hp++; honey -= nextCost(); repaired++;completed++;
          }
          if(repaired && honey<nextCost())progress=0;
        }
        if(hp >= RULES.maxHP || hp <= 0){ active = false; progress = 0; }
        return {hp, honey, repaired};
      },
      get active(){ return active; },
      get progress(){ return progress; },
      get hurt(){ return hurt; },
      get nextCost(){return nextCost();},
      get firstCost(){return firstCost;},
      get point(){return completed+1;},
      get dispatches(){return dispatches;},
      get nextDispatchCost(){return RULES.repairCost+dispatches*RULES.dispatchIncrease;},
      get remaining(){
        const work = RULES.repairSeconds - progress;
        return work <= hurt / 2 ? work * 2 : work + hurt / 2;
      }
    };
  }
  const api = Object.freeze({RULES, createCounter, createRepair});
  if(typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.HiveSystems = api;
})(typeof window === 'undefined' ? globalThis : window);
