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
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error=>errors.push(error.message));
    await page.goto(site, {waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>state.route?.train==="G337");
    assert.equal(await page.locator("#versionBadge").textContent(),"0.7.0");
    await page.tap("#toggleJourney");
    assert.equal(await page.locator("#stationList button").count(),7);
    await page.selectOption("#routeFrom","2");
    await page.selectOption("#routeTo","4");
    assert.deepEqual(await page.evaluate(()=>[state.route.stops[0].name,state.route.stops.at(-1).name,state.route.legs.length]),["郑州东","黄石北",2]);
    await page.tap("#fullJourney");
    assert.equal(await page.evaluate(()=>state.route.legs.length),6);
    await page.tap("#closeWorkspace");
    assert.equal(await page.locator("#playbackBar").isVisible(),false);
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
    await page.waitForFunction(()=>state.route?.stops?.length===7);
    assert.equal(await page.evaluate(async()=>(await (await fetch("./data/metro/macao.json")).json()).stations.length),32);
    assert.deepEqual(errors,[]);
    console.log(`${engine} / ${phone}: G337, station range, closing journey, city directory and offline reopening passed.`);
  } finally {
    await browser?.close();
    server?.kill();
  }
}
run().catch(error=>{console.error(error);process.exitCode=1;});
