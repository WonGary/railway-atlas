const StationLayoutLayer = (() => {
  const legacyCacheKey = "railway-atlas-station-areas-v1";
  const oldCellsKey = "railway-atlas-station-cells-v2";
  const cacheKey = "railway-atlas-station-cells-v3";
  const byID = new Map(), drawn = new Map(), numbers = new Map(), renderers = {};
  const switches = {outline:"showsStationOutlines",concourse:"showsConcourses",platform:"showsPlatforms",passage:"showsPassengerPassages",entrance:"showsStationEntrances"};
  const colors = {outline:["#536981","#B9C8DA"], concourse:["#925216","#FFCD8F"], platform:["#216B62","#7FD3C4"], passage:["#864097","#E4ACF3"],entrance:["#12558A","#A9D6FF"]};
  const visits = new Map(), failures = new Map();
  const worldTiles = new Map();
  let worldIndex, worldView = "", worldRows = [], worldGeneration = 0, worldRetry = 0;
  let map, snapshot, baseFeatures = [], activeKey, pending, timer, nextRequest = 0, message = "";
  let snapshotError = false;
  const attribution = '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';
  const ltaCredit = '<a href="https://data.gov.sg/datasets/d_b39d3a0871985372d7e1637193335da5/view" target="_blank" rel="noopener">LTA MRT Station Exit</a> · <a href="https://data.gov.sg/open-data-licence" target="_blank" rel="noopener">Singapore Open Data Licence</a>';
  let credited = false, ltaCredited = false;
  let worldAliases = new Set();

  function entryFor(feature) {
    if (!colors[feature.kind] || !Array.isArray(feature.paths) || !feature.paths[0]?.length) return null;
    const paths = feature.paths.map(path=>path.map(([lon,lat])=>[lat,lon]));
    return {feature,paths,bounds:L.latLngBounds(paths[0])};
  }
  function remember(features) {
    for (const feature of StationLayoutOSM.prepareFeatures(features)) {
      const entry=entryFor(feature);
      if (entry) byID.set(feature.id,entry);
    }
  }
  function style(feature,dark) {
    const kind = feature.kind;
    const point=feature.paths[0].length===1;
    return {color:colors[kind][dark?1:0], weight:kind==="outline"?1.4:2.2,
      fill:feature.area || point, fillOpacity:kind==="outline"?0.17:kind==="concourse"?0.22:0.34, dashArray:kind==="passage"?"4 3":null};
  }
  async function readWorldTile(path) {
    const url = new URL(path, document.baseURI);
    const bundled = url.hostname === "appassets.androidplatform.net" ||
      (url.hostname === "127.0.0.1" && url.port === "18763");
    if (navigator.onLine !== false || bundled) return loadJSON(path);
    const cached = await globalThis.caches?.match(url);
    if (cached) return cached.json();
    throw new Error("这个站区还没有离线缓存");
  }
  function showWorldTiles(bounds, enabled) {
    const keys = [];
    if (enabled && bounds.getEast()-bounds.getWest()<2 && bounds.getNorth()-bounds.getSouth()<2) {
      for (let y=Math.floor(bounds.getSouth()*4); y<=Math.floor(bounds.getNorth()*4); y++)
        for (let x=Math.floor(bounds.getWest()*4); x<=Math.floor(bounds.getEast()*4); x++)
          keys.push(`${y}_${((x+720)%1440+1440)%1440-720}`);
    }
    const view=keys.join("/");
    if (view===worldView && (!worldRetry || Date.now()<worldRetry)) return;
    worldView=view; worldRetry=0;
    const version=++worldGeneration;
    if (!keys.length) {
      worldRows=[]; worldAliases.clear();
      return;
    }
    const folder="./data/world-stations/";
    worldIndex ??= loadJSON(folder+"index.json").catch(error=>{ worldIndex=null; throw error; });
    worldIndex.then(async index=>{
      if (version!==worldGeneration) return;
      const layers=[index,...(index.supplements || [])];
      const files=keys.flatMap(key=>layers.map(layer=>layer.tiles[key]).filter(Boolean));
      const parts=await Promise.allSettled(files.map(file=>{
        let tile=worldTiles.get(file);
        if (tile) worldTiles.delete(file);
        else tile=readWorldTile(folder+file).then(rows=>rows.map(entryFor).filter(Boolean))
          .catch(error=>{ worldTiles.delete(file); throw error; });
        worldTiles.set(file,tile);
        return tile;
      }));
      if (version!==worldGeneration) return;
      if (parts.some(part=>part.status==="rejected")) worldRetry=Date.now()+10000;
      while (worldTiles.size>12) worldTiles.delete(worldTiles.keys().next().value);
      const unique=new Map();
      for (const part of parts) if (part.status==="fulfilled")
        for (const entry of part.value) unique.set(entry.feature.id,entry);
      worldRows=[...unique.values()];
      worldAliases=new Set(worldRows.map(entry=>entry.feature.matchedOSM).filter(Boolean));
      refresh();
    }).catch(()=>{ if(version===worldGeneration) worldRetry=Date.now()+10000; });
  }
  function setup(leafletMap) {
    map = leafletMap;
    for (const [kind,index] of [["outline",375],["concourse",376],["platform",394],["passage",395],["entrance",396]]) {
      const pane="station-layout-"+kind;
      const el=map.createPane(pane);
      el.style.zIndex=index;
      el.style.pointerEvents="none";
      renderers[kind]=L.svg({pane});
    }
    map.on("moveend zoomend resize",refresh);
    const numberPane=map.createPane("station-layout-number");
    numberPane.style.zIndex=610;
    numberPane.style.pointerEvents="none";
    refresh();
  }
  function refreshNumbers(entries, enabled, p) {
    const scale=p.uiScale;
    const keep=new Set(), occupied=[];
    const candidates=enabled ? entries.filter(({feature:f})=>f.labelAnchors?.length &&
      (f.kind==="platform" && p.showsPlatformNumbers && f.platformLabel ||
       f.kind==="passage" && p.showsPassageSigns && f.accessLabel ||
       f.kind==="entrance" && p.showsStationEntrances && f.accessLabel)) : [];
    const ids=new Set(candidates.map(({feature})=>feature.id));
    const rank=f=>f.kind==="entrance" ? (f.network==="railway" && /[进進出]站/.test(f.accessTitle)?0:1) :
      f.kind==="passage" ? 4 : f.area ? 2 : 3;
    candidates.sort((a,b)=>rank(a.feature)-rank(b.feature) || a.feature.id.localeCompare(b.feature.id));
    const screen=L.bounds([0,0],map.getSize());
    function place(feature, displaced=false) {
      if (ids.has(feature.labelOwner)) return false;
      const badge=feature.kind!=="platform", text=feature.accessLabel || feature.platformLabel;
      const textWidth=Array.from(text).reduce((sum,ch)=>sum+(ch.codePointAt(0)>255?10.5:6.7),0);
      const width=(badge?Math.max(18,textWidth+6):Math.max(13,text.length*7.5+5))*scale, height=badge?width:17*scale;
      const offsets=displaced?[width+4,(width+4)*1.6].flatMap(radius=>
        [[1,0],[-1,0],[0,-1],[0,1],[.71,-.71],[-.71,.71],[-.71,-.71],[.71,.71]].map(([x,y])=>[x*radius,y*radius])):[[0,0]];
      for (const [lon,lat] of feature.labelAnchors) {
        const position=L.latLng(lat,lon), origin=map.latLngToContainerPoint(position);
        if (!screen.contains(origin)) continue;
        for (const [dx,dy] of offsets) {
        const p=origin.add([dx,dy]);
        const box=L.bounds([p.x-width/2,p.y-height/2],[p.x+width/2,p.y+height/2]);
        if (!screen.contains(box) || occupied.some(old=>old.intersects(box))) continue;
        occupied.push(L.bounds(box.min.subtract([2,1]),box.max.add([2,1])));keep.add(feature.id);
        const previous=numbers.get(feature.id);
        if (previous && previous.text===text && previous.scale===scale && previous.title===feature.accessTitle &&
            previous.dx===dx && previous.dy===dy) {
          if (!previous.marker.getLatLng().equals(position)) previous.marker.setLatLng(position);
        } else {
          previous?.marker.remove();
          const glyph=document.createElement("span");glyph.textContent=text;
          const icon=L.divIcon({className:badge?"access-badge "+feature.kind:"platform-number",html:glyph,iconSize:[width,height],iconAnchor:[width/2-dx,height/2-dy]});
          const marker=L.marker(position,{icon,pane:"station-layout-number",interactive:badge,keyboard:badge,
            title:feature.accessTitle || "",alt:feature.accessTitle || text}).addTo(map);
          if (badge) {
            const title=document.createElement("span");title.textContent=feature.accessTitle || text;
            marker.bindTooltip(title,{direction:"top"}).on("click",()=>marker.openTooltip());
          }
          const el=marker.getElement();
          el.dataset.osmId=feature.id;
          if (displaced) {
            el.classList.add("offset-badge");
            el.style.setProperty("--leader-angle",`${Math.atan2(-dy,-dx)}rad`);
            el.style.setProperty("--leader-inset",`${width/2}px`);
            el.style.setProperty("--leader-length",`${Math.hypot(dx,dy)-width/2}px`);
          }
          numbers.set(feature.id,{marker,scale,text,title:feature.accessTitle,dx,dy});
        }
        return true;
        }
      }
      return false;
    }
    const exits=candidates.filter(({feature})=>feature.kind==="entrance");
    const crowded=exits.filter(({feature})=>!place(feature));
    for (const {feature} of crowded) place(feature,true);
    for (const {feature} of candidates) if (feature.kind!=="entrance") place(feature);
    for (const [id,{marker}] of numbers) if (!keep.has(id)) {marker.remove();numbers.delete(id);}
  }
  function refresh() {
    if (!map) return;
    const p=AtlasPrefs.value, z=map.getZoom();
    const enabled=p.showsStationLayouts && z>=StationLayoutOSM.minimumZoom.outline;
    showWorldTiles(map.getBounds(),enabled);
    const cell=currentCell(enabled,p);
    const button=$("loadStationLayouts"), status=$("stationLayoutStatus");
    const options=$("stationDetailOptions");
    if (options) options.hidden=!p.showsStationLayouts;
    if (enabled && !snapshot) {
      const legacy=readStored(legacyCacheKey,[]);
      const saved=readStored(cacheKey,[]);
      if (Array.isArray(saved)) for (const row of saved.slice(-32)) {
        if (typeof row?.key==="string" && Number.isFinite(row.date) && Array.isArray(row.features)) visits.set(row.key,row);
      }
      snapshot=loadJSON("./data/station-layouts.json").then(pack=>pack.features).catch(()=>{
        snapshotError=true;
        return [];
      }).then(features=>{
        const old=[legacy,readStored(oldCellsKey,[])].flatMap(cache=>Array.isArray(cache)?
          cache.flatMap(row=>Array.isArray(row?.features)?row.features:[]):[]);
        baseFeatures=[...old,...features];
        rebuild();
        refresh();
      });
    }
    schedule(cell);
    if (button) { button.hidden=!enabled || p.mode!=="online"; button.disabled=!cell || !!pending; }
    const bounds=map.getBounds(), keep=new Set(), dark=map.getContainer().dataset.stationInk==="light";
    const inView=entry=>bounds.intersects(entry.bounds) && !worldAliases.has(entry.feature.id);
    const nearby=enabled ? [...byID.values()].filter(inView)
      .concat(worldRows.filter(entry=>!byID.has(entry.feature.id) && inView(entry))) : [];
    if (status) {
      status.hidden=!p.showsStationLayouts;
      const counts={outline:0,concourse:0,platform:0,passage:0,entrance:0};
      for (const entry of nearby) counts[entry.feature.kind]++;
      const summary=nearby.length ? `当前视野有车站轮廓 ${counts.outline}，站厅 ${counts.concourse}，站台 ${counts.platform}，通道 ${counts.passage}，出入口 ${counts.entrance}。` :
        p.mode==="online" ? "" : "本地没有当前视野的站区图形。";
      status.textContent=z<StationLayoutOSM.minimumZoom.outline ? "放大到 Z14 可查看站区轮廓。" : [summary,message,
        snapshotError?"随包资料读取失败。":""].filter(Boolean).join(" ");
    }
    for (const {feature,paths} of nearby) {
      const id=feature.id;
      if (z<StationLayoutOSM.minimumZoom[feature.kind] || !p[switches[feature.kind]]) continue;
      keep.add(id);
      const previous=drawn.get(id);
      if (previous?.feature===feature) {
        if(previous.dark!==dark){previous.layer.setStyle(style(feature,dark));previous.dark=dark;}
        continue;
      }
      previous?.layer.remove();
      const options={...style(feature,dark),renderer:renderers[feature.kind],pane:"station-layout-"+feature.kind,interactive:false};
      const layer=feature.area ? L.polygon(paths,options) :
        paths[0].length === 1 ?
          L.circleMarker(paths[0][0],{...options,radius:feature.kind==="entrance"?3:4}) : L.polyline(paths[0],options);
      layer.addTo(map);
      const path=layer.getElement();
      if(path) path.dataset.osmId=id;
      drawn.set(id,{layer,dark,feature});
    }
    for (const [id,{layer}] of drawn) if (!keep.has(id)) { layer.remove(); drawn.delete(id); }
    refreshNumbers(nearby,enabled && z>=StationLayoutOSM.minimumZoom.entrance,p);
    if (credited !== !!(drawn.size || numbers.size)) {
      credited=!!(drawn.size || numbers.size);
      map.attributionControl?.[credited?"addAttribution":"removeAttribution"](attribution);
    }
    const ltaVisible=nearby.some(({feature})=>feature.id.startsWith("sg-lta/") && keep.has(feature.id));
    if (ltaCredited!==ltaVisible) {
      ltaCredited=ltaVisible;
      map.attributionControl?.[ltaVisible?"addAttribution":"removeAttribution"](ltaCredit);
    }
  }
  function rebuild() {
    byID.clear();
    remember(baseFeatures);
    for (const visit of visits.values()) remember(visit.features);
  }
  function currentCell(enabled,p) {
    if (!enabled || p.mode!=="online" || !(p.showsPlatformNumbers || p.showsPassageSigns || Object.values(switches).some(key=>p[key]))) return null;
    const {lat,lng}=map.getCenter().wrap();
    if (Math.abs(lat)>85) return null;
    const y=Math.round(lat*250), x=Math.round(lng*250);
    return {key:`${y}_${x}`,lat:y/250,lon:x/250};
  }
  function resultMessage(features) {
    return features.length ? `已读取地图中心附近的 ${features.length} 个站区要素。` :
      "已查询，OSM 暂无这片站区的可绘制资料。";
  }
  function schedule(cell,force=false) {
    const key=cell?.key ?? null, now=Date.now(), visit=visits.get(key);
    const fresh=visit && now-visit.date<(visit.features.length?7:1)*86400000;
    const cooling=(failures.get(key) || 0)>now;
    if (!force && key===activeKey && (!key || pending || timer || fresh || cooling)) return;
    clearTimeout(timer); timer=null;
    pending?.abort(); pending=null;
    activeKey=key; message="";
    if (!cell) return;
    if (!force && fresh) { message=resultMessage(visit.features); return; }
    if (!force && cooling) { message="上次读取失败，可重新查询当前站区。"; return; }
    message="正在查询地图中心附近的站区…";
    timer=setTimeout(()=>{
      timer=null;
      fetchCell(cell);
    },force?0:Math.max(800,nextRequest-now));
  }
  async function fetchCell(cell) {
    const controller=new AbortController();
    pending=controller;
    nextRequest=Date.now()+5000;
    refresh();
    try {
      const {lat,lon,key}=cell;
      const q=StationLayoutOSM.query(Math.max(-85,lat-.006),Math.max(-180,lon-.008),Math.min(85,lat+.006),Math.min(180,lon+.008));
      for (const url of StationLayoutOSM.sources(lat,lon)) {
        if (controller.signal.aborted) return;
        const attempt=new AbortController(), cancel=()=>attempt.abort();
        controller.signal.addEventListener("abort",cancel,{once:true});
        const regional=url.startsWith("https://ovp.dresel.systems/");
        const deadline=setTimeout(cancel,regional?8000:16000);
        try {
          const response=await fetch(url,{method:"POST",body:new URLSearchParams({data:q}),signal:attempt.signal,credentials:"omit"});
          if (!response.ok || Number(response.headers.get("content-length"))>8_000_000) continue;
          const blob=await response.blob();
          if (blob.size>8_000_000) continue;
          const features=StationLayoutOSM.extract(JSON.parse(await blob.text()));
          if (controller.signal.aborted) return;
          if (!features.length && regional) continue;
          failures.delete(key);
          visits.delete(key);
          visits.set(key,{key,date:Date.now(),features});
          if (visits.size>32) visits.delete(visits.keys().next().value);
          writeStored(cacheKey,[...visits.values()]);
          rebuild();
          message=resultMessage(features);
          return;
        } catch { /* Try the next source unless the user has moved the map. */ }
        finally { clearTimeout(deadline); controller.signal.removeEventListener("abort",cancel); }
      }
      if (!controller.signal.aborted) {
        for (const [key,until] of failures) if (until<=Date.now()) failures.delete(key);
        failures.set(cell.key,Date.now()+90000);
        message="本次未能联网读取站区，可重新查询。";
      }
    } finally { if (pending===controller) { pending=null; refresh(); } }
  }
  function supplement() {
    if (!map) return;
    const p=AtlasPrefs.value, cell=currentCell(p.showsStationLayouts && map.getZoom()>=StationLayoutOSM.minimumZoom.outline,p);
    if (cell) { schedule(cell,true); refresh(); }
  }
  function addFocusButton(parent,coordinate) {
    if (!coordinate) return;
    const button=document.createElement("button");
    button.type="button";
    button.className="text-button";
    button.textContent="查看站区细节";
    button.onclick=()=>{
      if (!AtlasPrefs.value.showsStationLayouts) {
        AtlasPrefs.change("showsStationLayouts",true,false);
        const toggle=$("pref-showsStationLayouts");
        if (toggle) toggle.checked=true;
      }
      if (window.matchMedia("(max-width: 900px)").matches) $("infoPanel").hidden=true;
      map.setView(coordinate,Math.max(StationLayoutOSM.minimumZoom.entrance,map.getZoom()),{animate:false});
      refresh();
    };
    parent.prepend(button);
  }
  return {setup,refresh,supplement,addFocusButton};
})();
