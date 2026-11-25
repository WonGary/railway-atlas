// node Scripts/build-line-sections.cjs PLAN.json Web/station-directory
// Use only published ride geometry and a contiguous run on one named physical line.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const crypto = require("node:crypto");
const [planFile, directory] = process.argv.slice(2);
const plans = JSON.parse(fs.readFileSync(planFile));
const context = {};
vm.runInNewContext(fs.readFileSync(path.join(directory, "national.js"), "utf8"), context);
const catalog = context.atlasRailDirectory;
const known = new Map(catalog.lines.map(([name, stops]) => [name, new Set(stops.map(s => s[0]))]));
const locations = new Map(catalog.names.map((name, i) => [name, catalog.coordinates[i]]));
const groups = new Map(), seen = new Set();
const read = file => JSON.parse(fs.readFileSync(path.join(directory, "paths", file)));
function decode(encoded) {
  const values = []; let current = 0, shift = 0;
  for (const char of encoded) {
    const n = char.charCodeAt(0) - 63;
    current |= (n & 31) << shift;
    if (n >= 32) { shift += 5; continue; }
    values.push((current >>> 1) ^ -(current & 1));
    current = shift = 0;
  }
  let x = 0, y = 0;
  const points = [];
  for (let i = 0; i < values.length; i += 2) points.push([x += values[i], y += values[i+1]]);
  return points;
}
function encode(points) {
  let result = "", prev = [0, 0];
  for (const point of points) {
    for (let i = 0; i < 2; i++) {
      const delta = point[i] - prev[i];
      let n = (delta << 1) ^ (delta >> 31);
      while (n >= 32) { result += String.fromCharCode(95 + (n & 31)); n >>>= 5; }
      result += String.fromCharCode(63 + n);
    }
    prev = point;
  }
  return result;
}
function addLeg(plan, i, encoded) {
  const start = plan.stops[i], end = plan.stops[i+1];
  const nodes = plan.nodes.slice(start, end+1), lines = plan.lines.slice(start, end);
  const key = JSON.stringify([nodes.map(n => n[0]), lines, encoded]);
  if (seen.has(key)) return;
  seen.add(key);
  const points = decode(encoded);
  if (points.length < 2) return;
  let anchor = 0, vertex = 0;
  for (let j = 1; j < nodes.length; j++) {
    let next = points.length-1;
    if (j < nodes.length-1) {
      const location = locations.get(nodes[j][0]);
      if (!location || !location[0]) continue;
      const cos = Math.cos(location[0]*Math.PI/180);
      let error = (1100/1.112)**2;
      next = -1;
      for (let k = vertex+1; k < points.length-1; k++) {
        const d = ((points[k][0]-location[1]*1e5)*cos)**2+(points[k][1]-location[0]*1e5)**2;
        if (d < error) { error = d; next = k; }
      }
      if (next < 0) continue;
    }
    const name = lines[anchor], a = nodes[anchor][0], b = nodes[j][0];
    if (a !== b && known.get(name)?.has(a) && known.get(name).has(b) &&
        lines.slice(anchor,j).every(l => l === name) && next > vertex) {
      const section = points.slice(vertex,next+1);
      const cos = Math.cos(section[0][1]*Math.PI/180e5);
      let km = 0;
      for (let k = 1; k < section.length; k++)
        km += Math.hypot((section[k][0]-section[k-1][0])*cos,section[k][1]-section[k-1][1])*.00111195;
      if (Math.abs(km-Math.abs(nodes[j][1]-nodes[anchor][1])) <= Math.max(2.5,km*.18)) {
        if (!groups.has(name)) groups.set(name,new Map());
        const entries = groups.get(name), id = JSON.stringify([a,b].sort());
        if (!entries.has(id)) entries.set(id,[a,b,encode(section)]);
      }
    }
    anchor = j; vertex = next;
  }
}
for (const file of Object.values(read("index.json").groups).sort()) {
  const group = read(file);
  for (const rows of Object.values(group.trains)) for (const row of rows) {
    const plan = plans[row.id];
    if (plan && plan.stops.length === row.s.length)
      row.p.forEach((idx,i) => { if (idx >= 0) addLeg(plan,i,group.paths[idx]); });
  }
}
const output = path.join(directory,"lines"), index = {};
fs.mkdirSync(output,{recursive:true});
const buckets = Array.from({length:32},()=>({}));
for (const [name, entries] of [...groups].sort(([a],[b])=>a.localeCompare(b,"en"))) {
  const bucket = crypto.createHash("sha256").update(name).digest()[0] % buckets.length;
  buckets[bucket][name] = [...entries.values()];
}
for (const [i,bucket] of buckets.entries()) {
  const text = JSON.stringify(bucket);
  const file = `${i}-${crypto.createHash("sha256").update(text).digest("hex").slice(0,12)}.json`;
  fs.writeFileSync(path.join(output,file),text);
  for (const name of Object.keys(bucket)) index[name]=file;
}
fs.writeFileSync(path.join(output,"index.json"),JSON.stringify(index));
console.log(`${groups.size} named lines, ${[...groups.values()].reduce((n,e)=>n+e.size,0)} sections`);
