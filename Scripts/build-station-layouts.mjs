// Usage: node Scripts/build-station-layouts.mjs YYYY-MM-DD osm-map-1.json ...
import fs from "node:fs";
import {fileURLToPath} from "node:url";
import {createHash} from "node:crypto";
import {basename} from "node:path";
import {cityRequest} from "./station-layout-city.mjs";
import "../Sources/RailwayAtlas/Resources/station-layouts.js";

const resources=new URL("../Sources/RailwayAtlas/Resources/",import.meta.url);
const [date,...files]=process.argv.slice(2);
if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !files.length) throw Error("Specify the retrieval date and at least one OSM map JSON extract.");
const dest=new URL("station-layouts.json",resources);
const prior=fs.existsSync(dest)?JSON.parse(fs.readFileSync(dest,"utf8")):null;
const previousDates=new Map(prior?.sources.map(s=>[s.sha256,s.date || prior.date]));
const features=new Map(), sources=[];
// Detailed station windows retain richer relation and platform-number information on overlap.
const isCity=path=>basename(path).endsWith(".overpass.json");
for (const path of files.toSorted((a,b)=>Number(isCity(b))-Number(isCity(a)))) {
  const raw=fs.readFileSync(path), doc=JSON.parse(raw);
  let source;
  if (isCity(path)) {
    const city=basename(path,".overpass.json");
    const {bounds,url,query}=cityRequest(city);
    if (!doc.osm3s?.timestamp_osm_base || !doc.elements?.length) throw Error(`Missing dated station data for ${city}`);
    source={city,bounds,url,query,osmTimestamp:doc.osm3s.timestamp_osm_base};
  } else {
    const {minlon,minlat,maxlon,maxlat}=doc.bounds;
    const bounds=[minlon,minlat,maxlon,maxlat];
    source={bounds,url:"https://api.openstreetmap.org/api/0.6/map.json?bbox="+bounds.join(",")};
  }
  const part=StationLayoutOSM.extract(doc);
  const sha256=createHash("sha256").update(raw).digest("hex");
  sources.push({...source,date:previousDates.get(sha256) || date,sha256,features:part.length});
  for (const feature of part) features.set(feature.id,feature);
}
const identity=s=>s.city ?? s.url;
const included=new Set(sources.map(identity));
for (const old of prior?.sources ?? [])
  if (!included.has(identity(old))) throw Error(`Missing earlier extract: ${identity(old)}`);
const pack={version:1,date,attribution:"© OpenStreetMap contributors",license:"ODbL-1.0",
  licenseURL:"https://www.openstreetmap.org/copyright",sources,features:[...features.values()]};
fs.writeFileSync(dest,JSON.stringify(pack)+"\n");
for (const filename of ["station-layouts.js","station-layouts.json"])
  fs.copyFileSync(new URL(filename,resources),new URL("../Web/data/"+filename,import.meta.url));
console.log(`${pack.features.length} mapped features in ${fileURLToPath(dest)}`);
