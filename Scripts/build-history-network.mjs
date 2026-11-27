// node Scripts/build-history-network.mjs [--check]
// Builds exclusively from the versioned snapshots; no network or wall clock.
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {Buffer} from "node:buffer";
import history from "../Web/history-network.js";

const resources = new URL("../Sources/RailwayCore/Resources/", import.meta.url);
const destination = new URL("../Web/data/history-network/", import.meta.url);
const check = process.argv.includes("--check");
const licenseURL = "https://opendatacommons.org/licenses/odbl/1-0/";
const cities = [["hongkong", "香港"], ["beijing", "北京"], ["qingdao", "青岛"], ["jinan", "济南"], ["macao", "澳门"], ["tokyo", "东京"]];
const railways = new Set(["rail", "subway", "light_rail", "tram", "monorail", "narrow_gauge", "funicular"]);
const servicesToSkip = new Set(["siding", "yard", "spur"]);
const dateKeys = ["opening_date", "start_date", "construction:start_date", "end_date", "closure_date"];
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");

function encodePath(points) {
  let lat = 0, lon = 0, encoded = "";
  function append(delta) {
    let n = delta < 0 ? -2 * delta - 1 : 2 * delta;
    while (n >= 32) {
      encoded += String.fromCharCode(95 + n % 32);
      n = Math.floor(n / 32);
    }
    encoded += String.fromCharCode(63 + n);
  }
  for (const point of points) {
    const y = Math.round(point.lat * 1e7), x = Math.round(point.lon * 1e7);
    append(y - lat);
    append(x - lon);
    lat = y;
    lon = x;
  }
  return encoded;
}

// This particular two-stop project has published dates and a verifiable extent.
// Fail the build if the route members, stops or shared geometry have changed.
function hengqin(elements) {
  const get = (type, id) => elements.find(el => el.type === type && el.id === id);
  const relation = get("relation", 18361945);
  const ways = relation.members.filter(m => m.type === "way" && m.role === "").map(m => m.ref);
  const stops = relation.members.filter(m => m.type === "node" && m.role === "stop").map(m => m.ref);
  assert.deepEqual(ways, [909486580, 909486582]);
  assert.deepEqual(stops, [12391564891, 12391564892]);
  const [left, right] = ways.map(id => get("way", id).geometry);
  const [first, last] = stops.map(id => { const {lat, lon} = get("node", id); return {lat, lon}; });
  assert.deepEqual(left[0], first);
  assert.deepEqual(left.at(-1), right[0]);
  assert.deepEqual(right.at(-1), last);
  return {
    name: "横琴站—莲花站", relation: relation.id, stops, ways,
    scope: "横琴站至莲花站之间的两段轨道共用该区间的工程日期。开工月份据竣工报告，逐段施工日未知。车站以外的轨道单独处理。",
    started: {raw: "2021-04", title: "澳门公共建设局 · 竣工及交付记录", url: "https://www.dsop.gov.mo/news/news/3217/"},
    opened: {raw: "2024-12-02", title: "澳门轻轨 · 载客通车公告", url: "https://www.gov.mo/zh-hans/news/795575/"},
    note: {title: "建设发展办公室 · 2021-03-18 动工仪式", url: "https://www.gov.mo/zh-hans/news/330514/"}
  };
}

async function output(file, text) {
  const url = new URL(file, destination);
  if (check) assert.equal(sha256(await readFile(url)), sha256(text), `${file} differs from extractor output`);
  else await writeFile(url, text);
}

async function city(id, title) {
  const snapshot = `metro-snapshot-${id}.json`;
  const bytes = await readFile(new URL(snapshot, resources));
  const {atlas, elements} = JSON.parse(bytes);
  assert.equal(atlas.id, id);
  assert.equal(atlas.license, "ODbL-1.0");
  const source = {...atlas, snapshot, snapshotSHA256: sha256(bytes), licenseURL};
  const names = [], namesByText = new Map();
  const bounds = [[90, 180], [-90, -180]];
  const segments = [];
  for (const el of elements.filter(el => el.type === "way").sort((a, b) => a.id - b.id)) {
    const tags = el.tags || {};
    if (!railways.has(tags.railway) || servicesToSkip.has(tags.service) || !el.geometry || el.geometry.length < 2) continue;
    for (const {lat, lon} of el.geometry) {
      assert.ok(Number.isFinite(lat) && Math.abs(lat) <= 90 && Number.isFinite(lon) && Math.abs(lon) <= 180);
      bounds[0] = [Math.min(bounds[0][0], lat), Math.min(bounds[0][1], lon)];
      bounds[1] = [Math.max(bounds[1][0], lat), Math.max(bounds[1][1], lon)];
    }
    const name = tags["name:zh-Hans"] || tags["name:zh"] || tags.name || "铁路区段";
    if (!namesByText.has(name)) namesByText.set(name, names.push(name) - 1);
    const row = {way: el.id, name: namesByText.get(name), path: encodePath(el.geometry)};
    if (/^#[0-9a-f]{6}$/i.test(tags.colour)) row.colour = tags.colour;
    const dateTags = Object.fromEntries(dateKeys.filter(k => tags[k]).map(k => [k, tags[k]]));
    if (Object.keys(dateTags).length) row.dateTags = dateTags;
    segments.push(row);
  }
  const header = {version: 1, id, title, source, bounds, names, sections: id === "macao" ? [hengqin(elements)] : []};
  const pack = history.prepare({...header, segments});
  const text = `${JSON.stringify(header).slice(0, -1)},"segments":[\n${segments.map(s => JSON.stringify(s)).join(",\n")}\n]}\n`;
  const file = `${id}.json`;
  await output(file, text);
  return {id, title, file, segments: segments.length, opened: segments.length - pack.unknownCount,
    started: pack.segments.filter(s => s.started).length, closed: pack.segments.filter(s => s.closed).length,
    unknown: pack.unknownCount, firstDate: pack.dates[1], lastDate: pack.dates.at(-1), bytes: Buffer.byteLength(text), sha256: sha256(text)};
}

if (!check) await mkdir(destination, {recursive: true});
const regions = [];
for (const [id, title] of cities) regions.push(await city(id, title));
await output("index.json", JSON.stringify({version: 1, copyright: "© OpenStreetMap contributors", license: "ODbL-1.0", licenseURL, regions}, null, 2) + "\n");
console.table(regions.map(({id, segments, opened, started, closed, unknown, bytes}) => ({id, segments, opened, started, closed, unknown, bytes})));
