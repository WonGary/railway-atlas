const assert = require("node:assert/strict");
const fs = require("node:fs");
const crypto = require("node:crypto");
const {chromium} = require("playwright-core");
const source = process.argv[2], output = process.argv[3], day = "2026-11-25";
const fixed = ["Z336","N147","Z58","C273","D2236","V6461"];
require("../Web/station-directory/national.js");
const data = global.atlasRailDirectory;
const ordered = [...new Set(data.trains.filter(t=>data.calendars[t[1]].includes("20261125")).map(t=>t[0]))]
  .filter(n=>!fixed.includes(n)).map(code=>[crypto.createHash("sha256").update(`atlas-20261125:${code}`).digest("hex"),code])
  .sort(([a],[b])=>a.localeCompare(b));
const trains=[...fixed,...ordered.slice(0,5).map(t=>t[1])];

(async()=>{
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY ? {proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}} : {})});
  const results=[];
  try {
    for (const train of trains) {
      const context=await browser.newContext({serviceWorkers:"block",locale:"zh-CN",timezoneId:"Asia/Shanghai",viewport:{width:1280,height:850}});
      const page=await context.newPage(),errors=[];
      page.on("pageerror",err=>errors.push(err.message));
      await page.goto(source,{waitUntil:"domcontentloaded",timeout:90000});
      await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map,null,{timeout:90000});
      if (process.env.RAILWAY_TEST_LIBRARY) {
        await page.locator("#libraryFile").setInputFiles(process.env.RAILWAY_TEST_LIBRARY);
        await page.waitForFunction(()=>!!RailLibrary.current,null,{timeout:60000});
      }
      const row={train,supplemental:train===ordered[4][1]};
      for(const run of ["cold","warm"]) {
        await page.evaluate(({day,train})=>{
          setWorkspaceView("route");setWorkspaceOpen(true);
          const input=document.getElementById("libraryTrain");input.closest("details").open=true;
          document.getElementById("libraryDate").value=day;
          input.value=train;input.dispatchEvent(new Event("input",{bubbles:true}));
        },{day,train});
        const button=page.locator("#libraryResults button").filter({hasText:new RegExp(`(?:^|/|快照查 )${train}(?:[/ ·]|$)`) }).first();
        await button.waitFor({timeout:15000});
        row[run]=await button.evaluate(async(el,{train,run})=>{
          const old=state.route;
          const start=performance.now();
          el.click();
          for (;;) {
            await new Promise(resolve=>requestAnimationFrame(resolve));
            const r=state.route, msg=document.getElementById("libraryStatus").textContent;
            if (msg.includes(`未收录 ${train}`)) return {ms:Math.round(performance.now()-start),status:"absent",message:msg};
            if (r && r!==old && RailLibrary.trainNames(r.train).includes(train)) {
              const drawn=state.routePolylines.filter(l=>l && state.map.hasLayer(l) &&
                (l._path?.getAttribute("d")?.length>5 || l._renderer?._ctx)).length;
              if (r.legs.some(x=>x?.length>1) && !drawn && performance.now()-start<12000) continue;
              await new Promise(resolve=>requestAnimationFrame(resolve));
              const requests=performance.getEntriesByType("resource").filter(e=>e.startTime>=start && e.name.includes("/station-directory/paths/"))
                .map(e=>({file:e.name.split("/").pop(),ms:Math.round(e.duration),bytes:e.transferSize}));
              return {ms:Math.round(performance.now()-start),status:r.geometryAvailable && drawn===r.stops.length-1 ? "full":"partial",
                drawn,legs:r.stops.length-1,from:r.stops[0].name,to:r.stops.at(-1).name,gaps:r.gaps||[],
                vertices:r.legs.reduce((n,l)=>n+l.length,0),sources:[...new Set(r.geometryKinds||[])],requests};
            }
            if(performance.now()-start>18000) throw Error(`${train} ${run}: no rendered result (${msg})`);
          }
        },{train,run});
      }
      if (row.cold.from) {
        // A separate document has no decoded train in memory. Clear HTTP cache too,
        // then exercise the ordinary postcard inputs and the browser PNG download.
        const fresh=await browser.newContext({serviceWorkers:"block",locale:"zh-CN",timezoneId:"Asia/Shanghai"});
        const card=await fresh.newPage();
        try {
          await card.goto(source,{waitUntil:"domcontentloaded",timeout:90000});
          await card.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map,null,{timeout:90000});
          if(process.env.RAILWAY_TEST_CONTOURS) {
            await card.locator("#cardContourFile").setInputFiles(process.env.RAILWAY_TEST_CONTOURS);
            await card.waitForFunction(()=>CardMap.hasContours);
          }
          await card.evaluate(({train,day,from,to})=>{
            setWorkspaceView("experiences"); setWorkspaceOpen(true); setExperiencePage("postcard");
            for(const [field,value] of Object.entries({Train:train,Date:day,From:from,To:to,Style:"map"})) document.getElementById("postcard"+field).value=value;
            window.cardBenchStart=performance.now();
            document.getElementById("postcardTo").dispatchEvent(new Event("input",{bubbles:true}));
          },{train,day,from:row.cold.from,to:row.cold.to});
          await card.waitForFunction(()=>cardRoute || !document.getElementById("postcardStatus").textContent.includes("正在"),null,{timeout:20000,polling:"raf"});
          row.postcard=await card.evaluate(()=>({previewMs:Math.round(performance.now()-window.cardBenchStart),
            ready:!!cardRoute && !document.getElementById("downloadPostcard").disabled,
            message:document.getElementById("postcardStatus").textContent}));
          if (row.postcard.ready) {
            const received=card.waitForEvent("download");
            await card.locator("#downloadPostcard").evaluate(button=>button.click());
            const d=await received, file=await d.path();
            row.postcard.pngMs=await card.evaluate(()=>Math.round(performance.now()-window.cardBenchStart));
            const png=fs.readFileSync(file);
            assert.equal(png.toString("hex",0,8),"89504e470d0a1a0a");
            row.postcard.bytes=png.length;
          }
        } finally {await fresh.close();}
      }
      assert.deepEqual(errors,[]);
      results.push(row);
      console.log(JSON.stringify(row));
      if(output) fs.writeFileSync(output,JSON.stringify({day,source,browser:browser.version(),sampleSeed:"atlas-20261125:",
        mapImportedLibrary:!!process.env.RAILWAY_TEST_LIBRARY,cardImportedContours:!!process.env.RAILWAY_TEST_CONTOURS,
        cardStyle:"map",budgetMs:5000,results},null,2)+"\n");
      await context.close();
    }
    for(const result of results) {
      if(result.train==="V6461") {assert.equal(result.cold.status,"absent");continue;}
      for(const run of [result.cold,result.warm]) {
        assert.equal(run.status,"full",result.train);
        assert.ok(run.ms<=5000,`${result.train} map: ${run.ms} ms`);
      }
      assert.ok(result.postcard?.ready && result.postcard.pngMs<=5000,`${result.train} PNG: ${result.postcard?.pngMs} ms`);
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
