import assert from "node:assert/strict";
import fs from "node:fs";
import "../Sources/RailwayAtlas/Resources/station-layouts.js";
const native = new URL("../Sources/RailwayAtlas/Resources/",import.meta.url);
const web = new URL("../Web/data/",import.meta.url);
for (const filename of ["station-layouts.json","station-layouts.js"])
  assert.deepEqual(fs.readFileSync(new URL(filename,native)),fs.readFileSync(new URL(filename,web)));
const data=JSON.parse(fs.readFileSync(new URL("station-layouts.json",native)));
assert.equal(new Set(data.features.map(f=>f.id)).size,data.features.length);
assert.equal(data.license,"ODbL-1.0");
assert.deepEqual(StationLayoutOSM.minimumZoom,{outline:16,platform:17,passage:18});
function inBox(x,y,r) { return data.features.filter(f=>f.paths[0].some(([lon,lat])=>Math.abs(lon-x)<r && Math.abs(lat-y)<r)); }
const west=inBox(116.3151,39.8935,.008);
assert.ok(west.some(f=>f.id==="way/30680817" && f.kind==="outline" && f.area && f.network==="railway"));
assert.equal(west.filter(f=>f.kind==="platform" && f.area).length,10);
const hujialou=inBox(116.4555,39.922,.002);
assert.equal(hujialou.filter(f=>f.kind==="platform" && f.network==="metro" && !f.area).length,2);
assert.ok(inBox(116.349,39.940,.003).some(f=>f.kind==="passage" && f.level));
const way=(id,coordinates,tags)=>({id,type:"way",tags,geometry:coordinates.map(([lon,lat])=>({lon,lat}))});
const ring=[[0,0],[1,0],[1,1],[0,1],[0,0]];
const pieces=[way(1,ring.slice(0,3),{}),way(2,ring.slice(2).reverse(),{}),way(3,ring.map(([x,y])=>[.2+x*.2,.2+y*.2]),{})];
const multi={type:"relation",id:4,tags:{type:"multipolygon",building:"train_station"},members:pieces.map((p,i)=>({type:"way",ref:p.id,role:i===2?"inner":"outer"}))};
const inside=way(5,[[.6,.6],[.7,.7]],{highway:"corridor"}), hole=way(6,[[.24,.24],[.26,.26]],{highway:"corridor"});
const notPublic=way(7,[[.6,.6],[.7,.7]],{highway:"corridor",access:"private"});
assert.deepEqual(StationLayoutOSM.extract({elements:[...pieces,multi,inside,hole,notPublic]}).map(f=>[f.id,f.paths.length]),[["relation/4",2],["way/5",1]]);
assert.deepEqual(StationLayoutOSM.extract({elements:[pieces[0],multi]}),[]);
assert.throws(()=>StationLayoutOSM.extract({elements:[],remark:"timeout"}));
console.log(`站区检查通过，${data.features.length} 个真实要素，原生与网页资料一致。`);
