const VERSION = "0.8.13";
const SHELL = `railway-atlas-web-${VERSION}-r1`;
// City snapshots still carry the same 2026-11-05 edition. Reuse downloads on upgrade.
const DETAILS = "railway-atlas-detail-0.7.0";
const base = self.registration.scope;
const address = path => new URL(path, base).href;
const files = [
  "ticket-face.js","line-focus.js","metro-handoff.js","metro-updates.js","card-map.js","station-directory/card-geography.json","station-directory/lines/index.json",
  "station-directory/national.js","station-directory/cnrail.js","station-directory/catalog.js","station-directory/panel.js","station-directory/panel.css","station-directory/paths.js","station-directory/paths/manifest.js",
  "index.html","styles.css","app.js","library.js","timetable-package.mjs","map-preferences.js","station-labels.js","rail-layers.js","vector-basemap.js","station-board.js","cache-client.js","cache-worker.mjs",
  "world-rail.js","data/rail/world-z2.json","data/rail/world-z4.json","data/rail/world-z6.json",
  "data/rail/speed-z2.json","data/rail/speed-z4.json","data/rail/speed-z6.json",
  "station-layout-layer.js","data/station-layouts.js","data/station-layouts.json","data/world-stations/index.json",
  "vendor/sqlite/index.mjs","vendor/sqlite/sqlite3.wasm","vendor/sqlite/sqlite3-opfs-async-proxy.js",
  "manifest.webmanifest","touch.png","icon-192.png","icon-512.png",
  "vendor/leaflet.js","vendor/leaflet.css","vendor/vector.js","vendor/vector.mjs","track-match.mjs",
  "licenses/NOTICE.txt","licenses/components.txt","licenses/NATIONAL-METRO-LICENCE.txt","licenses/METRO-PALETTE-LICENCE.txt",
  "data/railway-experience-corridors.json","data/railway-experience-routes.json",
  "data/railway-experience-timetables.json","data/china-metro-overview.json",
  "data/metro-index.json","data/railway-experience-history.json","data/rail/index.json","data/discovery.json"
];

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL);
    await cache.addAll(files.map(path => new Request(address(path),{cache:"reload"})));
    const {tiles} = await (await cache.match(address("data/rail/index.json"))).json();
    await cache.addAll(tiles.map(tile => new Request(address("data/rail/" + tile.file),{cache:"reload"})));
    await self.skipWaiting();
  })());
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
  } else if (/^station-directory\/(?:lines|paths)\/[A-Z0-9]+-[0-9a-f]{12}\.json$/.test(path) || /^data\/(?:metro\/[a-z]+\.json|regions\/[a-z-]+\.railmap|world-stations\/(?:sg-lta-)?-?\d+_-?\d+\.[0-9a-f]{12}\.json)$/.test(path)) {
    event.respondWith((async () => {
      const cache = await caches.open(DETAILS);
      const hit = await cache.match(request);
      if (hit) return hit;
      const response = await fetch(request);
      if (response.ok && !response.redirected) {
        try { await cache.put(request,response.clone()); } catch { /* A full cache still permits online use. */ }
      }
      return response;
    })());
  } else if (files.includes(path) || /^data\/rail\/4-\d+-\d+\.pbf$/.test(path)) {
    event.respondWith(caches.open(SHELL).then(async cache => await cache.match(request) || fetch(request)));
  }
});
