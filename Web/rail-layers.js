const RailMapLayers = (() => {
  const prefix = "./data/rail/";
  let map, overview, world, region, live, activeRegion, tileTemplate, regionGeneration = 0;
  const regionalTiles = [];
  const overviewTiles=new Map();
  let cityTracks=new MetroHandoff.Tracks(), regionTracks=new MetroHandoff.Tracks(), regionRail=new MetroHandoff.Tracks();
  const railwayIdentity=way=>({network:"railway",category:"track",ids:way ? [String(way)] : []});
  let cityEntries=[], metroRevision=0, metroFrame=0;
  function invalidateMetro() {
    metroRevision++;
    if (!metroFrame) metroFrame=requestAnimationFrame(()=>{
      metroFrame=0;
      if (state.metroPolylines.length) refreshMetroDetailVisibility();
    });
  }
  function setMetroCities(entries) {
    if (entries.length===cityEntries.length && entries.every((e,i)=>e===cityEntries[i])) return;
    cityEntries=entries;
    cityTracks=new MetroHandoff.Tracks();
    for (const {parts,identity} of entries) cityTracks.add(parts,identity);
    renderRegion();
    live?.redraw();
  }
  function metroCoverage() {
    const indexes=[cityTracks,regionTracks];
    if (live && map.hasLayer(live)) for (const tile of Object.values(live._tiles)) {
      if (tile.current && tile.coords.z===live._tileZoom && tile.loaded && tile.el.metroTracks?.bounds)
        indexes.push(tile.el.metroTracks);
    }
    return {revision:metroRevision,indexes};
  }
  const tagColor = value => /^#[0-9a-f]{6}$/i.test(value || "") ? value : null;
  const urbanType = value => /^(subway|light_rail|monorail|tram)$/.test(value || "");

  function inspect(name, tags, station = false, coordinate=null, focus=null) {
    if (station) LineFocus.station(name,null,coordinate,focus?.stopColors || (()=>[focusStyle(tags).color].filter(Boolean)));
    else if (focus?.parts?.length || focus?.match) LineFocus.set(name,focus.parts || [],focus.stops || [],{...focus,fittedLine:true});
    else LineFocus.clear();
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
      StationLayoutLayer.addFocusButton($("infoContent"),coordinate);
      if (!urbanType(tags.station || tags.subclass || tags.railway))
        StationMapBoard.mount($("infoContent"),tags["name:zh-Hans"] || tags["name:zh"] || name);
    }
    $("infoPanel").hidden = false;
    if (window.matchMedia("(max-width: 900px)").matches) setWorkspaceOpen(false);
    if (!station && focus) LineFocus.fitSelection();
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
  function focusStyle(tags) {
    const {category}=AtlasPrefs.classify(tags), visual=style(tags);
    const uncoloured=category==="unknown" || category==="urban" && !(AtlasPrefs.value.showsMetroColors && tagColor(tags.colour));
    return {color:uncoloured ? null : visual.color,dashArray:visual.dashArray};
  }
  function withRouteColour(feature) {
    const tags=feature.tags || {}, route=feature.routes?.find(r=>tagColor(r.color || r.tags?.["atlas:bundledColour"] || r.tags?.colour));
    return route && !tagColor(tags.colour) ? {...tags,colour:route.color || route.tags["atlas:bundledColour"] || route.tags.colour} : tags;
  }
  function stationColors(feature) {
    const colors=AtlasPrefs.value.showsMetroColors ? (feature.routes || []).map(r=>r.color || r.tags?.["atlas:bundledColour"] || r.tags?.colour).filter(tagColor) : [];
    return colors.length ? [...new Set(colors)].sort() : [focusStyle(feature.tags || {}).color].filter(Boolean);
  }
  const trackName=tags=>tags?.["name:zh-Hans"] || tags?.["name:zh"] || tags?.["name_zh-Hans"] || tags?.name_zh || tags?.name;
  function collectTile(match,coords,tile) {
    if (!match || !tile.hits) return;
    const {x,y,z}=coords;
    if (LineFocus.active.extra.has(`tile/${z}/${x}/${y}`)) return;
    const samples=[];
    for (const hit of tile.hits) {
      if (!hit.points || !(match.name && trackName(hit.tags)===match.name ||
          match.id!=null && match.id===hit.id && match.source===hit.source)) continue;
      const path=hit.points.map(([a,b])=>map.unproject([x*256+a,y*256+b],z));
      const tags=hit.tags;
      samples.push({path,style:()=>focusStyle(tags)});
    }
    LineFocus.addTile({x,y,z},samples);
  }
  function collectFocus(match) {
    if (match.name) for (const feature of activeRegion?.lines || []) {
      if (trackName(feature.tags)===match.name && !match.regionAlreadyDrawn) LineFocus.addTracks(`region/${feature.id}`,[{
        path:feature.coordinates.map(p=>[p.latitude,p.longitude]),style:()=>focusStyle(withRouteColour(feature))}]);
    }
    if (live && map.hasLayer(live)) for (const {coords,el,current} of Object.values(live._tiles)) {
      if (current && coords.z===live._tileZoom) collectTile(match,coords,el);
    }
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
    regionTracks=new MetroHandoff.Tracks();
    regionRail=new MetroHandoff.Tracks();
    invalidateMetro();
    if (!activeRegion) return;
    const data = activeRegion;
    const bounds = L.latLngBounds([]);
    const zoom = map.getZoom();
    for (const feature of [...data.lines, ...data.stations]) {
      const tags = withRouteColour(feature), visual = style(tags,false,!feature.coordinates);
      const points = feature.coordinates || [feature.coordinate];
      const coords = points.map(p => [p.latitude,p.longitude]);
      if (fit) coords.forEach(point => bounds.extend(point));
      if (!visual.visible || (AtlasPrefs.value.automaticDetail && (zoom < 8 || (!feature.coordinates && zoom < 11)))) continue;
      let paths=[coords];
      const facts=AtlasPrefs.classify(tags);
      if (feature.coordinates && facts.urban) {
        const identity=MetroHandoff.identity(facts,(feature.routes || []).map(r=>r.id));
        paths=MetroHandoff.remaining(paths,identity,[cityTracks]);
        if (!paths.length) continue;
        regionTracks.add(paths,identity);
      } else if (feature.coordinates) {
        regionRail.add(paths,railwayIdentity(/^way\/(\d+)/.exec(feature.id)?.[1]));
      }
      const item = feature.coordinates ? L.polyline(paths,{...visual,bubblingMouseEvents:false}) :
        L.circleMarker(coords[0],{radius:3.2*AtlasPrefs.value.stationRadiusMultiplier,color:visual.color,fillColor:"#fff",fillOpacity:1,weight:2,bubblingMouseEvents:false});
      const title = feature.name || feature.id;
      if (feature.coordinates) {
        const tooltip = document.createElement("span"); tooltip.textContent = title;
        item.bindTooltip(tooltip);
      }
      const open = () => {
        let focus;
        if (feature.coordinates) {
          const ids=new Set((feature.routes || []).map(r=>r.id));
          const oneDirection=facts.urban && ids.size===1;
          const member=f=>ids.size===1 && f.routes?.some(r=>ids.has(r.id));
          const named=f=>!oneDirection && trackName(tags) && trackName(f.tags)===trackName(tags);
          const lines=data.lines.filter(f=>f.id===feature.id || member(f) || named(f));
          focus={parts:lines.map(f=>f.coordinates.map(p=>[p.latitude,p.longitude])),styleForPart:i=>focusStyle(withRouteColour(lines[i])),
            match:!oneDirection && trackName(tags) ? {name:trackName(tags),regionAlreadyDrawn:true} : null,
            stops:data.stations.filter(member).map(s=>[s.name,[s.coordinate.latitude,s.coordinate.longitude],s.id,()=>stationColors(s)])};
        } else focus={stopColors:()=>stationColors(feature)};
        return focus;
      };
      const select = at => inspect(title,{...tags,membership:(feature.routes || []).map(route => route.name).filter(Boolean).join("、")},!feature.coordinates,at,open());
      if (feature.coordinates) MapHit.bind(item, e => select(e.latlng));
      else StationLabels.bind(item, title, {id:feature.id, minZoom:13, important:StationLabels.prominent(tags, feature.routes),
        open: () => select(item.getLatLng())});
      item.addTo(region);
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
      if (LineFocus.active?.match) collectFocus(LineFocus.active.match);
      live?.redraw();
    } catch (error) { if (generation === regionGeneration) $("regionStatus").textContent = error.message; }
  }
  async function loadOverview() {
    const index = await loadJSON(`${prefix}index.json`);
    await Promise.allSettled(index.tiles.map(async ({x,y,z,file}) => {
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
        for (const part of feature.loadGeometry()) groups.get(key).parts.push(part.map(p=>[p.x/feature.extent,p.y/feature.extent]));
      }
      if (groups.size) {
        regionalTiles.push([x,y]);
        overviewTiles.set(`${x}/${y}`,{x,y,z,groups:[...groups.values()]});
      }
    }));
    overview.redraw();
    toggle();
    world.repaint();
  }
  // Regional Z4 geometry is a tiled overview, just like the global overview.
  // A detailed tile takes over its own cell, including a verified empty rail tile.
  function regionalOverview() {
    const grid=L.gridLayer({pane:"railOverview",minZoom:2,maxZoom:9,keepBuffer:1});
    grid.createTile=coords=>{
      const canvas=document.createElement("canvas"), dpr=Math.min(2,devicePixelRatio||1);
      canvas.width=canvas.height=256*dpr;
      const ctx=canvas.getContext("2d");ctx.scale(dpr,dpr);
      canvas.tracks=[];
      for (const source of overviewTiles.values()) {
        const span=256*2**(coords.z-source.z), dx=span*source.x-coords.x*256, dy=span*source.y-coords.y*256;
        if (dx>=256 || dy>=256 || dx+span<=0 || dy+span<=0) continue;
        ctx.save();ctx.beginPath();ctx.rect(dx,dy,span,span);ctx.clip();
        for (const {tags,parts} of source.groups) {
          const visual=style(tags,true,false,coords.z);
          if (!visual.visible) continue;
          const path=new Path2D();
          for (const part of parts) {
            for (let i=0;i<part.length;i++) path[i?"lineTo":"moveTo"](dx+part[i][0]*span,dy+part[i][1]*span);
          }
          ctx.strokeStyle=visual.color;ctx.lineWidth=visual.weight;ctx.globalAlpha=visual.opacity;
          ctx.lineJoin=ctx.lineCap="round";ctx.setLineDash(visual.dashArray ? [7,6] : []);ctx.stroke(path);
          canvas.tracks.push({path,parts,tags,source});
        }
        ctx.restore();
      }
      if (live?._tiles?.[`${coords.x}:${coords.y}:${coords.z}`]?.el.detailReady) canvas.style.visibility="hidden";
      return canvas;
    };
    return grid;
  }
  async function timedResponse(url, parentSignal, timeout=6500) {
    const controller = new AbortController();
    const abort = () => controller.abort();
    if (parentSignal?.aborted) controller.abort();
    parentSignal?.addEventListener("abort",abort,{once:true});
    const timer = setTimeout(abort,timeout);
    try {
      const response = await fetch(url,{signal:controller.signal,credentials:"omit"});
      if (!response.ok) throw new Error(`地图资料 HTTP ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    } finally {
      clearTimeout(timer);
      parentSignal?.removeEventListener("abort",abort);
    }
  }
  let primaryRetryAt=0, primaryReady=false, primaryProbe;
  async function primaryTile(url,signal) {
    if (!primaryReady) {
      // One short request tests whether this browser can reach the railway
      // source; a CORS refusal should not stall every tile in the viewport.
      primaryProbe ??= {url,result:timedResponse(url,null,2000).then(AtlasVector.decode)};
      const probe=primaryProbe;
      try {
        const tile=await probe.result;
        primaryReady=true;
        if (probe.url===url) return tile;
      } finally { if (primaryProbe===probe) primaryProbe=null; }
    }
    signal.throwIfAborted();
    return AtlasVector.decode(await timedResponse(url,signal));
  }
  async function onlineTile({x,y,z}, signal) {
    if (Date.now()>=primaryRetryAt) {
      const layers="railway_line_high,railway_text_km";
      try {
        const track=await primaryTile(`https://openrailwaymap.app/${layers}/${z}/${x}/${y}`,signal);
        if (z>=9) {
          try {
            const stations=AtlasVector.decode(await timedResponse(`https://openrailwaymap.app/standard_railway_text_stations/${z}/${x}/${y}`,signal));
            return {layers:{...track.layers,...stations.layers}};
          } catch (error) { if(signal.aborted) throw error; }
        }
        return track;
      } catch (error) {
        if (signal.aborted) throw error;
        primaryReady=false;primaryRetryAt=Date.now()+60000;
      }
    }
    tileTemplate ??= timedResponse("https://tiles.openfreemap.org/planet").then(bytes => {
      const template = JSON.parse(new TextDecoder().decode(bytes)).tiles?.[0];
      if (!template?.startsWith("https://tiles.openfreemap.org/")) throw new Error("铁路瓦片地址不可用");
      return template;
    }).catch(error => { tileTemplate = null; throw error; });
    try {
      const template = await tileTemplate;
      const url = template.replace("{x}",x).replace("{y}",y).replace("{z}",z);
      return AtlasVector.decode(await timedResponse(url,signal));
    } catch (error) {
      if (signal.aborted) throw error;
      const url = `https://tiles.versatiles.org/tiles/osm-vector/${z}/${x}/${y}`;
      return AtlasVector.decode(await timedResponse(url,signal));
    }
  }
  // Detail tiles are painted independently. Leaflet retains the previous zoom's
  // tiles while the next view loads. The bundled Z4 layer remains underneath.
  function detailGrid() {
    const parents = new Map();
    function acquire(coords) {
      const key = `${AtlasPrefs.value.mode}/${coords.z}/${coords.x}/${coords.y}`;
      let entry = parents.get(key);
      if (!entry) {
        const controller = new AbortController();
        entry = {controller,users:0,ready:false};
        const request = entry;
        entry.promise = (async () => {
          const local = (await LocalRailCache.read(coords)).map(bytes => AtlasVector.decode(bytes));
          controller.signal.throwIfAborted();
          const primary=local.some(t=>t.layers.railway_line_high);
          const packed=primary ? null : await PackedRail.tile(coords).catch(()=>null);
          controller.signal.throwIfAborted();
          const tiles=packed ? [packed,...local] : local;
          if (!local.length && AtlasPrefs.value.mode==="online") {
            const remote=onlineTile(coords,controller.signal);
            if (packed) request.supplement=remote.then(t=>[packed,t],()=>null);
            else tiles.push(await remote);
          }
          request.ready = true;
          for (const [oldKey, old] of parents) {
            if (parents.size <= 24) break;
            if (old.ready && !old.users) parents.delete(oldKey);
          }
          return tiles;
        })().catch(error=>{if(parents.get(key)===request)parents.delete(key);throw error;});
        parents.set(key, entry);
      }
      entry.users++;
      return {promise:entry.promise,get supplement(){return entry.supplement;},release(){
        if (--entry.users === 0 && !entry.ready && parents.get(key)===entry) {
          parents.delete(key);entry.controller.abort();
        }
      }};
    }
    const Grid = L.GridLayer.extend({
      createTile(coords, done) {
        const canvas = document.createElement("canvas"), size = 256, scale = Math.min(2, devicePixelRatio || 1);
        canvas.width = canvas.height = size * scale;
        const ctx = canvas.getContext("2d"); ctx.scale(scale,scale);
        const {x,y,z} = coords;
        const nativeZ=Math.min(z,14), magnification=2**(z-nativeZ);
        const dx=(x%magnification)*size, dy=(y%magnification)*size;
        const source=acquire({x:Math.floor(x/magnification),y:Math.floor(y/magnification),z:nativeZ});
        let unloaded=false;
        canvas.abortTile = () => {if (!unloaded) {unloaded=true;source.release();}};
        function paint(tiles) {
          if (unloaded) return;
          ctx.clearRect(0,0,size,size);
          canvas.hits = [];
          canvas.stationNames = [];
          canvas.metroTracks=new MetroHandoff.Tracks();
          // Imported caches can contain primary and backup representations of one cell.
          const hasPrimary=tiles.some(t=>t.layers.railway_line_high);
          const packed=!hasPrimary && tiles.find(t=>t.layers.atlas_rail_detail)?.layers.atlas_rail_detail;
          const hasShortbread=tiles.some(t=>t.layers.streets);
          const hasDetail=hasPrimary || packed || hasShortbread || tiles.some(t=>t.layers.transportation);
          const backup=hasShortbread || tiles.some(t=>t.layers.transportation);
          const covered=packed && backup && PackedRail.mask(packed,magnification,dx,dy);
          canvas.detailReady=!!(hasPrimary || packed);
          for (const tile of tiles) {
          for (const layerName of Object.keys(tile.layers).filter(name =>
            ["poi","public_transport","railway_line_high"].includes(name) || !hasPrimary && name==="atlas_rail_detail" ||
            !hasPrimary && (name==="streets" || !hasShortbread && name==="transportation") ||
            !hasDetail && z<=9 && name==="speed_railway_line_low" ||
            name.startsWith("standard_railway_text_stations"))) {
            const layer = tile.layers[layerName];
            for (let i=0; i<(layer?.length || 0); i++) {
              const feature = layer.feature(i), tags = feature.properties;
              const line = feature.type === 2 && (["railway_line_high","speed_railway_line_low","atlas_rail_detail"].includes(layerName) ||
                (["rail","transit"].includes(tags.class) && /^(rail|subway|light_rail|tram|monorail|narrow_gauge|funicular)$/.test(tags.subclass)) ||
                (layerName === "streets" && [true,1,"yes"].includes(tags.rail) &&
                  /^(rail|light_rail|subway|tram|monorail|narrow_gauge|funicular|disused|abandoned)$/.test(tags.kind)));
              const station = feature.type === 1 && z >= 9 && (layerName.startsWith("standard_railway_text_stations") ||
                ["railway","railway_station"].includes(tags.class) ||
                /^(station|halt|tram_stop|subway)$/.test(tags.subclass) ||
                (layerName === "public_transport" && /^(station|halt|tram_stop|subway_station|railway_station)$/.test(tags.kind)));
              if (!line && !station) continue;
              const backupRail=line && ["streets","transportation"].includes(layerName) && !AtlasPrefs.classify(tags).urban;
              // At overview scales a generic transportation tile supplies neither
              // a speed nor a railway classification. Keep the classified overview.
              if(backupRail && !packed && z<=9 && AtlasPrefs.classify(tags).category==="unknown") continue;
              const visual = style(tags,false,station,z);
              if (!visual.visible) continue;
              const factor = size * magnification / feature.extent;
              if (magnification>1) {
                const [a,b,c,d]=feature.bbox();
                if (a*factor>dx+size+8 || b*factor>dy+size+8 || c*factor<dx-8 || d*factor<dy-8) continue;
              }
              ctx.strokeStyle = visual.color; ctx.lineWidth = visual.weight;ctx.globalAlpha=visual.opacity;
              ctx.setLineDash(visual.dashArray ? [7,6] : []);
              for (const path of feature.loadGeometry()) {
                ctx.beginPath();
                if (station && path.length) {
                  const px = path[0].x*factor-dx, py = path[0].y*factor-dy;
                  const radius = 2.4 * AtlasPrefs.value.stationRadiusMultiplier;
                  ctx.arc(px,py,radius,0,Math.PI*2); ctx.fillStyle="#fff"; ctx.fill();
                  const name=tags["name:zh"] || tags.name;
                  const latlng = map.unproject([x*size+px,y*size+py],z);
                  const open = () => inspect(name || tags.ref || "车站",tags,true,latlng);
                  const important = StationLabels.prominent(tags);
                  if (name && z >= 12 && px >= 0 && py >= 0 && px < size && py < size) {
                    canvas.stationNames.push({
                      name, id:feature.id ?? name, minZoom:12, tileZoom:z, radius,
                      important, latlng, open
                    });
                  }
                  canvas.hits.push({x:px,y:py,tags,station:true,important,open,radius:radius+visual.weight/2});
                } else {
                  const points=path.map(p=>[p.x*factor-dx,p.y*factor-dy]);
                  let strokes=backupRail && covered ? PackedRail.outside(points,covered) : [points];
                  const facts=AtlasPrefs.classify(tags);
                  if (z>=8 && (facts.urban || regionRail.bounds)) {
                    // A tile can include a large buffer (especially overzoomed parent
                    // tiles). Only the part actually painted inside it owns coverage.
                    const way=tags.osm_id || /^(\d+)-\d+$/.exec(tags.id)?.[1];
                    const identity=facts.urban ? MetroHandoff.identity(facts) : railwayIdentity(way);
                    const extent=L.bounds([0,0],[size,size]), clipped=[];
                    for (const stroke of strokes) for (let j=1;j<stroke.length;j++) {
                      const segment=L.LineUtil.clipSegment(L.point(stroke[j-1]),L.point(stroke[j]),extent);
                      if (!segment) continue;
                      const last=clipped.at(-1);
                      if (last && last.at(-1).equals(segment[0])) last.push(segment[1]);
                      else clipped.push(segment);
                    }
                    const geographic=clipped.map(part=>part.map(p=>{
                      const ll=map.unproject([x*size+p.x,y*size+p.y],z);
                      return [ll.lat,ll.lng];
                    }));
                    const visible=facts.urban ? MetroHandoff.remaining(geographic,identity,[cityTracks,regionTracks]) :
                      MetroHandoff.remaining(geographic,identity,[regionRail],2);
                    if (facts.urban) canvas.metroTracks.add(visible,identity);
                    strokes=visible.map(part=>part.map(ll=>{
                      const p=map.project(ll,z);
                      return [p.x-x*size,p.y-y*size];
                    }));
                  }
                  for (const stroke of strokes) {
                    stroke.forEach(([x,y],i)=>i ? ctx.lineTo(x,y) : ctx.moveTo(x,y));
                    canvas.hits.push({points:stroke,tags,id:tags.id ?? feature.id,source:layerName});
                  }
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
        }
        source.promise.then(tiles=>{
          if(unloaded)return;
          paint(tiles);
          done(null,canvas);
          source.supplement?.then(next=>{
            if(!next || unloaded)return;
            paint(next); showDetail(coords,canvas.detailReady); StationLabels.schedule(); invalidateMetro();
            const focus=LineFocus.active;
            if(focus?.match) collectTile(focus.match,coords,canvas);
          });
        }).catch(error=>{if(!unloaded)done(error,canvas);});
        return canvas;
      }
    });
    const grid = new Grid({pane:"railDetail",minZoom:7,maxZoom:19,keepBuffer:2,updateWhenIdle:true,
      attribution:AtlasVectorBasemap.openFreeMapAttribution+' · <a href="https://versatiles.org/">VersaTiles</a> · <a href="https://openrailwaymap.app/">OpenRailwayMap</a>'});
    grid.clearSourceCache=()=>{
      for (const entry of parents.values()) if(!entry.ready)entry.controller.abort();
      parents.clear();
    };
    function showDetail(coords,ready) {
      world.showDetail(coords,ready);
      const cell=overview._tiles?.[`${coords.x}:${coords.y}:${coords.z}`]?.el;
      if (cell) cell.style.visibility=ready ? "hidden" : "";
    }
    grid.on("tileunload",event => {event.tile.abortTile?.();showDetail(event.coords,false);});
    grid.on("tileload",event => {
      showDetail(event.coords,!!event.tile.detailReady);
      collectTile(LineFocus.active?.match,event.coords,event.tile);
    });
    grid.on("tileload tileunload",event=>{if (event.tile.metroTracks?.bounds) invalidateMetro();});
    grid.on("tileload tileunload add remove", StationLabels.schedule);
    grid.on("load",()=>toggle());
    MapHit.addProvider(({latlng, zoom, detail, focused, radius, padding, offer}) => {
      if (!map.hasLayer(grid)) return;
      const z = grid._tileZoom;
      if (z==null) return;
      const p = map.project(latlng,z), x = Math.floor(p.x/256), y = Math.floor(p.y/256);
      const cell = grid._tiles[`${x}:${y}:${z}`];
      if (!cell?.current || !cell.loaded) return;
      const tile = cell.el;
      const px=p.x-x*256,py=p.y-y*256;
      const tileScale=map.getZoomScale(z,zoom);
      const trackRadius=radius*tileScale;
      let nearest=Infinity, hit;
      for(const h of tile?.hits || []){
        if(h.station){
          const d=Math.hypot(h.x-px,h.y-py);
          if ((detail || (!focused && h.important && h.radius >= 3*tileScale)) && d<=h.radius+padding*tileScale)
            offer(1,d/tileScale,h.open);
          continue;
        }
        if(!trackRadius) continue;
        for(let i=1;i<h.points.length;i++){
          const [ax,ay]=h.points[i-1],[bx,by]=h.points[i],dx=bx-ax,dy=by-ay;
          const u=Math.max(0,Math.min(1,((px-ax)*dx+(py-ay)*dy)/(dx*dx+dy*dy || 1)));
          const d=Math.hypot(px-ax-u*dx,py-ay-u*dy);if(d<=trackRadius && d<nearest){nearest=d;hit=h;}
        }
      }
      if (hit) offer(3,nearest/tileScale,() => {
        const railName=trackName(hit.tags);
        const match={name:railName,id:hit.id,source:hit.source};
        const anonymous=!railName && hit.id==null;
        inspect(railName || hit.tags.ref || "轨道",hit.tags,false,latlng,
          anonymous ? {parts:[hit.points.map(([a,b])=>map.unproject([x*256+a,y*256+b],z))],styleForPart:()=>focusStyle(hit.tags)}
            : {match,note:"沿线轨迹随地图补充"});
      });
    });
    return grid;
  }
  function eachVisibleStation(visit) {
    if (!live || !map.hasLayer(live)) return;
    const zoom = live._tileZoom;
    for (const tile of Object.values(live._tiles)) {
      if (tile.current && tile.coords.z === zoom) tile.el.stationNames?.forEach(visit);
    }
  }
  function toggle(redraw=false) {
    StationMapBoard.refresh();
    if (!map) return;
    const rail = $("showRail").checked;
    const mode=AtlasPrefs.value.mode;
    setLayerVisible(world,WorldRail.enabled(map.getZoom()) && mode!=="offline");
    setLayerVisible(overview,mode!=="offline" && (rail || state.showMetro));
    setLayerVisible(live,mode!=="offline" && (rail || state.showMetro));
    if (redraw) { world.repaint(); overview.redraw(); live.redraw(); renderRegion(); }
  }
  function setup(target) {
    map = target;
    for (const [pane,z] of [["worldRail",375],["railOverview",380],["railDetail",390]]) map.createPane(pane).style.zIndex = z;
    region = L.layerGroup().addTo(map); overview = regionalOverview();
    world = WorldRail.create(map,regionalTiles,style);
    world.on("tileload", event => {
      const {x,y,z} = event.coords;
      world.showDetail(event.coords,!!live?._tiles?.[`${x}:${y}:${z}`]?.el.detailReady);
    });
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
  return {setup,toggle,inspect,eachVisibleStation,setMetroCities,metroCoverage,collectFocus,clearSourceCache:()=>live?.clearSourceCache()};
})();
