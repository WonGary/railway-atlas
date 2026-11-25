const MetroUpdates=(()=>{
  const feed="https://wongary.github.io/railway-atlas/data/metro-updates/";
  const limit=32*1024*1024;
  let bundle,active,busy=false,message="";
  const hex=buffer=>Array.from(new Uint8Array(buffer),n=>n.toString(16).padStart(2,"0")).join("");
  const digest=async bytes=>hex(await crypto.subtle.digest("SHA-256",bytes));
  function validateManifest(m) {
    if (m?.version!==1 || !/^\d{4}-\d\d-\d\d$/.test(m.sourceDate) || !Number.isFinite(Date.parse(m.fetchedAt)) ||
      !Array.isArray(m.chunks) || !m.chunks.length || m.chunks.length>512 ||
      new Set(m.chunks.map(c=>c.city)).size!==m.chunks.length ||
      m.chunks.some(c=>!c.city || !/^[0-9a-f]{64}$/.test(c.hash) || !Number.isSafeInteger(c.bytes) || c.bytes<2 ||
        !Number.isSafeInteger(c.count) || c.count<1) || m.chunks.reduce((n,c)=>n+c.bytes,0)>limit ||
      m.chunks.reduce((n,c)=>n+c.count,0)>20000) throw Error("更新清单无效");
    return m;
  }
  function groups(records) {
    const byCity=new Map();
    for (const rec of records) {
      if (!byCity.has(rec.city)) byCity.set(rec.city,[]);
      byCity.get(rec.city).push(rec);
    }
    return byCity;
  }
  function validateChunk(chunk,rows) {
    const modes=["subway","light_rail","tram","monorail"];
    if (!Array.isArray(rows) || rows.length!==chunk.count || rows.some(r=>r?.city!==chunk.city ||
      !/^relation\/[1-9]\d*$/.test(r.route?.id) || !modes.includes(r.route.tags?.route) ||
      !Array.isArray(r.parts) || !r.parts.length || r.parts.some(p=>!Array.isArray(p) || p.length<2 ||
        p.some(v=>!Array.isArray(v) || v.length!==2 || !v.every(Number.isFinite) || Math.abs(v[0])>180 || Math.abs(v[1])>85.1))))
      throw Error(`${chunk.city}的线路数据无效`);
  }
  async function stored(write) {
    const db=await new Promise((resolve,reject)=>{
      const req=indexedDB.open("railway-atlas-national-metro",1);
      req.onupgradeneeded=()=>req.result.createObjectStore("state");
      req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);
    });
    try {
      return await new Promise((resolve,reject)=>{
        const tx=db.transaction("state",write ? "readwrite" : "readonly");
        const store=tx.objectStore("state");
        const request=write ? store.put(write,"active") : store.get("active");
        tx.oncomplete=()=>resolve(request.result);
        tx.onabort=tx.onerror=()=>reject(tx.error || Error("无法保存全国城轨数据"));
      });
    } finally {db.close();}
  }
  function status(text) {
    if(text!==undefined)message=text;
    const note=$("metroUpdateStatus"),button=$("updateNationalMetro");
    if(note)note.textContent=message || (active ? `资料日期 ${active.sourceDate}，共 ${active.records.length} 条记录` : "正在读取全国城轨数据");
    if(button)button.disabled=busy || !active;
  }
  async function restore(snapshot) {
    bundle=snapshot;active=bundle;
    try {
      const saved=await stored();
      if (saved?.sourceDate>=bundle.sourceDate && saved.records?.length && validateManifest(saved.manifest)) active=saved;
    } catch { /* A bundled map also works when the browser disallows persistent storage. */ }
    status();return active;
  }
  async function download(url,max) {
    const response=await fetch(url,{cache:"no-store",credentials:"omit",signal:AbortSignal.timeout(16000)});
    if(!response.ok || Number(response.headers.get("content-length"))>max)throw Error("更新文件下载失败");
    const reader=response.body.getReader(), pieces=[];let length=0;
    try {
      for (;;) {
        const {done,value}=await reader.read();if(done)break;
        length+=value.length;if(length>max)throw Error("更新文件超过大小限制");pieces.push(value);
      }
    } finally {await reader.cancel().catch(()=>{});}
    const bytes=new Uint8Array(length);let at=0;
    for(const piece of pieces){bytes.set(piece,at);at+=piece.length;}return bytes;
  }
  async function sync(base=feed) {
    if (!active || busy) return;
    busy=true;status("正在核对各城市的版本…");
    try {
      const json=bytes=>JSON.parse(new TextDecoder().decode(bytes));
      const m=validateManifest(json(await download(new URL("manifest.json",base),128*1024)));
      if(active.sourceDate>m.sourceDate)throw Error("本机资料日期较新");
      const previous=groups(active.records), next=new Map(m.chunks.map(c=>[c.city,c]));
      for(const [city,rows] of previous) if (!next.has(city) || next.get(city).count<rows.length*.8) throw Error(`${city}的更新记录不完整`);
      const known=new Map(active.manifest?.chunks.map(c=>[c.city,c.hash]));
      let changed=0;const records=[];
      for (const chunk of m.chunks) {
        let rows=previous.get(chunk.city);
        if(rows && !known.has(chunk.city)) {
          const sorted=[...rows].sort((a,b)=>a.route.id<b.route.id ? -1 : a.route.id>b.route.id ? 1 : 0);
          known.set(chunk.city,await digest(new TextEncoder().encode(JSON.stringify(sorted))));
        }
        if(known.get(chunk.city)!==chunk.hash) {
          status(`正在下载${chunk.city}的变化…`);
          const bytes=await download(new URL(chunk.hash+".json",base),chunk.bytes);
          if(bytes.length!==chunk.bytes || await digest(bytes)!==chunk.hash)throw Error(`${chunk.city}的文件校验失败`);
          rows=json(bytes);validateChunk(chunk,rows);changed++;
        }
        records.push(...rows);
      }
      if(changed || active.sourceDate!==m.sourceDate) {
        const candidate={version:1,records,sourceDate:m.sourceDate,fetchedAt:m.fetchedAt,manifest:m};
        await stored(candidate);active=candidate;
        state.metroRecords=records;state.metroLayer.clearLayers();state.metroPolylines=[];
        AtlasPrefs.indexRoutes();AtlasPrefs.routeList();drawMetro();
        if (LineFocus.active?.overview) LineFocus.clear();
      } else active={...active,manifest:m};
      status(changed ? `已更新 ${changed} 个城市或网络，资料日期 ${m.sourceDate}` : `已是发布版本，下载 0 个分块 · ${m.sourceDate}`);
      return changed;
    } catch(error) {status(`${error.message}。已保留当前地图。`);return null;}
    finally {busy=false;status();}
  }
  return {restore,sync,status};
})();
