import {readFileSync, writeFileSync} from "node:fs";
const [, , input, output] = process.argv;
const source = readFileSync(input,"utf8");
const data = [];
for (const line of source.split("\n")) {
  if (!line.trimStart().startsWith(".init(")) continue;
  const row = line.match(/\.init\("([^"]+)", "([^"]+)", (?:"([A-Z]+)"|\.(\w+)), ([-\d.]+), ([-\d.]+)(?:, "([^"]+)")?\)/);
  if (!row) throw Error(`无法读取目录条目 ${line}`);
  const [,name,country,,kind,lat,lon,article] = row;
  data.push({name,country,kind:kind || "city",lat:+lat,lon:+lon,...(article && {article})});
}
writeFileSync(output, JSON.stringify(data)+"\n");
