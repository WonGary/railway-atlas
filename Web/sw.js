const VERSION = "0.8.17";
const SHELL = `railway-atlas-web-${VERSION}-r12`;
// Retain immutable track, station and timetable chunks. City projections are versioned below.
const DETAILS = "railway-atlas-detail-0.7.0";
const base = self.registration.scope;
const address = path => new URL(path, base).href;
const coreFiles = [
  "index.html","styles.css","ticket-typography.css","app.js","library.js","vendor/leaflet.js","vendor/leaflet.css","vendor/vector.js",
  "ticket-face.js","data/station-transliterations.js","vendor/qrcode-generator.js","journey-keepsakes.js","line-focus.js","metro-handoff.js","metro-updates.js","metro-source.js","metro-loader.js","card-map.js",
  "station-directory/national.js","data/journey-aliases.js","station-directory/cnrail.js","station-directory/catalog.js","station-directory/panel.js","station-directory/panel.css","station-directory/paths.js","station-directory/paths/manifest.js",
  "map-preferences.js","station-labels.js","rail-layers.js","vector-basemap.js","station-board.js","cache-client.js",
  "world-rail.js","packed-rail.js","station-layout-layer.js","data/station-layouts.js",
  "rail-games.js","games/outlines.json","history-network.js","run-info.js","route-inspector.js","data/history-network/index.json",
  "journey-guide.js","station-directory/journey-guide-core.js","station-directory/journey-places.json",
  "data/history-network/beijing.json","data/history-network/hongkong.json","data/history-network/jinan.json",
  "data/history-network/macao.json","data/history-network/qingdao.json","data/history-network/tokyo.json",
  "data/railway-experience-corridors.json","data/railway-experience-routes.json","data/railway-experience-timetables.json",
  "data/china-metro-overview.json","data/metro-index.json","data/metro/macao.json","data/rail/index.json"
];
const mapExtras = [
  "station-directory/card-geography.json","station-directory/lines/index.json","timetable-package.mjs","cache-worker.mjs",
  "data/rail/detail/index.json","data/rail/world-z2.json","data/rail/world-z4.json","data/rail/world-z6.json",
  "data/rail/speed-z2.json","data/rail/speed-z4.json","data/rail/speed-z6.json",
  "data/station-layouts.json","data/world-stations/index.json",
  "vendor/sqlite/index.mjs","vendor/sqlite/sqlite3.wasm","vendor/sqlite/sqlite3-opfs-async-proxy.js",
  "manifest.webmanifest","touch.png","icon-192.png","icon-512.png","vendor/vector.mjs","track-match.mjs",
  "licenses/NOTICE.txt","licenses/components.txt","licenses/NATIONAL-METRO-LICENCE.txt","licenses/METRO-PALETTE-LICENCE.txt","licenses/QR-Code-Generator.txt",
  "data/discovery.json"
];
const files = [...coreFiles, ...mapExtras];

async function cacheFiles(cache, paths, concurrency, optional = false) {
  const queue = paths[Symbol.iterator]();
  async function next() {
    for (const path of queue) {
      const url = address(path);
      try {
        if (!await cache.match(url)) await cache.add(new Request(url, {cache:"no-cache"}));
      } catch (error) {
        if (!optional) throw error;
      }
    }
  }
  await Promise.all(Array.from({length:concurrency}, next));
}

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL);
    await cacheFiles(cache, coreFiles, 6);
    await self.skipWaiting();
  })());
});

let pendingWarmup;
function warmMap() {
  if (!pendingWarmup) pendingWarmup = (async () => {
    const cache = await caches.open(SHELL);
    const index = await cache.match(address("data/rail/index.json"));
    const {tiles} = await index.json();
    await cacheFiles(cache, [...tiles.map(tile => "data/rail/" + tile.file), ...mapExtras], 3, true);
  })().finally(() => { pendingWarmup = null; });
  return pendingWarmup;
}

self.addEventListener("message", event => {
  if (event.data === "warm-offline-map") event.waitUntil(warmMap());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (/^railway-atlas-(web|detail)-/.test(key) && key !== SHELL && key !== DETAILS) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", event => {
  const {request} = event;
  if (request.method !== "GET" || !request.url.startsWith(base)) return;
  const {pathname} = new URL(request.url);
  const path = pathname.slice(new URL(base).pathname.length);
  if (request.mode === "navigate" && (path === "" || path === "index.html")) {
    event.respondWith((async () => {
      const cache = await caches.open(SHELL);
      const page = await cache.match(address("index.html"));
      if (!page) return fetch(request);
      // File servers may canonicalize index.html to "./". A navigation in
      // manual redirect mode rejects that cached redirect chain when offline.
      return page.redirected ? new Response(page.body, {headers:page.headers, status:page.status}) : page;
    })());
  } else if (files.includes(path) || /^data\/rail\/4-\d+-\d+\.pbf$/.test(path)) {
    event.respondWith((async () => {
      const cache = await caches.open(SHELL);
      const key = address(path);
      const hit = await cache.match(key);
      if (hit) return hit;
      let response;
      try { response = await fetch(request); }
      catch { return new Response(null, {status:503}); }
      if (response.ok && !response.redirected) {
        try { await cache.put(key, response.clone()); } catch { /* The response is still usable online. */ }
      }
      return response;
    })());
  } else if (/^station-directory\/(?:lines|paths)\/[A-Z0-9]+-[0-9a-f]{12}\.json$/.test(path) || /^data\/(?:rail\/detail\/\d+-\d+-[0-9a-f]{12}\.json|metro\/[a-z0-9-]+\.json|regions\/[a-z-]+\.railmap|world-stations\/(?:sg-lta-)?-?\d+_-?\d+\.[0-9a-f]{12}\.json)$/.test(path)) {
    event.respondWith((async () => {
      const cache = await caches.open(DETAILS);
      const cacheKey=path.startsWith("data/metro/") ? address(path+"?edition="+VERSION) : request;
      const hit = await cache.match(cacheKey);
      if (hit) return hit;
      // Offline areas can lack station or track chunks. Let the caller retain the
      // currently drawn features and retry later without rejecting the fetch event.
      let response;
      try {
        response = await fetch(request);
      } catch {
        return new Response(null, {status: 503, headers: {"Cache-Control":"no-store"}});
      }
      if (response.ok && !response.redirected) {
        try { await cache.put(cacheKey,response.clone()); } catch { /* A full cache still permits online use. */ }
      }
      return response;
    })());
  }
});
