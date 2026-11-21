// Read the timetable resources in the official Android download as data.
// A local File and the desktop range reader use the same decoder.
const utf8 = new TextDecoder("utf-8", {fatal:true});
const maximumSize = 100_000_000;
const bad = reason => new Error(`${reason}。原有时刻库已保留。`);
const view = bytes => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
const text = bytes => utf8.decode(bytes);
const clean = value => value.length > 0 && !/[\p{Cc}]/u.test(value);

export function localPackage(file) {
  return {size:file.size, read:async (start,length) => new Uint8Array(await file.slice(start,start+length).arrayBuffer())};
}

export async function desktopPackage() {
  const endpoint = "/timetable-package";
  const head = await fetch(endpoint, {method:"HEAD", cache:"no-store"});
  const size = Number(head.headers.get("content-length")), etag = head.headers.get("etag");
  if (!head.ok || !etag || !Number.isSafeInteger(size) || size <= 0) throw bad("未能读取路路通的文件版本");
  return {size, async read(start,length) {
    const end = start + length - 1;
    const response = await fetch(endpoint, {cache:"no-store",headers:{Range:`bytes=${start}-${end}`,"If-Match":etag}});
    if (response.status !== 206 || response.headers.get("etag") !== etag ||
        response.headers.get("content-range") !== `bytes ${start}-${end}/${size}`) throw bad("下载中断或上游文件已经更新，请重试");
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length !== length) throw bad("时刻资源下载不完整");
    return bytes;
  }};
}

async function resources(source) {
  if (!Number.isSafeInteger(source.size) || source.size < 22 || source.size > maximumSize) throw bad("文件大小超出支持范围");
  const tailLength = Math.min(source.size,65557);
  const tail = await source.read(source.size-tailLength,tailLength), header = view(tail);
  let end = tail.length-22;
  while (end>=0 && !(header.getUint32(end,true)===0x06054b50 && end+22+header.getUint16(end+20,true)===tail.length)) end--;
  if (end<0 || header.getUint32(end+4,true)!==0) throw bad("请选择完整的路路通 APK");
  const count=header.getUint16(end+10,true), size=header.getUint32(end+12,true), start=header.getUint32(end+16,true);
  if (!count || count>30000 || !size || size>4_000_000 || start+size>source.size-tailLength+end) throw bad("安装包目录无效");
  const bytes=await source.read(start,size), directory=view(bytes), selected=[];
  let offset=0, expanded=0;
  for (let index=0; index<count; index++) {
    if (offset+46>size || directory.getUint32(offset,true)!==0x02014b50) throw bad("资源目录不完整");
    const field16 = n => directory.getUint16(offset+n,true), field32 = n => directory.getUint32(offset+n,true);
    const nameSize=field16(28), after=offset+46+nameSize+field16(30)+field16(32);
    if (!nameSize || after>size) throw bad("资源名称无效");
    const name=text(bytes.subarray(offset+46,offset+46+nameSize));
    if (/^res\/(?:[^/]+\/)*(?:[^/]+\.(?:txt|dat)|[^/.]+)$/.test(name)) {
      const entry={name,method:field16(10),crc:field32(16),compressed:field32(20),size:field32(24),offset:field32(42)};
      expanded+=entry.size;
      if ((field16(8)&1) || ![0,8].includes(entry.method) || entry.compressed>4_000_000 ||
          entry.size>8_000_000 || expanded>60_000_000 || entry.offset+30+entry.compressed>start) throw bad("不支持这版时刻资源");
      selected.push(entry);
    }
    offset=after;
  }
  if (offset!==size || !selected.length || selected.length>200 || new Set(selected.map(e=>e.name)).size!==selected.length) throw bad("时刻资源目录不完整");
  // Merge nearby resource entries to avoid a request per resource header.
  selected.sort((a,b)=>a.offset-b.offset);
  const groups=[];
  for (const entry of selected) {
    const limit=Math.min(start,entry.offset+30+new TextEncoder().encode(entry.name).length+512+entry.compressed);
    let group=groups.at(-1);
    if (!group || entry.offset>group.end+2048 || limit-group.start>4_100_000) {
      group={start:entry.offset,end:limit,entries:[]}; groups.push(group);
    }
    group.end=Math.max(group.end,limit); group.entries.push(entry);
  }
  const files=new Map();
  let next=0;
  async function reader() {
    while (next<groups.length) {
      const group=groups[next++];
      const block=await source.read(group.start,group.end-group.start), local=view(block);
      for (const entry of group.entries) {
        const p=entry.offset-group.start;
        if (p+30>block.length || local.getUint32(p,true)!==0x04034b50 || local.getUint16(p+8,true)!==entry.method ||
            (local.getUint16(p+6,true)&1)) throw bad("资源头部无效");
        const n=local.getUint16(p+26,true), extra=local.getUint16(p+28,true), dataAt=p+30+n+extra;
        if (text(block.subarray(p+30,p+30+n))!==entry.name || entry.offset+30+n+extra+entry.compressed>start) throw bad("资源名称或长度不符");
        const packed=dataAt+entry.compressed<=block.length ? block.subarray(dataAt,dataAt+entry.compressed) :
          await source.read(group.start+dataAt,entry.compressed);
        const data=await unpack(packed,entry);
        files.set(entry.name,data);
      }
    }
  }
  await Promise.all([reader(),reader(),reader()]);
  return files;
}

