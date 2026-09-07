
(function(){
  "use strict";

  const sprites = window.HiveSprites;
  const {RULES, createCounter, createRepair} = window.HiveSystems;
  const repair = createRepair();
  const adventure = window.HiveAdventure;
  const bear = adventure.createBear();
  let storage;
  try { storage = window.localStorage; } catch(error) { console.warn('Hive storage unavailable',error.name); }
  const collection = adventure.createCollection(storage);
  const honeyCounter = createCounter(220);
  const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
  let honeyFeedbackAge = 1, honeyDelta = 0;

  // ===== 六边形网格几何（尖顶，odd-r 偏移）=====
  const SIZE = 26;
  const HEX_W = Math.sqrt(3) * SIZE;
  const HEX_H = 2 * SIZE;
  const OX = 24, OY = 30;
  const COLS = 14, ROWS = 9;
  const W = 664, H = 372;

  function cellCenter(c, r){
    return {
      x: OX + HEX_W * (c + 0.5 * (r & 1)),
      y: OY + SIZE * 1.5 * r
    };
  }
  function hexPath(ctx, x, y, s){
    ctx.beginPath();
    for(let i = 0; i < 6; i++){
      const a = Math.PI / 180 * (60 * i - 30);
      const px = x + s * Math.cos(a), py = y + s * Math.sin(a);
      if(i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }
  function pixelToCell(px, py){
    let best = null, bd = 1e9;
    for(let r = 0; r < ROWS; r++){
      for(let c = 0; c < COLS; c++){
        const p = cellCenter(c, r);
        const d = (p.x - px) ** 2 + (p.y - py) ** 2;
        if(d < bd){ bd = d; best = {c, r}; }
      }
    }
    return bd <= SIZE * SIZE ? best : null;
  }

  // ===== 蜡道：一条蜿蜒穿过网格的路径 =====
  const PATH = (function(){
    const p = [];
    const push = (c, r) => p.push({c, r});
    for(let c = 0; c <= 12; c++) push(c, 1);
    push(12, 2); push(12, 3);
    for(let c = 11; c >= 1; c--) push(c, 3);
    push(1, 4); push(1, 5);
    for(let c = 2; c <= 12; c++) push(c, 5);
    push(12, 6); push(12, 7);
    for(let c = 11; c >= 4; c--) push(c, 7);
    return p;
  })();
  const HIVE = PATH[PATH.length - 1];
  const pathKeys = new Set(PATH.map(p => p.c + "," + p.r));
  const PTS = PATH.map(p => cellCenter(p.c, p.r));
  const SEG = [];       // 每段长度
  let TOTAL_LEN = 0;
  for(let i = 0; i < PTS.length - 1; i++){
    const d = Math.hypot(PTS[i+1].x - PTS[i].x, PTS[i+1].y - PTS[i].y);
    SEG.push(d); TOTAL_LEN += d;
  }
  function posAt(dist){
    let d = Math.max(0, dist), i = 0;
    while(i < SEG.length && d > SEG[i]){ d -= SEG[i]; i++; }
    if(i >= SEG.length) return {x: PTS[PTS.length-1].x, y: PTS[PTS.length-1].y, done:true};
    const t = SEG[i] ? d / SEG[i] : 0;
    return {
      x: PTS[i].x + (PTS[i+1].x - PTS[i].x) * t,
      y: PTS[i].y + (PTS[i+1].y - PTS[i].y) * t,
      done:false
    };
  }

  // ===== 防御塔定义 =====
  const TOWERS = {
    sting:{
      name:"工蜂哨塔", short:"单体速射，性价比最高", cost:60, color:"#E0A62A",
      range:92, dmg:9, rate:1.7, kind:"single"
    },
    bomb:{
      name:"蜂胶炮", short:"溅射伤害，适合打成群小虫", cost:110, color:"#C0703A",
      range:104, dmg:17, rate:0.65, kind:"splash", splash:44
    },
    pollen:{
      name:"花粉喷雾", short:"范围减速，自身伤害很低", cost:90, color:"#7FA8C4",
      range:88, dmg:4, rate:1.1, kind:"pulse", slow:0.45, slowDur:1.6
    },
    barb:{
      name:"毒刺弩", short:"超远射程，无视护甲", cost:150, color:"#8A5FA8",
      range:196, dmg:46, rate:0.5, kind:"pierce"
    },
    drum:{
      name:"共鸣塔", short:"不攻击，增强邻近防御塔", cost:130, color:"#5E9160",
      range:78, dmg:0, rate:0, kind:"aura", boostDmg:0.28, boostRange:0.12
    }
  };
  const TKEYS = Object.keys(TOWERS);

  // ===== 虫群定义 =====
  const BUGS = {
    aphid:{ name:"蚜虫", hp:30,   speed:64, armor:0,  bounty:6,   dmg:1, color:"#8FAE5A", r:7 },
    wasp: { name:"黄蜂", hp:68,   speed:50, armor:1,  bounty:9,   dmg:1, color:"#D9A227", r:8 },
    beetle:{name:"甲虫", hp:150,  speed:34, armor:7,  bounty:15,  dmg:2, color:"#5B6E88", r:10 },
    moth: { name:"飞蛾", hp:78,   speed:92, armor:0,  bounty:12,  dmg:1, color:"#B9A9C6", r:8 },
    spider:{name:"蜘蛛", hp:170,  speed:42, armor:2,  bounty:19,  dmg:2, color:"#6E4A55", r:10, splits:2 },
    hornet:{name:"大黄蜂", hp:1400, speed:30, armor:12, bounty:140, dmg:6, color:"#B33F22", r:15, boss:true }
  };

  // ===== 波次表 =====
  const WAVES = [
    [["aphid",6,0.8]],
    [["aphid",10,0.65]],
    [["aphid",8,0.6],["wasp",3,1.2]],
    [["wasp",8,0.8]],
    [["aphid",12,0.45],["beetle",2,2]],
    [["moth",8,0.7],["wasp",5,0.9]],
    [["beetle",5,1.4],["aphid",10,0.4]],
    [["spider",3,1.8],["wasp",8,0.7]],
    [["moth",14,0.4]],
    [["hornet",1,1],["aphid",12,0.5]],
    [["beetle",8,1],["moth",10,0.5]],
    [["spider",6,1.2],["wasp",10,0.6]],
    [["moth",18,0.32],["beetle",4,1.5]],
    [["spider",8,1],["beetle",6,1.2]],
    [["hornet",2,3],["moth",14,0.45]],
    [["wasp",20,0.4],["spider",6,1.1]],
    [["beetle",12,0.8],["moth",12,0.4]],
    [["spider",12,0.8]],
    [["hornet",3,2.5],["beetle",10,0.9]],
    [["hornet",4,2],["spider",10,0.7],["moth",16,0.35]]
  ];
  function waveDef(n){
    if(n <= WAVES.length) return WAVES[n-1];
    const k = n - WAVES.length;
    return [
      ["hornet", 2 + Math.floor(k/2), 2],
      ["spider", 8 + k, 0.7],
      ["beetle", 8 + k, 0.7],
      ["moth", 12 + k*2, 0.3]
    ];
  }
  function hpScale(n){ return Math.pow(1.16, n - 1); }

  // ===== 状态 =====
  const cv = document.getElementById("map");
  const ctx = cv.getContext("2d");
  let mapCache = document.createElement("canvas");
  let P = {};   // 从 CSS 读取的调色板

  let towers = [], bugs = [], shots = [], parts = [], texts = [];
  let hp, honey, wave, kills, prep, spawnQueue, running, paused, over, speed;
  let selType = null, selTower = null, hoverCell = null, blinkT = 0;

  function readPalette(){
    const cs = getComputedStyle(document.documentElement);
    const g = n => cs.getPropertyValue(n).trim();
    P = {
      bg:g("--map-bg"), cell:g("--map-cell"), cellHi:g("--map-cell-hi"),
      path:g("--map-path"), pathEdge:g("--map-path-edge"), line:g("--map-line"),
      hive:g("--hive"), ink:g("--ink"), ink2:g("--ink-2"), ink3:g("--ink-3"),
      danger:g("--danger"), honeyC:g("--honey"), panel:g("--panel")
    };
    buildMapCache();
  }

  function buildMapCache(){
    const dpr = window.devicePixelRatio || 1;
    mapCache.width = W * dpr; mapCache.height = H * dpr;
    const m = mapCache.getContext("2d");
    m.setTransform(dpr, 0, 0, dpr, 0, 0);
    m.clearRect(0, 0, W, H);
    m.fillStyle = P.bg; m.fillRect(0, 0, W, H);

    for(let r = 0; r < ROWS; r++){
      for(let c = 0; c < COLS; c++){
        const p = cellCenter(c, r);
        const onPath = pathKeys.has(c + "," + r);
        hexPath(m, p.x, p.y, SIZE - 1.5);
        m.fillStyle = onPath ? P.path : P.cell;
        m.fill();
        m.strokeStyle = onPath ? P.pathEdge : P.line;
        m.lineWidth = 1;
        m.stroke();
      }
    }
    // 入口与蜂巢标记
    const s = PTS[0];
    m.fillStyle = P.ink3;
    m.font = "600 10px 'IBM Plex Mono', monospace";
    m.textAlign = "center";
    m.fillText("入口", s.x, s.y - SIZE - 4);
  }

  function reset(){
    towers = []; bugs = []; shots = []; parts = []; texts = [];
    hp = RULES.maxHP; honey = 220; wave = 0; kills = 0; prep = 0;
    spawnQueue = []; running = false; paused = false; over = false; speed = 1;
    selType = null; selTower = null;
    repair.reset(); bear.reset(); closeBear(); renderCollection(); honeyCounter.reset(honey);
    honeyFeedbackAge = 1; honeyDelta = 0;
    honeyEl.textContent = honey;
    honeyEl.setAttribute('aria-label', '蜂蜜 ' + honey);
    honeyDeltaEl.textContent = '';
    syncHud(); renderShop(); renderInfo(); renderWaveInfo();
  }

  // ===== 波次调度 =====
  function startWave(){
    wave++;
    if(bear.spawn(wave,towers)) renderBearNotice();
    const def = waveDef(wave);
    const scale = hpScale(wave);
    let t = 0;
    spawnQueue = [];
    def.forEach(function(group, gi){
      const [type, count, gap] = group;
      let tt = gi * 1.2;
      for(let i = 0; i < count; i++){
        spawnQueue.push({at: tt, type: type, scale: scale});
        tt += gap;
      }
      t = Math.max(t, tt);
    });
    spawnQueue.sort((a, b) => a.at - b.at);
    prep = 0;
    renderWaveInfo();
    syncHud();
  }

  function makeBug(type, scale){
    const b = BUGS[type];
    return {
      type: type,
      hp: Math.round(b.hp * scale), maxHp: Math.round(b.hp * scale),
      speed: b.speed, armor: b.armor, bounty: Math.round(b.bounty * (1 + (wave-1) * 0.05)),
      dmg: b.dmg, color: b.color, r: b.r, boss: !!b.boss,
      dist: 0, x: PTS[0].x, y: PTS[0].y,
      slowUntil: 0, slowAmt: 0, wob: Math.random() * 6.28, hitFlash: 0
    };
  }

  // ===== 战斗 =====
  function towerStats(t){
    const base = TOWERS[t.type];
    const lv = t.level;
    let dmg = base.dmg * Math.pow(1.62, lv - 1);
    let range = base.range * Math.pow(1.1, lv - 1);
    let rate = base.rate * Math.pow(1.16, lv - 1);
    // 共鸣塔加成
    let boostD = 0, boostR = 0;
    if(base.kind !== "aura"){
      towers.forEach(function(o){
        if(o.damaged || o === t || TOWERS[o.type].kind !== "aura") return;
        const or_ = TOWERS[o.type].range * Math.pow(1.1, o.level - 1);
        if(Math.hypot(o.x - t.x, o.y - t.y) <= or_){
          boostD += TOWERS[o.type].boostDmg * (1 + (o.level - 1) * 0.4);
          boostR += TOWERS[o.type].boostRange * (1 + (o.level - 1) * 0.4);
        }
      });
    }
    return {
      dmg: dmg * (1 + boostD), range: range * (1 + boostR), rate: rate,
      boosted: boostD > 0, splash: base.splash || 0
    };
  }
  function upgradeCost(t){ return Math.round(TOWERS[t.type].cost * 0.85 * Math.pow(1.9, t.level - 1)); }
  function sellValue(t){
    let spent = TOWERS[t.type].cost;
    for(let l = 1; l < t.level; l++) spent += Math.round(TOWERS[t.type].cost * 0.85 * Math.pow(1.9, l - 1));
    return Math.round(spent * 0.6);
  }

  function damage(bug, amount, ignoreArmor, srcColor){
    const real = Math.max(1, ignoreArmor ? amount : amount - bug.armor);
    bug.hp -= real;
    bug.hitFlash = 0.12;
    if(bug.hp <= 0) killBug(bug, srcColor);
    return real;
  }

  function killBug(bug, color){
    if(bug.dead) return;
    bug.dead = true;
    kills++;
    if(collection.unlock(bug.sprite || bug.type)) renderCollection();
    honey += bug.bounty;
    texts.push({x:bug.x, y:bug.y, t:0, s:"+" + bug.bounty + " 蜂蜜", c:P.honeyC, reward:true});
    burst(bug.x, bug.y, color || bug.color, bug.boss ? 26 : 10);
    const def = BUGS[bug.type];
    if(def.splits){
      for(let i = 0; i < def.splits; i++){
        const child = makeBug("aphid", hpScale(wave) * 1.4);
        child.dist = Math.max(0, bug.dist - 12 - i * 10);
        child.color = "#6E4A55"; child.sprite = "spider";
        child.speed = 70;
        bugs.push(child);
      }
    }
    syncHud();
  }

  function burst(x, y, color, n){
    for(let i = 0; i < n; i++){
      const a = Math.random() * 6.283, sp = 20 + Math.random() * 70;
      parts.push({x:x, y:y, vx:Math.cos(a)*sp, vy:Math.sin(a)*sp, life:0.45 + Math.random()*0.3, t:0, c:color, r:1.5 + Math.random()*2});
    }
  }

  function tick(dt){
    if(bear.active) return;
    if(bear.walk(dt,towers)){ renderInfo(); renderBearNotice(); }
    // 生成
    if(spawnQueue.length){
      spawnQueue.forEach(s => s.at -= dt);
      while(spawnQueue.length && spawnQueue[0].at <= 0){
        const s = spawnQueue.shift();
        bugs.push(makeBug(s.type, s.scale));
      }
    }

    // 虫子移动
    for(let i = bugs.length - 1; i >= 0; i--){
      const b = bugs[i];
      if(b.dead){ bugs.splice(i, 1); continue; }
      b.hitFlash = Math.max(0, b.hitFlash - dt);
      const slowed = b.slowUntil > 0;
      if(slowed) b.slowUntil -= dt;
      const sp = b.speed * (slowed ? (1 - b.slowAmt) : 1);
      b.dist += sp * dt;
      b.wob += dt * 8;
      const p = posAt(b.dist);
      b.x = p.x; b.y = p.y;
      if(b.dist >= TOTAL_LEN){
        hp -= b.dmg;
        repair.hit();
        texts.push({x:PTS[PTS.length-1].x, y:PTS[PTS.length-1].y - 14, t:0, s:"-" + b.dmg, c:P.danger});
        burst(b.x, b.y, P.danger, 8);
        bugs.splice(i, 1);
        syncHud();
        if(hp <= 0){ gameOver(); return; }
      }
    }

    // 塔开火
    towers.forEach(function(t){
      const st = towerStats(t);
      t.st = st;
      if(t.damaged) return;
      if(TOWERS[t.type].kind === "aura") return;
      t.cd -= dt;
      // 选取「走得最远」的目标
      let target = null, best = -1;
      for(const b of bugs){
        if(b.dead) continue;
        if(Math.hypot(b.x - t.x, b.y - t.y) <= st.range && b.dist > best){ best = b.dist; target = b; }
      }
      if(target) t.angle = Math.atan2(target.y - t.y, target.x - t.x);
      if(t.cd > 0 || !target) return;
      t.cd = 1 / st.rate;
      const kind = TOWERS[t.type].kind;
      if(kind === "pulse"){
        // 花粉：范围内全体减速 + 少量伤害
        bugs.forEach(function(b){
          if(b.dead || Math.hypot(b.x - t.x, b.y - t.y) > st.range) return;
          damage(b, st.dmg, false, TOWERS[t.type].color);
          b.slowUntil = TOWERS[t.type].slowDur;
          b.slowAmt = TOWERS[t.type].slow;
        });
        parts.push({ring:true, x:t.x, y:t.y, t:0, life:0.4, r:st.range, c:TOWERS[t.type].color});
      }else{
        shots.push({
          x:t.x, y:t.y, target:target, sp: kind === "pierce" ? 900 : 460,
          dmg:st.dmg, splash:st.splash, pierce: kind === "pierce",
          c:TOWERS[t.type].color, trail: kind === "pierce"
        });
      }
    });

    // 抛射物
    for(let i = shots.length - 1; i >= 0; i--){
      const s = shots[i];
      const tg = s.target;
      if(!tg || tg.dead){ shots.splice(i, 1); continue; }
      const dx = tg.x - s.x, dy = tg.y - s.y, d = Math.hypot(dx, dy);
      const step = s.sp * dt;
      if(d <= step){
        if(s.splash){
          bugs.forEach(function(b){
            if(b.dead) return;
            const dd = Math.hypot(b.x - tg.x, b.y - tg.y);
            if(dd <= s.splash){
              const combo=b.slowUntil>0;
              damage(b, s.dmg * (dd < s.splash * 0.5 ? 1 : 0.6) * (combo ? adventure.RULES.combo : 1), false, s.c);
              if(combo && !b.comboShown){
                b.comboShown=true;
                texts.push({x:b.x,y:b.y-16,t:0,s:'花粉 + 蜂胶！',c:P.honeyC});
              }
            }
          });
          parts.push({ring:true, x:tg.x, y:tg.y, t:0, life:0.28, r:s.splash, c:s.c});
        }else{
          damage(tg, s.dmg, s.pierce, s.c);
        }
        burst(tg.x, tg.y, s.c, 4);
        shots.splice(i, 1);
      }else{
        s.x += dx / d * step; s.y += dy / d * step;
      }
    }

    // 粒子与飘字
    for(let i = parts.length - 1; i >= 0; i--){
      const p = parts[i];
      p.t += dt;
      if(p.t >= p.life){ parts.splice(i, 1); continue; }
      if(!p.ring){ p.x += p.vx * dt; p.y += p.vy * dt; p.vy += 90 * dt; }
    }
    for(let i = texts.length - 1; i >= 0; i--){
      texts[i].t += dt;
      texts[i].y -= 26 * dt;
      if(texts[i].t > 0.9) texts.splice(i, 1);
    }

    // 波次推进
    if(!spawnQueue.length && !bugs.length){
      if(prep <= 0){
        prep = wave === 0 ? 0.01 : RULES.restSeconds;
      }else{
        prep -= dt;
        if(prep <= 0) startWave();
      }
      syncHud();
    }
    const repaired = repair.step(dt, hp, honey);
    hp = repaired.hp; honey = repaired.honey;
    if(repaired.repaired){
      collection.repair(repaired.repaired); renderCollection();
      const hive = cellCenter(HIVE.c, HIVE.r);
      texts.push({x:hive.x, y:hive.y - 20, t:0, s:'+' + repaired.repaired + ' 修复', c:P.hive});
      syncHud(); renderShop(); renderInfo();
    }
    renderRepair();
  }

  // ===== 绘制 =====
  function draw(){
    ctx.clearRect(0, 0, W, H);
    ctx.drawImage(mapCache, 0, 0, W, H);

    // 悬停高亮 / 建造预览
    if(hoverCell && selType){
      const p = cellCenter(hoverCell.c, hoverCell.r);
      const ok = canBuild(hoverCell);
      hexPath(ctx, p.x, p.y, SIZE - 1.5);
      ctx.fillStyle = ok ? P.cellHi : "rgba(192,64,42,.28)";
      ctx.fill();
      if(ok){
        const base = TOWERS[selType];
        ctx.beginPath();
        ctx.arc(p.x, p.y, base.range, 0, 6.284);
        ctx.fillStyle = hexToRgba(base.color, .1); ctx.fill();
        ctx.strokeStyle = hexToRgba(base.color, .5); ctx.lineWidth = 1.5; ctx.stroke();
        drawTowerGlyph(p.x, p.y, selType, 1, 0, .55);
      }
    }

    // 选中塔的射程圈
    if(selTower){
      const st = towerStats(selTower);
      ctx.beginPath();
      ctx.arc(selTower.x, selTower.y, st.range, 0, 6.284);
      ctx.fillStyle = hexToRgba(TOWERS[selTower.type].color, .09); ctx.fill();
      ctx.strokeStyle = hexToRgba(TOWERS[selTower.type].color, .6);
      ctx.setLineDash([5, 4]); ctx.lineWidth = 1.5; ctx.stroke(); ctx.setLineDash([]);
    }

    drawHive();

    // 塔
    towers.forEach(t => {
      drawTowerGlyph(t.x,t.y,t.type,t.level,t.angle||0,t.damaged?0.35:1,!t.damaged && t.st && t.st.boosted);
      if(t.damaged){ctx.fillStyle=P.danger;ctx.font='bold 12px sans-serif';ctx.textAlign='center';ctx.fillText('待修',t.x,t.y+5);}
    });
    if(bear.state){
      sprites.draw(ctx,'bear',bear.state.x,bear.state.y,68);
      ctx.fillStyle=P.ink;ctx.font='bold 11px sans-serif';ctx.textAlign='center';
      ctx.fillText('点击狗熊',bear.state.x,bear.state.y-31);
    }

    // 虫子
    bugs.forEach(drawBug);

    // 抛射物
    shots.forEach(function(s){
      ctx.beginPath();
      if(s.pierce){
        const a = Math.atan2(s.target.y - s.y, s.target.x - s.x);
        ctx.moveTo(s.x - Math.cos(a) * 9, s.y - Math.sin(a) * 9);
        ctx.lineTo(s.x, s.y);
        ctx.strokeStyle = s.c; ctx.lineWidth = 2.5; ctx.stroke();
      }else{
        ctx.arc(s.x, s.y, s.splash ? 5 : 3.2, 0, 6.284);
        ctx.fillStyle = s.c; ctx.fill();
      }
    });

    // 粒子
    parts.forEach(function(p){
      const k = 1 - p.t / p.life;
      ctx.globalAlpha = Math.max(0, k);
      if(p.ring){
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r * (0.5 + (1 - k) * 0.6), 0, 6.284);
        ctx.strokeStyle = p.c; ctx.lineWidth = 2.5; ctx.stroke();
      }else{
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r * k, 0, 6.284);
        ctx.fillStyle = p.c; ctx.fill();
      }
      ctx.globalAlpha = 1;
    });

    // 飘字
    ctx.font = "600 12px 'IBM Plex Mono', monospace";
    ctx.textAlign = "center";
    texts.forEach(function(t){
      ctx.globalAlpha = Math.max(0, 1 - t.t / 0.9);
      ctx.fillStyle = t.c;
      ctx.font = (t.reward ? '700 13px' : '600 12px') + " 'IBM Plex Mono', monospace";
      ctx.strokeStyle = P.bg; ctx.lineWidth = 3;
      ctx.strokeText(t.s, t.x, t.y);
      ctx.fillText(t.s, t.x, t.y);
      ctx.globalAlpha = 1;
    });

    // 准备倒计时
    if(running && !over && prep > 0.05 && !spawnQueue.length && !bugs.length){
      ctx.font = "600 12px 'IBM Plex Mono', monospace";
      ctx.fillStyle = P.ink2;
      ctx.textAlign = "left";
      ctx.fillText("休整中 · 第 " + (wave + 1) + " 波 " + prep.toFixed(1) + "s 后进攻", 12, H - 12);
    }
  }

  function drawHive(){
    const p = cellCenter(HIVE.c, HIVE.r);
    ctx.save();
    ctx.translate(p.x, p.y);
    sprites.draw(ctx, 'hive', 0, 0, 52);
    // 裂纹随损伤加深，维修后逐渐变淡。
    ctx.globalAlpha = Math.max(0, 1 - hp / RULES.maxHP);
    ctx.strokeStyle = '#38220E'; ctx.lineWidth = 2.5;
    ctx.beginPath(); ctx.moveTo(-15,-16); ctx.lineTo(-5,-5);
    ctx.lineTo(-10,2); ctx.lineTo(2,13); ctx.moveTo(17,-10);
    ctx.lineTo(8,0); ctx.lineTo(14,8); ctx.stroke();
    ctx.globalAlpha = 1;
    if(repair.active && running && !over){
      const moving = !paused && honey >= RULES.repairCost && !motionPreference.matches;
      const angle = moving ? blinkT * 1.8 : -0.7;
      const bx=Math.cos(angle)*32,by=Math.sin(angle)*20-12;
      sprites.draw(ctx, 'repair-bee', bx, by, 34);
      if(collection.rank){
        ctx.fillStyle='#E9B636';ctx.fillRect(bx-8,by-15,16,4);ctx.fillRect(bx-5,by-20,10,6);
        if(collection.rank>1){ctx.fillStyle='#9A603D';ctx.fillRect(bx+7,by+2,11,8);ctx.strokeRect(bx+10,by,5,3);}
      }
      ctx.beginPath(); ctx.arc(0,0,29,-Math.PI/2,-Math.PI/2 + Math.PI*2*repair.progress/RULES.repairSeconds);
      ctx.strokeStyle = P.hive; ctx.lineWidth = 2; ctx.stroke();
    }
    ctx.restore();
    // 血条
    const w = 40;
    ctx.fillStyle = hexToRgba(P.ink3, .3);
    ctx.fillRect(p.x - w/2, p.y + SIZE - 4, w, 4);
    ctx.fillStyle = hp > 8 ? P.hive : P.danger;
    ctx.fillRect(p.x - w/2, p.y + SIZE - 4, w * Math.max(0, hp) / RULES.maxHP, 4);
  }

  function drawTowerGlyph(x, y, type, level, angle, alpha, boosted){
    const base = TOWERS[type];
    ctx.save();
    ctx.globalAlpha = alpha === undefined ? 1 : alpha;
    ctx.translate(x, y);

    // 底座：六边形，等级越高边框越厚
    hexPath(ctx, 0, 0, 15);
    ctx.fillStyle = hexToRgba(base.color, .22); ctx.fill();
    ctx.strokeStyle = base.color; ctx.lineWidth = 1 + level * 0.7; ctx.stroke();

    if(boosted){
      hexPath(ctx, 0, 0, 19);
      ctx.strokeStyle = hexToRgba("#5E9160", .55); ctx.lineWidth = 1.5; ctx.stroke();
    }

    if(type !== 'pollen' && type !== 'drum') ctx.rotate(angle);
    sprites.draw(ctx, type, 0, 0, 43);
    ctx.restore();

    // 等级点
    if(level > 1){
      ctx.fillStyle = base.color;
      for(let i = 0; i < level - 1; i++){
        ctx.beginPath();
        ctx.arc(x - 4 + i * 8, y + 18, 2, 0, 6.284);
        ctx.fill();
      }
    }
  }

  function drawBug(b){
    const wob = Math.sin(b.wob) * 1.6;
    ctx.save();
    ctx.translate(b.x, b.y + wob);

    if(b.slowUntil > 0){
      ctx.beginPath(); ctx.arc(0, 0, b.r + 4, 0, 6.284);
      ctx.fillStyle = "rgba(127,168,196,.28)"; ctx.fill();
    }

    const ahead = posAt(Math.min(TOTAL_LEN, b.dist + 1));
    ctx.rotate(Math.atan2(ahead.y - b.y, ahead.x - b.x));
    if(b.hitFlash > 0) ctx.globalAlpha = 0.65;
    sprites.draw(ctx, b.sprite || b.type, 0, 0, b.r * 3.8);
    ctx.restore();

    // 血条
    if(b.hp < b.maxHp){
      const w = b.r * 2.2;
      ctx.fillStyle = "rgba(0,0,0,.25)";
      ctx.fillRect(b.x - w/2, b.y - b.r - 8, w, 3);
      ctx.fillStyle = b.boss ? "#B33F22" : "#4E8A4A";
      ctx.fillRect(b.x - w/2, b.y - b.r - 8, w * b.hp / b.maxHp, 3);
    }
  }

  function hexToRgba(hex, a){
    hex = (hex || "#000000").trim();
    if(hex[0] !== "#") return hex;
    if(hex.length === 4) hex = "#" + hex[1]+hex[1] + hex[2]+hex[2] + hex[3]+hex[3];
    const n = parseInt(hex.slice(1), 16);
    return "rgba(" + ((n>>16)&255) + "," + ((n>>8)&255) + "," + (n&255) + "," + a + ")";
  }

  // ===== 建造 =====
  function canBuild(cell){
    if(!cell) return false;
    if(pathKeys.has(cell.c + "," + cell.r)) return false;
    return !towers.some(t => t.c === cell.c && t.r === cell.r);
  }
  function build(cell){
    const base = TOWERS[selType];
    if(honey < base.cost){ flashHud(); return; }
    const p = cellCenter(cell.c, cell.r);
    honey -= base.cost;
    const t = {c:cell.c, r:cell.r, x:p.x, y:p.y, type:selType, level:1, cd:0, angle:-Math.PI/2};
    towers.push(t);
    selTower = t;
    burst(p.x, p.y, base.color, 8);
    syncHud(); renderShop(); renderInfo();
  }

  // ===== 界面 =====
  const shopEl = document.getElementById("shop");
  function renderShop(){
    shopEl.innerHTML = "";
    TKEYS.forEach(function(k, i){
      const t = TOWERS[k];
      const el = document.createElement("button");
      el.className = "card" + (selType === k ? " sel" : "") + (honey < t.cost ? " poor" : "");
      el.innerHTML =
        '<img class="glyph" src="assets/' + k + '.png" alt="">' +
        '<span><span class="nm">' + t.name + '</span><span class="de">' + t.short + '</span></span>' +
        '<span class="pr">' + t.cost + '</span>';
      el.addEventListener("click", function(){
        selType = (selType === k) ? null : k;
        selTower = null;
        renderShop(); renderInfo();
      });
      el.title = "快捷键 " + (i + 1);
      shopEl.appendChild(el);
    });
  }

  const infoEmpty = document.getElementById("infoEmpty");
  const infoBody = document.getElementById("infoBody");
  const infoRows = document.getElementById("infoRows");
  const upBtn = document.getElementById("upBtn");
  const sellBtn = document.getElementById("sellBtn");
  const towerRepairBtn = document.getElementById("towerRepairBtn");
  const towerRepairCost = t => Math.ceil(TOWERS[t.type].cost * adventure.RULES.repairFraction);

  function renderInfo(){
    towerRepairBtn.hidden = !selTower?.damaged;
    if(!selTower){
      infoEmpty.hidden = false; infoBody.hidden = true;
      if(selType){
        const t = TOWERS[selType];
        infoEmpty.textContent = "已选「" + t.name + "」，点击通道两侧的空格建造，" + t.cost + " 蜂蜜。";
      }else{
        infoEmpty.textContent = "点击地图上的防御塔查看数据，或先从左侧选一种塔再点空地建造。";
      }
      return;
    }
    infoEmpty.hidden = true; infoBody.hidden = false;
    const t = selTower, base = TOWERS[t.type], st = towerStats(t);
    const rows = [
      ["名称", base.name],
      ["等级", "Lv." + t.level],
      ["状态", t.damaged ? "损坏停机" : "正常"],
      ["伤害", st.dmg.toFixed(1) + (st.boosted ? " ↑" : "")],
      ["射程", Math.round(st.range)],
      ["射速", base.rate ? st.rate.toFixed(2) + "/秒" : "—"]
    ];
    if(base.splash) rows.push(["溅射半径", base.splash]);
    if(base.slow) rows.push(["减速", Math.round(base.slow * 100) + "%"]);
    if(base.kind === "pierce") rows.push(["特性", "无视护甲"]);
    if(base.kind === "aura") rows.push(["特性", "增伤 " + Math.round(base.boostDmg * 100) + "%"]);
    infoRows.innerHTML = rows.map(function(r){
      return "<div><span>" + r[0] + "</span><b" + (String(r[1]).includes("↑") ? ' class="up"' : "") + ">" + r[1] + "</b></div>";
    }).join("");
    const uc = upgradeCost(t);
    upBtn.textContent = t.level >= 4 ? "已满级" : "升级 " + uc;
    upBtn.disabled = t.damaged || t.level >= 4 || honey < uc;
    towerRepairBtn.textContent = "修复塔 " + towerRepairCost(t) + " 蜂蜜";
    towerRepairBtn.disabled = honey < towerRepairCost(t);
    sellBtn.textContent = "出售 " + sellValue(t);
  }

  upBtn.addEventListener("click", function(){
    if(bear.active || !selTower || selTower.damaged || selTower.level >= 4) return;
    const c = upgradeCost(selTower);
    if(honey < c) return;
    honey -= c; selTower.level++;
    burst(selTower.x, selTower.y, TOWERS[selTower.type].color, 12);
    syncHud(); renderInfo(); renderShop();
  });
  sellBtn.addEventListener("click", function(){
    if(bear.active || !selTower) return;
    honey += sellValue(selTower);
    burst(selTower.x, selTower.y, P.ink3, 10);
    towers = towers.filter(t => t !== selTower);
    selTower = null;
    syncHud(); renderInfo(); renderShop();
  });

  towerRepairBtn.addEventListener('click',function(){
    if(bear.active || !selTower?.damaged || honey<towerRepairCost(selTower)) return;
    honey-=towerRepairCost(selTower);selTower.damaged=false;
    syncHud();renderInfo();renderShop();
  });

  const hpEl = document.getElementById("hp");
  const honeyEl = document.getElementById("honey");
  const honeyDeltaEl = document.getElementById('honeyDelta');
  const repairBtn = document.getElementById('repairBtn');
  const repairStatus = document.getElementById('repairStatus');
  const repairProgress = document.getElementById('repairProgress');
  repairBtn.addEventListener('click', function(){
    if(bear.active) return;
    repair.toggle(hp, running && !over && (!paused || repair.active));
    renderRepair();
  });
  function renderRepair(){
    repairBtn.disabled = !running || over || (paused && !repair.active) || hp >= RULES.maxHP;
    repairBtn.textContent = repair.active ? '停止维修' : '派维修蜂';
    repairBtn.setAttribute('aria-pressed', String(repair.active));
    repairProgress.value = repair.progress;
    let status = '每 3 秒修 1 点 · 每点 4 蜂蜜';
    if(over) status = '蜂巢已失守';
    else if(!running) status = '开始防守后可维修';
    else if(hp >= RULES.maxHP) status = '蜂巢完好';
    else if(paused) status = '游戏已暂停 · 维修进度保留';
    else if(repair.active && honey < RULES.repairCost) status = '等待蜂蜜 · 每点需要 4 蜂蜜';
    else if(repair.active) status = (repair.hurt > 0 ? '受击减速 · ' : '维修中 · ') + '下一点 ' + Math.ceil(repair.remaining) + ' 秒';
    if(repairStatus.textContent !== status) repairStatus.textContent = status;
  }
  function animateHoney(dt){
    honeyEl.textContent = honeyCounter.step(dt, motionPreference.matches);
    honeyFeedbackAge += dt;
    const visible = honeyFeedbackAge < 0.9;
    honeyEl.classList.toggle('earning', visible && honeyDelta > 0);
    honeyEl.classList.toggle('spending', visible && honeyDelta < 0);
    const pulse = visible && !motionPreference.matches ? Math.sin(Math.min(1,honeyFeedbackAge/0.45)*Math.PI)*0.16 : 0;
    honeyEl.style.transform = 'scale(' + (1+pulse) + ')';
    honeyDeltaEl.style.opacity = visible ? String(Math.min(1,(0.9-honeyFeedbackAge)*3)) : '0';
    honeyDeltaEl.style.transform = motionPreference.matches ? 'none' : 'translateY(' + (-honeyFeedbackAge*9) + 'px)';
  }
  const waveEl = document.getElementById("wave");
  const killsEl = document.getElementById("kills");
  const callBtn = document.getElementById("callBtn");
  function syncHud(){
    hpEl.textContent = Math.max(0, hp);
    hpEl.className = "v" + (hp <= 8 ? " hurt" : "");
    const delta = honeyCounter.set(honey);
    if(delta){
      honeyDelta = honeyFeedbackAge < 0.3 && Math.sign(delta) === Math.sign(honeyDelta) ? honeyDelta + delta : delta;
      honeyFeedbackAge = 0;
      honeyDeltaEl.textContent = (honeyDelta > 0 ? '+' : '') + honeyDelta;
      honeyEl.setAttribute('aria-label', '蜂蜜 ' + honey);
      // 可购买状态使用真实余额，绝不等待视觉数字追上。
      document.querySelectorAll('#shop .card').forEach((el,i) => el.classList.toggle('poor', honey < TOWERS[TKEYS[i]].cost));
      if(selTower) renderInfo();
    }
    waveEl.textContent = wave;
    killsEl.textContent = kills;
    callBtn.disabled = !running || over || prep <= 0.05;
    callBtn.textContent = prep > 0.05 ? "下一波 +" + Math.round(prep * 3) : "进攻中";
    renderRepair();
  }
  function flashHud(){
    honeyEl.classList.add("hurt");
    setTimeout(() => honeyEl.classList.remove("hurt"), 260);
  }

  const waveInfoEl = document.getElementById("waveInfo");
  function renderWaveInfo(){
    if(wave === 0){ waveInfoEl.innerHTML = '<span class="chip">尚未开始</span>'; return; }
    const def = waveDef(wave);
    waveInfoEl.innerHTML = def.map(function(g){
      return '<span class="chip">' + BUGS[g[0]].name + " ×" + g[1] + "</span>";
    }).join("");
  }

  function renderCollection(){
    const titles=['维修学徒','小帽子维修蜂','工具箱维修蜂'];
    document.getElementById('beeGrowth').textContent=titles[collection.rank]+' · 累计修复 '+collection.repairs+' 点'+(collection.rank===0?' · 5 点得小帽子':collection.rank===1?' · 20 点得工具箱':' · 装扮已集齐');
    document.getElementById('bestiary').innerHTML=Object.keys(BUGS).map(k=>{
      const known=collection.has(k),facts=adventure.FACTS[k];
      return '<details class="collection-card '+(known?'':'locked')+'"><summary><img class="creature-icon" src="assets/'+k+'.png" alt="">'+(known?BUGS[k].name:'未发现')+'</summary><p>'+(known?facts.join('<br>'):'首次击败后解锁卡片')+'</p></details>';
    }).join('');
  }

  const bearPanel=document.getElementById('bearPanel');
  const bearCanvas=document.getElementById('bearCanvas');
  const bearCtx=bearCanvas.getContext('2d');
  const bearStatus=document.getElementById('bearStatus');
  const bearExit=document.getElementById('bearExit');
  let aim={x:332,y:186},bearFlash=0;
  function renderBearNotice(){
    const b=bear.state;
    document.getElementById('bearOpen').hidden=!b;
    document.getElementById('bearNotice').textContent=b?(b.arrived?'狗熊停在塔旁！损坏的塔可花建造价的 20% 修复。':'狗熊来了！点击它进入瞄准小游戏，可在它碰到塔前阻止它。'):'第 3 波起偶尔出现狗熊，每次最多损坏一座塔。';
  }
  function setAdventureLock(locked){
    document.querySelectorAll('.hud,.shop,.side').forEach(el=>el.inert=locked);
  }
  function openBear(){
    if(!running || over || !bear.open())return;
    bearPanel.hidden=false;setAdventureLock(true);
    bearStatus.textContent='命中 '+bear.state.hits+'/5 · 点击狗熊发射；方向键瞄准，空格发射。防线已暂停。';
    bearExit.textContent='暂时返回防线';bearCanvas.focus();drawBear(0);
  }
  function closeBear(){
    bear.close();bearPanel.hidden=true;setAdventureLock(false);renderBearNotice();
  }
  function shootBear(){
    const result=bear.shoot(aim.x,aim.y,motionPreference.matches);
    if(!bear.state || bear.state.reward && !result.reward)return;
    bearFlash=0.18;
    bearStatus.textContent=result.hit?'命中 '+bear.state.hits+'/5！':'没打中，再试一次！没有时间限制。';
    if(result.reward){
      honey+=result.reward;syncHud();
      bearStatus.textContent='狗熊被击败！获得 '+result.reward+' 蜂蜜。';
      bearExit.textContent='带着奖励返回防线';
    }
  }
  function drawBear(dt){
    if(!bear.active)return;
    bear.step(dt);bearFlash=Math.max(0,bearFlash-dt);
    const p=bear.target(motionPreference.matches);
    bearCtx.fillStyle=P.bg;bearCtx.fillRect(0,0,W,H);
    bearCtx.strokeStyle=P.pathEdge;bearCtx.lineWidth=2;
    bearCtx.beginPath();bearCtx.arc(p.x,p.y,adventure.RULES.radius,0,Math.PI*2);bearCtx.stroke();
    bearCtx.globalAlpha=bear.state.reward?0.35:1;
    sprites.draw(bearCtx,'bear',p.x,p.y,135);bearCtx.globalAlpha=1;
    bearCtx.strokeStyle=bearFlash?P.honeyC:P.ink;bearCtx.lineWidth=2;
    bearCtx.beginPath();bearCtx.arc(aim.x,aim.y,12,0,Math.PI*2);
    bearCtx.moveTo(aim.x-20,aim.y);bearCtx.lineTo(aim.x+20,aim.y);
    bearCtx.moveTo(aim.x,aim.y-20);bearCtx.lineTo(aim.x,aim.y+20);bearCtx.stroke();
  }
  document.getElementById('bearOpen').addEventListener('click',openBear);
  bearExit.addEventListener('click',()=>{closeBear();document.getElementById('bearOpen').focus();});
  bearCanvas.addEventListener('pointerdown',e=>{
    const r=bearCanvas.getBoundingClientRect();
    // object-fit preserves the logical canvas ratio inside the flex panel.
    const scale=Math.min(r.width/W,r.height/H);
    aim={x:(e.clientX-r.left-(r.width-W*scale)/2)/scale,y:(e.clientY-r.top-(r.height-H*scale)/2)/scale};
    shootBear();
  });

  // ===== 输入 =====
  function evtPos(e){
    const rect = cv.getBoundingClientRect();
    const cx = (e.touches ? e.touches[0].clientX : e.clientX) - rect.left;
    const cy = (e.touches ? e.touches[0].clientY : e.clientY) - rect.top;
    return {x: cx * W / rect.width, y: cy * H / rect.height};
  }
  cv.addEventListener("mousemove", function(e){
    const p = evtPos(e);
    hoverCell = pixelToCell(p.x, p.y);
  });
  cv.addEventListener("mouseleave", function(){ hoverCell = null; });
  cv.addEventListener("click", function(e){
    if(!running || over) return;
    const p = evtPos(e);
    if(bear.state && Math.hypot(p.x-bear.state.x,p.y-bear.state.y)<40){openBear();return;}
    const cell = pixelToCell(p.x, p.y);
    if(!cell) return;
    const existing = towers.find(t => t.c === cell.c && t.r === cell.r);
    if(existing){ selTower = existing; selType = null; renderShop(); renderInfo(); return; }
    if(selType && canBuild(cell)){ build(cell); return; }
    selTower = null; renderInfo();
  });

  document.addEventListener("keydown", function(e){
    const k = e.key;
    if(bear.active){
      if(k.startsWith("Arrow") || k===" "){
        e.preventDefault();
        if(k===" ")shootBear();
        else {aim.x=Math.max(0,Math.min(W,aim.x+(k==="ArrowRight"?12:k==="ArrowLeft"?-12:0)));aim.y=Math.max(0,Math.min(H,aim.y+(k==="ArrowDown"?12:k==="ArrowUp"?-12:0)));}
      } else if(k==="Escape")closeBear();
      return;
    }
    if(k >= "1" && k <= "5"){
      selType = TKEYS[+k - 1]; selTower = null; renderShop(); renderInfo();
    }else if(k === " "){
      e.preventDefault(); togglePause();
    }else if(k === "f" || k === "F"){
      cycleSpeed();
    }else if(k === "n" || k === "N"){
      callNow();
    }else if(k === "Escape"){
      selType = null; selTower = null; renderShop(); renderInfo();
    }
  });

  const speedBtn = document.getElementById("speedBtn");
  const pauseBtn = document.getElementById("pauseBtn");
  function cycleSpeed(){
    if(bear.active) return;
    speed = speed === 1 ? 2 : speed === 2 ? 3 : 1;
    speedBtn.textContent = speed + "×";
    speedBtn.classList.toggle("on", speed > 1);
  }
  function togglePause(){
    if(bear.active) return;
    if(!running || over) return;
    paused = !paused;
    pauseBtn.textContent = paused ? "继续" : "暂停";
    pauseBtn.classList.toggle("on", paused);
    renderRepair();
  }
  function callNow(){
    if(bear.active) return;
    if(!running || over || prep <= 0.05) return;
    honey += Math.round(prep * 3);
    prep = 0;
    startWave();
  }
  speedBtn.addEventListener("click", cycleSpeed);
  pauseBtn.addEventListener("click", togglePause);
  callBtn.addEventListener("click", callNow);

  // ===== 流程 =====
  const overlay = document.getElementById("overlay");
  const ovTitle = document.getElementById("ovTitle");
  const ovText = document.getElementById("ovText");
  const startBtn = document.getElementById("startBtn");

  function gameOver(){
    over = true; running = false;
    repair.stop();
    ovTitle.textContent = "蜂巢失守";
    ovText.innerHTML = "撑到第 <b>" + wave + "</b> 波，消灭 <b>" + kills + "</b> 只虫子。<br>换个建塔位置再试一次？";
    startBtn.textContent = "重新防守";
    overlay.hidden = false;
    syncHud();
  }
  startBtn.addEventListener("click", function(){
    reset();
    running = true;
    prep = 6;
    overlay.hidden = true;
    syncHud();
  });

  // ===== 主循环 =====
  let last = 0;
  function frame(now){
    if(document.hidden) { last = now; requestAnimationFrame(frame); return; }
    if(!last) last = now;
    let dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if(running && !paused && !over && !bear.active){
      for(let i = 0; i < speed && !over; i++) tick(dt);
    }
    if(!paused && !bear.active) blinkT += dt;
    animateHoney(dt);
    draw();
    drawBear(dt);
    requestAnimationFrame(frame);
  }

  // ===== 初始化 =====
  function fitCanvas(){
    const dpr = window.devicePixelRatio || 1;
    cv.width = W * dpr; cv.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  fitCanvas();
  readPalette();
  reset();

  // 首屏摆几座示范塔，让人一眼看懂玩法
  ["sting","bomb","pollen"].forEach(function(k, i){
    const cell = [{c:3,r:2},{c:6,r:4},{c:9,r:2}][i];
    const p = cellCenter(cell.c, cell.r);
    towers.push({c:cell.c, r:cell.r, x:p.x, y:p.y, type:k, level:i === 1 ? 2 : 1, cd:0, angle:-0.6});
  });

  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  mq.addEventListener("change", readPalette);
  new MutationObserver(readPalette).observe(document.documentElement, {attributes:true, attributeFilter:["data-theme"]});
  window.addEventListener("resize", function(){ fitCanvas(); });

  sprites.ready.then(() => requestAnimationFrame(frame)).catch(error => {
    ovText.textContent = '游戏图片加载失败，请重新打开插件。';
    startBtn.disabled = true;
    console.error('Hive sprite loading failed', error);
  });
})();
