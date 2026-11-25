// The national timetable names each service by its primary number. Preserve the
// dated alternate numbers from its existing geometry index for searchable trips.
import fs from "node:fs";
const root=new URL("../Web/",import.meta.url), folder=new URL("station-directory/paths/",root);
const index=JSON.parse(fs.readFileSync(new URL("index.json",folder)));
const aliases={};
for(const file of Object.values(index.groups)) {
  const group=JSON.parse(fs.readFileSync(new URL(file,folder)));
  for(const [primary,rows] of Object.entries(group.trains)) for(const row of rows) {
    const periods=row.a.map(([names,start,end])=>[names.filter(n=>n!==primary),start,end]).filter(([names])=>names.length);
    if(periods.length)aliases[row.id]=periods;
  }
}
fs.writeFileSync(new URL("data/journey-aliases.js",root),
  `globalThis.atlasJourneyAliases=${JSON.stringify({edition:index.edition,byTrip:aliases})};\n`);
console.log(Object.keys(aliases).length+" 条排图有分段车次号");
