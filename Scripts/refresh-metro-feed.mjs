// node Scripts/refresh-metro-feed.mjs overpass.json /path/to/RailwayAtlasCheck [feed-directory]
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {execFileSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import {convert} from "./build-national-metro.mjs";
const [source,check,destination]=process.argv.slice(2);
const root=fileURLToPath(new URL("../",import.meta.url));
const directory=destination || path.join(root,"Web/data/metro-updates");
const baseline=path.join(root,"Web/data/china-metro-overview.json");
const bundled=JSON.parse(fs.readFileSync(baseline));
const osm=JSON.parse(fs.readFileSync(source));
const date=osm.osm3s?.timestamp_osm_base?.slice(0,10);
const previous=JSON.parse(fs.readFileSync(path.join(directory,"manifest.json")));
assert.ok(date && date>=previous.sourceDate && !osm.remark,"需要一个完整且不早于发布版本的 OSM 快照");
// Use the shipped source attribution of each relation as the city reference.
// Unassigned/new relations still go through the normal network and name matching.
function reference(type) {
  return {type:"FeatureCollection",features:bundled.records.filter(r=>r.route.tags["atlas:citySource"]?.startsWith(type+":"))
    .map(r=>({properties:{city:r.city,osm_id:r.route.tags.osm_id,network:r.route.tags.network}}))};
}
const {document}=convert(osm,reference("github-reference"),reference("taiwan-reference"));
document.features=document.features.filter(f=>f.geometry);
const temp=fs.mkdtempSync(path.join(os.tmpdir(),"atlas-metro-edition-"));
const geo=path.join(temp,"drawable.geojson"),archive=path.join(temp,"overview.json");
fs.writeFileSync(geo,JSON.stringify(document));
execFileSync(check,["--build-national-overview",geo,archive,date],{stdio:"pipe"});
const next=JSON.parse(fs.readFileSync(archive)), counts=new Map(),oldCounts=new Map();
for(const r of next.records) counts.set(r.city,1+(counts.get(r.city)||0));
for(const c of previous.chunks) oldCounts.set(c.city,c.count);
for(const [city,n] of oldCounts) assert.ok(counts.get(city)>=n*.8,`${city}的线路记录不完整`);
execFileSync(process.execPath,[path.join(root,"Scripts/build-metro-feed.mjs"),archive,directory],{stdio:"inherit"});
const updated=JSON.parse(fs.readFileSync(path.join(directory,"manifest.json")));
const old=new Map(previous.chunks.map(c=>[c.city,c.hash]));
const changes=updated.chunks.filter(c=>c.hash!==old.get(c.city));
console.log(`${changes.length} 个分组变化，${changes.reduce((sum,c)=>sum+c.bytes,0)} 字节`);
console.log(changes.map(c=>c.city).join("、"));
