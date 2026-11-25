// Run with --apply to regenerate the city projections after rebuilding OSM snapshots.
// An operator's station order applies to a particular service direction only.
import fs from "node:fs";
import assert from "node:assert/strict";
const root=new URL("../",import.meta.url);
const read=path=>JSON.parse(fs.readFileSync(new URL(path,root)));
const write=(path,data)=>fs.writeFileSync(new URL(path,root),JSON.stringify(data)+"\n");
const index=read("Web/data/metro-index.json"), apply=process.argv.includes("--apply");
const source="https://www.bjsubway.com/station/zjgls/";
const forward=["马连洼","上地软件园","东北旺","龙泽西","回龙观西大街","文华路","回龙观东大街","霍营东","天通苑","太平庄","天通苑东"];
const missingNodes=new Map([["上地软件园",13410014896],["东北旺",13410014897],["龙泽西",13354529561],
  ["回龙观西大街",13410014898],["文华路",13410014899]]);
const raw=read("Sources/RailwayCore/Resources/metro-snapshot-beijing.json");
const nodes=new Map(raw.elements.filter(e=>e.type==="node").map(e=>[e.id,e]));
function restoreDirection(city,route,names) {
  const previous=new Map(route.stops.map(s=>[s.name,s]));
  assert.ok(previous.size>=6 && route.stops.every(s=>names.includes(s.name)));
  route.stops=names.map(name=>{
    if(previous.has(name)) return previous.get(name);
    const node=nodes.get(missingNodes.get(name));
    assert.ok(node?.tags.name===name && node.tags.railway==="station");
    return {id:"node/"+node.id,name,coordinate:[node.lon,node.lat],role:"station"};
  });
  for(const stop of route.stops){
    let station=city.stations.find(s=>s.id===stop.id);
    if(!station){station={id:stop.id,name:stop.name,coordinate:stop.coordinate,routes:[]};city.stations.push(station);}
    if(!station.routes.some(r=>r.id===route.id))
      station.routes.push({id:route.id,name:route.name,ref:route.ref,color:route.color,city:city.name});
  }
  route.stopSource=source;
  route.stopCoverage="operator";
}
// HK and Macao use bilingual endpoint tags and single-language stop names.
const norm=s=>String(s??"").trim().toLowerCase().replace(/[（(].*?[)）]/g,"").replace(/站$/,"").trim();
const aliases=s=>[norm(s),...norm(s).split(/\s+(?=[A-Za-zÀ-ž])|[/／]/u)].filter(Boolean);
const agrees=(a,b)=>aliases(a).some(name=>aliases(b).includes(name));
const reports=[];
for (const meta of index.cities) {
  if (!meta.data) continue;
  const path=`Web/data/metro/${meta.id}.json`, city=read(path);
  for(const route of city.routes) {
    if (meta.id==="beijing" && ["relation/20010805","relation/20010820"].includes(route.id))
      restoreDirection(city,route,route.id==="relation/20010805"?forward:[...forward].reverse());
    if (route.stopCoverage!=="operator") {
      const reasons=[];
      if(route.stops.length<2) reasons.push(route.stops.length ? "只收录一个站" : "没有站序");
      else for(const [field,stop] of [["from",route.stops[0]],["to",route.stops.at(-1)]]) {
        if (route[field] && !agrees(route[field],stop.name)) reasons.push(field==="from"?"首站名称待核":"末站名称待核");
      }
      if(reasons.length){route.stopCoverage="partial";route.stopNote=reasons.join("、");}
      else {delete route.stopCoverage;delete route.stopNote;}
    }
    assert.ok(route.stops.every(stop=>city.stations.some(s=>s.id===stop.id)));
  }
  meta.stationCount=city.stations.length;
  reports.push({city:meta.name,directions:city.routes.length,noStops:city.routes.filter(r=>!r.stops.length).length,
    oneStop:city.routes.filter(r=>r.stops.length===1).length,review:city.routes.filter(r=>r.stopCoverage==="partial").length});
  if(apply)write(path,city);
  else assert.deepEqual(city,read(path),"Regenerate station data for "+meta.id);
}
if(apply)write("Web/data/metro-index.json",index);
else assert.deepEqual(index,read("Web/data/metro-index.json"));
console.table(reports);
