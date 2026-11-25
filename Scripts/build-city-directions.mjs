// Fetch public OSM city packs, or rebuild China's packs from the national relation archive.
// node Scripts/build-city-directions.mjs <scratch directory> [national-overpass.json national-overview.json]
import fs from "node:fs";
import path from "node:path";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {fileURLToPath} from "node:url";
import "../Web/metro-source.js";
const exec = promisify(execFile), root = fileURLToPath(new URL("../",import.meta.url));
const [scratch, national, overview] = process.argv.slice(2);
const read = f => JSON.parse(fs.readFileSync(f));
const write = (f,d) => fs.writeFileSync(f,JSON.stringify(d)+"\n");
const web = path.join(root,"Web/data"), indexPath = path.join(web,"metro-index.json");
const index = read(indexPath), old = new Map(index.cities.map(c=>[c.id,c]));
const original = new Set(["beijing","hongkong","jinan","macao","qingdao","tokyo"]);
const catalogue = new Map(index.cities.filter(c=>original.has(c.id)).map(c=>[c.name,c]));
const foreign = {巴黎:"paris",伦敦:"london",新加坡:"singapore",首尔:"seoul",纽约:"new-york",柏林:"berlin",
  悉尼:"sydney",圣保罗:"sao-paulo",开罗:"cairo",墨西哥城:"mexico-city",大阪:"osaka",马德里:"madrid",多伦多:"toronto"};
function entry(id,name,lat,lon,country) {
  if (catalogue.has(name) && (!country || country==="中国" || catalogue.get(name).country === country)) return;
  const dx = .32/Math.max(.45,Math.cos(lat*Math.PI/180));
  const bounds = [lat-.27,lon-dx,lat+.27,lon+dx].map(n=>+n.toFixed(4));
  const city = old.get(id) || {id,name,bounds};
  catalogue.set(country && catalogue.has(name) ? `${name} (${country})` : name,{...city,country});
}
for (const [id,name,lat,lon] of read(path.join(root,"Scripts/china-metro-cities.json"))) entry(id,name,lat,lon,"中国");
for (const p of read(path.join(web,"discovery.json")).filter(p=>p.kind==="city")) {
  if (original.has(catalogue.get(p.name)?.id)) continue;
  entry(foreign[p.name] || `city-${Math.round((p.lat+90)*1000)}-${Math.round((p.lon+180)*1000)}`,p.name,p.lat,p.lon,p.country);
}
fs.mkdirSync(scratch,{recursive:true});
async function fetchOSM(key,endpoints,query) {
  const file = path.join(scratch,key+".json");
  if (fs.existsSync(file)) {const d=read(file); if (!d.remark && d.osm3s) return d;}
  for (const url of endpoints) {
    try {
      const {stdout} = await exec("curl",["-fsSL","--compressed","--max-time","58","--get",url,
        "--data-urlencode","data="+query],{maxBuffer:48*1024*1024});
      const d = JSON.parse(stdout);
      if (d.remark || !d.osm3s) throw Error(d.remark || "missing timestamp");
      write(file,d); return d;
    } catch(e) {console.warn(key,url,e.message.slice(0,100));}
  }
  throw Error(key+" could not be fetched");
}
function pack(city,osm) {
  const detail = MetroSource.convert(city,osm);
  if (!detail.routes.length || !detail.stations.length) return;
  const file = `metro/${city.id}.json`;
  write(path.join(web,file),detail);
  Object.assign(city,{data:"./"+file,source:detail.source,sourceDate:detail.sourceDate,
    routeCount:detail.routes.length,stationCount:detail.stations.length});
}
if (national && overview) {
  const source=read(national), rows=read(overview).records, byCity=new Map();
  const routeById=new Map(source.elements.map(e=>["relation/"+e.id,e]));
  for(const row of rows) {
    if(["未归档","氢淞号"].includes(row.city)) continue;
    const line=routeById.get(row.route.id);
    if(!line)continue;
    if(!byCity.has(row.city))byCity.set(row.city,[]);
    byCity.get(row.city).push(line);
  }
  const relations=[...byCity.values()].flat();
  const members=new Map();
  for(let at=0;at<relations.length;at+=160) {
    const ids=relations.slice(at,at+160).map(r=>r.id);
    const response=await fetchOSM(`cn-${source.osm3s.timestamp_osm_base.slice(0,10)}-${ids[0]}`,
      MetroSource.endpoints([25,95,42,123]),
      `[out:json][timeout:40];rel(id:${ids.join(",")})->.r;${MetroSource.memberQuery}`);
    for(const e of response.elements)members.set(`${e.type}/${e.id}`,e);
  }
  for(const [name,lines] of byCity) {
    let city=catalogue.get(name);
    if(original.has(city?.id))continue;
    if(!city) {
      const b=lines[0].bounds;
      if(!b)continue;
      entry("cn-"+lines[0].id,name,(b.minlat+b.maxlat)/2,(b.minlon+b.maxlon)/2,"中国");
      city=catalogue.get(name);
    }
    const used=new Set(lines.flatMap(r=>r.members.map(m=>`${m.type}/${m.ref}`)));
    pack(city,{osm3s:source.osm3s,elements:[...lines,...[...used].map(k=>members.get(k)).filter(Boolean)]});
  }
}
// Two simultaneous requests, with each city fetched only once on subsequent builds.
const seeds = Object.entries(foreign);
async function worker() {
  while(seeds.length) {
    const [name,id]=seeds.shift(), city=catalogue.get(name);
    try {pack(city,await fetchOSM(id,MetroSource.endpoints(city.bounds),MetroSource.query(city.bounds)));}
    catch {console.warn(`${name}保留在线查询入口`);}
  }
}
await Promise.all([worker(),worker()]);
index.cities=[...catalogue.values()].sort((a,b)=>a.name.localeCompare(b.name,"zh-CN"));
index.generatedAt=new Date().toISOString().slice(0,10);
write(indexPath,index);
console.log("城市入口",index.cities.length,"静态详情",index.cities.filter(c=>c.data).length);
