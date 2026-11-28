const assert = require("node:assert/strict");
const {chromium} = require("playwright-core");

async function run(browser, url, touch) {
  const context = await browser.newContext({viewport:{width:1100,height:800},hasTouch:touch,serviceWorkers:"block"});
  const page = await context.newPage(), errors = [];
  page.on("pageerror", e => errors.push(e.message));
  await page.route("**/*", r => new URL(r.request().url()).origin === new URL(url).origin ? r.continue() : r.abort());
  await page.addInitScript(() => localStorage.setItem("railway-atlas-map-settings-v1",
    JSON.stringify({mode:"offline",automaticDetail:false,showsLabels:true,inspectorLayout:"floating"})));
  try {
    await page.goto(url, {waitUntil:"load"});
    await page.waitForFunction(() => typeof state !== "undefined" && state.corridor);
    // Import through the normal region-file control, away from the bundled network.
    const lat = 20, lng = -145;
    const coord = (latitude,longitude) => ({latitude,longitude});
    const region = {schemaVersion:1,name:"点击回归",lines:[{id:"way/1",name:"A线",tags:{railway:"rail",name:"A线"},
      coordinates:[coord(lat,lng-.8),coord(lat,lng+.8)]}],stations:[
      {id:"a",name:"总站",tags:{railway:"station",highspeed:"yes"},coordinate:coord(lat,lng)},
      {id:"b",name:"小站",tags:{railway:"halt"},coordinate:coord(lat+.016,lng)},
      {id:"c",name:"被避让站",tags:{railway:"halt"},coordinate:coord(lat+.000001,lng)}
    ]};
    await page.locator("#regionFile").setInputFiles({name:"qa.railmap",mimeType:"application/json",buffer:Buffer.from(JSON.stringify(region))});
    await page.waitForFunction(() => document.querySelector("#regionStatus").textContent.includes("点击回归"));
    await page.evaluate(() => {
      setWorkspaceOpen(false);
      // Record actual detail openings, including unwanted duplicate actions.
      window.hitLog = [];
      const title = document.querySelector("#infoTitle");
      new MutationObserver(records => { for (const record of records) window.hitLog.push(record.addedNodes[0]?.textContent); })
        .observe(title,{childList:true});
    });
    const wait = ms => page.waitForTimeout(ms);
    async function view(z, y=lat,x=lng) {
      if (!touch) await page.mouse.move(2,2);
      await page.evaluate(({z,y,x}) => {
        LineFocus.clear(); $("infoPanel").hidden = true;
        state.map.setView([y,x],z,{animate:false}); hitLog.length=0;
      }, {z,y,x});
      await wait(90);
    }
    async function xy(y,x,dx=0,dy=0) {
      return page.evaluate(({y,x,dx,dy}) => {
        const p=state.map.latLngToContainerPoint([y,x]), r=state.map.getContainer().getBoundingClientRect();
        return [r.left+p.x+dx,r.top+p.y+dy];
      },{y,x,dx,dy});
    }
    const tap = (x,y) => touch ? page.touchscreen.tap(x,y) : page.mouse.click(x,y);
    async function expectHit(expected, description) {
      await wait(490);
      const log = await page.evaluate(() => hitLog.splice(0));
      assert.deepEqual(log, expected ? [expected] : [], `${touch?"touch":"mouse"} ${description}: ${log}`);
    }
    for (const z of [7,10,12,15,18]) {
      await view(z,lat,lng+.55);
      for (const offset of [0,3,4,5,6,8,10,13]) {
        const [x,y]=await xy(lat,lng+.55,0,offset);
        await tap(x,y);
        const tolerance=z<11 ? -1 : (z<14 ? 3.5 : 4.5)+(touch?2:0);
        await expectHit(offset<=tolerance ? "A线" : null,`Z${z} +${offset}`);
        await page.evaluate(() => {LineFocus.clear();$("infoPanel").hidden=true;});
      }
    }
    await view(10);
    await tap(...await xy(lat+.016,lng));
    await expectHit(null,"minor dot in overview");
    await tap(...await xy(lat,lng));
    await expectHit("总站","visible major");
    await view(14);
    await tap(...await xy(lat+.016,lng));
    await expectHit("小站","minor in detail");
    await view(14);
    const labels = page.locator(".station-label span");
    // A real pointer may hover the colliding platform first. Both names occupy
    // the same space; use the actual winner, not the nominal priority alone.
    const names = await labels.allTextContents();
    const visibleName = names.find(n => n === "总站" || n === "被避让站");
    assert.ok(visibleName,`station labels at Z14: ${JSON.stringify(names)}, errors=${errors}, map=${JSON.stringify(await page.evaluate(()=>[state.map.getCenter(),state.map.getZoom(),[...document.querySelectorAll(".station-label")].map(e=>[e.className,e.textContent])]))}`);
    assert.equal(names.filter(n=>n==="总站" || n==="被避让站").length,1);
    const label = await labels.filter({hasText:visibleName}).boundingBox();
    await tap(label.x+label.width/2,label.y+label.height/2);
    await expectHit(visibleName,"painted label above track");
    await view(14,lat,lng+.55);
    const [x,y] = await xy(lat,lng+.55);
    if (touch) {
      const cdp = await context.newCDPSession(page);
      const send = (type,points) => cdp.send("Input.dispatchTouchEvent",{type,touchPoints:points.map(([id,x,y])=>({id,x,y}))});
      await send("touchStart",[[1,x,y]]);
      await send("touchMove",[[1,x+7,y]]); await send("touchMove",[[1,x,y]]); await send("touchEnd",[]);
      await expectHit(null,"short drag and return");
      await send("touchStart",[[1,x-15,y],[2,x+15,y]]);
      await send("touchMove",[[1,x-45,y],[2,x+45,y]]); await send("touchEnd",[]);
      await expectHit(null,"pinch");
    } else {
      for (const d of [4,35]) {
        await page.mouse.move(x,y); await page.mouse.down(); await page.mouse.move(x+d,y); await page.mouse.move(x,y); await page.mouse.up();
        await expectHit(null,`drag ${d} and return`);
      }
      await page.mouse.dblclick(x,y);
      await expectHit(null,"double-click zoom");
      await page.mouse.move(x,y); await page.mouse.down(); await page.mouse.wheel(0,90); await page.mouse.up();
      await expectHit(null,"wheel during press");
    }
    await view(15,lat,lng+.55);
    await tap(...await xy(lat,lng+.55));
    await expectHit("A线","next clean tap");
    // Use the actual station-layout renderer and a cached platform with an inner ring.
    const platform = {id:"way/qa-platform",kind:"platform",network:"railway",area:true,platformLabel:"7",
      paths:[[[10,10],[10.002,10],[10.002,10.002],[10,10.002],[10,10]],
        [[10.0008,10.0008],[10.0012,10.0008],[10.0012,10.0012],[10.0008,10.0012],[10.0008,10.0008]]]};
    await page.route("**/data/station-layouts.json", r=>r.fulfill({json:{features:[platform]}}));
    await page.reload({waitUntil:"load"});
    await page.waitForFunction(() => typeof state !== "undefined" && state.corridor);
    await page.evaluate(() => {setWorkspaceOpen(false);$("infoPanel").hidden=true;state.map.setView([10.001,10.001],17,{animate:false});});
    await page.waitForSelector('[data-osm-id="way/qa-platform"]',{state:"attached",timeout:5000});
    await tap(...await xy(10.001,10.001));
    await wait(500); assert.equal(await page.locator("#infoPanel").isVisible(),false,"hole");
    await tap(...await xy(10.0004,10.0004));
    await page.waitForFunction(() => !$("infoPanel").hidden && $("infoTitle").textContent.includes("站台"));
    assert.deepEqual(errors,[]);
    console.log(`${touch?"touch":"mouse"} PASS: 40 line offsets, stations/labels, gestures, single dispatch, filled platform/hole`);
  } finally { await context.close(); }
}
(async () => {
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,args:["--no-proxy-server"]});
  try { await Promise.all([false,true].map(touch => run(browser,process.argv[2],touch))); }
  finally { await browser.close(); }
})().catch(e=>{ console.error(e);process.exitCode=1; });
