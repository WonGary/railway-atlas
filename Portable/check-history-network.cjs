// node Portable/check-history-network.cjs [--data-only | --with-test-hooks]
// Optionally pass a running Web URL; otherwise serve this checkout on loopback.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const {createHash} = require("node:crypto");
const webRoot = path.resolve(__dirname, "../Web");
const {civilDate, decodePath, prepare, phaseAt} = require("../Web/history-network.js");

function dataChecks() {
  const directory = path.join(webRoot, "data/history-network");
  const index = JSON.parse(fs.readFileSync(path.join(directory, "index.json")));
  assert.equal(index.regions.length, 6);
  let verified = 0, vertices = 0;
  for (const item of index.regions) {
    const bytes = fs.readFileSync(path.join(directory, item.file));
    assert.equal(createHash("sha256").update(bytes).digest("hex"), item.sha256);
    const pack = prepare(JSON.parse(bytes));
    const snapshot = fs.readFileSync(path.resolve(__dirname, "../Sources/RailwayCore/Resources", pack.source.snapshot));
    assert.equal(createHash("sha256").update(snapshot).digest("hex"), pack.source.snapshotSHA256);
    const ways = new Map(JSON.parse(snapshot).elements.filter(el => el.type === "way").map(el => [el.id, el]));
    assert.equal(new Set(pack.segments.map(s => s.way)).size, item.segments);
    assert.equal(pack.unknownCount, item.unknown);
    for (const segment of pack.segments) {
      const way = ways.get(segment.way);
      assert.deepEqual(segment.points, way.geometry.map(p => [p.lat, p.lon]));
      for (const [key, value] of Object.entries(segment.tags)) assert.equal(way.tags[key], value);
      assert.equal(phaseAt(segment, pack.dates[0]), null);
      if (segment.opened) assert.equal(phaseAt(segment, segment.opened.date), "opened");
      verified++;
      vertices += segment.points.length;
    }
    const byID = id => pack.segments.find(s => s.way === id);
    if (item.id === "hongkong") {
      assert.equal(phaseAt(byID(4181592), "1998-07-05"), null);
      assert.equal(phaseAt(byID(4181592), "1998-07-06"), "opened");
      assert.equal(phaseAt(byID(26321741), "2026-09-11"), "opened");
      assert.equal(phaseAt(byID(26321741), "2026-09-12", true), null);
    } else if (item.id === "beijing") {
      assert.equal(phaseAt(byID(929145384), "2021-12-30"), null);
      assert.equal(phaseAt(byID(929145384), "2021-12-31"), "opened");
      assert.equal(phaseAt(byID(1028336496), "2021-12-31", true), "unknown");
    } else if (item.id === "qingdao") {
      assert.equal(byID(654109481).opened.date, "2021-12-30");
    } else if (item.id === "macao") {
      assert.equal(phaseAt(byID(909486580), "2021-04-29"), null);
      assert.equal(phaseAt(byID(909486580), "2021-04-30"), "started");
      assert.equal(phaseAt(byID(909486582), "2024-12-02"), "opened");
      assert.equal(phaseAt(byID(1339606703), "2024-12-02", true), "unknown"); // beyond the terminal
    }
  }
  for (const raw of ["before 2021-12", "2018-02-29", "2024-04-31", "2024-00", "2024-13", "20--"]) assert.equal(civilDate(raw), null);
  assert.equal(civilDate("2021"), "2021-12-31");
  assert.equal(civilDate("2024-02"), "2024-02-29");
  assert.throws(() => decodePath("_"));
  console.log(`history data: ${verified} source ways, ${vertices} original vertices, 6 regions verified`);
}

