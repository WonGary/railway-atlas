// node Portable/check-journey-guide.cjs [--data-only | --with-test-hooks] [Web URL]
const assert = require("node:assert/strict");
const {withBrowser} = require("./check-history-network.cjs");
const {Places, arrival, transfers, dayMinute} = require("../Web/station-directory/journey-guide-core.js");

function pure() {
  const catalog={lines:new Map([["甲",[{title:"甲线"},{title:"乙线"}]]])};
  const directory={names:["甲","路弯内的站"],coordinates:[[30,110],[30.05,110.05]]};
  const places=new Places({version:1,rows:[]},directory,catalog);
  const a=[30,110],b=[30.10,110],c=[30.10,110.10];
  assert.deepEqual(places.nearby([[a,b,c]],0,a,["hub","station"]).map(p=>p.name),["甲"]);
  assert.deepEqual(places.nearby([[a,b],[],[b,c]],1,a,["hub"]),[]);
  assert.deepEqual(places.nearby([[a,b]],0,a,["metro"]),[]);
  const table={serviceDate:"2026-11-26",stops:[{name:"始发",departure:1420},{name:"换乘站",arrival:1438,departure:1445},{name:"终点",arrival:1470}]};
  const calls=arrival(table,1,1420*60);
  const dates=[];
  const item=(id,dep,origin="2026-11-26")=>({dep,origin,detail:()=>({id,number:"D2",stops:[["起点",null,1],["换乘站",dep-1,dep],["终点",dep+5,null]]})});
  const items=transfers(calls,{origin:"2026-11-26",trip:"same"},(_,date)=>{
    dates.push(date);return [item("same",1444),item("old",1437),item("late",2010),item("variant1",1444),
      item("variant2",1444),item("tomorrow",4,"2026-11-27"),{...item("pass",1444),pass:true}];
  },6);
  assert.deepEqual(dates,["2026-11-26","2026-11-27"]);
  assert.deepEqual(items.map(c=>c.trip).sort(),["tomorrow","variant1","variant2"]);
  assert.ok(items.every(c=>c.wait===6 && c.boardDate==="2026-11-27" && c.absolute===dayMinute("2026-11-27")+4));
  assert.equal(arrival(table,1,1446*60),null);
  assert.equal(arrival({...table,stops:table.stops.slice(1)},0,1438*60),null);
  assert.equal(arrival(table,1,1443*60).at,dayMinute("2026-11-27")+3);
  console.log("corridor, filters, gaps, platform time, midnight, duplicate board days and distinct timetable variants passed");
}

