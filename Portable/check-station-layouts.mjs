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
assert.deepEqual(StationLayoutOSM.minimumZoom,{outline:14,concourse:15,platform:15,passage:16,entrance:16});
function inBox(x,y,r) { return data.features.filter(f=>f.paths[0].some(([lon,lat])=>Math.abs(lon-x)<r && Math.abs(lat-y)<r)); }
const west=inBox(116.3151,39.8935,.008);
assert.ok(west.some(f=>f.id==="way/30680817" && f.kind==="outline" && f.area && f.network==="railway"));
assert.equal(west.filter(f=>f.kind==="platform" && f.area).length,10);
const hujialou=inBox(116.4555,39.922,.002);
assert.equal(hujialou.filter(f=>f.kind==="platform" && f.network==="metro" && !f.area).length,2);
assert.ok(hujialou.every(f=>!f.platformLabel));
const dongmen=inBox(121.52885,25.03385,.003);
assert.deepEqual(dongmen.filter(f=>f.network==="metro" && f.kind==="platform" && f.area).map(f=>f.level).sort(),["-2","-3"]);
assert.ok(dongmen.some(f=>f.kind==="outline" && f.area));
assert.ok(inBox(121.5171,25.0477,.003).some(f=>f.kind==="concourse" && f.area && f.name==="車站大廳"));
assert.equal(inBox(116.4960,39.9217,.003).filter(f=>f.kind==="passage").length,4);
assert.equal(inBox(116.4724,39.9218,.002).filter(f=>f.kind!=="entrance").length,0);
const admiralty=inBox(114.166,22.2785,.002).filter(f=>f.kind==="platform");
assert.deepEqual(admiralty.filter(f=>f.area).map(f=>f.platformLabel).sort(),["5/6","7","8"]);
assert.ok(admiralty.filter(f=>f.platformLabel && !f.area).every(f=>admiralty.some(a=>a.id===f.labelOwner)));
const yuen=inBox(114.0347,22.4456,.001).filter(f=>f.kind==="platform" && f.network==="lightRail" && f.area);
assert.deepEqual(yuen.map(f=>f.platformLabel).sort(),["1","2","3","4","5"]);
assert.ok(yuen.every(f=>f.labelAnchors.length===3));
assert.equal(data.features.find(f=>f.id==="way/43045232").network,"railway");
assert.ok(data.sources.every(s=>s.sha256.length===64 && s.date));
assert.ok(inBox(116.349,39.940,.003).some(f=>f.kind==="passage" && f.level));
const way=(id,coordinates,tags)=>({id,type:"way",tags,geometry:coordinates.map(([lon,lat])=>({lon,lat}))});
const ring=[[0,0],[1,0],[1,1],[0,1],[0,0]];
const pieces=[way(1,ring.slice(0,3),{}),way(2,ring.slice(2).reverse(),{}),way(3,ring.map(([x,y])=>[.2+x*.2,.2+y*.2]),{})];
const multi={type:"relation",id:4,tags:{type:"multipolygon",building:"train_station"},members:pieces.map((p,i)=>({type:"way",ref:p.id,role:i===2?"inner":"outer"}))};
const inside=way(5,[[.6,.6],[.7,.7]],{highway:"corridor"}), hole=way(6,[[.24,.24],[.26,.26]],{highway:"corridor"});
const notPublic=way(7,[[.6,.6],[.7,.7]],{highway:"corridor",access:"private"});
assert.deepEqual(StationLayoutOSM.extract({elements:[...pieces,multi,inside,hole,notPublic]}).map(f=>[f.id,f.paths.length]),[["relation/4",2],["way/5",1]]);
assert.deepEqual(StationLayoutOSM.extract({elements:[pieces[0],multi]}),[]);
const numbered={...multi,tags:{type:"multipolygon","area:railway":"platform",local_ref:"2A",ref:"9",light_rail:"yes"}};
const [face]=StationLayoutOSM.extract({elements:[...pieces,numbered]});
assert.equal(face.platformLabel,"2A");
assert.ok(face.labelAnchors.every(([x,y])=>x>=0 && x<=1 && y>=0 && y<=1 && !(x>=.2 && x<=.4 && y>=.2 && y<=.4)));
const tramPoint={type:"node",id:14,lat:.5,lon:.5,tags:{public_transport:"platform",tram:"yes",local_ref:"A"}};
assert.deepEqual(StationLayoutOSM.extract({elements:[tramPoint]}).map(f=>[f.area,f.paths,f.labelAnchors]),[[false,[[[.5,.5]]],[[.5,.5]]]]);
const line=way(13,[[0,0],[0,1]],{public_transport:"platform"});
const route={type:"relation",id:32,tags:{type:"route",route:"monorail",ref:"7"},members:[{type:"way",ref:13,role:"platform"}]};
const [member]=StationLayoutOSM.extract({elements:[line,route]});
assert.equal(member.network,"lightRail");assert.equal(member.platformLabel,undefined);
assert.equal(StationLayoutOSM.extract({elements:[{...tramPoint,tags:{public_transport:"platform",bus:"yes",ref:"1"}}]}).length,0);
assert.throws(()=>StationLayoutOSM.extract({elements:[],remark:"timeout"}));
const onlyPoints=[
  {type:"node",id:70,lat:.5,lon:.5,tags:{railway:"station",station:"subway",ref:"10"}},
  {type:"node",id:71,lat:.5001,lon:.5,tags:{railway:"subway_entrance",ref:"B"}}
];
assert.deepEqual(StationLayoutOSM.extract({elements:onlyPoints}).map(f=>[f.kind,f.accessLabel]),[["entrance","B"]]);
const rel=(id,role)=>({type:"relation",id:91,tags:{type:"route",route:"subway"},members:[{type:"node",ref:id,role}]});
// These station and stopping-point records are listed as platforms by their relations.
for (const [id,tags] of [[294123681,{public_transport:"stop_position",railway:"stop",subway:"yes"}],
                          [7791605887,{public_transport:"station",railway:"station",station:"subway",ref:"A03"}],
                          [71,{railway:"subway_entrance",ref:"B"}]]) {
  assert.ok(StationLayoutOSM.extract({elements:[{type:"node",id,lat:1,lon:2,tags},rel(id,"platform")]}).every(f=>f.kind==="entrance" && !f.platformLabel));
}
const roleOnly={type:"node",id:81,lat:1,lon:2,tags:{local_ref:"2"}};
for (const role of ["platform","platform_entry_only","platform_exit_only"]) {
  const [f]=StationLayoutOSM.extract({elements:[roleOnly,rel(81,role)]});
  assert.deepEqual([f.area,f.paths,f.platformLabel],[false,[[[2,1]]],"2"]);
  assert.ok(StationLayoutOSM.query(1,2,1.01,2.01).includes(`node(r.parents:"${role}")`));
}
for (const [id,name,kind] of [["way/126857011","育新","outline"],["way/152587337","长春桥站","outline"],
                            ["way/596468270","七里堡","outline"],["way/1086183848","浮山所","outline"],
                            ["relation/15525717","岗厦北站","outline"],["way/1343685232","沙河站地面站厅","concourse"]]) {
  assert.ok(data.features.some(f=>f.id===id && f.name===name && f.kind===kind && f.area),name);
}
const qianmen=data.features.find(f=>f.id==="node/1408143367");
assert.deepEqual([qianmen.network,qianmen.kind,qianmen.area,qianmen.paths],["tram","platform",false,[[[116.3917177,39.8968439]]]]);
const hall=way(50,ring,{railway:"concourse"});
assert.deepEqual(StationLayoutOSM.extract({elements:[hall]}).map(f=>[f.id,f.kind,f.area]),[["way/50","concourse",true]]);
assert.equal(StationLayoutOSM.extract({elements:[{...hall,tags:{...hall.tags,access:"private"}}]}).length,0);
assert.throws(()=>StationLayoutOSM.query(20,115,21,116));
const byID=new Map(data.features.map(f=>[f.id,f]));
for (const [id,text,name] of [
  ["node/3450796157","C1","C1 出口"],["node/13446134636","西进","青岛站西进站口"],
  ["node/13446134640","东进","青岛站东进站口"],["way/330398338","→B2","通往 B2 口"]]) {
  const feature=byID.get(id);
  assert.deepEqual([feature.accessLabel,feature.accessTitle],[text,name]);
  assert.ok(feature.labelAnchors.length>0);
}
assert.ok(!byID.has("node/8841911925")); // A named public park gate near Beijing South.
const entrance=(id,tags)=>({type:"node",id,lat:1,lon:1,tags});
const gate=entrance(901,{railway:"subway_entrance",local_ref:"D2",name:"南站D2口"});
const walkway={...way(903,[[1,1],[1.001,1]],{highway:"corridor",local_ref:"3"}),nodes:[901,902]};
let rows=StationLayoutOSM.extract({elements:[gate,walkway]});
assert.equal(rows.find(f=>f.kind==="passage").accessLabel,"3");
for(const t of [{entrance:"service"},{entrance:"emergency"},{access:"private"},{foot:"no"}])
  assert.ok(!StationLayoutOSM.extract({elements:[{...gate,tags:{...gate.tags,...t}}]}).length);
assert.equal(StationLayoutOSM.extract({elements:[entrance(9,{railway:"subway_entrance"})]})[0].accessLabel,"");
assert.equal(rows.find(f=>f.kind==="entrance").paths[0].length,1);
console.log(`站区检查通过，${data.features.length} 个真实要素，原生与网页资料一致。`);
