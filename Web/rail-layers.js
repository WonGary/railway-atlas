const RailMapLayers = (() => {
  const prefix = "./data/rail/";
  let map, overview, region, live, activeRegion, tileTemplate, regionGeneration = 0;
  let overviewReady = false;
  const tagColor = value => /^#[0-9a-f]{6}$/i.test(value || "") ? value : null;
  const urbanType = value => /^(subway|light_rail|monorail|tram)$/.test(value || "");

  function inspect(name, tags, station = false) {
    state.selectedMetroStation = state.selectedMetroRoute = null;
    state.selectedStation = station ? name : "";
    $("favoriteStation").hidden = !station;
    $("favoriteStation").textContent = state.favorites.has(name) ? "★" : "☆";
    $("infoTitle").textContent = name;
    const fields = [["类型",tags.railway || tags.subclass || tags.feature],["线路",tags.ref],["网络",tags.network],
      ["运营方",tags.operator || tags.primary_operator],["状态",tags.state || tags.construction],["限速",tags.maxspeed],
      ["轨距",tags.gauge],["电气化",tags.electrified],["途经线路",tags.membership]];
    $("infoContent").innerHTML = fields.filter(([,value]) => value).map(([label,value]) =>
      `<div class="info-block"><div class="info-label">${label}</div><div class="info-value">${escapeHTML(value)}</div></div>`).join("");
    if (station) {
      const button = document.createElement("button");
      button.className = "text-button"; button.textContent = "查看线路与本站车次";
      button.onclick = () => showStationBoard(name); $("infoContent").append(button);
    }
    $("infoPanel").hidden = false;
    if (window.matchMedia("(max-width: 900px)").matches) setWorkspaceOpen(false);
  }
  function typeOf(tags) {
    return tags["construction:railway"] || tags["proposed:railway"] || (/^(construction|proposed)$/.test(tags.railway) ? tags.construction || tags.proposed : tags.railway) || tags.subclass || tags.feature;
  }
  function style(tags, main = false) {
    const urban = urbanType(typeOf(tags)) || urbanType(tags.station);
    const planned = metroIsConstruction({tags}) || /^(construction|proposed|planned)$/.test(tags.state || "");
    return {color: planned ? (urban ? "#d5dce0" : "#f2c94c") : urban ? tagColor(tags.colour) || "#438fd1" : main ? "#a96c28" : "#8b5631",
      weight: main ? 1.4 : 2.2, opacity:.85, dashArray: planned ? "7 6" : null,
      visible: (!planned || state.showConstruction) && (urban ? state.showMetro : $("showRail").checked)};
  }
  const validPoint = point => point && Number.isFinite(point.latitude) && Math.abs(point.latitude) <= 85 &&
    Number.isFinite(point.longitude) && Math.abs(point.longitude) <= 180;
  function validateRegion(data) {
    if (data?.schemaVersion !== 1 || !Array.isArray(data.lines) || !Array.isArray(data.stations) ||
        data.lines.length > 20000 || data.stations.length > 8000 || !(data.lines.length || data.stations.length) ||
        !data.lines.every(line => Array.isArray(line.coordinates) && line.coordinates.length >= 2 &&
          line.coordinates.every(validPoint)) || !data.stations.every(s => validPoint(s.coordinate))) {
      throw new Error("无法读取这份 .railmap 的线路或坐标。");
    }
    return data;
  }
  function renderRegion(fit = false) {
    region.clearLayers();
    if (!activeRegion) return;
    const data = activeRegion;
    const bounds = L.latLngBounds([]);
    const zoom = map.getZoom();
    for (const feature of [...data.lines, ...data.stations]) {
      const tags = feature.tags || {}, visual = style(tags);
      const points = feature.coordinates || [feature.coordinate];
      const coords = points.map(p => [p.latitude,p.longitude]);
      if (fit) coords.forEach(point => bounds.extend(point));
      if (!visual.visible || zoom < 8 || (!feature.coordinates && zoom < 11)) continue;
      const item = feature.coordinates ? L.polyline(coords,visual) :
        L.circleMarker(coords[0],{radius:4,color:visual.color,fillColor:"#fff",fillOpacity:1,weight:2});
      const title = feature.name || feature.id;
      const tooltip = document.createElement("span"); tooltip.textContent = title;
      item.bindTooltip(tooltip).on("click", () => inspect(title,{...tags,
        membership:(feature.routes || []).map(route => route.name).filter(Boolean).join("、")}, !feature.coordinates)).addTo(region);
    }
    if (fit && bounds.isValid()) map.fitBounds(bounds,{maxZoom:13,animate:false});
    $("regionStatus").textContent = `${data.name || "区域地图"} · ${data.lines.length} 段轨道，${data.stations.length} 个车站要素`;
  }
  async function selectRegion(file) {
    const generation = ++regionGeneration;
    try {
      let data;
      if (file) {
        if (file.size > 32 * 1024 * 1024) throw new Error("区域地图上限为 32 MB。");
        data = JSON.parse(await file.text());
      } else if ($("regionSelect").value) {
        data = await loadJSON(`./data/regions/${$("regionSelect").value}.railmap`);
      }
      if (generation !== regionGeneration) return;
      activeRegion = data ? validateRegion(data) : null;
      if (file) $("regionSelect").value = "";
      $("regionStatus").textContent = "";
      renderRegion(true);
    } catch (error) { if (generation === regionGeneration) $("regionStatus").textContent = error.message; }
  }
  async function loadOverview() {
    const index = await loadJSON(`${prefix}index.json`);
    const groups = await Promise.all(index.tiles.map(async ({x,y,z,file}) => {
      const response = await fetch(prefix + file);
      if (!response.ok) throw new Error("铁路概览瓦片读取失败。");
      const tile = AtlasVector.decode(new Uint8Array(await response.arrayBuffer()));
      const layer = tile.layers.speed_railway_line_low;
      const groups = new Map();
      for (let i = 0; i < (layer?.length || 0); i++) {
        const feature = layer.feature(i);
        if (feature.type !== 2) continue;
        const visual = style(feature.properties,true);
        const key = visual.color + (visual.dashArray || "");
        if (!groups.has(key)) groups.set(key,{visual,parts:[]});
        const shape = feature.toGeoJSON(x,y,z).geometry;
        const parts = shape.type === "LineString" ? [shape.coordinates] : shape.coordinates;
        for (const part of parts) groups.get(key).parts.push(part.map(([lon,lat]) => [lat,lon]));
      }
      return [...groups.values()];
    }));
    for (const {parts,visual} of groups.flat()) L.polyline(parts,{...visual,interactive:false,pane:"railOverview"}).addTo(overview);
    overviewReady = true;
    toggle();
  }
  // Detail tiles are painted independently. Leaflet retains the previous zoom's
  // tiles while the next view loads. The bundled Z4 layer remains underneath.
  function detailGrid() {
    const Grid = L.GridLayer.extend({
      createTile(coords, done) {
        const canvas = document.createElement("canvas"), size = 256, scale = Math.min(2, devicePixelRatio || 1);
        canvas.width = canvas.height = size * scale;
        const ctx = canvas.getContext("2d"); ctx.scale(scale,scale);
        const {x,y,z} = coords;
        const controller = new AbortController();
        canvas.abortTile = () => controller.abort();
        (async () => {
          let sources = await LocalRailCache.read(coords);
          if (!sources.length) {
          if (!tileTemplate) tileTemplate = loadJSON("https://tiles.openfreemap.org/planet").then(info => {
            const template = info.tiles?.[0];
            if (!template?.startsWith("https://tiles.openfreemap.org/")) throw new Error("铁路瓦片地址不可用");
            return template;
          }).catch(error => { tileTemplate = null; throw error; });
          const url = (await tileTemplate).replace("{x}",x).replace("{y}",y).replace("{z}",z);
          const response = await fetch(url,{signal:controller.signal});
          if (!response.ok) throw new Error(`地图资料 HTTP ${response.status}`);
          sources = [new Uint8Array(await response.arrayBuffer())];
          }
          if (controller.signal.aborted) return;
          canvas.hits = [];
          for (const source of sources) {
          const tile = AtlasVector.decode(source);
          for (const layerName of Object.keys(tile.layers).filter(name =>
            ["transportation","poi","streets","public_transport","railway_line_high","speed_railway_line_low"].includes(name) ||
            name.startsWith("standard_railway_text_stations"))) {
            const layer = tile.layers[layerName];
            for (let i=0; i<(layer?.length || 0); i++) {
              const feature = layer.feature(i), tags = feature.properties;
              const line = feature.type === 2 && (["railway_line_high","speed_railway_line_low"].includes(layerName) ||
                (["rail","transit"].includes(tags.class) && /^(rail|subway|light_rail|tram|monorail|narrow_gauge|funicular)$/.test(tags.subclass)) ||
                (layerName === "streets" && /^(rail|light_rail|subway|tram)$/.test(tags.kind)));
              const station = feature.type === 1 && z >= 9 && (layerName.startsWith("standard_railway_text_stations") ||
                ["railway","railway_station"].includes(tags.class) ||
                /^(station|halt|tram_stop|subway)$/.test(tags.subclass));
              if (!line && !station) continue;
              const visual = style(tags);
              if (!visual.visible) continue;
              const factor = size / feature.extent;
              ctx.strokeStyle = visual.color; ctx.lineWidth = visual.weight;
              ctx.setLineDash(visual.dashArray ? [7,6] : []);
              for (const path of feature.loadGeometry()) {
                ctx.beginPath();
                if (station && path.length) {
                  const px = path[0].x*factor, py = path[0].y*factor;
                  ctx.arc(px,py,3,0,Math.PI*2); ctx.fillStyle="#fff"; ctx.fill();
                  canvas.hits.push({x:px,y:py,tags});
                } else path.forEach((p,i) => i ? ctx.lineTo(p.x*factor,p.y*factor) : ctx.moveTo(p.x*factor,p.y*factor));
                ctx.stroke();
              }
            }
          }
          }
        })().then(() => done(null,canvas),error => done(error,canvas));
        return canvas;
      }
    });
    const grid = new Grid({pane:"railDetail",minZoom:7,maxNativeZoom:14,maxZoom:19,keepBuffer:1,updateWhenIdle:true,
      attribution:'<a href="https://openfreemap.org/">OpenFreeMap</a> · <a href="https://openmaptiles.org/">OpenMapTiles</a> · © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'});
    grid.on("tileunload",event => event.tile.abortTile?.());
    map.on("click",event => {
      if (!map.hasLayer(grid)) return;
      const z = Math.min(map.getZoom(),14);
      const p = map.project(event.latlng,z), x = Math.floor(p.x/256), y = Math.floor(p.y/256);
      const tile = grid._tiles[`${x}:${y}:${z}`]?.el;
      const hit = tile?.hits?.find(h => Math.hypot(h.x-(p.x-x*256),h.y-(p.y-y*256)) < 7);
      if (hit) inspect(hit.tags["name:zh"] || hit.tags.name || "车站",hit.tags,true);
    });
    return grid;
  }
  function toggle(redraw=false) {
    if (!map) return;
    const rail = $("showRail").checked;
    if (overviewReady) setLayerVisible(overview,rail && map.getZoom() <= 10);
    setLayerVisible(live,rail || state.showMetro);
    if (redraw) { live.redraw(); renderRegion(); }
  }
  function setup(target) {
    map = target;
    for (const [pane,z] of [["railOverview",380],["railDetail",390]]) map.createPane(pane).style.zIndex = z;
    region = L.layerGroup().addTo(map); overview = L.layerGroup();
    live = detailGrid(); toggle();
    LocalRailCache.setup();
    map.on("zoomend",() => { toggle(); renderRegion(); });
    $("showRail").onchange = () => toggle(true);
    $("regionSelect").onchange = () => selectRegion();
    $("regionFile").onchange = event => {
      const file = event.target.files[0]; if (file) selectRegion(file); event.target.value="";
    };
    loadOverview().catch(error => { $("regionStatus").textContent = error.message; });
  }
  return {setup,toggle};
})();
