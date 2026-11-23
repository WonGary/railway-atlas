import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import {fileURLToPath} from "node:url";
import {join} from "node:path";
import "./check-track.mjs";
import "./check-station-layouts.mjs";
const root = fileURLToPath(new URL("../Web/",import.meta.url));
const text = file=>fs.readFileSync(join(root,file),"utf8");
const json = file=>JSON.parse(text(file));
for (const file of fs.readdirSync(root).filter(file=>file.endsWith(".js"))) new vm.Script(text(file),{filename:file});
const sw = {self:{registration:{scope:"https://example.test/railway-atlas/"},addEventListener(){}},URL};
vm.createContext(sw);vm.runInContext(text("sw.js"),sw);
const files = vm.runInContext("[...files]",sw);
for (const file of files) assert.ok(fs.existsSync(join(root,file)),file);
assert.ok(text("index.html").includes(`id="versionBadge">${vm.runInContext("VERSION",sw)}<`));
const ids = [...text("index.html").matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
assert.equal(new Set(ids).size, ids.length);
const icons = json("manifest.webmanifest").icons;
for (const size of [192,512]) {
  const icon=icons.find(i=>i.sizes===`${size}x${size}`);
  const header=fs.readFileSync(join(root,icon.src));
  assert.equal(header.readUInt32BE(16),size);assert.equal(header.readUInt32BE(20),size);
}
const index=json("data/metro-index.json");
for (const city of index.cities) {
  const detail=json("data/"+city.data);
  assert.equal(detail.id,city.id);assert.equal(detail.routes.length,city.routeCount);assert.equal(detail.stations.length,city.stationCount);
  const routes = new Set(detail.routes.map(r=>r.id)), stations=new Set(detail.stations.map(s=>s.id));
  assert.equal(routes.size,detail.routes.length);assert.equal(stations.size,detail.stations.length);
  for (const station of detail.stations) assert.ok(station.routes.every(r=>routes.has(r.id)));
  for (const route of detail.routes) assert.ok(route.stops.every(s=>stations.has(s.id)));
}
const tiles = json("data/rail/index.json").tiles;
for (const z of [2,4,6]) {
  const path=`data/rail/world-z${z}.json`, data=json(path);
  assert.ok(files.includes(path), `Offline world map Z${z}`);
  assert.equal(data.zoom,z);
  for (const [key,paths] of Object.entries(data.tiles)) {
    assert.ok(key.split("/").every(n=>Number.isInteger(+n) && +n>=0 && +n<2**z));
    assert.ok(paths.length && paths.every(line=>line.length>=4 && line.length%2===0 &&
      line.every(v=>Number.isInteger(v) && v>=0 && v<=data.extent)),key);
  }
  for (const [name,lat,lon] of [["Paris",48.86,2.35],["Chicago",41.88,-87.63],["Buenos Aires",-34.6,-58.4],
    ["Johannesburg",-26.20,28.05],["Sydney",-33.87,151.21],["Delhi",28.64,77.21]]) {
    const side=2**z,x=(lon+180)/360*side,y=(1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)/2*side;
    const paths=data.tiles[`${Math.floor(x)}/${Math.floor(y)}`] || [];
    const px=(x%1)*data.extent,py=(y%1)*data.extent;
    assert.ok(paths.some(line=>line.some((v,i)=>i%2===0 && Math.hypot(v-px,line[i+1]-py)<data.extent/3)),`${name} Z${z}`);
  }
}
const policy={};vm.createContext(policy);vm.runInContext(text("map-preferences.js"),policy);
for (const [tags,expected] of [
  [{railway:"construction","construction:railway":"subway"},["metro","construction"]],
  [{railway:"subway",construction:"yes",maxspeed:80},["metro","construction"]],
  [{railway:"construction",construction:"rail"},["railway","construction"]],
  [{feature:"rail",maxspeed:"350"},["railway","speed350"]],
  [{railway:"rail",usage:"industrial",maxspeed:160},["industrial","freight"]]
]) {
  policy.tags=tags;
  assert.equal(vm.runInContext("JSON.stringify([AtlasPrefs.classify(tags).network,AtlasPrefs.classify(tags).category])",policy),JSON.stringify(expected));
}
assert.equal(tiles.length,12);for (const tile of tiles) assert.ok(fs.existsSync(join(root,"data/rail",tile.file)));
assert.equal(json("data/discovery.json").length,325);
assert.equal(json("data/railway-experience-timetables.json").timetables.find(t=>t.train==="G337").stops.length,7);
console.log(`网页检查通过，${files.length} 项离线资源，${index.cities.length} 城详细站表，${tiles.length} 张铁路概览瓦片。`);
