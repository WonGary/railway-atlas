// node Portable/check-rail-games.cjs [--browser | --print-outlines]
// Browser mode additionally needs playwright-core and RAILWAY_BROWSER (or its installed Chromium).
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {pathToFileURL, fileURLToPath} = require("node:url");
const http = require("node:http");
const games = require("../Web/rail-games.js");
require("../Web/station-directory/national.js");
require("../Web/station-directory/paths/manifest.js");

const web = path.join(__dirname, "../Web");
const directory = globalThis.atlasRailDirectory;
const db = games.catalog(directory);
const referenceDate = "2026-11-24";
const examples = ["G1", "G337", "G6580", "D174", "G219", "D2281", "C7311", "D2711",
  "D2196", "C681", "G3471", "D551", "D3523", "D3609", "G8701", "G879"];

function sourceResolver() {
  const context = vm.createContext({URL, document: {baseURI: pathToFileURL(web + "/").href},
    atlasRailDirectory: directory, atlasPathManifest: globalThis.atlasPathManifest,
    fetch: async url => ({ok: true, json: () => JSON.parse(fs.readFileSync(fileURLToPath(url), "utf8"))})});
  for (const file of ["library.js", "station-directory/paths.js"]) {
    vm.runInContext(fs.readFileSync(path.join(web, file), "utf8"), context, {filename: file});
  }
  return vm.runInContext("RailPaths", context);
}

// Project the continuous chain of verified track vertices onto a small anonymous pixel grid.
// Douglas–Peucker keeps bends relative to the final card size. No station-to-station chords are substituted.
function outline(legs) {
  const raw = legs.flat();
  let south = Infinity, north = -Infinity, west = Infinity, east = -Infinity;
  for (const [lat, lon] of raw) {
    south = Math.min(south, lat); north = Math.max(north, lat);
    west = Math.min(west, lon); east = Math.max(east, lon);
  }
  const longitudeScale = Math.cos((north + south) * Math.PI / 360);
  const scale = Math.min(216 / ((east - west) * longitudeScale), 126 / (north - south));
  const points = raw.map(([lat, lon]) => [
    120 + (lon - (east + west) / 2) * longitudeScale * scale,
    75 - (lat - (north + south) / 2) * scale
  ]);
  const keep = new Set([0, points.length - 1]), pending = [[0, points.length - 1]];
  while (pending.length) {
    const [a, b] = pending.pop(), [x, y] = points[a], dx = points[b][0] - x, dy = points[b][1] - y;
    const length2 = dx * dx + dy * dy;
    let error = 0.7 ** 2, index = -1;
    for (let i = a + 1; i < b; i++) {
      const px = points[i][0] - x, py = points[i][1] - y;
      const t = length2 ? Math.max(0, Math.min(1, (px * dx + py * dy) / length2)) : 0;
      const distance2 = (px - t * dx) ** 2 + (py - t * dy) ** 2;
      if (distance2 > error) { error = distance2; index = i; }
    }
    if (index >= 0) { keep.add(index); pending.push([a, index], [index, b]); }
  }
  return Buffer.from([...keep].sort((a, b) => a - b).flatMap(i => points[i].map(Math.round))).toString("base64");
}

async function buildPack() {
  const resolver = sourceResolver(), outlines = [];
  for (const train of examples) {
    const row = db.rows.find(r => r.train === train && db.runs(r, referenceDate));
    assert.ok(row, train);
    const route = await resolver.find({train, date: referenceDate, trip: row.trip});
    assert.ok(route.geometryAvailable, `${train}: ${route.gaps.join(", ")}`);
    assert.ok(route.geometryKinds.every(k => k > 0));
    assert.deepEqual(Array.from(route.stops, s => s.name), row.stops.map((_, i) => db.name(row, i)));
    outlines.push([row.trip, outline(route.legs)]);
  }
  return {edition: db.edition, date: referenceDate, outlines};
}

