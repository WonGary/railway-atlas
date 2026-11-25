const assert = require("node:assert/strict");
const fs = require("node:fs");
const {chromium} = require("playwright-core");
const baseline = require("../Sources/RailwayCore/Resources/national-metro-baseline.json");
const published = require("../Web/data/metro-updates/manifest.json");

const [site, output] = process.argv.slice(2);
const publicFeed = "https://wongary.github.io/railway-atlas/data/metro-updates/";
const siteFeed = new URL("data/metro-updates/", site).href;
const count = manifest => manifest.chunks.reduce((n, item) => n + item.count, 0);

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.RAILWAY_BROWSER,
    ...(process.env.RAILWAY_TEST_PROXY && {proxy: {server: process.env.RAILWAY_TEST_PROXY, bypass: "127.0.0.1,localhost"}})
  });
  try {
    const context = await browser.newContext({locale: "zh-CN", serviceWorkers: "block"});
    const page = await context.newPage();
    const errors = [], requests = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("request", request => {
      if (request.url().startsWith(publicFeed)) requests.push(request.url().slice(publicFeed.length));
    });
    // Preview builds use the same button as the public site. Only the HTTP origin changes.
    if (siteFeed !== publicFeed) {
      await page.route(publicFeed + "*", async route => {
        const file = route.request().url().slice(publicFeed.length);
        const response = await route.fetch({url: new URL(file, siteFeed).href});
        await route.fulfill({response, headers: {...response.headers(), "access-control-allow-origin": "*"}});
      });
    }
    const ready = () => page.waitForFunction(() => typeof state !== "undefined" &&
      state.metroPolylines.length && document.getElementById("updateNationalMetro")?.disabled === false,
      null, {timeout: 90000});
    const status = () => page.locator("#metroUpdateStatus").textContent();
    async function sync() {
      requests.length = 0;
      await page.locator("#updateNationalMetro").evaluate(button => button.click());
      await ready();
      return {message: await status(), requests: [...requests]};
    }
    await page.goto(site, {waitUntil: "domcontentloaded", timeout: 90000});
    await ready();
    const before = await status();
    assert.match(before, new RegExp(`${baseline.sourceDate}.*${count(baseline)}`));
    const known = new Map(baseline.chunks.map(item => [item.city, item.hash]));
    const changed = published.chunks.filter(item => known.get(item.city) !== item.hash);
    const first = await sync();
    const chunkFiles = changed.map(item => item.hash + ".json");
    assert.deepEqual(first.requests.sort(), ["manifest.json", ...chunkFiles].sort(), first.message);
    assert.ok(first.message.includes(published.sourceDate), first.message);
    assert.equal(await page.evaluate(() => state.metroRecords.length), count(published));
    const repeat = await sync();
    assert.deepEqual(repeat.requests, ["manifest.json"]);
    assert.match(repeat.message, /0 个分块/);
    await page.reload({waitUntil: "domcontentloaded"});
    await ready();
    const reopened = await status();
    assert.match(reopened, new RegExp(`${published.sourceDate}.*${count(published)}`));
    assert.equal(await page.evaluate(() => state.metroRecords.length), count(published));
    assert.deepEqual(errors, []);
    const receipt = {site, before, first: first.message, groups: changed.map(item => item.city),
      bytes: changed.reduce((n, item) => n + item.bytes, 0), repeat: repeat.message, reopened};
    if (output) fs.writeFileSync(output, JSON.stringify(receipt, null, 2) + "\n");
    console.log(JSON.stringify(receipt));
  } finally {
    await browser.close();
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
