const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {chromium} = require("playwright-core");

async function main() {
  const [url, output] = process.argv.slice(2);
  fs.mkdirSync(output,{recursive:true});
  const browser = await chromium.launch({executablePath:process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY ? {proxy:{server:process.env.RAILWAY_TEST_PROXY,bypass:"127.0.0.1,localhost"}} : {})});
  try {
    const page = await browser.newPage({locale:"zh-CN",timezoneId:"Asia/Shanghai",
      viewport:{width:1440,height:900},serviceWorkers:"block"});
    const errors = [];
    page.on("pageerror", e=>errors.push(e.message));
    await page.goto(url,{waitUntil:"domcontentloaded",timeout:90000});
    await page.waitForFunction(()=>globalThis.atlasRailDirectory && typeof state!=="undefined" && state.corridor);
    const contourFile=process.env.RAILWAY_TEST_CONTOURS;
    if(contourFile) {
      await page.locator("#cardContourFile").setInputFiles(contourFile);
      await page.waitForFunction(()=>CardMap.hasContours);
    }
    await page.evaluate(()=>{setWorkspaceOpen(false);showStationBoard("北京西");});
    const board=page.locator("#infoContent .station-directory");
    await board.locator("summary").filter({hasText:/^京九线 ·/}).click();
    await page.waitForFunction(()=>LineFocus.active?.title==="京九线" && LineFocus.active.parts.length>0);
    await board.getByRole("button",{name:/地图查看沿线站点/}).click();
    await page.waitForFunction(()=>LineFocus.active?.parts.length>0 && state.map.getZoom()<10);
    const directory=await page.evaluate(()=>({stops:LineFocus.active.stops.length,parts:LineFocus.active.parts.length,
      note:LineFocus.active.note,backgroundOpacity:getComputedStyle(state.map.getPane("overlayPane")).opacity}));
    assert.ok(+directory.backgroundOpacity<0.4);
    await page.screenshot({path:path.join(output,"directory-focus.png")});
    await board.locator("summary").filter({hasText:/^京西联络线 ·/}).click();
    await page.waitForFunction(()=>LineFocus.active?.title==="京西联络线" && !LineFocus.active.note.includes("读取"));
    await page.locator("#closeInfo").click();
    await page.waitForFunction(()=>!LineFocus.active && getComputedStyle(state.map.getPane("overlayPane")).opacity==="1");

    // Find a genuine rendered hit point away from station symbols, using the
    // loaded city geometry. Dispatch a pointer click through the browser.
    const expected=await page.evaluate(async()=>{
      const city=state.metroCities.find(c=>c.id==="beijing");
      await loadMetroCity(city);
      const line=state.metroCityLayers.get("beijing").routeLines.find(e=>e.route.ref==="15");
      const part=line.line.getLatLngs().reduce((a,b)=>a.length>b.length?a:b);
      const point=part[Math.floor(part.length/3)];
      state.map.setView(point,14,{animate:false});refreshMetroDetailVisibility();
      return {lat:point.lat,lng:point.lng};
    });
    await page.waitForTimeout(350);
    const xy=await page.evaluate(p=>{
      const v=state.map.latLngToContainerPoint(p),r=state.map.getContainer().getBoundingClientRect();return [r.x+v.x,r.y+v.y];
    },expected);
    await page.mouse.click(...xy);
    await page.waitForFunction(()=>state.selectedMetroRoute?.route.ref==="15" && LineFocus.active?.stops.length>0);
    const metro=await page.evaluate(()=>({title:LineFocus.active.title,parts:LineFocus.active.parts.length,stops:LineFocus.active.stops.length}));
    await page.screenshot({path:path.join(output,"metro-focus.png")});
    await page.locator("[data-metro-stop]").first().click();
    await page.waitForFunction(()=>!!state.selectedMetroStation && !!LineFocus.active);
    await page.locator("#clearLineFocus").click();
    await page.waitForFunction(()=>!LineFocus.active);

    const passenger={train:"G337",from:"石家庄",to:"武汉",date:"2026-11-25"};
    await page.evaluate(journey=>{
      setWorkspaceView("experiences");setWorkspaceOpen(true);setExperiencePage("passport");
      state.journeys=[{...journey,status:"travelled"}];renderPassport();
    },passenger);
    const section=page.locator("#passportList .passenger-map");
    await section.locator("summary").click();
    await section.locator("canvas").waitFor();
    const passport=await section.locator("[role=status]").textContent();
    assert.equal(passport,"石家庄 → 郑州东 → 武汉"+(contourFile?"":" · 沿线城市及海岸"));
    const cards=[];
    for (const [train,from,to] of [["G337","石家庄","武汉"],["Z58","北京西","三亚"],["S8140","海口东","海口"]]) {
      const result=await page.evaluate(async({train,from,to})=>{
        setWorkspaceView("experiences");setWorkspaceOpen(true);setExperiencePage("postcard");
        const start=performance.now();
        for(const [id,value] of Object.entries({postcardTrain:train,postcardFrom:from,postcardTo:to,postcardDate:"2026-11-25",postcardStyle:"map"})) $(id).value=value;
        await refreshPostcard();
        if(!cardRoute) throw Error($("postcardStatus").textContent);
        const canvas=$("postcardPreview");
        const scratch=document.createElement("canvas");scratch.width=640;scratch.height=360;
        const ctx=scratch.getContext("2d");
        const labels=CardMap.draw(ctx,cardRoute,[23,52,594,243],"#267c73","#e8eee9",3);
        const png=await new Promise(resolve=>canvas.toBlob(async b=>resolve(await b.arrayBuffer())));
        return {labels,ms:Math.round(performance.now()-start),bytes:png.byteLength,size:[canvas.width,canvas.height]};
      },{train,from,to});
      assert.ok(result.labels.includes(from) && result.labels.includes(to));
      if (train==="G337") for (const place of contourFile?["河北省","河南省","湖北省","郑州"]:["郑州"]) assert.ok(result.labels.includes(place),`${place}: ${result.labels}`);
      if (train==="S8140") for (const place of contourFile?["海南省","秀英"]:["秀英"]) assert.ok(result.labels.includes(place),`${place}: ${result.labels}`);
      assert.ok(result.bytes>1000);
      assert.deepEqual(result.size,[1280,720]);
      const download=page.waitForEvent("download");
      await page.locator("#downloadPostcard").click();
      await (await download).saveAs(path.join(output,`${train}-web.png`));
      cards.push({train,from,to,...result});
    }
    assert.deepEqual(errors,[]);
    const receipt={url,directory,metro,passport,cards};
    fs.writeFileSync(path.join(output,"web.json"),JSON.stringify(receipt,null,2)+"\n");
    console.log(JSON.stringify(receipt));
  } finally {await browser.close();}
}
main().catch(e=>{console.error(e);process.exitCode=1;});
