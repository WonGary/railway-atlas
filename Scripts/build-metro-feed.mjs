// Build a content-addressed feed from the same compact OSM archive used by both clients.
import fs from "node:fs";
import path from "node:path";
import {createHash} from "node:crypto";
import {fileURLToPath} from "node:url";

const root=fileURLToPath(new URL("../",import.meta.url));
const input=process.argv[2] || path.join(root,"Web/data/china-metro-overview.json");
const destination=process.argv[3] || path.join(root,"Web/data/metro-updates");
const bytes=fs.readFileSync(input), snapshot=JSON.parse(bytes);
const sha=data=>createHash("sha256").update(data).digest("hex");
const cities=new Map();
for (const record of snapshot.records) {
  if (!cities.has(record.city)) cities.set(record.city,[]);
  cities.get(record.city).push(record);
}
if (snapshot.version!==1 || !cities.size || !snapshot.sourceDate) throw Error("全国概览缺少版本、城市或资料日期");
fs.mkdirSync(destination,{recursive:true});
const chunks=[];
for (const name of [...cities.keys()].sort()) {
  const records=cities.get(name).sort((a,b)=>a.route.id<b.route.id ? -1 : a.route.id>b.route.id ? 1 : 0);
  const data=Buffer.from(JSON.stringify(records)), hash=sha(data);
  const file=path.join(destination,hash+".json");
  if (!fs.existsSync(file)) fs.writeFileSync(file,data);
  else if (sha(fs.readFileSync(file))!==hash) throw Error("已有分块摘要不符");
  chunks.push({city:name,hash,bytes:data.length,count:records.length});
}
const manifest={version:1,sourceDate:snapshot.sourceDate,fetchedAt:snapshot.fetchedAt,snapshotHash:sha(bytes),chunks};
const json=JSON.stringify(manifest)+"\n";
fs.writeFileSync(path.join(destination,"manifest.json.tmp"),json);
fs.renameSync(path.join(destination,"manifest.json.tmp"),path.join(destination,"manifest.json"));
// A local native build must recognize its own edition even after the feed advances.
if (!process.argv[2]) fs.writeFileSync(path.join(root,"Sources/RailwayCore/Resources/national-metro-baseline.json"),json);
console.log(`${chunks.length} 个分块，${snapshot.records.length} 条记录，资料日期 ${snapshot.sourceDate}`);
