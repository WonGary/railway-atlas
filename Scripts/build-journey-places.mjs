// node Scripts/build-journey-places.mjs [--check]
import fs from "node:fs";
import assert from "node:assert/strict";
import {prepare} from "../Web/history-network.js";

const web = new URL("../Web/", import.meta.url);
const json = name => JSON.parse(fs.readFileSync(new URL(name, web), "utf8"));
const directory = "station-directory/";
const rows = [], ids = new Set();
function add(kind, name, lat, lon, ref, note, evidence = "") {
  if (!name || !Number.isFinite(lat) || !Number.isFinite(lon) || ids.has(`${kind}:${ref}`)) return;
  ids.add(`${kind}:${ref}`);
  rows.push([kind, name, Math.round(lat * 1e5), Math.round(lon * 1e5), ref, note, evidence]);
}
const geo = json(directory + "card-geography.json");
for (const c of geo.cities) add("city", c.name, c.lat, c.lon, `${c.lat}/${c.lon}`, geo.source);
for (const file of fs.readdirSync(new URL("data/metro/", web)).filter(f => f.endsWith(".json")).sort()) {
  const city = json("data/metro/" + file);
  for (const s of city.stations || []) {
    if (!/^(node|way|relation)\/\d+$/.test(s.id) || !s.coordinate) continue;
    add("metro", s.name, s.coordinate[1], s.coordinate[0], s.id,
      [city.name, ...new Set((s.routes || []).map(r => r.ref).filter(Boolean))].join(" · "));
  }
}
for (const region of json("data/history-network/index.json").regions) {
  const pack = prepare(json("data/history-network/" + region.file));
  for (const s of pack.segments) {
    const event = s.opened || s.started;
    if (!event) continue;
    const p = s.points[Math.floor(s.points.length / 2)];
    add("history", s.section?.name || s.name || `${pack.title}铁路区段`, ...p, `way/${s.way}`,
      [s.started && "开工 " + s.started.raw, s.opened && "开通 " + s.opened.raw, s.closed && "停用 " + s.closed.raw].filter(Boolean).join(" · "),
      event.url || "");
  }
  const original = json("../Sources/RailwayCore/Resources/" + pack.source.snapshot);
  for (const way of original.elements) {
    if (way.type !== "way" || !way.geometry?.length) continue;
    const t = way.tags || {};
    const title = t["bridge:name"] || t["tunnel:name"] ||
      (t.bridge && t.bridge !== "no" && /桥|橋|\bbridge\b/i.test(t.name || "") && t.name) ||
      (t.tunnel && t.tunnel !== "no" && /隧道|\btunnel\b/i.test(t.name || "") && t.name);
    if (!title) continue;
    const p = way.geometry[Math.floor(way.geometry.length / 2)];
    add("landmark", title, p.lat, p.lon, `way/${way.id}`, pack.title);
  }
}
const file = new URL(directory + "journey-places.json", web);
const text = JSON.stringify({version:1, credits:["© OpenStreetMap contributors · ODbL 1.0", geo.source], rows}) + "\n";
if (process.argv.includes("--check")) assert.equal(fs.readFileSync(file, "utf8"), text);
else fs.writeFileSync(file, text);
console.log("journey places", Object.fromEntries([...new Set(rows.map(r=>r[0]))].map(k=>[k,rows.filter(r=>r[0]===k).length])), Buffer.byteLength(text), "bytes");
