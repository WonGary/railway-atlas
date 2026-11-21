const RailMapLayers = (() => {
  const prefix = "./data/rail/";
  let map, overview, region, live, activeRegion, tileTemplate, regionGeneration = 0;
  let overviewReady = false;
  const overviewGroups=[];
  const tagColor = value => /^#[0-9a-f]{6}$/i.test(value || "") ? value : null;
  const urbanType = value => /^(subway|light_rail|monorail|tram)$/.test(value || "");

  function inspect(name, tags, station = false, coordinate=null) {
    state.selectedMetroStation = state.selectedMetroRoute = null;
    state.selectedMapFeature={name,tags,station,coordinate:coordinate ? [coordinate.lat,coordinate.lng] : null};
    state.selectedStation = station ? name : "";
    $("favoriteStation").hidden = false;
    $("favoriteStation").textContent = state.favorites.has(mapFeatureKey(state.selectedMapFeature)) ? "★" : "☆";
    $("infoTitle").textContent = name;
    const fields = [["类型",tags.railway || tags.subclass || tags.feature || tags.route],["线路",tags.ref],["网络",tags.network],
      ["运营方",tags.operator || tags.primary_operator],["状态",tags.state || tags.construction],["限速",tags.maxspeed],
      ["轨距",tags.gauge],["电气化",tags.electrified],["途经线路",tags.membership]];
    $("infoContent").innerHTML = fields.filter(([,value]) => value).map(([label,value]) =>
      `<div class="info-block"><div class="info-label">${label}</div><div class="info-value">${escapeHTML(value)}</div></div>`).join("");
    if(coordinate){
      const row=document.createElement("p");row.textContent=`WGS84 · ${coordinate.lat.toFixed(5)}, ${coordinate.lng.toFixed(5)}`;$("infoContent").append(row);
    }
    const raw=document.createElement("details"), summary=document.createElement("summary"), data=document.createElement("pre");
    summary.textContent="原始属性";data.textContent=JSON.stringify(tags,null,2);raw.append(summary,data);$("infoContent").append(raw);
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
  function style(tags, main = false, station=false, z=map.getZoom()) {
    const p=AtlasPrefs.value, facts=AtlasPrefs.classify(tags);
    const {category,urban}=facts, planned=category==="construction";
    const color=planned ? (urban ? "#d5dce0" : "#f2c94c") : urban && p.showsMetroColors && tagColor(tags.colour) || AtlasPrefs.categories[category][1];
    return {color,weight:(main?1.45:2.4)*(urban?p.metroWidthScale:p.railwayWidthScale),
      opacity:category==="service"?p.depotBrightness:.9,dashArray:planned?"7 6":["disused","abandoned"].includes(category)?"4 5":null,
      visible:AtlasPrefs.visible(facts,z,{overview:main,station}) && (!planned || state.showConstruction) && (urban ? state.showMetro : $("showRail").checked)};
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
      const tags = feature.tags || {}, visual = style(tags,false,!feature.coordinates);
      const points = feature.coordinates || [feature.coordinate];
      const coords = points.map(p => [p.latitude,p.longitude]);
      if (fit) coords.forEach(point => bounds.extend(point));
      if (!visual.visible || (AtlasPrefs.value.automaticDetail && (zoom < 8 || (!feature.coordinates && zoom < 11)))) continue;
      const item = feature.coordinates ? L.polyline(coords,visual) :
        L.circleMarker(coords[0],{radius:3.2*AtlasPrefs.value.stationRadiusMultiplier,color:visual.color,fillColor:"#fff",fillOpacity:1,weight:2});
      const title = feature.name || feature.id;
      const tooltip = document.createElement("span"); tooltip.textContent = title;
      item.bindTooltip(tooltip,{permanent:!feature.coordinates && zoom>=13 && AtlasPrefs.value.showsLabels}).on("click", e => inspect(title,{...tags,
        membership:(feature.routes || []).map(route => route.name).filter(Boolean).join("、")}, !feature.coordinates,e.latlng)).addTo(region);
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
        const tags=feature.properties,f=AtlasPrefs.classify(tags),key=`${f.category}|${f.network}`;
        if (!groups.has(key)) groups.set(key,{tags,parts:[]});
        const shape = feature.toGeoJSON(x,y,z).geometry;
        const parts = shape.type === "LineString" ? [shape.coordinates] : shape.coordinates;
        for (const part of parts) groups.get(key).parts.push(part.map(([lon,lat]) => [lat,lon]));
      }
      return [...groups.values()];
    }));
    for (const {parts,tags} of groups.flat()) {
      const line=L.polyline(parts,{...style(tags,true),interactive:true,pane:"railOverview"});
      const {category}=AtlasPrefs.classify(tags);
      line.on("click",e=>inspect("铁路概览 · "+AtlasPrefs.categories[category][0],{feature:"铁路概览",分类:AtlasPrefs.categories[category][0]},false,e.latlng));
      overviewGroups.push({line,tags});
    }
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
          if(AtlasPrefs.value.mode!=="online") return;
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
              const visual = style(tags,false,station,map.getZoom());
              if (!visual.visible) continue;
              const factor = size / feature.extent;
              ctx.strokeStyle = visual.color; ctx.lineWidth = visual.weight;ctx.globalAlpha=visual.opacity;
              ctx.setLineDash(visual.dashArray ? [7,6] : []);
              for (const path of feature.loadGeometry()) {
                ctx.beginPath();
                if (station && path.length) {
                  const px = path[0].x*factor, py = path[0].y*factor;
                  ctx.arc(px,py,2.4*AtlasPrefs.value.stationRadiusMultiplier,0,Math.PI*2); ctx.fillStyle="#fff"; ctx.fill();
                  const name=tags["name:zh"] || tags.name;
                  if(name && AtlasPrefs.value.showsLabels && z>=12){ctx.fillStyle="#23282d";ctx.font="11px sans-serif";ctx.fillText(name,px+5,py-4);}
                  canvas.hits.push({x:px,y:py,tags,station:true});
                } else {
                  const points=path.map(p=>[p.x*factor,p.y*factor]);
                  points.forEach(([x,y],i)=>i ? ctx.lineTo(x,y) : ctx.moveTo(x,y));
                  canvas.hits.push({points,tags});
                }
                ctx.stroke();
                if(line && !visual.dashArray && AtlasPrefs.value.railwayPattern && !AtlasPrefs.classify(tags).urban && z>=11){
                  ctx.save();ctx.strokeStyle="#f4f5f3";ctx.lineWidth=visual.weight*.44;ctx.setLineDash([3,7]);ctx.stroke();ctx.restore();
                }
              }
            }
          }
          canvas.hasRail = canvas.hits.length>0;
          }
        })().then(() => done(null,canvas),error => done(error,canvas));
        return canvas;
      }
    });
    const grid = new Grid({pane:"railDetail",minZoom:7,maxNativeZoom:14,maxZoom:19,keepBuffer:2,updateWhenIdle:true,
      attribution:'<a href="https://openfreemap.org/">OpenFreeMap</a> · <a href="https://openmaptiles.org/">OpenMapTiles</a> · © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'});
    grid.on("tileunload",event => event.tile.abortTile?.());
    grid.on("load",()=>toggle());
    map.on("click",event => {
      if (!map.hasLayer(grid)) return;
      const z = Math.min(map.getZoom(),14);
      const p = map.project(event.latlng,z), x = Math.floor(p.x/256), y = Math.floor(p.y/256);
      const tile = grid._tiles[`${x}:${y}:${z}`]?.el;
      const px=p.x-x*256,py=p.y-y*256,tol=7/Math.pow(2,map.getZoom()-z);
      let nearest=tol, hit;
      for(const h of tile?.hits || []){
        if(h.station){if(Math.hypot(h.x-px,h.y-py)<=tol){hit=h;break;}continue;}
        for(let i=1;i<h.points.length;i++){
          const [ax,ay]=h.points[i-1],[bx,by]=h.points[i],dx=bx-ax,dy=by-ay;
          const u=Math.max(0,Math.min(1,((px-ax)*dx+(py-ay)*dy)/(dx*dx+dy*dy || 1)));
          const d=Math.hypot(px-ax-u*dx,py-ay-u*dy);if(d<nearest){nearest=d;hit=h;}
        }
      }
      if (hit) inspect(hit.tags["name:zh"] || hit.tags.name || hit.tags.ref || (hit.station?"车站":"轨道"),hit.tags,!!hit.station,event.latlng);
    });
    return grid;
  }
  function toggle(redraw=false) {
    if (!map) return;
    const rail = $("showRail").checked;
    const mode=AtlasPrefs.value.mode;
    if(overviewReady){
      for(const {line,tags} of overviewGroups){
        const visual=style(tags,true);
        if(redraw || !line._map)line.setStyle(visual);
        if(visual.visible!==overview.hasLayer(line))visual.visible?overview.addLayer(line):overview.removeLayer(line);
      }
      // Keep generalized geometry beneath loading or missing detail, including offline.
      setLayerVisible(overview,mode!=="offline" && (rail || state.showMetro));
    }
    setLayerVisible(live,mode!=="offline" && (rail || state.showMetro));
    if (redraw) { live.redraw(); renderRegion(); }
  }
  function setup(target) {
    map = target;
    for (const [pane,z] of [["railOverview",380],["railDetail",390]]) map.createPane(pane).style.zIndex = z;
    region = L.layerGroup().addTo(map); overview = L.layerGroup();
    live = detailGrid(); toggle();
    LocalRailCache.setup();
    map.on("zoomend",() => { toggle(); renderRegion(); });
    $("showRail").onchange = () => {toggle(true);saveLayerPreferences();};
    $("regionSelect").onchange = () => selectRegion();
    $("regionFile").onchange = event => {
      const file = event.target.files[0]; if (file) selectRegion(file); event.target.value="";
    };
    loadOverview().catch(error => { $("regionStatus").textContent = error.message; });
  }
  return {setup,toggle,inspect};
})();
