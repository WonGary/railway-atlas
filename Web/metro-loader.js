const MetroLoader = (() => {
  const cacheName = "atlas-city-directions-v1";
  const key = city => new URL(`./city-cache/${encodeURIComponent(city.id)}`,document.baseURI).href;
  async function load(city,mode) {
    let cache, prior;
    try {
      cache = await caches.open(cacheName);
      const hit = await cache.match(key(city));
      if (hit) prior = await hit.json();
    } catch { /* Private browsing can disable persistent storage. */ }
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
      const hit = await globalThis.caches?.match(new URL(url+"?edition="+$("versionBadge").textContent));
      if (hit) return hit.json();
      if (prior) return prior;
      throw Error("本设备还没有这个城市的离线资料");
    }
    if (prior && (mode !== "online" || Date.now()-prior.savedAt < (prior.routes.length ? 7*86400000 : 86400000))) return prior;
    if (mode !== "online") throw Error("本设备还没有这个城市的离线资料");
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
