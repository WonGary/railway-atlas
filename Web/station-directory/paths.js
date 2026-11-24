/* Dated train geometry shared by journeys, the passport and postcards. */
const RailPaths = (() => {
  const base = new URL("station-directory/paths/", document.baseURI);
  const files = new Map();
  const rowIndexes = new WeakMap();
  function rowsFor(group, numbers) {
    let index = rowIndexes.get(group);
    if (!index) {
      index=new Map();
      for (const [primary,rows] of Object.entries(group.trains)) for (const row of rows) {
        const candidate={primary,row};
        for (const name of new Set([primary,...row.a.flatMap(entry=>entry[0])])) {
          if (!index.has(name)) index.set(name,[]);
          index.get(name).push(candidate);
        }
      }
      rowIndexes.set(group,index);
    }
    return new Set([...numbers].flatMap(n=>index.get(n)||[]));
  }
  function read(name) {
    if (!files.has(name)) {
      const request = fetch(new URL(name, base)).then(response => {
        if (!response.ok) throw Error(`路线资料未能读取（${response.status}）。`);
        return response.json();
      }).catch(error => { files.delete(name); throw error; });
      if (files.size > 32) files.delete([...files.keys()].find(k => k !== "index.json"));
      files.set(name, request);
    }
    return files.get(name);
  }
  function decode(text) {
    const points = [];
    let lon = 0, lat = 0, offset = 0;
    function delta() {
      let value = 0, shift = 0;
      while (offset < text.length && shift <= 30) {
        const c = text.charCodeAt(offset++) - 63;
        if (c < 0 || c > 63) break;
        value |= (c & 31) << shift;
        if (c < 32) return (value >>> 1) ^ -(value & 1);
        shift += 5;
      }
      throw Error("线路坐标不完整。");
    }
    while (offset < text.length) {
      lon += delta(); lat += delta();
      if (Math.abs(lon) > 18000000 || Math.abs(lat) > 9000000) throw Error("线路坐标无效。");
      points.push([lat / 100000, lon / 100000]);
    }
    return points;
  }
  function metres(a,b) {
    return Math.hypot(a[0]-b[0], (a[1]-b[1])*Math.cos((a[0]+b[0])*Math.PI/360))*111195;
  }
  async function fingerprint(plan) {
    if (!plan?.nodes || !plan?.edges) return null;
    const string = plan.nodes.map((n,i) => `${n.station}\t${n.kilometre}\t${plan.edges[i]?.lineName || ""}`).join("\n");
    const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(string));
    return Array.from(new Uint8Array(bytes), b=>b.toString(16).padStart(2,"0")).join("");
  }
  async function find({train, date, stops, routing, trip, from, to, boarding = false, departure}) {
    const manifest=globalThis.atlasPathManifest, directory=globalThis.atlasRailDirectory;
    const compact=manifest && directory && manifest.edition===directory.edition;
    const meta=compact ? manifest : await read("index.json");
    if (meta.version !== 1) throw Error("请更新线路资料。");
    const numbers = new Set(RailLibrary.trainNames(String(train).trim().toUpperCase()));
    const groups = [...new Set([...numbers].flatMap(n => compact ?
      (meta.aliases[n] || [n.replace(/\d+$/, digits=>String(Math.floor(Number(digits)/100)))]).filter(k=>meta.groups[k]) : meta.lookup[n]||[]))];
    if (!groups.length) throw Error(`这版时刻库未收录 ${train || "该车次"}。`);
    const [signature, loaded] = await Promise.all([fingerprint(routing), Promise.all(groups.map(g => read(meta.groups[g])))]);
    const matches = [];
    let known = false;
    for (const group of loaded) for (const {primary,row} of rowsFor(group,numbers)) {
      known = true;
      if (trip && trip !== row.id) continue;
      if (!numbers.has(primary) && !row.a.some(([aliases]) => aliases.some(n=>numbers.has(n)))) continue;
      if (signature && row.r && signature !== row.r) continue;
      if (signature && !row.r) continue;
      const names = row.s.map(([id])=>(compact ? directory : meta).names[id]);
      if (stops && (stops.length !== names.length || !stops.every((s,i)=> {
        const a=s.arrival??null, d=s.departure??null;
        return (s.station??s.name)===names[i] && (!i || a===row.s[i][1]) && (i+1===names.length || d===row.s[i][2]);
      }))) continue;
      const pairs = [];
      for (let a=0;a<names.length-1;a++) if (from ? names[a]===from : a===0) {
        for (let b=a+1;b<names.length;b++) if (to ? names[b]===to : b===names.length-1) pairs.push([a,b]);
      }
      if (pairs.length!==1) continue;
      const [a,b]=pairs[0], minute=row.s[a][2];
      if (departure && parseMinutes(departure)!==minute%1440) continue;
      const origin = boarding ? StationCatalog.day(date,-Math.floor(minute/1440)) : date;
      if (!origin || !(compact ? directory : meta).calendars[row.c].includes(origin.replaceAll("-",""))) continue;
      if (!numbers.has(primary) && !row.a.some(([aliases,s,e])=>s<=origin && origin<=e && aliases.some(n=>numbers.has(n)))) continue;
      matches.push({row,primary,names,group,a,b,origin});
    }
    if (!known) throw Error(`这版时刻库未收录 ${train || "该车次"}。`);
    if (matches.length!==1) throw Error(matches.length ? "该日期有多份排图，请选定具体车次。" : "该日期、站序或时刻与路线资料不符。");
    const {row,primary,names,group,a,b,origin}=matches[0];
    const sectionNames=names.slice(a,b+1);
    const legs=row.p.slice(a,b).map(idx => idx < 0 ? [] : decode(group.paths[idx]));
    const gaps=[];
    for (let i=0;i<legs.length;i++) {
      if (legs[i].length<2) gaps.push(`${sectionNames[i]} → ${sectionNames[i+1]}`);
      else if (i && legs[i-1].length && metres(legs[i-1].at(-1),legs[i][0])>120) gaps.push(`${sectionNames[i]}站内衔接`);
    }
    return {id:`national:${row.id}:${origin}`,train:train || primary,serviceDate:origin,
      stops:row.s.slice(a,b+1).map(([,arrival,departure],i)=>({name:sectionNames[i],arrival,departure})),
      legs,stopCoordinates:sectionNames.map((_,i)=>legs[i]?.[0] || legs[i-1]?.at(-1) || null),
      geometryAvailable:!gaps.length, gaps, routing:from||to ? null : routing,
      source:{title:"全国铁路车次径路 · "+meta.edition,note:"China Railway GTFS · Jeremy Gao / © OpenStreetMap contributors"},
      geometryKinds:row.k.slice(a,b), indexed:true};
  }
  return {find};
})();
