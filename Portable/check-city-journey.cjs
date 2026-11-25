const {chromium}=require("playwright-core");
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path");
const [base,out,localLibrary]=process.argv.slice(2);
(async()=>{
  fs.mkdirSync(out,{recursive:true});
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY?{proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"localhost,127.0.0.1"}}:{})});
  try {
    const context=await browser.newContext({serviceWorkers:"block",viewport:{width:1350,height:920},locale:"zh-CN",timezoneId:"Asia/Shanghai"});
    const page=await context.newPage(),errors=[];
    page.on("pageerror",e=>{errors.push(e.message); console.error("page error:",e.message);});
    page.on("requestfailed",req=>{if(req.url().startsWith(base) && !req.url().includes("/data/world-stations/")) console.warn(req.url(),req.failure()?.errorText);});
    await page.goto(base,{waitUntil:"domcontentloaded",timeout:90000});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.metroPolylines.length,null,{timeout:90000}).catch(async error=>{
      console.error(await page.evaluate(()=>[document.title,typeof state,$("mapDataError").textContent,$("libraryStatus").textContent]));throw error;
    });
    const result={version:await page.locator("#versionBadge").textContent()};
    result.cities=await page.evaluate(()=>({all:state.metroCities.length,packed:state.metroCities.filter(c=>c.data).length}));
    assert.ok(result.cities.packed>60 && result.cities.all>200);
    await page.evaluate(()=>{setWorkspaceView("experiences");setWorkspaceOpen(true);});
    await page.locator("#toggleJourney").click();
    assert.ok(await page.locator("#libraryTrain").isVisible());
    assert.ok(await page.locator("#routeSelect optgroup").first().locator("option").count()>2);
    result.schedule=await page.locator("#libraryStatus").textContent();
    const runTrain=async(name)=>{
      await page.locator("#libraryDate").fill("2026-11-25");
      await page.locator("#libraryTrain").fill(name);
      await page.waitForFunction(n=>[...document.querySelectorAll('#routeSelect option[value^="search:"]')].some(o=>o.textContent.split(" · ")[0].split("/").includes(n)),name);
      const id=await page.locator("#routeSelect").evaluate((e,n)=>[...e.options].find(o=>o.value.startsWith("search:") && o.textContent.split(" · ")[0].split("/").includes(n)).value,name);
      const at=Date.now();
      await page.locator("#routeSelect").selectOption(id);
      await page.waitForFunction(n=>state.route?.train.includes(n) && state.route.geometryAvailable && state.routePolylines.some(p=>p && state.map.hasLayer(p)),name,{timeout:30000});
      const route=await page.evaluate(()=>({train:state.route.train,stops:state.route.stops.length,legs:state.route.legs.length}));
      return {...route,elapsedMs:Date.now()-at};
    };
    result.national=await runTrain("Z58");console.log(result.national);
    await page.screenshot({path:path.join(out,"journey.png")});
    if(localLibrary) {
      await page.locator("#libraryFile").setInputFiles(localLibrary);
      await page.waitForFunction(()=>!!RailLibrary.current);
      result.library=await page.evaluate(()=>({edition:RailLibrary.current.edition,rows:RailLibrary.current.services.length}));
      result.fromLibrary=await runTrain("D2236");console.log(result.fromLibrary);
      await page.reload({waitUntil:"domcontentloaded"});
      await page.waitForFunction(()=>typeof RailLibrary!=="undefined" && RailLibrary.current?.services.length>10000);
    }
    await page.evaluate(()=>{if(journeyOpen()) closeJourney();});
    const directions=[];
    for (const name of ["上海","新加坡","维也纳"]) {
      const id=await page.evaluate(n=>{
        const city=state.metroCities.find(c=>c.name===n),center=metroCityBounds(city).getCenter();
        state.map.setView(center,12,{animate:false});return city.id;
      },name);
      await page.waitForFunction(id=>state.metroDetails.get(id)?.routes.some(r=>r.stops.length>3),id,{timeout:150000});
      directions.push(await page.evaluate(id=>{
        const d=state.metroDetails.get(id), route=d.routes.find(r=>r.stops.length>3 && r.parts.length);
        selectMetroRoute(d,route,{fit:true});
        const count=document.querySelectorAll("[data-metro-stop]").length;
        document.querySelector("[data-metro-stop]").click();
        return {city:d.name, routes:d.routes.length, direction:route.name,stops:count,selected:$("infoTitle").textContent};
      },id));
      console.log(directions.at(-1));
      if(name==="维也纳") {
        const restored=await page.evaluate(async id=>(await MetroLoader.load(state.metroCities.find(c=>c.id===id),"cached")).routes.length,id);
        assert.equal(restored,directions.at(-1).routes);
        await page.screenshot({path:path.join(out,"vienna.png")});
      }
    }
    result.directions=directions;result.errors=errors;
    fs.writeFileSync(path.join(out,"checks.json"),JSON.stringify(result,null,2));
    console.log(JSON.stringify(result));assert.deepEqual(errors,[]);
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
