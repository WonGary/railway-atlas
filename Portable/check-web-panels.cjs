// NODE_PATH=<playwright-core directory's parent> node Portable/check-web-panels.cjs
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {createHash} = require("node:crypto");
const {withBrowser} = require("./check-history-network.cjs");

const settingsKey = "railway-atlas-map-settings-v1";
const legacy = {mode:"cached", legendOpacity:.37, statusOpacity:.58, noticeOpacity:.62,
  infoOpacity:.73, inspectorBackgroundOpacity:.84};
const screenshots = process.env.RAILWAY_PANEL_SCREENSHOTS;
const surfaces = [
  ["panel","panelBackgroundOpacity"], ["inspector","inspectorBackgroundOpacity"], ["assistant","assistantOpacity"],
  ["topbar","topbarOpacity"], ["playback","playbackOpacity"], ["legend","legendOpacity"], ["zoom","zoomOpacity"],
  ["coordinates","coordinatesOpacity"], ["scale","scaleOpacity"], ["status","statusOpacity"], ["credits","creditsOpacity"],
  ["info","infoOpacity"], ["lineFocus","lineFocusOpacity"], ["history","historyOpacity"], ["stationDialog","stationDialogOpacity"],
  ["chatHistory","chatHistoryOpacity"], ["favoriteEditor","favoriteEditorOpacity"], ["notice","noticeOpacity"],
  ["mapError","mapErrorOpacity"], ["toast","toastOpacity"], ["shelf","shelfOpacity"]
];