const crcTable=Uint32Array.from({length:256},(_,i)=>{
  for (let bit=0;bit<8;bit++) i=(i>>>1)^((i&1)?0xedb88320:0);
  return i>>>0;
});
async function unpack(bytes,entry) {
  let output=bytes;
  if (entry.method===8) {
    const reader=new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw")).getReader();
    output=new Uint8Array(entry.size);
    let offset=0;
    try {
      for (;;) {
        const {done,value}=await reader.read();
        if (done) break;
        if (offset+value.length>output.length) throw bad("资源解压长度不符");
        output.set(value,offset); offset+=value.length;
      }
      if (offset!==output.length) throw bad("资源解压不完整");
    } finally { await reader.cancel().catch(()=>{}); }
  }
  let crc=0xffffffff;
  for (const byte of output) crc=(crc>>>8)^crcTable[(crc^byte)&255];
  if (output.length!==entry.size || ((crc^0xffffffff)>>>0)!==entry.crc) throw bad("资源校验失败");
  return output;
}

function dateString(number) {
  const digits=String(number);
  if (!/^\d{8}$/.test(digits)) return null;
  const value=`${digits.slice(0,4)}-${digits.slice(4,6)}-${digits.slice(6)}`;
  const time=Date.parse(value+"T00:00:00Z");
  return Number.isFinite(time) && new Date(time).toISOString().slice(0,10)===value ? value : null;
}
function dictionary(bytes) {
  if (bytes.length<2) return;
  const data=view(bytes), count=data.getUint16(0), names=[];
  if (count<=100 || count>30000) return;
  let offset=2;
  for (let i=0;i<count;i++) {
    if (offset+2>bytes.length) return;
    const size=data.getUint16(offset); offset+=2;
    if (!size || size>120 || offset+size>bytes.length) return;
    let value;
    try { value=text(bytes.subarray(offset,offset+size)); } catch { return; }
    if (!clean(value)) return;
    names.push(value); offset+=size;
  }
  if (offset===bytes.length) return names;
}
function services(bytes,trains,stations) {
  const base255 = p => bytes[p]*255+bytes[p+1];
  function civil(p) {
    const digits=bytes.subarray(p,p+4);
    if (digits.some(n=>n>127)) return null;
    return dateString(digits.reduce((sum,n,i)=>sum+(n<<(i*7)),0));
  }
  const rows=[];
  let p=0;
  while (p<bytes.length) {
    if (p+17>bytes.length) return;
    const id=base255(p), count=base255(p+15), validFrom=civil(p+5), validThrough=civil(p+9);
    if (id>=trains.length || count<2 || count>250 || p+17+7*count>bytes.length || !validFrom || !validThrough || validFrom>validThrough) return;
    const stops=[], kilometreMarks=[], flags=[2,3,4,13,14].map(i=>bytes[p+i]);
    let previous=0;
    for (let i=0;i<count;i++) {
      const s=p+17+i*7, station=stations[base255(s)],hour=bytes[s+2],minute=bytes[s+3];
      if (!station || hour>23 || minute>59) return;
      let arrival=hour*60+minute;
      while (arrival<previous) arrival+=1440;
      previous=arrival+bytes[s+4];
      stops.push({station,arrival:i===0?null:arrival,departure:i===count-1?null:previous});
      kilometreMarks.push(base255(s+5));
    }
    rows.push({id,train:trains[id],validFrom,validThrough,flags,stops,kilometreMarks});
    p+=17+count*7;
  }
  return rows;
}
function topology(bytes) {
  const data=view(bytes); let offset=0;
  const uint=()=>{if (offset+4>bytes.length) throw bad("线路表被截断"); offset+=4; return data.getUint32(offset-4);};
  const count=max=>{const n=uint(); if (!n||n>max) throw bad("线路记录数无效"); return n;};
  function string() {
    const n=bytes[offset++];
    if (!n || offset+n>bytes.length) throw bad("线路站名被截断");
    const value=text(bytes.subarray(offset,offset+n)); offset+=n;
    if (!clean(value)) throw bad("线路站名无效");
    return value;
  }
  const lines=Array.from({length:count(5000)},()=>{
    const id=uint(), name=string(), stations=Array.from({length:count(5000)},()=>{
      const name=string(), code=string(); uint();
      const kilometre=uint();
      if (kilometre>100000 && id!==0) throw bad("线路里程无效");
      return {name,code,kilometre};
    });
    return {id,name,stations};
  }).filter(line=>line.id!==0);
  const ids=new Set(lines.map(l=>l.id));
  if (ids.size!==lines.length) throw bad("线路编号重复");
  const routes=Array.from({length:count(100000)},()=>{
    const id=string(), end=string(), parts=Array.from({length:count(1000)},()=>{
      const from=string(), lineID=uint();
      if (!ids.has(lineID)) throw bad("经由线路不存在");
      return {from,lineID};
    });
    if (!/^[\x20-\x7E]{12}$/.test(id)) throw bad("径路编号无效");
    return {id,end,parts};
  });
  if (offset!==bytes.length || new Set(routes.map(r=>r.id)).size!==routes.length) throw bad("径路表不完整");
  return {lines,routes};
}
export async function readPackage(source) {
  const files=await resources(source);
  let trains,stations,edition,routing;
  for (const [path,bytes] of files) {
    if (path.endsWith(".txt") && bytes.length<=40) {
      const date=dateString(new TextDecoder().decode(bytes).trim());
      if (date) edition=date;
    }
    if (bytes.length>18 && new TextDecoder().decode(bytes.subarray(9,18))==="线路名") {
      if (routing) throw bad("存在多份径路表");
      routing=topology(bytes);
    }
    const names=dictionary(bytes);
    if (!names) continue;
    if (names.slice(0,50).every(n=>/^[A-Z0-9/]+$/.test(n))) {
      if (trains) throw bad("车次索引重复");
      trains=names;
    } else if (names.slice(0,50).every(n=>/^\p{Script=Han}+$/u.test(n))) {
      if (stations) throw bad("车站索引重复");
      stations=names;
    }
  }
  if (!trains || !stations || !edition || !routing) throw bad("安装包缺少车次、车站、日期或径路表");
  const rows=new Map();
  for (const [path,bytes] of files) {
    if (!path.endsWith(".dat")) continue;
    for (const row of services(bytes,trains,stations)||[]) {
      if (rows.has(row.id)) throw bad("车次记录重复");
      rows.set(row.id,row);
    }
  }
  if (rows.size!==trains.length) throw bad("时刻库的车次数量不符");
  return {version:1,edition,stationCount:stations.length,services:[...rows.values()].sort((a,b)=>a.id-b.id),routing};
}