async function withBrowser(run) {
  const {chromium, devices} = require("playwright-core");
  const server = http.createServer((req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    const file = path.resolve(webRoot, "." + (pathname === "/" ? "/index.html" : pathname));
    if (!file.startsWith(webRoot + path.sep) || !fs.statSync(file, {throwIfNoEntry:false})?.isFile()) {
      res.writeHead(404).end(); return;
    }
    const mime = {".js":"application/javascript", ".mjs":"application/javascript", ".json":"application/json",
      ".html":"text/html", ".css":"text/css", ".png":"image/png", ".pbf":"application/octet-stream"};
    res.writeHead(200, {"Content-Type": (mime[path.extname(file)] || "application/octet-stream")});
    fs.createReadStream(file).pipe(res);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    const edge = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge";
    const executablePath = process.env.RAILWAY_BROWSER || (fs.existsSync(edge) ? edge : undefined);
    browser = await chromium.launch({executablePath, args: ["--no-proxy-server"]});
    const url = process.argv.slice(2).find(s => /^https?:\/\//.test(s)) || `http://127.0.0.1:${server.address().port}/`;
    await run({browser, devices, url, testHooks:process.argv.includes("--with-test-hooks")});
  } finally {
    await browser?.close();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

async function exercise({browser, devices, url, testHooks}, phone) {
  const context = await browser.newContext({serviceWorkers: "block", timezoneId: phone ? "America/Los_Angeles" : "Asia/Shanghai",
    ...(phone ? devices["Pixel 7"] : {viewport:{width:1360,height:860}})});
  try {
    const page = await context.newPage();
    const errors = [], packs = new Set();
    page.on("pageerror", e => errors.push(e.message));
    page.on("request", r => { if (r.url().includes("/data/history-network/")) packs.add(new URL(r.url()).pathname.split("/").pop()); });
    await page.route("**/*", route => new URL(route.request().url()).origin === new URL(url).origin ? route.continue() : route.abort());
    if (testHooks) {
      // Only transform the HTTP response for this browser. Release files stay on disk as-is.
      await page.route("**/app.js", async route => {
        const response = await route.fetch();
        let js = await response.text();
        if (!js.includes("RailwayHistoryNetwork.setActive") && !js.includes("RailwayHistoryNetwork?.setActive")) {
          const sync = `RailwayHistoryNetwork.setActive(state.workspaceView === "experiences" && !document.querySelector('[data-experience-page="history"]').hidden, state.map);`;
          js = js.replace(/setLayerVisible\(state\.historyLayer,\s*(?:view === "experiences"|page==="history").*?;\n/g, sync + "\n")
            .replace('if (page === "history") renderHistoryEvent();', "")
            .replace('  $("historyDate").addEventListener("input", renderHistoryEvent);', "")
            .replace("  renderHistoryEvent();\n", "")
            .replace(/  if \(state.historyEvents.length\) \{[^}]+?\}\n/, "");
        }
        await route.fulfill({response, body:js});
      });
      await page.route(url, async route => {
        const response = await route.fetch();
        const html = await response.text();
        await route.fulfill({response, body:html.includes('src="./history-network.js"') ? html :
          html.replace('<script src="./app.js">','<script src="./history-network.js"></script><script src="./app.js">')});
      });
    }
    await page.goto(url, {waitUntil:"domcontentloaded"});
    await page.waitForFunction(() => typeof state !== "undefined" && state.map && state.routes.length);
    const press = selector => phone ? page.locator(selector).tap() : page.locator(selector).click();
    if (await page.locator("#toggleWorkspace").getAttribute("aria-expanded") !== "true") await press("#toggleWorkspace");
    await press('[data-view="experiences"]');
    const camera = () => page.evaluate(() => ({center:state.map.getCenter(), zoom:state.map.getZoom(),
      layers:localStorage.getItem(STORAGE.layers)}));
    const before = await camera();
    await press('[data-experience="history"]');
    const ui = page.locator(".atlas-history-panel"), field = s => ui.locator(`[data-h="${s}"]`);
    const ready = () => page.waitForSelector('.atlas-history-panel[data-state="ready"]');
    await ready();
    assert.deepEqual([...packs].sort(), ["hongkong.json", "index.json"]);
    const tracks = page.locator(".leaflet-atlasHistory-pane path[data-way]");
    const way = id => page.locator(`.leaflet-atlasHistory-pane [data-way="${id}"]`);
    const day = async d => {
      await field("day").fill(d);
      await field("day").dispatchEvent("change");
    };
    assert.equal(await tracks.count(), 0);
    const masked = await page.evaluate(() => Object.entries(state.map.getPanes()).filter(([k]) =>
      !["mapPane","vectorBasemap","basemapShade","atlasHistory"].includes(k)).every(([,el]) => getComputedStyle(el).display === "none"));
    assert.equal(masked, true);
    await day("1998-07-05");
    assert.equal(await way(4181592).count(), 0);
    await day("1998-07-06");
    assert.equal(await way(4181592).getAttribute("data-phase"), "opened");
    await way(4181592).dispatchEvent("click");
    assert.equal(await field("evidence").locator("a").first().getAttribute("href"), "https://www.openstreetmap.org/way/4181592");
    const opened = await tracks.count();
    await field("unknown").check();
    assert.equal(await tracks.locator("xpath=self::*[@data-phase='opened']").count(), opened);
    assert.ok(await tracks.locator("xpath=self::*[@data-phase='unknown']").count() > 0);
    await field("unknown").uncheck();
    await day("2026-09-11");
    assert.equal(await way(26321741).count(), 1);
    await day("2026-09-12");
    assert.equal(await way(26321741).count(), 0);
    await day("1998-07-05");
    assert.equal(await way(4181592).count(), 0);
    // Hold an old response while the user selects another region; it must never replace it.
    let release, began;
    const started = new Promise(resolve => { began = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    await page.route("**/history-network/beijing.json", async route => {
      began(); await held;
      await route.continue().catch(() => {});
    });
    await field("region").selectOption("beijing");
    await started;
    await field("region").selectOption("macao");
    await ready();
    release();
    await day("2021-04-30");
    assert.equal(await way(909486580).getAttribute("data-phase"), "started");
    await day("2024-11-01");
    assert.equal(await way(620888026).getAttribute("data-phase"), "opened");
    await day("2024-12-02");
    assert.equal(await way(909486582).getAttribute("data-phase"), "opened");
    assert.equal(await tracks.count(), 7);
    assert.match(await field("sources").textContent(), /竣工/);
    await ui.getByRole("button",{name:"播放",exact:true}).click();
    await page.waitForFunction(() => document.querySelector('[data-h="day"]').value === "2021-04-30");
    if (phone) await press("#closeWorkspace");
    await page.getByRole("button",{name:"清除回放并恢复地图",exact:true}).click();
    assert.equal(await tracks.count(), 0);
    assert.equal(await page.locator(".atlas-history-hud").count(), 0);
    assert.deepEqual(await camera(), before);
    if (phone) await press("#toggleWorkspace");
    await ui.getByRole("button",{name:"恢复回放"}).click();
    await ready();
    assert.equal(await field("day").inputValue(), "2021-04-30");
    assert.equal(await way(909486580).getAttribute("data-phase"), "started");
    await press('[data-experience="passport"]');
    assert.deepEqual(await camera(), before);
    assert.equal(await page.locator(".atlas-history-map").count(), 0);
    assert.deepEqual(errors, []);
    console.log(`history UI: ${phone ? "phone" : "desktop"}, opening, closure, construction, unknown, source, playback, scrub, race, camera/layers restored; ${testHooks ? "HTTP test hooks" : "checkout hooks"}`);
  } finally { await context.close(); }
}

module.exports = {withBrowser};
if (require.main === module) (async () => {
  dataChecks();
  if (!process.argv.includes("--data-only")) await withBrowser(async options => {
    await exercise(options, false);
    await exercise(options, true);
  });
})().catch(error => { console.error(error); process.exitCode = 1; });