async function checkGames(pack) {
  const fixed = () => 0.999;
  const box = games.blindTrip(db, "海石湾", "2026-11-25", 52, fixed);
  assert.ok(box);
  assert.equal(box.origin, "2026-11-24");
  assert.equal(box.row.train, "Z230");
  assert.deepEqual(box.row.stops.slice(box.from, box.to + 1).map(stop => db.names[stop[0]]), ["海石湾", "乐都", "平安驿"]);
  assert.equal(box.row.stops[box.to][1] - box.row.stops[box.from][2], 52);
  assert.equal(games.blindTrip(db, "海石湾", "2026-11-25", 10), null);
  assert.equal(games.blindTrip(db, "海石湾", "2035-01-01", 52), null);
  assert.equal(games.blindTrip(db, "无此站", "2026-11-25", 2000), null);
  const fixture = games.catalog({
    edition: referenceDate, names: ["甲", "乙", "丙"], calendars: [["20261124"]],
    trains: [["T1", 0, [[0, 1420, 1420], [1, 1450, 1455], [2, 1492, 1492]], "night"],
      ["T2", 0, [[0, 1420, 1420], [1, 1450, 1400], [2, 1492, 1492]], "invalid"]]
  });
  assert.equal(fixture.rows.length, 1);
  assert.equal(games.blindTrip(fixture, "乙", referenceDate, 60), null);
  assert.equal(games.blindTrip(fixture, "乙", "2026-11-25", 37).origin, referenceDate);
  assert.equal(games.clock(1450), "+1日 00:10");
  assert.equal(games.clock(1450, 1), "00:10");
  assert.equal(games.clock(2905), "+2日 00:25");
  const full = await sourceResolver().find({train: "Z230", date: box.origin, trip: box.row.trip});
  assert.equal(full.legs.slice(box.from, box.to).every(leg => leg.length > 1), true);
  assert.deepEqual(Array.from(sourceResolver().gapsFor(full.stops.slice(box.from, box.to + 1), full.legs.slice(box.from, box.to))), []);
  console.log("PASS blind box: boarding date, overnight, transfer-free ranges, exact time limit and empty results");

  const deck = games.detectiveDeck(db, pack);
  assert.equal(deck.length, examples.length);
  assert.equal(new Set(deck.map(card => card.label)).size, deck.length);
  for (let i = 0; i < deck.length; i++) {
    const {card, choices, clues} = games.detectiveRound(db, deck, null, () => (i + 0.5) / deck.length);
    assert.equal(card, deck[i]);
    assert.ok(card.points.length >= 8);
    assert.ok(card.points.every(([x, y]) => x >= 0 && x < 240 && y >= 0 && y < 150));
    assert.equal(new Set(choices).size, 4);
    assert.ok(choices.includes(card.label));
    assert.equal(clues.length, 3);
    assert.ok(clues.every(clue => !clue.includes(card.row.train) && !clue.includes(card.label)));
    assert.notEqual(games.detectiveRound(db, deck, card, fixed).card, card);
  }
  assert.throws(() => games.detectiveDeck(db, {...pack, edition: "different"}), /版本不同/);
  console.log(`PASS detective: all ${deck.length} anonymous outlines match dated continuous track, choices and clues`);

  for (let i = 0; i < 12; i++) {
    const p = games.makePuzzle(db, referenceDate, () => i / 12);
    assert.deepEqual(p.answer, p.row.stops.slice(p.from, p.to + 1).map(stop => db.names[stop[0]]));
    assert.deepEqual(p.pieces.slice().sort(), p.answer.slice().sort());
    assert.notDeepEqual(p.pieces, p.answer);
    assert.ok(p.answer.length >= 4 && p.answer.length <= 6);
  }
  console.log("PASS puzzle: 12 shuffled contiguous sections checked against their original schedules");

  assert.equal(games.civilDay(Date.parse("2026-11-27T15:59:59Z")), "2026-11-27");
  assert.equal(games.civilDay(Date.parse("2026-11-27T16:00:00Z")), "2026-11-28");
  const reverse = games.catalog({...directory, trains: directory.trains.slice().reverse()});
  const kinds = new Set();
  let overnight = 0;
  for (const day of db.days.concat("2027-04-01")) {
    const t = games.dailyTask(db, day), {row, from, to} = t;
    assert.equal(t.key, games.dailyTask(reverse, day).key);
    assert.ok(db.runs(row, t.origin));
    const expected = t.kind === "dwell" ? row.stops[from][2] - row.stops[from][1] : row.stops[to][1] - row.stops[from][2];
    assert.ok(games.gradeMinutes(t, String(expected)));
    for (const wrong of [expected + 1, "", "3min", "1.0", "-1"]) assert.equal(games.gradeMinutes(t, wrong), false);
    if (t.kind === "ride" && Math.floor(row.stops[to][1] / 1440) > Math.floor(row.stops[from][2] / 1440)) overnight++;
    kinds.add(t.kind);
  }
  assert.ok(overnight > 0);
  assert.deepEqual(kinds, new Set(["ride", "dwell"]));
  assert.equal(games.dailyTask(db, "2027-04-01").origin, db.days.at(-1));
  console.log(`PASS daily: ${db.days.length + 1} challenge dates, both task types, ${overnight} midnight crossings, grading and archived fallback`);
}