async function ui({browser,devices,url,testHooks}, phone) {
  const context=await browser.newContext({serviceWorkers:"block",...(phone?devices["Pixel 7"]:{viewport:{width:1440,height:900}}),
    timezoneId:phone?"America/Los_Angeles":"Asia/Shanghai"});
  try {
    const page=await context.newPage(), errors=[];
    page.on("pageerror",e=>errors.push(e.message));
    await page.route("**/*",r=>new URL(r.request().url()).origin===new URL(url).origin?r.continue():r.abort());
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.map && state.routes.length);
    const fixtureWiring=testHooks && !await page.evaluate(()=>Boolean(globalThis.RailwayJourneyGuide));
    if (fixtureWiring) {
      for (const path of ["station-directory/journey-guide-core.js","journey-guide.js"])
        await page.addScriptTag({url:new URL(path,url).href});
    }
    const press=async locator=>phone?locator.tap():locator.click();
    async function workspace() {
      if(await page.locator("#toggleWorkspace").getAttribute("aria-expanded")!=="true") await press(page.locator("#toggleWorkspace"));
    }
    const guide=page.locator("#journeyGuide");
    const action=(name)=>press(guide.getByRole("button",{name,exact:true}));
    await workspace();await press(page.locator('[data-view="experiences"]'));await press(page.locator("#toggleJourney"));
    await page.locator("#libraryDate").fill("2026-11-26");
    await page.locator("#libraryTrain").fill("D174");
    await press(page.locator("#libraryResults button").filter({hasText:/^D174\b/}).first());
    await page.waitForFunction(()=>state.route?.trip==="880000D17403" && state.route.geometryAvailable);
    await workspace();
    await press(guide.getByText("沿线地点",{exact:true}));
    const place=guide.locator("[data-place]").filter({hasText:"西宁"}).first();
    await place.waitFor();
    const nearby=await guide.locator("[data-place]").count();
    assert.match(await place.locator("a").getAttribute("href"),/^https:/);
    const rail=guide.getByLabel("铁路交汇站");
    await rail.uncheck();assert.equal(await guide.locator('[data-place="hub"]').count(),0);await rail.check();
    await press(guide.getByText("沿线地点",{exact:true}));
    if (phone) await press(page.locator("#toggleWorkspace"));
    await press(page.locator("#playJourney"));
    await workspace();
    await action("观光模式");
    const before=await page.evaluate(()=>{state.map.setView([36.8,102],10,{animate:false});return state.playbackSeconds;});
    await page.waitForFunction(t=>state.playbackSeconds>t+8,before);
    assert.ok(await page.evaluate(()=>!document.getElementById("followJourney").checked && state.map.getCenter().distanceTo([36.8,102])<100));
    await action("回到列车");
    await guide.getByLabel("锁定缩放").check();
    assert.ok(await page.evaluate(()=>{
      const z=state.map.getZoom();state.map.setZoom(z-1,{animate:false});return state.map.getZoom()===z;
    }));
    // Desktop sends physical mouse events to Leaflet. CDP supplies a touch drag on the phone.
    if (phone) await press(page.locator("#toggleWorkspace"));
    const handle=await page.waitForFunction(()=>{
      const map=state.map.getContainer(), rect=map.getBoundingClientRect();
      for (const yf of [.45,.60,.30,.70]) for (const xf of [.50,.58,.64,.40,.73,.28]) {
        const x=Math.round(rect.left+rect.width*xf),y=Math.round(rect.top+rect.height*yf);
        if ([x,x+90].every(px=>{const hit=document.elementFromPoint(px,y);return hit && map.contains(hit) && !hit.closest(".leaflet-control");})) return {x,y};
      }
      return false;
    });
    const {x,y}=await handle.jsonValue();
    if (phone) {
      const touch=await context.newCDPSession(page);
      await touch.send("Input.dispatchTouchEvent",{type:"touchStart",touchPoints:[{x,y}]});
      for(let d=10;d<=90;d+=10) await touch.send("Input.dispatchTouchEvent",{type:"touchMove",touchPoints:[{x:x+d,y}]});
      await touch.send("Input.dispatchTouchEvent",{type:"touchEnd",touchPoints:[]});await touch.detach();
    } else {
      await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+90,y,{steps:10});await page.mouse.up();
    }
    await page.waitForFunction(()=>!document.getElementById("followJourney").checked && state.playbackTimer);
    await workspace();await action("回到列车");
    if (phone) await press(page.locator("#toggleWorkspace"));
    await press(page.locator("#playJourney"));
    await workspace();
    await press(guide.getByText("同站车次接力",{exact:true}));
    async function choose(station,to,trip) {
      await guide.getByLabel("换乘站",{exact:true}).selectOption({label:station});
      await action("查找同站车次");
      const services=guide.getByLabel("接续车次");
      const option=services.locator("option").filter({hasText:trip}).first();
      await option.waitFor({state:"attached"});
      const text=await option.textContent();
      await services.selectOption(await option.getAttribute("value"));
      await guide.getByLabel("接力下车站").selectOption({label:to});
      return text;
    }
    // Remove exactly the ridden leg from a real response. A failed relay must
    // leave the current route, clock, playback and chain untouched.
    const damagedTrip="76000D19280J";
    const damagedFile=await page.evaluate(()=>globalThis.atlasPathManifest.groups.D19);
    let faultDelivered=false;
    await page.route(`**/paths/${damagedFile}`,async r=>{
      const response=await r.fetch(), group=await response.json();
      const row=Object.values(group.trains).flat().find(t=>t.id===damagedTrip);
      const fullNames=await page.evaluate(()=>globalThis.atlasRailDirectory.names);
      row.p[row.s.findIndex(([id])=>fullNames[id]==="广元")]=-1;
      faultDelivered=true;await r.fulfill({response,json:group});
    });
    await choose("广元","宁强南",damagedTrip);
    const checkpoint=await page.evaluate(()=>({id:state.route.id,time:state.playbackSeconds,running:!!state.playbackTimer}));
    await action("跳到发车并接续");
    await guide.getByText(/接力区间缺少连续轨迹.*广元 → 宁强南/).waitFor();
    assert.ok(faultDelivered);
    assert.deepEqual(await page.evaluate(()=>({id:state.route.id,time:state.playbackSeconds,running:!!state.playbackTimer})),checkpoint);
    assert.equal(await guide.locator("ol li").count(),0);
    async function transfer(station,train,to,trip) {
      const text=await choose(station,to,trip);
      await action("跳到发车并接续");
      await page.waitForFunction(({trip,to})=>state.route?.trip===trip && state.route.stops.at(-1).name===to && state.playbackTimer,{trip,to});
      const actual=await page.evaluate(()=>({from:state.route.stops[0].name,day:state.route.serviceDate,geometry:state.route.geometryAvailable,
        legs:state.route.legs.length,vertices:state.route.legs[0].length}));
      assert.equal(actual.from,station);assert.equal(actual.geometry,true);assert.equal(actual.legs,1);
      await workspace();
      return {train,text,...actual};
    }
    const first=await transfer("广元","Z318","江油","490000Z31804");
    assert.equal(first.day,"2026-11-25");assert.equal(first.vertices,337);
    const second=await transfer("江油","G8689","绵阳","76000G868909");
    assert.equal(second.day,"2026-11-26");assert.equal(second.vertices,45);
    const chain=await guide.locator("ol li").allTextContents();
    assert.deepEqual(chain.map(s=>s.split("　")[0]),["D174/D175","Z318","G8689"]);
    if (phone) await press(page.locator("#toggleWorkspace"));
    await press(page.locator("#closePlayback"));
    await guide.waitFor({state:"hidden"});assert.equal(await guide.locator("ol li").count(),0);
    assert.deepEqual(errors,[]);
    console.log(JSON.stringify({view:phone?"phone":"desktop",entry:fixtureWiring?"test hooks":"checkout",nearby,first,second,chain}));
  } finally {await context.close();}
}
(async()=>{pure();if(!process.argv.includes("--data-only")) await withBrowser(async opts=>{await ui(opts,false);await ui(opts,true);});})()
  .catch(e=>{console.error(e);process.exitCode=1;});
