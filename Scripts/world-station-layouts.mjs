// Download only station features, one regional extract at a time. Never download track geometry.
import fs from "node:fs";
import path from "node:path";
import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import "../Sources/RailwayAtlas/Resources/station-layouts.js";

const regions = {eu:"api",na:"api-na",ca:"api-ca",sa:"api-sa",as:"api-as",af:"api-af",oc:"api-oc"};
const links = seed=>`way(bn.${seed})[highway~"^(steps|footway|pedestrian|corridor)$"](if:t["indoor"] || t["tunnel"] || t["level"] || t["location"]=="underground" || t["highway"]=="corridor");`;
const query = `[out:json][timeout:420];
rel[route=subway]->.routes;
node[railway=subway_entrance]->.gates;
(${links("gates")})->.first; node(w.first)->.joins;
(${links("joins")})->.next;
(wr(r.routes:"platform");wr(r.routes:"platform_entry_only");wr(r.routes:"platform_exit_only");
 wr[railway=platform][subway=yes];wr[public_transport=platform][subway=yes];
 wr[railway=station][station=subway];wr[public_transport=station][subway=yes];
 wr[railway=concourse];wr[public_transport=concourse];wr["area:railway"=concourse];
 .gates;.first;.next;);out geom;`;
const [task,dir,officialInput] = process.argv.slice(2);
if (!dir || !["fetch","build"].includes(task)) throw Error("Usage: world-station-layouts.mjs fetch|build EXTRACT_DIRECTORY");
const root = fileURLToPath(new URL("../",import.meta.url));
const digest = bytes=>createHash("sha256").update(bytes).digest("hex");
const ltaID = "d_b39d3a0871985372d7e1637193335da5";
const ltaFile = officialInput || path.join(dir,"sg-lta-exits.geojson");
const ltaSource = `https://data.gov.sg/datasets/${ltaID}/view`;

