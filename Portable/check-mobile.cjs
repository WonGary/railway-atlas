const assert = require("node:assert/strict");
const {spawn} = require("node:child_process");
const {setTimeout: delay} = require("node:timers/promises");
const playwright = require("playwright-core");

async function run() {
  const engine = process.argv[2] || "chromium";
  const site = process.env.RAILWAY_TEST_URL || "http://127.0.0.1:18765/";
  const server = process.env.RAILWAY_TEST_URL ? null : spawn("python3",
    ["-m","http.server","18765","--bind","127.0.0.1","--directory","Web"],{stdio:"ignore"});
  let browser;
  try {
    for (let i=0; i<50; i++) {
      if (await fetch(site).then(r=>r.ok).catch(()=>false)) break;
      await delay(150);
    }
    browser = await playwright[engine].launch({executablePath:process.env.RAILWAY_BROWSER});
    const phone = engine==="webkit" ? "iPhone 13" : "Pixel 7";
    const context = await browser.newContext({...playwright.devices[phone]});
    await context.addInitScript(()=>{if(!localStorage.getItem("old-version-tested")){
      localStorage.setItem("railway-atlas-journey-open","true");
      localStorage.setItem("railway-atlas-favorites",'["北京西"]');
      localStorage.setItem("old-version-tested","1");
    }});
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error=>errors.push(error.message));
    await page.goto(site, {waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>state.routes.length>0 && state.metroPolylines.length>0);
    assert.equal(await page.locator("#versionBadge").textContent(),"0.8.0");
    assert.equal(await page.locator("#playbackBar").isVisible(),false);
    assert.deepEqual(await page.evaluate(()=>[state.route,state.map.hasLayer(state.routeLayer),state.map.hasLayer(state.historyLayer),state.workspaceView]),[null,false,false,"layers"]);
    await page.tap("#toggleWorkspace");
    await page.tap('[data-view="settings"]');
    await page.selectOption("#pref-mode","cached");
    await page.tap('[data-view="layers"]');
    await page.uncheck("#pref-showsStations");
    await page.uncheck("#pref-showsNationalMetroOverview");
    assert.equal(await page.evaluate(()=>state.metroLayer.getLayers().length),0);
    await page.check("#pref-showsNationalMetroOverview");
    assert.ok(await page.evaluate(()=>state.metroLayer.getLayers().length>0));
    await page.tap('[data-view="experiences"]');
    await page.tap("#toggleJourney");
    const routeID=await page.evaluate(()=>state.routes.find(route=>route.train==="G337").id);
    await page.selectOption("#routeSelect",routeID);
    assert.equal(await page.locator("#stationList button").count(),7);
    await page.selectOption("#routeFrom","2");
    await page.selectOption("#routeTo","4");
    assert.deepEqual(await page.evaluate(()=>[state.route.stops[0].name,state.route.stops.at(-1).name,state.route.legs.length]),["郑州东","黄石北",2]);
    await page.tap("#fullJourney");
    assert.equal(await page.evaluate(()=>state.route.legs.length),6);
    await page.tap("#closeWorkspace");
    assert.equal(await page.locator("#playbackBar").isVisible(),false);
    assert.equal(await page.evaluate(()=>state.map.hasLayer(state.routeLayer)),false);
    await page.tap("#toggleWorkspace");
    await page.tap('[data-view="stations"]');
    await page.selectOption("#metroCitySelect","macao");
    await page.waitForFunction(()=>document.querySelector("#directoryStatus").textContent.includes("32 / 32"));
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
    await page.evaluate(()=>navigator.serviceWorker.ready.then(()=>true));
    await page.waitForFunction(()=>navigator.serviceWorker.controller);
    await page.evaluate(()=>fetch("./data/metro/macao.json").then(r=>r.json()));
    await context.setOffline(true);
    await page.reload({waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>state.routes.length && state.metroPolylines.length);
    assert.equal(await page.evaluate(()=>state.route),null);
    assert.deepEqual(await page.evaluate(()=>[AtlasPrefs.value.showsStations,AtlasPrefs.value.mode,state.favorites.has("北京西")]),[false,"cached",true]);
    assert.equal(await page.evaluate(async()=>(await (await fetch("./data/metro/macao.json")).json()).stations.length),32);
    assert.deepEqual(errors,[]);
    console.log(`${engine} / ${phone}: map-first upgrade, map settings, G337, city directory and offline reopening passed.`);
  } finally {
    await browser?.close();
    server?.kill();
  }
}
run().catch(error=>{console.error(error);process.exitCode=1;});
