const assert = require("node:assert/strict");
const {chromium} = require("playwright-core");

async function main() {
  const browser = await chromium.launch({executablePath:process.env.RAILWAY_BROWSER});
  try {
    const context = await browser.newContext({viewport:{width:1360,height:900}, locale:"zh-CN"});
    const page = await context.newPage();
    const faults = [];
    page.on("pageerror",err=>faults.push(err.message));
    await page.goto(process.argv[2],{waitUntil:"domcontentloaded",timeout:90000});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.corridor && state.map, null, {timeout:90000});
    const panel = page.locator("#infoContent .station-directory");
    async function pick(name) {
      await page.evaluate(station=>{
        const coordinate=atlasRailDirectory.coordinates[atlasRailDirectory.names.indexOf(station)] ||
          pointToLatLng(state.corridor.points[state.corridor.nodes.find(n=>n.name===station).vertex]);
        AtlasPrefs.change("showsStations",true);
        document.getElementById("showRail").checked=true;
        document.getElementById("infoPanel").hidden=true;
        setWorkspaceOpen(false);
        state.map.setView(coordinate,14,{animate:false});
        StationMapBoard.refresh();
      },name);
      const xy=await page.evaluate(station=>{
        const marker=Object.values(state.map._layers).find(layer=>layer instanceof L.CircleMarker &&
          layer.getTooltip()?.getContent()?.textContent===station);
        if (!marker) throw Error("Missing rendered station marker: "+station);
        const rect=state.map.getContainer().getBoundingClientRect();
        const point=state.map.latLngToContainerPoint(marker.getLatLng());
        return [rect.x+point.x,rect.y+point.y];
      },name);
      await page.mouse.click(...xy);
      await page.waitForFunction(station=>document.querySelector("#infoContent [data-station-directory]")?.dataset.stationDirectory===station,name);
      await panel.locator("input[type=date]").fill("2026-11-24");
      await panel.locator("input[type=date]").dispatchEvent("change");
    }
    await pick("北京西");
    assert.match(await panel.innerText(),/350 条记录/);
    await panel.getByRole("button",{name:"末页"}).click();
    assert.match(await panel.innerText(),/第 12 \/ 12 页/);
    await panel.locator("input[type=search]").fill("G337");
    await panel.locator("summary").filter({hasText:/^G337北京西/}).click();
    await panel.getByText(/7 个停站/).waitFor();
    assert.match(await panel.innerText(),/7 个停站/);
    await panel.getByLabel("站表来源").selectOption("original");
    assert.match(await panel.innerText(),/426 条记录/);
    await panel.locator("summary").filter({hasText:"京西联络线"}).click();
    await panel.locator("li").filter({hasText:"杜家坎所"}).waitFor();
    assert.match(await panel.innerText(),/杜家坎所[\s\S]*17 km/);
    await pick("虎门");
    assert.match(await panel.innerText(),/132 条记录/);
    await panel.locator("summary").filter({hasText:"广深港高速线"}).click();
    await panel.locator("li").filter({hasText:"香港西九龙"}).waitFor();
    assert.match(await panel.innerText(),/香港西九龙/);
    await pick("杜家坎所");
    assert.match(await panel.innerText(),/途经线路 · 2/);
    if (process.env.RAILWAY_TEST_LIBRARY) {
      await page.locator("#libraryFile").setInputFiles(process.env.RAILWAY_TEST_LIBRARY);
      await page.waitForFunction(()=>!!RailLibrary.current);
      await page.evaluate(()=>showStationBoard("盐步所"));
      await panel.getByLabel("站表来源").selectOption("local");
      await panel.locator("input[type=date]").fill("2026-11-24");
      await panel.locator("input[type=date]").dispatchEvent("change");
      await panel.locator("input[type=search]").fill("G6580");
      await panel.locator("summary").filter({hasText:/^G6580/}).click();
      await panel.locator("summary").filter({hasText:/经由 .* 段线路/}).click();
      assert.match(await panel.innerText(),/通过 · 时刻未公布/);
      assert.match(await panel.innerText(),/9 个停站/);
    }
    assert.deepEqual(faults,[]);
    console.log("通过地图点选北京西、虎门、杜家坎所，核对末页、G337 全程停站和原站线路所。");
  } finally { await browser.close(); }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