// Serve this checkout under a Pages-like prefix. Inject only in the test response.
async function testServer() {
  const prefix = "/railway-atlas/";
  const types = {".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json",
    ".css": "text/css", ".html": "text/html", ".png": "image/png", ".svg": "image/svg+xml", ".wasm": "application/wasm"};
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (!url.pathname.startsWith(prefix)) { res.writeHead(404).end(); return; }
    const file = path.resolve(web, "." + url.pathname.slice(prefix.length - 1), url.pathname.endsWith("/") ? "index.html" : "");
    if (!file.startsWith(web + path.sep) || !fs.statSync(file, {throwIfNoEntry: false})?.isFile()) {
      res.writeHead(404).end(); return;
    }
    res.setHeader("Content-Type", types[path.extname(file)] || "application/octet-stream");
    fs.createReadStream(file).on("error", () => res.destroy()).pipe(res);
  });
  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  return {server, url: `http://127.0.0.1:${server.address().port}${prefix}`};
}

function readTime(text) {
  const match = text.match(/(?:\+(\d+)日 )?(\d{2}):(\d{2})/);
  assert.ok(match, text);
  return Number(match[1] || 0) * 1440 + Number(match[2]) * 60 + Number(match[3]);
}

async function exerciseBrowser(browser, url, pack, phone) {
  const context = await browser.newContext({
    viewport: phone ? {width: 390, height: 844} : {width: 1360, height: 900},
    isMobile: phone, hasTouch: phone, locale: "zh-CN", timezoneId: phone ? "America/Los_Angeles" : "Asia/Shanghai",
    serviceWorkers: "block", acceptDownloads: true
  });
  try {
    await context.route(/^https:\/\//, route => route.abort());
    const page = await context.newPage(), errors = [], gameRequests = [];
    page.setDefaultTimeout(6500);
    page.on("pageerror", e => errors.push(e.message));
    page.on("request", request => {
      if (/\/(?:games\/|station-directory\/paths\/[^/]+\.json)/.test(request.url())) gameRequests.push(request.url());
    });
    await page.clock.setFixedTime(new Date("2026-11-27T16:30:00Z"));
    const openMore = async () => {
      if (await page.locator("#toggleWorkspace").getAttribute("aria-expanded") !== "true") await press(page.locator("#toggleWorkspace"));
      await press(page.locator('[data-view="experiences"]'));
    };
    const press = locator => phone ? locator.tap() : locator.click();
    const tab = id => page.locator(`[data-experience="${id}"]`);
    const panel = id => page.locator(`[data-experience-page="${id}"]`);
    const byName = (locator, name) => locator.getByRole("button", {name, exact: true});
    const open = async id => { await press(tab(id)); assert.ok(await panel(id).isVisible()); return panel(id); };
    async function ready() {
      await page.goto(url, {waitUntil: "domcontentloaded"});
      await page.waitForFunction(() => typeof state !== "undefined" && state.routes.length && state.map);
      await openMore();
    }
    await ready();
    assert.equal(await page.locator('.experience-tab[data-experience^="rail-"]').count(), 4);
    const quiz = await open("quiz"), city = quiz.locator("#quizChoices button");
    assert.ok(await city.count() >= 2);
    await press(city.first());
    assert.match(await quiz.locator("#quizScore").innerText(), /1/);
    await press(byName(quiz, "换一题"));

    let blind = await open("rail-blind");
    const travel = locator => byName(locator, "在主地图沿线旅行");
    await blind.getByLabel("上车站").fill("无此站");
    await press(byName(blind, "抽一段行程"));
    assert.match(await blind.innerText(), /没有符合条件/);
    await blind.getByLabel("上车站").fill("海石湾");
    await blind.getByLabel("上车日期").fill("2026-11-25");
    await blind.getByLabel("最多乘车（分钟）").fill("52");
    await press(byName(blind, "抽一段行程"));
    assert.equal(await blind.locator("ol li").count(), 1);
    assert.doesNotMatch(await blind.innerText(), /Z230|乐都|平安驿/);
    assert.equal(await travel(blind).count(), 0);
    let revealed = 1;
    while (await byName(blind, "揭晓下一站").count()) {
      await press(byName(blind, "揭晓下一站"));
      assert.equal(await blind.locator("ol li").count(), ++revealed);
      assert.ok(revealed <= 3);
    }
    const stations = (await blind.locator("ol li").allTextContents()).map(text => text.trim().split(/\s+/)[0]);
    assert.deepEqual(stations, ["海石湾", "乐都", "平安驿"].slice(0, revealed));
    assert.match(await blind.innerText(), /Z230/);
    assert.match(await blind.innerText(), /始发日 2026-11-24 · 上车日 2026-11-25/);
    // Simulate an uncached train pack going offline, then retry without drawing another box.
    const group = "**/station-directory/paths/*-*.json";
    await page.route(group, r => r.fulfill({status: 503, body: ""}), {times: 1});
    await press(travel(blind));
    await blind.getByText(/暂时无法回放/).waitFor();
    await press(travel(blind));
    await page.waitForFunction(() => state.route?.trip === "650000Z2300K" && state.playbackVisible);
    const ride = await page.evaluate(() => ({
      train: state.route.train, origin: state.route.serviceDate, full: state.route.geometryAvailable,
      stops: state.route.stops.map(s => s.name), legs: state.route.legs.length, playable: !$("playJourney").disabled
    }));
    assert.deepEqual(ride, {train: "Z230", origin: "2026-11-24", full: true, stops: stations, legs: revealed - 1, playable: true});

    await openMore();
    const detective = panel("rail-detective");
    const requestStart = gameRequests.length;
    await page.route("**/games/outlines.json", r => r.fulfill({status: 503, body: ""}), {times: 1});
    await open("rail-detective");
    await press(byName(detective, "重新读取题图"));
    const canvas = detective.getByRole("img", {name: "本题的铁路线形"});
    await canvas.waitFor();
    assert.equal(await detective.locator("ol li").count(), 0);
    assert.equal(await travel(detective).count(), 0);
    const markup = await detective.innerHTML();
    for (const [trip] of pack.outlines) {
      assert.ok(!markup.includes(trip) && !markup.includes(db.byTrip.get(trip).train), "source must not identify the active train");
    }
    assert.ok(!/data-(?:answer|trip|lat|lon)|<title|<svg|<img |<a |<image /.test(markup));
    const originalInk = await canvas.evaluate(node => node.toDataURL());
    const choiceBox = detective.locator(".quiz-choices");
    for (let i = 1; i <= 3; i++) {
      await press(byName(detective, "给我一条线索"));
      assert.equal(await detective.locator("ol li").count(), i);
    }
    assert.ok(await byName(detective, "给我一条线索").isDisabled());
    const clues = await detective.locator("ol").innerText();
    const options = await choiceBox.locator("button").allTextContents();
    const matches = games.detectiveDeck(db, pack).filter(({row, to, label}) =>
      options.includes(label) && clues.includes(`${row.stops.length} 个停站`) &&
      clues.includes(`${row.stops[to][1] - row.stops[0][2]} 分钟`) && clues.includes(db.name(row, Math.floor(to / 2)) + "站"));
    assert.equal(matches.length, 1);
    const answer = matches[0];
    await press(byName(choiceBox, options.find(label => label !== answer.label)));
    assert.match(await detective.innerText(), /对不上/);
    await press(byName(choiceBox, answer.label));
    assert.match(await detective.innerText(), /猜中了/);
    assert.ok((await detective.innerText()).includes(answer.row.train));
    assert.ok(await travel(detective).isVisible());
    await press(byName(detective, "换条线路"));
    assert.equal(await detective.locator("ol li").count(), 0);
    assert.notEqual(await canvas.evaluate(node => node.toDataURL()), originalInk);
    assert.ok(gameRequests.slice(requestStart).every(entry => entry === new URL("games/outlines.json", url).href));

    const puzzle = await open("rail-puzzle");
    const tiles = puzzle.locator(".quiz-choices");
    const pieces = await tiles.locator("button").allTextContents(), help = await puzzle.locator(".panel-note").first().innerText();
    const train = help.match(/拼出 (\S+) 次/)[1], date = help.match(/\d{4}-\d\d-\d\d/)[0];
    const row = db.rows.find(r => r.train === train && db.runs(r, date) && pieces.every(name => r.stops.some(s => db.names[s[0]] === name)));
    assert.ok(row);
    const ordered = row.stops.map(stop => db.names[stop[0]]).filter(name => pieces.includes(name));
    assert.notDeepEqual(ordered, pieces);
    for (const name of pieces) await press(byName(tiles, name));
    await press(byName(puzzle, "核对站序"));
    assert.match(await puzzle.innerText(), /站序没对上/);
    await press(byName(puzzle, `取回${pieces[0]}`));
    while (await byName(puzzle, "撤回一站").isEnabled()) await press(byName(puzzle, "撤回一站"));
    for (const name of ordered) await press(byName(tiles, name));
    await press(byName(puzzle, "核对站序"));
    assert.ok((await puzzle.locator("article").innerText()).includes(ordered.join(" → ")));
    const downloadPromise = page.waitForEvent("download");
    await press(byName(puzzle, "保存完成卡 PNG"));
    const download = await downloadPromise;
    assert.ok(download.suggestedFilename().includes(train));
    const png = fs.readFileSync(await download.path());
    assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    assert.equal(png.readUInt32BE(16), 720);

    let daily = await open("rail-daily");
    async function signature() {
      return [await daily.locator("h3").textContent(), await daily.locator(".panel-note").first().textContent(),
        await daily.locator("p").nth(1).textContent(), ...await daily.locator("li").allTextContents()];
    }
    const original = await signature(), times = original.slice(-2).map(readTime);
    const minutes = times[1] - times[0];
    assert.match(original[0], /2026-11-28/);
    await daily.getByLabel("你的答案（分钟）").fill(String(minutes + 1));
    await press(byName(daily, "提交答案"));
    assert.match(await daily.innerText(), /再核对/);
    await page.reload({waitUntil: "domcontentloaded"});
    await openMore(); daily = await open("rail-daily");
    assert.deepEqual(await signature(), original);
    assert.match(await daily.innerText(), /已试过 1 次/);
    await daily.getByLabel("你的答案（分钟）").fill(String(minutes));
    await press(byName(daily, "提交答案"));
    assert.match(await daily.innerText(), /答对了.*共作答 2 次/);
    await page.reload({waitUntil: "domcontentloaded"});
    await openMore(); daily = await open("rail-daily");
    assert.match(await daily.innerText(), /答对了.*共作答 2 次/);
    await page.clock.setFixedTime(new Date("2026-11-28T16:00:00Z"));
    await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
    assert.match(await daily.locator("h3").innerText(), /2026-11-29/);
    assert.deepEqual(await daily.getByLabel("你的答案（分钟）").inputValue(), "");
    assert.deepEqual(errors, []);
    console.log(`PASS browser ${phone ? "390x844 touch / Los Angeles" : "1360x900 desktop / Shanghai"}: original city quiz, all four games, PNG, Z230 range, retry, reload and day rollover`);
    return original;
  } finally { await context.close(); }
}

async function checkBrowser(pack) {
  const {chromium} = require("playwright-core");
  const {server, url} = await testServer();
  try {
    const browser = await chromium.launch({executablePath: process.env.RAILWAY_BROWSER || undefined});
    try {
      const desktop = await exerciseBrowser(browser, url, pack, false);
      const phone = await exerciseBrowser(browser, url, pack, true);
      assert.deepEqual(phone, desktop, "two fresh browser contexts in different time zones must receive the same daily task");
    } finally { await browser.close(); }
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

async function main() {
  const expected = await buildPack();
  if (process.argv.includes("--print-outlines")) {
    console.log(`{\n  "edition": "${expected.edition}",\n  "date": "${expected.date}",\n  "outlines": [\n` +
      expected.outlines.map(row => "    " + JSON.stringify(row)).join(",\n") + "\n  ]\n}");
    return;
  }
  const pack = JSON.parse(fs.readFileSync(path.join(web, "games/outlines.json"), "utf8"));
  assert.deepEqual(pack, expected, "anonymous drawings must reproduce the dated track geometry");
  await checkGames(pack);
  if (process.argv.includes("--browser")) await checkBrowser(pack);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
