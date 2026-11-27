const assert = require("node:assert/strict");
const {chromium, devices} = require("playwright-core");

const url = process.argv[2] || "http://127.0.0.1:18782/";
const day = "2026-11-27";
const camera = page => page.evaluate(() => ({
  center: state.map.getCenter(), zoom: state.map.getZoom(),
  offset: state.playbackMarker && state.map.latLngToContainerPoint(state.playbackMarker.getLatLng())
    .distanceTo(state.map.getSize().divideBy(2))
}));

async function exercise(browser, phone) {
  const context = await browser.newContext({
    ...(phone ? devices["Pixel 7"] : {viewport: {width: 1280, height: 850}}),
    locale: "zh-CN", timezoneId: "Asia/Shanghai", serviceWorkers: process.env.RAILWAY_TEST_SHELL ? "allow" : "block"
  });
  try {
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", err => errors.push(err.message));
    const press = selector => phone ? page.locator(selector).tap() : page.locator(selector).click();
    const follow = page.getByRole("checkbox", {name: "跟随列车"});
    const progress = page.locator("#journeyProgress");
    await page.goto(url, {waitUntil: "domcontentloaded", timeout: 60000});
    await page.bringToFront();
    const ready = () => page.waitForFunction(() => typeof state !== "undefined" && state.routes.length && state.map,
      null, {polling: 100, timeout: 60000}).catch(async error => {
      throw Error(`${error.message} (${[...errors, await page.locator("#mapDataError").textContent()].join(" ")})`);
    });
    await ready();
    if (process.env.RAILWAY_TEST_SHELL) {
      await page.waitForFunction(async shell => navigator.serviceWorker.controller &&
        (await caches.keys()).includes(shell), process.env.RAILWAY_TEST_SHELL, {timeout: 90000});
      await page.reload({waitUntil: "domcontentloaded"});
      await ready();
    }
    await press("#toggleWorkspace");
    let before;
    if (phone) {
      await press('[data-view="stations"]');
      await page.locator("#stationSearch").fill("陇南");
      await press("#stationBoard");
      const board = page.locator("#infoContent .station-directory");
      await board.locator("input[type=date]").fill(day);
      await board.locator("input[type=search]").fill("D174");
      await board.locator("summary").filter({hasText: /^D174/}).tap();
      before = await camera(page);
      await board.getByRole("button", {name: "在主地图沿线旅行"}).tap();
    } else {
      await press('[data-view="experiences"]');
      before = await camera(page);
      await press("#toggleJourney");
      await page.locator("#libraryDate").fill(day);
      await page.locator("#libraryTrain").fill("D174");
      await page.locator("#libraryResults button").filter({hasText: /^D174\b/}).first().click();
    }
    await page.waitForFunction(() => state.route?.trip === "880000D17403" && state.route.geometryAvailable);
    assert.equal(await follow.isChecked(), true);
    if (phone) {
      assert.equal(await page.locator("#toggleWorkspace").getAttribute("aria-expanded"), "false");
      await press("#toggleWorkspace");
      await press("#closeWorkspace");
      assert.ok(await progress.isVisible());
    }
    const preview = await camera(page);
    assert.ok(preview.offset > 30, "selection should show the route overview");
    await page.locator("#playbackSpeed").selectOption("1");
    await press("#playJourney");
    const initial = await camera(page);
    assert.ok(initial.offset < 3 && initial.zoom >= preview.zoom, "play should center on the train");
    await page.waitForFunction(() => state.playbackSeconds - Number($("journeyProgress").min) >= 1);
    await page.locator("#playbackSpeed").selectOption("120");
    await page.waitForFunction(center => state.map.distance(center, state.map.getCenter()) > 500 &&
      state.map.latLngToContainerPoint(state.playbackMarker.getLatLng()).distanceTo(state.map.getSize().divideBy(2)) < 24,
      initial.center, {timeout: 15000});
    const moving = await camera(page);
    await press("#playJourney");
    const segment = await page.evaluate(() => {
      const i = state.route.stops.findIndex(stop => stop.name === "陇南");
      const next = state.route.stops[i + 1];
      return {to: next.name, midpoint: (state.route.stops[i].departure + next.arrival) * 30};
    });
    assert.equal(segment.to, "广元");
    await progress.evaluate((input, seconds) => {
      input.value = seconds;
      input.dispatchEvent(new Event("input", {bubbles: true}));
    }, segment.midpoint);
    assert.ok((await camera(page)).offset < 3, "scrubbing while paused should center immediately");
    await press(".leaflet-control-zoom-in");
    await page.waitForFunction(z => !state.mapZooming && state.map.getZoom() > z, moving.zoom);
    const userZoom = (await camera(page)).zoom;
    if (phone) {
      await follow.tap();
    } else {
      const box = await page.locator("#map").boundingBox();
      const x = box.x + box.width * 0.65, y = box.y + box.height * 0.55;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + 90, y + 40, {steps: 12});
      await page.waitForTimeout(100); // Release after the drag to avoid inertial panning.
      await page.mouse.up();
    }
    assert.equal(await follow.isChecked(), false);
    const free = await camera(page);
    await press("#playJourney");
    await page.waitForFunction(t => state.playbackSeconds > t + 120, segment.midpoint);
    await progress.press("End");
    await page.waitForFunction(() => !state.playbackTimer);
    assert.deepEqual((await camera(page)).center, free.center, "free browsing must keep its camera");
    assert.ok((await camera(page)).offset > 50);
    if (phone) await follow.tap(); else await follow.check();
    const resumed = await camera(page);
    assert.ok(resumed.offset < 3 && resumed.zoom === userZoom, "reacquire at the user's zoom");
    await press("#playJourney");
    await page.waitForFunction(() => state.playbackTimer && state.playbackSeconds < Number($("journeyProgress").max) - 60);
    assert.equal((await camera(page)).zoom, userZoom);
    await press("#closePlayback");
    assert.equal(await progress.isVisible(), false);
    const after = await camera(page);
    assert.equal(after.zoom, before.zoom);
    const returnOffset = await page.evaluate(p => state.map.latLngToContainerPoint(p).distanceTo(state.map.getSize().divideBy(2)), before.center);
    assert.ok(returnOffset < 3, `exit camera offset ${returnOffset}px`);
    if (!phone) {
      await press('[data-view="experiences"]');
      await press("#toggleJourney");
      await page.locator("#importTimetable").setInputFiles({
        name: "time-only.json", mimeType: "application/json",
        buffer: Buffer.from(JSON.stringify({train: "TEST", stops: [{station: "甲", departure: 100}, {station: "乙", arrival: 120}]}))
      });
      await page.waitForFunction(() => state.route?.train === "TEST");
      assert.ok(await follow.isDisabled() && await progress.isDisabled() && await page.locator("#playJourney").isDisabled());
    }
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({url, view: phone ? "phone / station board" : "desktop / train search",
      train: "D174", previewZoom: preview.zoom, followZoom: initial.zoom, userZoom,
      movingCameraOffsetPx: moving.offset, reacquiredOffsetPx: resumed.offset, returnOffsetPx: returnOffset}));
  } finally {
    await context.close();
  }
}

(async () => {
  const browser = await chromium.launch({executablePath: process.env.RAILWAY_BROWSER,
    args: process.env.RAILWAY_TEST_DIRECT ? ["--no-proxy-server"] : []});
  try {
    await exercise(browser, false);
    await exercise(browser, true);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
