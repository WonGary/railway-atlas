const assert = require("node:assert/strict");
const fs = require("node:fs");
const crypto = require("node:crypto");
const {chromium} = require("playwright-core");
const source = process.argv[2], output = process.argv[3], day = process.env.RAILWAY_TEST_DAY || "2026-11-25";
const fixed = ["Z336","N147","Z58","C273","D2236","V6461","D174","V571","V604"];
require("../Web/station-directory/national.js");
const data = global.atlasRailDirectory;
const dateKey=day.replaceAll("-","");
const ordered = [...new Set(data.trains.filter(t=>data.calendars[t[1]].includes(dateKey)).map(t=>t[0]))]
  .filter(n=>!fixed.includes(n)).map(code=>[crypto.createHash("sha256").update(`atlas-${dateKey}:${code}`).digest("hex"),code])
  .sort(([a],[b])=>a.localeCompare(b));
const trains=process.argv.length>4 ? process.argv.slice(4) : [...fixed,...ordered.slice(0,3).map(t=>t[1])];

async function openApp(page) {
  const failures=[];
  page.on("pageerror",err=>failures.push(err.message));
  page.on("requestfailed",req=>{
    if (new URL(req.url()).origin===new URL(source).origin) failures.push(`${req.url()} ${req.failure()?.errorText}`);
  });
  await page.goto(source,{waitUntil:"domcontentloaded",timeout:60000});
  await page.bringToFront();
  try {
    await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map,null,{polling:100,timeout:30000});
  } catch(error) {
    const status=await page.locator("#mapDataError").allTextContents();
    throw Error(`${error.message}: ${page.url()} ${[...failures,...status].join(" | ")}`);
  }
}

(async()=>{
  const browser=await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY ? {proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}} : {})});
  const results=[];
  try {
    for (const train of trains) {
      const context=await browser.newContext({serviceWorkers:"block",locale:"zh-CN",timezoneId:"Asia/Shanghai",viewport:{width:1280,height:850}});
      const page=await context.newPage(),errors=[];
      page.on("pageerror",err=>errors.push(err.message));
      await openApp(page);
      if (process.env.RAILWAY_TEST_LIBRARY) {
        await page.locator("#libraryFile").setInputFiles(process.env.RAILWAY_TEST_LIBRARY);
        await page.waitForFunction(()=>!!RailLibrary.current,null,{timeout:60000});
      }
      const row={train};
      for(const run of ["cold","warm"]) {
        await page.evaluate(({day,train})=>{
          setWorkspaceView("route");setWorkspaceOpen(true);
          const input=document.getElementById("libraryTrain");
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
        row.playback=await page.evaluate(train=>{
          const r=state.route;
          if (!r.geometryAvailable) return null;
          const a=train==="D174"?r.stops.findIndex(s=>s.name==="陇南"):
            train==="V571"?r.stops.findIndex(s=>s.name==="菏泽"):Math.floor(r.legs.length/2);
          const b=train==="V571"?r.stops.findIndex(s=>s.name==="浠水"):a+1;
          if (a<0 || b<=a) throw Error(`${train} 乘车区间不存在`);
          $("playJourney").click();
          if (!state.playbackTimer || !state.playbackMarker) throw Error("主地图未开始播放");
          const start=r.stops[a].departure, end=r.stops[a+1].arrival;
          const mid=(start+end)*30;
          $("journeyProgress").value=String(mid);updatePlayback();stopPlayback();
          const position=state.playbackMarker.getLatLng();
          if (state.map.distance(position,r.legs[a][0])<5 || state.map.distance(position,r.legs[a].at(-1))<5)
            throw Error("播放位置停留在站点");
          return {from:r.stops[a].name,to:r.stops[b].name,legs:b-a,
            date:StationCatalog.day(r.serviceDate,Math.floor(start/1440))};
        },train);
        await context.close();
        // A separate document has no decoded train in memory. Clear HTTP cache too,
        // then exercise the ordinary postcard inputs and the browser PNG download.
        const fresh=await browser.newContext({serviceWorkers:"block",locale:"zh-CN",timezoneId:"Asia/Shanghai"});
        const card=await fresh.newPage();
        try {
          await openApp(card);
          if(process.env.RAILWAY_TEST_CONTOURS) {
            await card.locator("#cardContourFile").setInputFiles(process.env.RAILWAY_TEST_CONTOURS);
            await card.waitForFunction(()=>CardMap.hasContours);
          }
          await card.evaluate(({train,day,from,to})=>{
            setWorkspaceView("experiences"); setWorkspaceOpen(true); setExperiencePage("postcard");
            for(const [field,value] of Object.entries({Train:train,Date:day,From:from,To:to,Style:"map"})) document.getElementById("postcard"+field).value=value;
            window.cardBenchStart=performance.now();
            document.getElementById("postcardTo").dispatchEvent(new Event("input",{bubbles:true}));
          },{train,day:row.playback?.date || day,from:row.playback?.from || row.cold.from,to:row.playback?.to || row.cold.to});
          await card.waitForFunction(()=>cardRoute || !document.getElementById("postcardStatus").textContent.includes("正在"),null,{timeout:20000,polling:"raf"});
          row.postcard=await card.evaluate(()=>({previewMs:Math.round(performance.now()-window.cardBenchStart),
            ready:!!cardRoute && !document.getElementById("downloadPostcard").disabled,
            from:cardRoute?.stops[0].name,to:cardRoute?.stops.at(-1).name,legs:cardRoute?.legs.length,
            message:document.getElementById("postcardStatus").textContent}));
          if (row.playback && row.postcard.ready) {
            for (const field of ["from","to","legs"]) assert.equal(row.postcard[field],row.playback[field]);
          }
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
      if(output) fs.writeFileSync(output,JSON.stringify({day,source,browser:browser.version(),sampleSeed:`atlas-${dateKey}:`,
        mapImportedLibrary:!!process.env.RAILWAY_TEST_LIBRARY,cardImportedContours:!!process.env.RAILWAY_TEST_CONTOURS,
        cardStyle:"map",budgetMs:5000,results},null,2)+"\n");
      if (!row.cold.from) await context.close();
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
