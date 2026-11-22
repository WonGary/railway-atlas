// Usage: node Scripts/build-station-layouts.mjs YYYY-MM-DD osm-map-1.json ...
import fs from "node:fs";
import {fileURLToPath} from "node:url";
import {createHash} from "node:crypto";
import "../Sources/RailwayAtlas/Resources/station-layouts.js";

const resources=new URL("../Sources/RailwayAtlas/Resources/",import.meta.url);
const [date,...files]=process.argv.slice(2);
if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !files.length) throw Error("Specify the retrieval date and at least one OSM map JSON extract.");
const features=new Map(), sources=[];
for (const path of files) {
  const raw=fs.readFileSync(path), doc=JSON.parse(raw);
  const {minlon,minlat,maxlon,maxlat}=doc.bounds;
  const bounds=[minlon,minlat,maxlon,maxlat];
  const part=StationLayoutOSM.extract(doc);
  sources.push({bounds, url:"https://api.openstreetmap.org/api/0.6/map.json?bbox="+bounds.join(","),
    sha256:createHash("sha256").update(raw).digest("hex"),features:part.length});
  for (const feature of part) features.set(feature.id,feature);
}
const pack={version:1,date,attribution:"© OpenStreetMap contributors",license:"ODbL-1.0",
  licenseURL:"https://www.openstreetmap.org/copyright",sources,features:[...features.values()]};
const dest=new URL("station-layouts.json",resources);
fs.writeFileSync(dest,JSON.stringify(pack)+"\n");
console.log(`${pack.features.length} mapped features in ${fileURLToPath(dest)}`);