function singaporeExits(osmTiles, directories) {
  const bytes = fs.readFileSync(ltaFile), doc = JSON.parse(bytes);
  if (doc.type !== "FeatureCollection" || !doc.features?.length) throw Error("Missing LTA station exits");
  const source = {id:"sg-lta", name:"LTA MRT Station Exit", publisher:"Land Transport Authority, Singapore",
    url:ltaSource, license:"Singapore Open Data Licence 1.0", licenseURL:"https://data.gov.sg/open-data-licence",
    sha256:digest(bytes), records:doc.features.length, tiles:{}};
  const buckets = new Map(), seen = new Set(), matches = [];
  for (const {geometry,properties} of doc.features) {
    const point = geometry?.coordinates || [];
    const [lon,lat] = point;
    const label = /^Exit ([A-Z0-9]+)$/i.exec(properties?.EXIT_CODE)?.[1].toUpperCase();
    if (geometry.type !== "Point" || !(lon>103 && lon<105 && lat>1 && lat<2) || !label ||
        !Number.isSafeInteger(properties.OBJECTID) || seen.has(properties.OBJECTID) || !properties.STATION_NA)
      throw Error("Invalid LTA exit: "+properties.OBJECTID);
    seen.add(properties.OBJECTID);
    const exit = {id:`sg-lta/${properties.OBJECTID}`,kind:"entrance",network:"metro",area:false,paths:[[point]],
      labelAnchors:[point],accessLabel:label,accessTitle:`${properties.STATION_NA} · Exit ${label} · LTA`};
    const x = Math.floor(lon*4), y = Math.floor(lat*4), key = `${y}_${x}`;
    if (!buckets.has(key)) buckets.set(key,[]);
    buckets.get(key).push(exit);
    // A coordinate can be on either side of a tile edge. Match only like-numbered
    // gates within 25 m, or an unsigned point within 4 m. Preserve competing doors.
    for (let j=y-1;j<=y+1;j++) for (let i=x-1;i<=x+1;i++)
      for (const osm of osmTiles.get(`${j}_${i}`) || []) {
        if (osm.kind!=="entrance" || osm.accessLabel && osm.accessLabel!==label) continue;
        const [ox,oy] = osm.paths[0][0];
        const distance = 111320*Math.hypot((ox-lon)*Math.cos(lat*Math.PI/180),oy-lat);
        if (distance <= (osm.accessLabel ? 25 : 4)) matches.push({exit,osm,distance});
      }
  }
  matches.sort((a,b)=>Number(!a.osm.accessLabel)-Number(!b.osm.accessLabel) || a.distance-b.distance ||
    a.exit.id.localeCompare(b.exit.id) || a.osm.id.localeCompare(b.osm.id));
  const matched = new Set();
  for (const {exit,osm} of matches) if (!exit.matchedOSM && !matched.has(osm.id)) {
    exit.matchedOSM = osm.id;
    matched.add(osm.id);
  }
  source.matchedOSM = matched.size;
  for (const [key,features] of [...buckets].sort(([a],[b])=>a.localeCompare(b))) {
    const data = JSON.stringify(features.sort((a,b)=>a.id.localeCompare(b.id)));
    const file = `sg-lta-${key}.${digest(data).slice(0,12)}.json`;
    source.tiles[key] = file;
    for (const directory of directories) fs.writeFileSync(path.join(directory,file),data);
  }
  return source;
}
// Split the two largest extracts so a throttled response can resume between strips.
const parts=Object.entries(regions).flatMap(([region,api])=>{
  const splits=region==="eu"?[-180,0,9,18,180]:region==="as"?[-180,100,114,121,132,180]:[-180,180];
  return splits.slice(1).map((east,i)=>({region,api,key:splits.length===2?region:`${region}-${i}`,
    q:splits.length===2?query:query.replace("[timeout:420];",`[timeout:420][bbox:-89,${splits[i]},89,${east}];`)}));
});
if (task==="fetch") {
  fs.mkdirSync(dir,{recursive:true});
  for (const {key,api,q} of parts) {
    const target=path.join(dir,key+".json");
    if (fs.existsSync(target)) continue;
    const url=`https://ovp.dresel.systems/${api}/interpreter`;
    const bytes=execFileSync("curl",["-fsSL","--compressed","--max-time","600","--max-filesize","96000000",
      "--get","--data-urlencode","data="+q,url],{maxBuffer:96_000_000});
    const doc=JSON.parse(bytes);
    if (!doc.osm3s?.timestamp_osm_base || doc.remark || !doc.elements?.length) throw Error(key+": incomplete extract "+(doc.remark || ""));
    fs.writeFileSync(target,bytes,{flag:"wx"});
    console.log(key,doc.elements.length,bytes.length,doc.osm3s.timestamp_osm_base);
  }
  if (!fs.existsSync(ltaFile)) {
    const get = url=>execFileSync("curl",["-fsSL","--max-time","45","--max-filesize","2000000",url],{maxBuffer:2_000_000});
    const poll = JSON.parse(get(`https://api-open.data.gov.sg/v1/public/api/datasets/${ltaID}/poll-download`));
    const url = new URL(poll.data.url);
    if (url.protocol !== "https:" || !url.hostname.endsWith(".amazonaws.com") ||
        !url.pathname.startsWith("/blobs.data.gov.sg/")) throw Error("Unexpected LTA download host");
    const bytes = get(url.href);
    if (JSON.parse(bytes).type !== "FeatureCollection") throw Error("Invalid LTA GeoJSON");
    fs.writeFileSync(ltaFile,bytes,{flag:"wx"});
  }
} else {
  const groups=new Map(), sources=[], unique=new Map();
  // None of these selectors returns a surface-rail platform unless it belongs to a subway route.
  for (const {key,api,q} of parts) {
    const bytes=fs.readFileSync(path.join(dir,key+".json")), d=JSON.parse(bytes);
    if (d.remark || !d.osm3s?.timestamp_osm_base || !d.elements?.length) throw Error("Incomplete extract: "+key);
    sources.push({region:key,url:`https://ovp.dresel.systems/${api}/interpreter`,query:q,asOf:d.osm3s.timestamp_osm_base,sha256:digest(bytes)});
    for (const e of d.elements) {
      if (!e.tags || e.tags.bus==="yes" && e.tags.subway!=="yes") continue;
      const platform=e.tags.railway==="platform" || e.tags.railway==="platform_edge" || e.tags.public_transport==="platform";
      if (platform) e.tags={...e.tags,subway:"yes"};
      const coord=e.type==="node"?e:e.geometry?.[0] ?? e.members?.find(m=>m.geometry?.length)?.geometry[0];
      if (!coord || !Number.isFinite(coord.lon) || !Number.isFinite(coord.lat)) continue;
      unique.set(e.type+"/"+e.id,{e,coord});
    }
  }
  // Small independent groups avoid running the indoor extractor against a continent of exits.
  for (const {e,coord} of unique.values()) {
    const key=`${Math.floor(coord.lat*4)}_${Math.floor(coord.lon*4)}`;
    if (!groups.has(key)) groups.set(key,[]);
    groups.get(key).push(e);
  }
  const tiles=new Map(), counts={outline:0,platform:0,entrance:0,passage:0,concourse:0}, ids=new Set();
  for (const elements of groups.values()) {
    const features=StationLayoutOSM.extract({elements,osm3s:{timestamp_osm_base:sources.map(s=>s.asOf).sort()[0]}});
    for (const feature of features) {
      if (!(feature.kind in counts) || ids.has(feature.id)) continue;
      ids.add(feature.id); counts[feature.kind]++;
      const coords=feature.paths.flat(), xs=coords.map(p=>p[0]),ys=coords.map(p=>p[1]);
      const x0=Math.floor(4*Math.min(...xs)),x1=Math.floor(4*Math.max(...xs));
      const y0=Math.floor(4*Math.min(...ys)),y1=Math.floor(4*Math.max(...ys));
      if (x1-x0>2 || y1-y0>2) throw Error("Unexpected size for station feature "+feature.id);
      for (let y=y0;y<=y1;y++) for (let x=x0;x<=x1;x++) {
        const key=`${y}_${x}`;
        if (!tiles.has(key)) tiles.set(key,[]);
        tiles.get(key).push(feature);
      }
    }
  }
  const dirs=["Sources/RailwayAtlas/Resources/world-stations","Web/data/world-stations"].map(p=>path.join(root,p));
  for (const directory of dirs) fs.mkdirSync(directory,{recursive:true});
  const previous=dirs.map(directory=>{
    const manifest=path.join(directory,"index.json");
    return fs.existsSync(manifest)?Object.values(JSON.parse(fs.readFileSync(manifest)).tiles):[];
  });
  const index={version:1,cellsPerDegree:4,license:"ODbL-1.0",attribution:"© OpenStreetMap contributors",query,sources,counts,tiles:{}};
  for (const [key,features] of [...tiles].sort(([a],[b])=>a.localeCompare(b))) {
    const bytes=JSON.stringify(features.sort((a,b)=>a.id.localeCompare(b.id)));
    const filename=key+"."+digest(bytes).slice(0,12)+".json";
    index.tiles[key]=filename;
    for (const directory of dirs) fs.writeFileSync(path.join(directory,filename),bytes);
  }
  index.supplements = [singaporeExits(tiles,dirs)];
  for (const directory of dirs) fs.writeFileSync(path.join(directory,"index.json"),JSON.stringify(index)+"\n");
  const active=new Set(Object.values(index.tiles));
  for (const [i,directory] of dirs.entries()) for (const file of previous[i]) {
    const match=/^-?\d+_-?\d+\.([a-f0-9]{12})\.json$/.exec(file);
    if (!active.has(file) && match) {
      const old=path.join(directory,file);
      if (fs.existsSync(old) && digest(fs.readFileSync(old)).startsWith(match[1])) fs.unlinkSync(old);
    }
  }
  console.log(counts,tiles.size+" tiles");
}
