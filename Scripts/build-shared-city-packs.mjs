// Publish OSM-derived city records. Inputs are public catalogue IDs or quarter-degree cells.
import fs from "node:fs/promises";
import {createHash} from "node:crypto";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import "../Web/metro-source.js";

const exec = promisify(execFile);
const web = new URL("../Web/data/", import.meta.url), output = new URL("city-packs/", web);
const catalog = JSON.parse(await fs.readFile(new URL("metro-index.json", web))).cities;
await fs.mkdir(output, {recursive:true});
const manifestFile = new URL("manifest.json",output);
let manifest;
try { manifest = JSON.parse(await fs.readFile(manifestFile)); }
catch (error) { if (error.code !== "ENOENT") throw error; manifest = {version:1, cities:{}}; }
if (manifest.version !== 1) throw Error("Unsupported city pack manifest");

function area(id) {
  const city = catalog.find(row => row.id === id);
  if (city) return city;
  const match = /^area-(-?\d{1,3})_(-?\d{1,3})$/.exec(id);
  if (match) {
    const cell = MetroSource.cell((Number(match[1])+.5)/4,(Number(match[2])+.5)/4);
    if (cell?.id === id) return cell;
  }
  throw Error("Unknown area ID: " + id);
}

async function upstream(city) {
  let last;
  for (const endpoint of MetroSource.endpoints(city.bounds)) {
    try {
      const {stdout} = await exec("curl",["--fail","--silent","--show-error","--compressed",
        "--max-time","45","--get",endpoint,"--data-urlencode","data="+MetroSource.query(city.bounds)],{maxBuffer:48_000_000});
      return MetroSource.convert(city, JSON.parse(stdout));
    } catch (error) { last=error; }
  }
  throw last;
}

const args=process.argv.slice(2), batch=args.length===1 && args[0]==="--batch";
const ordered=catalog.filter(c=>!c.data).sort((a,b)=>a.id.localeCompare(b.id,"en"));
const start=Math.floor(Date.now()/86400000)*4;
const cities=batch ? Array.from({length:Math.min(4,ordered.length)},(_,i)=>ordered[(start+i)%ordered.length]) : args.map(area);
if (!cities.length || cities.length>12) throw Error("Pass 1–12 public area IDs or --batch");
let changed=false, successes=0;
for (const city of cities) {
  try {
    const detail=await upstream(city), old=manifest.cities[city.id];
    if (!detail.routes.length || !detail.stations.length) {
      console.log(`${city.id}: no route with stops`);
      successes++;
      continue;
    }
    if (old && detail.sourceDate<old.sourceDate) throw Error("Older map source");
    if (old) {
      const previous=JSON.parse(await fs.readFile(new URL(old.hash+".json",output)));
      if (JSON.stringify({...previous,sourceDate:detail.sourceDate})===JSON.stringify(detail)) {
        successes++;
        continue;
      }
    }
    const bytes=Buffer.from(JSON.stringify(detail)+"\n");
    if (bytes.length>32_000_000) throw Error("City pack exceeds 32 MB");
    const hash=createHash("sha256").update(bytes).digest("hex");
    await fs.writeFile(new URL(hash+".json",output),bytes);
    manifest.cities[city.id]={hash,bytes:bytes.length,sourceDate:detail.sourceDate};
    changed=true;
    successes++;
    console.log(city.id,detail.routes.length,detail.stations.length,bytes.length);
  } catch (error) {
    console.error(city.id, String(error.message).split("\n")[0].slice(0,160));
    if (!batch) process.exitCode=1;
  }
}
if (changed) {
  manifest.cities=Object.fromEntries(Object.entries(manifest.cities).sort(([a],[b])=>a.localeCompare(b,"en")));
  const tmp=new URL("manifest.pending",output);
  await fs.writeFile(tmp,JSON.stringify(manifest)+"\n");
  await fs.rename(tmp,manifestFile);
}
if (!successes) process.exitCode=1;