async function exercise({browser,url}, phone) {
  const size = phone ? {width:390,height:844} : {width:1440,height:900};
  const context = await browser.newContext({viewport:size, isMobile:phone, hasTouch:phone, serviceWorkers:"block"});
  const page = await context.newPage();
  page.setDefaultTimeout(5500);
  const errors = [];
  page.on("pageerror",error=>errors.push(error.message));
  await context.route("**/*",r=>r.request().url().startsWith(url) ? r.continue() : r.abort());
  await context.addInitScript(({key,legacy})=>{
    if (!localStorage.getItem(key)) localStorage.setItem(key,JSON.stringify(legacy));
    localStorage.setItem("railway-atlas-favorites",JSON.stringify(["北京西"]));
  },{key:settingsKey,legacy});
  const $ = s=>page.locator(s);
  const press = selector=>phone ? $(selector).tap() : $(selector).click();
  const ready = ()=>page.waitForFunction(()=>typeof state!=="undefined" && state.routes.length && state.map?._loaded && document.querySelector("#mapCoordinates"));
  const prefs = ()=>page.evaluate(()=>structuredClone(AtlasPrefs.value));
  const chip = id=>`#uiShelfItems button[aria-controls="${id}"]`;
  const folded = new Set();
  async function fold(id) {
    await press(`#${id} [data-fold]`);
    await $(`#${id}[data-ui-folded]`).waitFor({state:"attached"});
    assert.equal(await chipCount(id),1,id);
    folded.add(id);
  }
  const chipCount = id=>$(chip(id)).count();
  async function restore(id) {
    await press(chip(id));
    await $(`#${id}`).waitFor();
    assert.equal(await chipCount(id),0,id);
    assert.equal(await $(`#${id}`).getAttribute("data-ui-folded"),null,id);
  }
  async function workspace(view) {
    if (await $("#toggleWorkspace").getAttribute("aria-expanded")!=="true") await press("#toggleWorkspace");
    if (view) await press(`[data-view="${view}"]`);
  }
  async function closeWorkspace() {
    if (await $("#toggleWorkspace").getAttribute("aria-expanded")==="true") await press("#closeWorkspace");
  }
  async function snap(name) {
    if (screenshots) {
      fs.mkdirSync(screenshots,{recursive:true});
      await page.screenshot({path:path.join(screenshots,`${phone?"phone":"desktop"}-${name}.png`)});
    }
  }
  const alpha = (selector,pseudo)=>$(selector).evaluate((el,pseudo)=>{
    const color=getComputedStyle(el,pseudo).backgroundColor;
    return color.startsWith("rgba") ? +color.split(",").at(-1).replace(")","") : 1;
  },pseudo);
  try {
    await page.goto(url,{waitUntil:"domcontentloaded"}); await ready();
    const migrated = await prefs();
    for (const [field,expected] of Object.entries({zoomOpacity:.37,scaleOpacity:.58,coordinatesOpacity:.58,
      creditsOpacity:.58,mapErrorOpacity:.62,toastOpacity:.62,lineFocusOpacity:.73,historyOpacity:.73,
      stationDialogOpacity:.73,chatHistoryOpacity:.73,favoriteEditorOpacity:.73,assistantOpacity:.84,shelfOpacity:.88})) {
      assert.equal(migrated[field],expected,field);
    }
    await workspace("settings");
    assert.equal(await $(".surface-item").count(),surfaces.length);
    for (const [group,field] of surfaces) {
      const before=await prefs();
      await $(`#pref-${field}`).press("End"); // trusted input + change from the actual range
      assert.deepEqual(await prefs(),{...before,[field]:0},field);
      const surface=$(`[data-ui-surface="${group}"]`);
      if (await surface.count()) {
        assert.equal(await surface.getAttribute("data-ui-paint"),"text",group);
        assert.equal(await alpha(`[data-ui-surface="${group}"]`),0,group);
      }
    }
    await page.getByRole("button",{name:"恢复浮窗默认外观"}).click();
    await $("#pref-surfaceMode").selectOption("translucent");
    await $("#pref-mode-zoom").selectOption("text");
    await $("#pref-mode-info").selectOption("text");
    await $("#pref-mode-shelf").selectOption("text");
    await $("#pref-mode-chatHistory").selectOption("text");
    await $("#pref-mode-history").selectOption("glass");
    await $("#pref-scaleOpacity").press("End");
    await $("#pref-surfaceGroupOpacity").press("End");
    assert.equal(await alpha("#mapTopbar"),0);
    await $("#pref-surfaceGroupOpacity").press("Home");
    assert.ok(await alpha("#mapTopbar")>.8);
    const saved=await prefs();
    await page.reload({waitUntil:"domcontentloaded"}); await ready();
    assert.deepEqual(await prefs(),saved);
    assert.equal(await $("#mapZoomTools").getAttribute("data-ui-paint"),"text");
    assert.equal(await alpha("#mapZoomTools .leaflet-control-zoom-in"),0);
    assert.equal(await alpha("#mapScale .leaflet-control-scale-line"),0);
    assert.equal(await $("#mapLegend").getAttribute("data-ui-paint"),"translucent");
    assert.ok(await alpha("#mapLegend")>.85);
    assert.equal(await $("#mapLegend").evaluate(el=>getComputedStyle(el).backdropFilter),"none");

    const zoom=()=>page.evaluate(()=>state.map.getZoom());
    const originalZoom=await zoom();
    await press("#mapZoomTools .leaflet-control-zoom-in");
    await page.waitForFunction(z=>state.map.getZoom()>z && !state.mapZooming,originalZoom);
    await press("#mapZoomTools .leaflet-control-zoom-out");
    await page.waitForFunction(z=>state.map.getZoom()===z && !state.mapZooming,originalZoom);
    const coords=$("#mapCoordinates .map-coordinate-value");
    const previous=await coords.textContent();
    const x=Math.round(size.width*.55), y=Math.round(size.height*.52);
    if (phone) {
      const cdp=await context.newCDPSession(page);
      await cdp.send("Input.dispatchTouchEvent",{type:"touchStart",touchPoints:[{x,y}]});
      for (let i=1;i<=8;i++) await cdp.send("Input.dispatchTouchEvent",{type:"touchMove",touchPoints:[{x:x+i*9,y:y+i*3}]});
      await cdp.send("Input.dispatchTouchEvent",{type:"touchEnd",touchPoints:[]});
      await cdp.detach();
    } else {
      await page.mouse.move(x,y); await page.mouse.down(); await page.mouse.move(x+80,y+24,{steps:8}); await page.mouse.up();
    }
    await page.waitForFunction(old=>document.querySelector(".map-coordinate-value").textContent!==old,previous);
    await page.waitForFunction(()=>{
      const p=state.map.getCenter().wrap(), fields=document.querySelector(".map-coordinate-value").children;
      return fields[0].textContent.startsWith(Math.abs(p.lng).toFixed(4)) && fields[1].textContent.startsWith(Math.abs(p.lat).toFixed(4));
    });
    await fold("mapLegend"); await restore("mapLegend"); // the compact legend has its own fold button
    await press("#mapLegend summary");
    await fold("mapStatus"); await fold("mapLegend"); await restore("mapStatus");
    assert.ok(await $("#mapLegend").getAttribute("data-ui-folded")!==null);
    await restore("mapLegend");
    await press("#mapLegend summary");
    await snap("controls");
    await press("#mapLegend summary"); await fold("mapStatus"); await fold("mapLegend");
    await press("#toggleInfo"); await fold("infoPanel");
    await workspace(); await fold("workspacePanel");
    await fold("mapZoomTools"); await fold("mapCoordinates"); await fold("mapScale"); await fold("mapTopbar");
    await press("#toggleShelf"); assert.equal(await $("#uiShelfItems").isVisible(),false);
    assert.match(await $("#toggleShelf").getAttribute("aria-label"),/8/);
    assert.equal(await alpha("#uiShelf"),0);
    await snap("shelf");
    await press("#toggleShelf");
    if (phone) assert.ok(await $("#uiShelfItems").evaluate(el=>el.scrollWidth>el.clientWidth),"phone shelf scrolls horizontally");
    for (const id of ["mapTopbar","mapScale","mapZoomTools","mapCoordinates","mapLegend","mapStatus","infoPanel"]) await restore(id);
    await press("#closeInfo");
    await restore("workspacePanel"); await closeWorkspace();
    assert.equal(await $("#uiShelf").isVisible(),false);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth),true);

    await workspace("favorites"); await press(".edit-favorite");
    await $("#favoriteCity").fill("保留草稿"); await fold("favoriteEditor"); await restore("favoriteEditor");
    assert.equal(await $("#favoriteCity").inputValue(),"保留草稿");
    await press("#cancelFavoriteNote");
    await fold("workspacePanel");
    assert.equal(await $("#workspaceScrim").isVisible(),false);
    await press("#toggleWorkspace"); assert.equal(await chipCount("workspacePanel"),0);
    await closeWorkspace();
    await press("#toggleAssistant"); await press("#openAssistantHistory");
    assert.equal(await alpha("#assistantHistoryDialog","::backdrop"),0);
    await fold("assistantHistoryDialog"); await restore("assistantHistoryDialog"); await press("#closeAssistantHistory");
    await fold("assistantPanel"); await restore("assistantPanel"); await press("#closeAssistant");
    await press("#toggleInfo"); await fold("infoPanel"); await restore("infoPanel"); await press("#closeInfo");

    await workspace("stations"); await press("#discovery summary"); await $("#discoverySearch").fill("北京");
    await press("#discoveryList button:first-child"); await closeWorkspace();
    const popup=$(".leaflet-popup"); const popupID=await popup.getAttribute("id");
    assert.equal(await alpha(".leaflet-popup-content-wrapper"),0);
    assert.equal(await alpha(".leaflet-popup-tip"),0);
    await fold(popupID); await restore(popupID); await fold(popupID);
    // Selecting a second place must discard the first place's folded chip.
    await workspace("stations"); await $("#discoverySearch").fill("上海");
    await press("#discoveryList button:first-child"); await closeWorkspace();
    await $(chip(popupID)).waitFor({state:"detached"});
    await $(`#${popupID}`).waitFor({state:"detached"}); // Leaflet fades out the retired node.
    await press(".leaflet-popup-close-button");
    await workspace("stations"); await $("#stationSearch").fill("北京西"); await press("#stationBoard");
    await closeWorkspace();
    const board = $("#infoContent .station-directory");
    const line = board.locator("summary").filter({hasText:/^京九线 ·/});
    if (phone) await line.tap(); else await line.click();
    const showLine = board.getByRole("button",{name:/地图查看沿线站点/});
    if (phone) await showLine.tap(); else await showLine.click();
    await page.waitForFunction(()=>LineFocus.active?.title==="京九线" && LineFocus.active.parts.length>0);
    await fold("lineFocusBar"); await restore("lineFocusBar");
    assert.equal(await $("#lineFocusName").textContent(),"京九线");
    await press("#closeInfo");
    await workspace("experiences"); await press('[data-experience="history"]');
    await $('.atlas-history-panel[data-state="ready"]').waitFor(); await closeWorkspace();
    await fold("mapHistoryHUD"); await restore("mapHistoryHUD");
    assert.equal(await $("#mapHistoryHUD").getAttribute("data-ui-paint"),"glass");
    assert.match(await $("#mapHistoryHUD").evaluate(el=>getComputedStyle(el).boxShadow),/inset/);
    await fold("mapHistoryHUD");
    await workspace(); await press('[data-experience="passport"]');
    await $(chip("mapHistoryHUD")).waitFor({state:"detached"});
    await press("#toggleJourney");
    await workspace(); await press("#openStationDialog"); await fold("stationDialog"); await restore("stationDialog"); await press("#closeDialog");
    await closeWorkspace();
    const train=await $("#playbackTrain").textContent();
    await fold("playbackBar"); await restore("playbackBar");
    assert.equal(await $("#playbackTrain").textContent(),train);
    await press("#closePlayback"); await closeWorkspace();

    // Inject provider failures through their normal presentation and exercise their live controls.
    await page.evaluate(()=>showError(Error("离线测试")));
    await fold("mapDataErrorWindow"); await restore("mapDataErrorWindow");
    await page.evaluate(()=>{ $("mapDataError").hidden=true; $("baseLayerWarning").textContent="底图暂不可用"; $("baseLayerWarning").hidden=false; });
    await fold("baseLayerWarningWindow"); await restore("baseLayerWarningWindow");
    await page.evaluate(()=>{ $("baseLayerWarning").hidden=true; showToast("设置已导入"); });
    await fold("appToastWindow"); await restore("appToastWindow"); await fold("appToastWindow");
    await $(chip("appToastWindow")).waitFor({state:"detached"});
    await workspace("settings");
    await $("#pref-mode-coordinates").selectOption("glass");
    const oldFile={name:"legacy.json",mimeType:"application/json",buffer:Buffer.from(JSON.stringify({version:1,mapPreferences:legacy}))};
    await $("#importMapSettings").setInputFiles(oldFile);
    await page.waitForFunction(()=>AtlasPrefs.value.coordinatesOpacity===.58 && !Object.keys(AtlasPrefs.value.surfaceOverrides).length);
    await $("#pref-mode").selectOption("online");
    await press('[data-view="layers"]'); await $("#baseLayer").selectOption("osm");
    await closeWorkspace();
    await fold("basemapCreditLine"); await restore("basemapCreditLine");
    assert.equal(await $("#basemapCreditLine a").first().getAttribute("href"),"https://www.openstreetmap.org/copyright");
    assert.equal(folded.size,20);
    assert.deepEqual(errors,[]);
    console.log(`${size.width}×${size.height}: ${surfaces.length} independent sliders, three modes, persistence/import, actual ${phone?"touch pan/taps":"mouse drag/clicks"}, ${folded.size} fold/restore targets: ${[...folded].join(", ")}`);
  } finally { await context.close(); }
}

