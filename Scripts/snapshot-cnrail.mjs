// Collect complete public station boards and their line diagrams for offline comparison.
import {execFileSync} from "node:child_process";
import {writeFileSync} from "node:fs";

const names = process.argv.slice(3);
if (!names.length) throw Error("usage: node snapshot-cnrail.mjs OUTPUT.js STATION ...");
const records = {stations:{}, lines:{}, retrieved:new Date().toISOString().slice(0,10)};
const valid = id => /^[a-f0-9]{32}$/.test(id);
function get(path, query={}) {
  const url = new URL(path, "http://cnrail.geogv.org/api/");
  url.search = new URLSearchParams({locale:"zhcn", ...query});
  const text = execFileSync("curl", ["--fail","--silent","--show-error","--max-time","35","--retry","2",url.href],
    {encoding:"utf8",maxBuffer:4000000});
  if (!text.trim() && path.startsWith("stationroute/")) return {};
  const raw = JSON.parse(text);
  if (typeof raw !== "string") return raw;
  const n = raw.charCodeAt(0);
  let decoded = "";
  for (let i=n+1; i<raw.length; i++) decoded += String.fromCharCode(raw.charCodeAt(i)-raw.charCodeAt(1+(i-n-1)%n));
  return JSON.parse(decoded);
}
for (const name of names) {
  const matches = get("search/", {keyword:name}).filter(r=>r.name===name && r.query.startsWith("geo/"));
  if (matches.length !== 1 || !valid(matches[0].query.slice(4))) throw Error(`Ambiguous or missing station ${name}`);
  const id=matches[0].query.slice(4);
  const poi=get(`poi/${id}`), board=get(`stationroute/${id}`);
  const connections=poi.exd?.find(row=>row.view==="station" || !row.view)?.data?.connection || [];
  const lines=connections.filter(row=>valid(row.eid));
  for (const {eid} of lines) {
    if (records.lines[eid]) continue;
    const {data}=get(`feature/${eid}`);
    const diagram=(data.diagram || []).flatMap(([,node,km])=>{
      const label=node?.station || node?.poi || node?.info;
      return label ? [[label,km ?? "",[node.poi,node.info].filter(v=>v && v!==label).join(" · ")]] : [];
    });
    records.lines[eid]=diagram.length ? diagram : (data.stations || []).map(s=>[s.name,s.mileage ?? "",""]);
  }
  if (!Array.isArray(board.list) && !Array.isArray(board.hash) && Object.keys(board).length) {
    console.error(name, "原站未提供班表", Object.keys(board));
  }
  const trains=(board.list || []).map(r=>[r.opid,board.hash[r.from].name,board.hash[r.to].name,
    board.hash[r.from].kid===id ? "始发" : r.arr || "",board.hash[r.to].kid===id ? "终到" : r.dep || "",r.route || ""]);
  records.stations[name]={id,lines:connections.map(x=>[x.linename,x.eid || null]),trains,hasBoard:Array.isArray(board.list),update:board.update || ""};
  console.log(name, connections.length, trains.length);
}
writeFileSync(process.argv[2], "globalThis.atlasGeoGV = " + JSON.stringify(records) + ";\n");
