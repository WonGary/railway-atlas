const MetroLoader = (() => {
  const cacheName = "atlas-city-directions-v1";
  const key = city => new URL(`./city-cache/${encodeURIComponent(city.id)}`,document.baseURI).href;
  const feed = "https://wongary.github.io/railway-atlas/data/city-packs/";
  const pending = new Map();
  let manifest, nextCheck = 0;
  function entries() {
    if (!manifest || Date.now()>=nextCheck) {
      nextCheck=Date.now()+6*3600000;
      manifest=fetch(feed+"manifest.json",{cache:"no-cache",credentials:"omit",signal:AbortSignal.timeout(3500)})
        .then(async response=>{
          if (!response.ok) throw Error("无法读取共享城市目录");
          const value=await response.json();
          if (value.version!==1 || !value.cities) throw Error("共享城市目录格式无效");
          return value.cities;
        }).catch(()=>{nextCheck=Date.now()+60000;return {};});
    }
    return manifest;
  }
  async function fromRepo(city,prior,cache) {
    const entry=(await entries())[city.id];
    if (!entry || !/^[a-f0-9]{64}$/.test(entry.hash) || !(entry.bytes>0 && entry.bytes<=32000000)) return null;
    if (prior && (prior.sharedHash===entry.hash || prior.sourceDate>entry.sourceDate)) return prior;
    const response=await fetch(feed+entry.hash+".json",{credentials:"omit",signal:AbortSignal.timeout(9500)});
    if (!response.ok) throw Error("共享城市包下载失败");
    const bytes=await response.arrayBuffer();
    if (bytes.byteLength!==entry.bytes) throw Error("共享城市包大小不符");
    const digest=await crypto.subtle.digest("SHA-256",bytes);
    if (Array.from(new Uint8Array(digest),n=>n.toString(16).padStart(2,"0")).join("")!==entry.hash)
      throw Error("共享城市包校验失败");
    const detail=JSON.parse(new TextDecoder().decode(bytes));
    if (detail.id!==city.id || detail.sourceDate!==entry.sourceDate || !Array.isArray(detail.routes) ||
        !Array.isArray(detail.stations)) throw Error("共享城市记录不符");
    Object.assign(detail,{sharedHash:entry.hash,savedAt:Date.now()});
    if (cache) try {await cache.put(key(city),new Response(JSON.stringify(detail)));} catch {}
    return detail;
  }
  function shared(city,prior,cache) {
    if (!pending.has(city.id))
      pending.set(city.id,fromRepo(city,prior,cache).catch(()=>null).finally(()=>pending.delete(city.id)));
    return pending.get(city.id);
  }
  async function load(city,mode) {
    let cache, prior;
    try {
      cache = await caches.open(cacheName);
      const hit = await cache.match(key(city));
      if (hit) prior = await hit.json();
    } catch { /* Private browsing can disable persistent storage. */ }
    if (prior && mode!=="online") return prior;
    if (mode==="online" && prior?.sharedHash) {
      void shared(city,prior,cache);
      return prior;
    }
    if (city.data) {
      const url = new URL(city.data,new URL("./data/",document.baseURI));
      if (mode === "online") {
        try {
          const detail=await loadJSON(url);
          if (cache && (!prior || prior.sourceDate!==detail.sourceDate))
            try {await cache.put(key(city),new Response(JSON.stringify(detail)));} catch {}
          return detail;
        } catch(error) { if(prior) return prior; throw error; }
      }
      const localOrigin = ["localhost", "127.0.0.1", "[::1]", "appassets.androidplatform.net"].includes(url.hostname);
      if (localOrigin && url.origin === new URL(document.baseURI).origin) return loadJSON(url);
      const hit = await globalThis.caches?.match(new URL(url+"?edition="+$("versionBadge").textContent))
        || await globalThis.caches?.match(url);
      if (hit) return hit.json();
      if (prior) return prior;
      throw Error("本设备还没有这个城市的离线资料");
    }
    if (prior && Date.now()-prior.savedAt < (prior.routes.length ? 7*86400000 : 86400000)) {
      void shared(city,prior,cache);
      return prior;
    }
    if (mode !== "online") throw Error("本设备还没有这个城市的离线资料");
    const published=await shared(city,prior,cache);
    if (published) return published;
    let last;
    for (const endpoint of MetroSource.endpoints(city.bounds)) {
      try {
        const url = new URL(endpoint);
        url.searchParams.set("data",MetroSource.query(city.bounds));
        const response = await fetch(url,{credentials:"omit",signal:AbortSignal.timeout(45000)});
        if (!response.ok) throw Error(`地图源 HTTP ${response.status}`);
        const detail = MetroSource.convert(city,await response.json());
        detail.savedAt = Date.now();
        if (cache) try { await cache.put(key(city),new Response(JSON.stringify(detail))); } catch {}
        return detail;
      } catch (error) { last = error; }
    }
    if (prior) return prior;
    throw last;
  }
  return {load};
})();