async function offline({browser,url}) {
  const context=await browser.newContext();
  try {
    await context.addInitScript(key=>localStorage.setItem(key,JSON.stringify({mode:"cached"})),settingsKey);
    const page=await context.newPage();
    // Seed a stale shell and a retained detail entry before the current worker installs.
    await page.goto(new URL("data/rail/index.json",url).href);
    await page.evaluate(async()=>{
      const old=await caches.open("railway-atlas-web-0.8.17-r12");
      await old.put(new URL("../../index.html",location.href),new Response("old shell"));
      const details=await caches.open("railway-atlas-detail-0.7.0");
      await details.put(new URL("../../retained-detail",location.href),new Response("cached detail"));
    });
    await page.goto(url,{waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>navigator.serviceWorker.controller && document.querySelector("#offlineReady").textContent.includes("已可离线"),null,{timeout:35000});
    const files=["index.html","styles.css","map-preferences.js","history-network.js","map-hit.js"];
    const hashes=await page.evaluate(async files=>{
      const keys=await caches.keys();
      const installed=keys.filter(k=>k.startsWith("railway-atlas-web-"));
      if (installed.length !== 1) throw Error("预期一个已启用的网页缓存，实际为 " + installed.join(", "));
      const shell=await caches.open(installed[0]);
      const hashes={};
      for (const file of files) {
        const bytes=await (await shell.match(new URL(file,location.href))).arrayBuffer();
        hashes[file]=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes)),b=>b.toString(16).padStart(2,"0")).join("");
      }
      return {keys,hashes,detail:await (await caches.match(new URL("retained-detail",location.href))).text()};
    },files);
    assert.equal(hashes.keys.includes("railway-atlas-web-0.8.17-r12"),false);
    assert.equal(hashes.detail,"cached detail");
    for (const file of files) assert.equal(hashes.hashes[file],createHash("sha256").update(fs.readFileSync(path.join(__dirname,"../Web",file))).digest("hex"));
    await context.setOffline(true); await page.reload({waitUntil:"domcontentloaded"});
    await page.waitForFunction(()=>typeof state!=="undefined" && state.routes.length && document.querySelector(".map-coordinate-value")?.textContent);
    await page.locator("#mapCoordinates [data-fold]").click(); await page.locator('#uiShelfItems [aria-controls="mapCoordinates"]').click();
    assert.equal(await page.locator("#mapCoordinates").isVisible(),true);
    console.log(`Service Worker: r12 cache retired, detail retained, ${files.length} installed file hashes match checkout; offline document, trains and coordinate fold/restore passed`);
  } finally { await context.close(); }
}

withBrowser(async options=>{
  if (!process.argv.includes("--offline-only")) {
    await exercise(options,false);
    await exercise(options,true);
  }
  await offline(options);
}).catch(error=>{console.error(error);process.exitCode=1;});
