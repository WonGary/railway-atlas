const StationLayoutLayer = (() => {
  const cacheKey = "railway-atlas-station-areas-v1";
  const byID = new Map(), drawn = new Map(), numbers = new Map(), renderers = {};
  const switches = {outline:"showsStationOutlines",platform:"showsPlatforms",passage:"showsPassengerPassages"};
  const colors = {outline:["#536981","#B9C8DA"], platform:["#216B62","#7FD3C4"], passage:["#864097","#E4ACF3"]};
  let map, snapshot, loading = false, message = "", messageBounds;
  const attribution = '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';
  let credited = false;

  function remember(features) {
    for (const feature of StationLayoutOSM.prepareFeatures(features)) {
      if (!colors[feature.kind] || !Array.isArray(feature.paths) || !feature.paths[0]?.length) continue;
      const paths = feature.paths.map(path=>path.map(([lon,lat])=>[lat,lon]));
      byID.set(feature.id,{feature,paths,bounds:L.latLngBounds(paths[0])});
      const previous = drawn.get(feature.id);
      if (previous) { previous.layer.remove(); drawn.delete(feature.id); }
    }
  }
  function style(feature,dark) {
    const kind = feature.kind;
    return {color:colors[kind][dark?1:0], weight:kind==="outline"?1.4:2.2,
      fill:feature.area, fillOpacity:kind==="outline"?0.17:0.34, dashArray:kind==="passage"?"4 3":null};
  }
  function setup(leafletMap) {
    map = leafletMap;
    for (const [kind,index] of [["outline",375],["platform",394],["passage",395]]) {
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
  function refreshNumbers(entries, enabled, scale) {
    const keep=new Set(), occupied=[];
    const candidates=enabled ? entries.filter(({feature})=>feature.platformLabel && feature.labelAnchors?.length) : [];
    const ids=new Set(candidates.map(({feature})=>feature.id));
    candidates.sort((a,b)=>Number(b.feature.area)-Number(a.feature.area) || a.feature.id.localeCompare(b.feature.id));
    const screen=L.bounds([0,0],map.getSize());
    for (const {feature} of candidates) {
      if (ids.has(feature.labelOwner)) continue;
      const text=feature.platformLabel;
      const width=Math.max(13,text.length*7.5+5)*scale, height=17*scale;
      for (const [lon,lat] of feature.labelAnchors) {
        const position=L.latLng(lat,lon), p=map.latLngToContainerPoint(position);
        const box=L.bounds([p.x-width/2,p.y-height/2],[p.x+width/2,p.y+height/2]);
        if (!screen.contains(box) || occupied.some(old=>old.intersects(box))) continue;
        occupied.push(L.bounds(box.min.subtract([2,1]),box.max.add([2,1])));keep.add(feature.id);
        const previous=numbers.get(feature.id);
        if (previous && previous.text===text && previous.scale===scale) {
          if (!previous.marker.getLatLng().equals(position)) previous.marker.setLatLng(position);
        } else {
          previous?.marker.remove();
          const glyph=document.createElement("span");glyph.textContent=text;
          const icon=L.divIcon({className:"platform-number",html:glyph,iconSize:[width,height],iconAnchor:[width/2,height/2]});
          const marker=L.marker(position,{icon,pane:"station-layout-number",interactive:false,keyboard:false}).addTo(map);
          numbers.set(feature.id,{marker,scale,text});
        }
        break;
      }
    }
    for (const [id,{marker}] of numbers) if (!keep.has(id)) {marker.remove();numbers.delete(id);}
  }
  function refresh() {
    if (!map) return;
    const p=AtlasPrefs.value, z=map.getZoom();
    const enabled=p.showsStationLayouts && z>=16;
    const button=$("loadStationLayouts"), status=$("stationLayoutStatus");
    const options=$("stationDetailOptions");
    if (options) options.hidden=!p.showsStationLayouts;
    if (button) { button.hidden=!enabled || p.mode!=="online"; button.disabled=loading; }
    if (enabled && !snapshot) {
      snapshot=loadJSON("./data/station-layouts.json").then(pack=>{
        remember(pack.features);
        const local=readStored(cacheKey,[]);
        if (Array.isArray(local)) for (const cell of local) if (Array.isArray(cell.features)) remember(cell.features);
        refresh();
      }).catch(()=>{snapshot=null;message="未能读取随包站区资料。";if(status){status.hidden=false;status.textContent=message;}});
    }
    const bounds=map.getBounds(), keep=new Set(), dark=map.getContainer().dataset.stationInk==="light";
    const nearby=enabled ? [...byID.values()].filter(entry=>bounds.intersects(entry.bounds)) : [];
    if (status) {
      status.hidden=!p.showsStationLayouts;
      status.textContent=z<16 ? "放大到 Z16 可查看站区。" : message && messageBounds?.contains(bounds.getCenter()) ? message :
        nearby.length ? `当前视野有 ${nearby.filter(e=>e.feature.kind==="platform" && e.paths[0].length>1).length} 个站台图形。` :
        (p.mode==="online" ? "本地暂无这一带的站区资料，可补充当前站区。" : "随包和已缓存的资料未覆盖当前视野。");
    }
    for (const {feature,paths} of nearby) {
      const id=feature.id;
      if (z<StationLayoutOSM.minimumZoom[feature.kind] || !p[switches[feature.kind]] || paths[0].length<2) continue;
      keep.add(id);
      const previous=drawn.get(id);
      if (previous) {
        if(previous.dark!==dark){previous.layer.setStyle(style(feature,dark));previous.dark=dark;}
        continue;
      }
      const options={...style(feature,dark),renderer:renderers[feature.kind],pane:"station-layout-"+feature.kind,interactive:false};
      const layer=feature.area ? L.polygon(paths,options) : L.polyline(paths[0],options);
      layer.addTo(map);
      const path=layer.getElement();
      if(path) path.dataset.osmId=id;
      drawn.set(id,{layer,dark});
    }
    for (const [id,{layer}] of drawn) if (!keep.has(id)) { layer.remove(); drawn.delete(id); }
    refreshNumbers(nearby,enabled && z>=18 && p.showsPlatformNumbers,p.uiScale);
    if (credited !== !!(drawn.size || numbers.size)) {
      credited=!!(drawn.size || numbers.size);
      map.attributionControl?.[credited?"addAttribution":"removeAttribution"](attribution);
    }
  }
  async function supplement() {
    if (loading || !map || map.getZoom()<16 || AtlasPrefs.value.mode!=="online") return;
    const b=map.getBounds();
    loading=true; messageBounds=b; message="正在读取当前站区…"; refresh();
    try {
      const q=StationLayoutOSM.query(b.getSouth(),b.getWest(),b.getNorth(),b.getEast());
      const url = new URL("https://overpass-api.de/api/interpreter");
      url.searchParams.set("data",q);
      const response=await fetch(url,{signal:AbortSignal.timeout(24000)});
      if (!response.ok) throw Error("数据服务未响应");
      const bytes=await response.blob();
      if (bytes.size>8_000_000) throw Error("站区过大");
      const features=StationLayoutOSM.extract(JSON.parse(await bytes.text()));
      if (features.length) {
        remember(features);
        const center=b.getCenter(), key=[center.lat,center.lng].map(v=>v.toFixed(3)).join(",");
        const prior=readStored(cacheKey,[]);
        writeStored(cacheKey,[...(Array.isArray(prior)?prior:[]).filter(cell=>cell.key!==key),{key,features}].slice(-32));
      }
      message=features.length?`已读取当前站区的 ${features.length} 个要素。`:"这个站区暂缺已绘制的细节。";
    } catch {message="未能读取这个站区，稍后可以重试。";}
    finally {loading=false;refresh();}
  }
  return {setup,refresh,supplement};
})();
