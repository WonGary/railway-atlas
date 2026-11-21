// node --experimental-sqlite Portable/export-overview.mjs <bundled .railcache> <output directory>
import {DatabaseSync} from "node:sqlite";
import {mkdirSync, writeFileSync} from "node:fs";
import {join} from "node:path";
const [, , input, output] = process.argv;
const db = new DatabaseSync(input, {readOnly:true});
const rows = db.prepare("SELECT z,x,y,data FROM tiles WHERE source=? AND layer=? ORDER BY z,x,y")
  .all("https://openrailwaymap.app", "speed_railway_line_low");
mkdirSync(output, {recursive:true});
const tiles = rows.map(({z,x,y,data}) => {
  const file = `${z}-${x}-${y}.pbf`;
  writeFileSync(join(output, file), data);
  return {z,x,y,file};
});
writeFileSync(join(output, "index.json"), JSON.stringify({date:"2026-11-03", license:"ODbL-1.0", tiles}) + "\n");
db.close();
