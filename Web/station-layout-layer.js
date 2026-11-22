const StationLayoutLayer = (() => {
  const cacheKey = "railway-atlas-station-areas-v1";
  const byID = new Map(), drawn = new Map(), renderers = {};
  const colors = {outline:["#536981","#B9C8DA"], platform:["#216B62","#7FD3C4"], passage:["#864097","#E4ACF3"]};
  let map, snapshot, loading = false, message = "";
  const attribution = '<a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>';
  let credited = false;

  function remember(features) {
    for (const feature of features) {
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
    for (const id of ["showMetro","showRail"]) $(id).addEventListener("change",()=>queueMicrotask(refresh));
    refresh();
  }
  function refresh() {
    if (!map) return;
    const p=AtlasPrefs.value, z=map.getZoom();
    const enabled=p.showsStations && p.showsStationLayouts && z>=16;
    const button=$("loadStationLayouts"), status=$("stationLayoutStatus");
    if (button) { button.hidden=!enabled || p.mode!=="online"; button.disabled=loading; }
    if (status) {status.hidden=!enabled || !message; status.textContent=message;}
    if (enabled && !snapshot) {
      snapshot=loadJSON("./data/station-layouts.json").then(pack=>{
        remember(pack.features);
        const local=readStored(cacheKey,[]);
        if (Array.isArray(local)) for (const cell of local) if (Array.isArray(cell.features)) remember(cell.features);
        refresh();
      }).catch(()=>{snapshot=null;message="未能读取随包站区资料。";if(status){status.hidden=false;status.textContent=message;}});
    }
    const bounds=map.getBounds(), keep=new Set(), dark=map.getContainer().dataset.stationInk==="light";
    if (enabled) for (const [id,{feature,paths,bounds:box}] of byID) {
      const urban=feature.network!=="railway";
      if (z<StationLayoutOSM.minimumZoom[feature.kind] || !bounds.intersects(box) ||
          !(urban?state.showMetro:$("showRail").checked) || !p.networks.includes(feature.network) ||
          (urban && !p.prioritizesUrbanTransit && !p.categories.includes("urban"))) continue;
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
    if (credited !== !!drawn.size) {
      credited=!!drawn.size;
      map.attributionControl?.[credited?"addAttribution":"removeAttribution"](attribution);
    }
  }
  async function supplement() {
    if (loading || !map || map.getZoom()<16 || AtlasPrefs.value.mode!=="online") return;
    const b=map.getBounds();
    loading=true; message="正在读取当前站区…"; refresh();
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
