// A separate foreground pane keeps the original map layers interactive and lets
// tile arrivals, zooms and preference changes retain their normal paint styles.
const LineFocus = (() => {
  let map, ink, current, rimRenderer, trackRenderer, renderer;
  const loaded = new Map();
  function read(file) {
    if (!loaded.has(file)) loaded.set(file,loadJSON("./station-directory/lines/"+file)
      .catch(error=>{loaded.delete(file);throw error;}));
    return loaded.get(file);
  }
  function setup(target) {
    map=target;
    const pane=map.createPane("lineFocus");
    pane.style.zIndex=620; pane.style.pointerEvents="none";
    // Keep casings below every track and station rings above arriving rail tiles.
    [rimRenderer,trackRenderer,renderer]=Array.from({length:3},()=>L.svg({pane:"lineFocus",padding:.4}).addTo(map));
    ink=L.layerGroup().addTo(map);
    $("clearLineFocus").onclick=()=>clear();
    document.addEventListener("keydown",e=>{
      if (e.key==="Escape" && current && !e.target.closest?.("input,textarea,dialog,select")) clear();
    });
    map.on("click",e=>{
      if (e.sourceTarget===map && !e.originalEvent?.atlasFeatureHit) clear();
    });
  }
  function clear() {
    if (!current) return;
    current=null; ink.clearLayers();
    map.getContainer().classList.remove("line-focused");
    $("lineFocusBar").hidden=true;
    StationLabels.schedule();
  }
  const pathOptions={pane:"lineFocus",interactive:false,lineCap:"round",lineJoin:"round"};
  function tracks(paths,styles,layer=ink) {
      if (!paths.length) return;
      L.polyline(paths,{...pathOptions,renderer:rimRenderer,color:"#ffffff",weight:7.5,opacity:.9}).addTo(layer);
      const groups=new Map();
      paths.forEach((path,i)=>{
        const style=styles?.(i) || {}, color=style.color || AtlasPrefs.value.focusColor;
        const key=[color,style.dashArray || ""].join("|");
        if (!groups.has(key)) groups.set(key,{color,dashArray:style.dashArray,parts:[]});
        groups.get(key).parts.push(path);
      });
      for (const {color,dashArray,parts} of groups.values())
        L.polyline(parts,{...pathOptions,renderer:trackRenderer,color,dashArray,weight:4.4,opacity:1}).addTo(layer);
  }
  function drawExtra(entry) {
    const group=L.layerGroup();
    tracks(entry.samples.map(s=>s.path),i=>entry.samples[i].style(),group);
    ink.addLayer(group);
    if (entry.group) ink.removeLayer(entry.group);
    entry.group=group;
  }
  function addTracks(key, samples) {
    if (!current || !samples.length || current.extra.has(key)) return;
    const entry={samples};
    current.extra.set(key,entry);
    drawExtra(entry);
  }
  // Clip in the tile's pixel space. An ancestor keeps only the portions for
  // which no finer matching rail geometry has arrived.
  function clippedSamples(samples,cell,inside) {
    const origin=L.point(cell.x*256,cell.y*256);
    const bounds=L.bounds(origin,origin.add([256,256])), result=[];
    for (const sample of samples) {
      const path=sample.path.map(ll=>map.project(ll,cell.z));
      let part=[];
      function finish() {
        if (part.length>1) result.push({...sample,path:part.map(p=>map.unproject(p,cell.z))});
        part=[];
      }
      function append(a,b) {
        if (a.equals(b)) return;
        if (part.length && !part.at(-1).equals(a)) finish();
        if (!part.length) part.push(a);
        part.push(b);
      }
      for (let i=1;i<path.length;i++) {
        const a=path[i-1], b=path[i], cut=L.LineUtil.clipSegment(a,b,bounds);
        if (inside) { if (cut) append(...cut); else finish(); }
        else if (!cut) append(a,b);
        else { append(a,cut[0]);finish();append(cut[1],b); }
      }
      finish();
    }
    return result;
  }
  function addTile(cell,samples) {
    if (!current || !samples.length) return;
    const key=`tile/${cell.z}/${cell.x}/${cell.y}`;
    if (current.extra.has(key)) return;
    let visible=clippedSamples(samples,cell,true);
    if (!visible.length) return;
    const contains=(outer,inner)=>inner.z>outer.z &&
      Math.floor(inner.x/2**(inner.z-outer.z))===outer.x && Math.floor(inner.y/2**(inner.z-outer.z))===outer.y;
    for (const entry of current.extra.values()) {
      if (!entry.cell) continue;
      if (contains(entry.cell,cell)) {
        entry.samples=clippedSamples(entry.samples,cell,false);
        drawExtra(entry);
      } else if (contains(cell,entry.cell)) visible=clippedSamples(visible,entry.cell,false);
    }
    const entry={cell,samples:visible};
    current.extra.set(key,entry);
    drawExtra(entry);
  }
  function paint() {
    ink.clearLayers();
    const {parts,stops,selectStop}=current;
    const options={...pathOptions,renderer};
    tracks(parts,current.styleForPart);
    for (const entry of current.extra.values()) drawExtra(entry);
    const drawn=[];
    if (AtlasPrefs.value.showsStations) for (const [name,p,id,source] of stops) {
      const colors=stopColors(source), radius=4.7*AtlasPrefs.value.stationRadiusMultiplier;
      const marker=L.circleMarker(p,{...options,interactive:!!selectStop,bubblingMouseEvents:false,
        radius,weight:2.5,color:colors[0],fillColor:"#fff",fillOpacity:1});
      if (drawn.some(s=>s[0]===name && marker.getLatLng().distanceTo(s[1])<250)) continue;
      drawn.push([name,p]);
      StationLabels.bind(marker,name,{id:id||name,minZoom:0,focused:true});
      if (selectStop) marker.on("click",()=>selectStop(name,id));
      marker.addTo(ink);
      if (colors.length>1) {
        const step=2*Math.PI*radius/colors.length;
        colors.forEach((color,i)=>L.circleMarker(p,{...options,radius,weight:2.5,color,fill:false,
          lineCap:"butt",dashArray:`${step} ${step*(colors.length-1)}`,dashOffset:-i*step}).addTo(ink));
      }
    }
    $("lineFocusName").textContent=current.title;
    $("lineFocusNote").textContent=current.note || "";
    $("lineFocusBar").hidden=false;
    map.getContainer().classList.add("line-focused");
    StationLabels.schedule();
  }
  function set(title,parts,stops=[],opts={}) {
    if (!map) return;
    current={title,parts,stops,extra:new Map(),...opts};
    paint();
    if (current.match) RailMapLayers.collectFocus(current.match);
    if (current.match?.name && !current.directory) void addDirectoryTrack(current,current.match.name);
    return current;
  }
  async function addDirectoryTrack(selection,name) {
    try {
      const index=await read("index.json");
      if (!index[name] || selection!==current) return;
      const entries=(await read(index[name]))[name] || [];
      if (selection!==current) return;
      // Directory geometry is the continuous backing; local speed colours stay on top.
      const paths=entries.map(([, ,path])=>RailPaths.decode(path));
      drawBacking(paths);
    } catch { /* The selected source geometry remains available. */ }
  }
  function drawBacking(paths) {
    if (!paths.length) return;
    const backing=L.layerGroup().addTo(ink);
    tracks(paths,null,backing);
    backing.eachLayer(line=>line.bringToBack());
    current.backing=paths;
  }
  function stopColors(source) {
    const colors=typeof source==="function" ? source() : source;
    return colors?.length ? colors : [AtlasPrefs.value.focusColor];
  }
  function station(name,id,p,colors) {
    if (current?.stops.some(([n,,key])=>id && key ? key===id : n===name)) return;
    if (p) set(name,[],[[name,p,id,colors]]);
    else clear();
  }
  function metro(city,route,{fit = false} = {}) {
    const key=AtlasPrefs.routeKey(city.name,route);
    const detail=state.metroCityLayers.get(city.id);
    const members=(detail?.routeLines || []).filter(e=>AtlasPrefs.routeKey(city.name,e.route)===key);
    const ids=new Set(members.map(e=>e.route.id));
    const parts=members.flatMap(e=>e.line.getLatLngs());
    const stops=(detail?.detail.stations || []).filter(s=>s.routes?.some(r=>ids.has(r.id)))
      .map(s=>[s.name,pointToLatLng(s.coordinate),s.id,()=>metroStopColors(detail,s)]).filter(([,p])=>p);
    const styles=members.flatMap(e=>e.line.getLatLngs().map(()=>()=>({color:e.construction ? "#d5dce0" :
      AtlasPrefs.value.showsMetroColors && e.route.color, dashArray:e.line.options.dashArray})));
    set(metroRouteLabel(route),parts,stops,{styleForPart:i=>styles[i](),
      selectStop:(_name,id)=>{const s=detail.detail.stations.find(s=>s.id===id);if(s) selectMetroStation(city,s,{pan:false});}});
    if (fit) {
      const bounds=L.latLngBounds(stops.map(([,location])=>location));
      for (const member of members) bounds.extend(member.line.getBounds());
      if (bounds.isValid()) map.fitBounds(bounds,{padding:[32,32],maxZoom:15,animate:false});
    }
  }
  function closestPart(parts,at) {
    const target=map.project(at);
    let best=null,distance=Infinity;
    for(const part of parts) for(let i=1;i<part.length;i++) {
      const d=L.LineUtil.pointToSegmentDistance(target,map.project(part[i-1]),map.project(part[i]));
      if(d<distance){distance=d;best=part;}
    }
    return best;
  }
  async function directory(title,rows,names,fit=false) {
    const selection=set(title,[],rows,{directory:true,match:{name:title},note:"读取轨迹…",selectStop:n=>selectStation(n,{pan:false})});
    if (!selection) return;
    if (fit && rows.length) map.fitBounds(rows.map(r=>r[1]),{padding:[36,36],maxZoom:13,animate:false});
    try {
      const index=await read("index.json");
      const entries=index[title] ? (await read(index[title]))[title] : [];
      if (current!==selection) return;
      const wanted=new Set(names), covered=new Set(), order=new Map(names.map((n,i)=>[n,i]));
      for (const [a,b,path] of entries || []) if (wanted.has(a) && wanted.has(b)) {
        selection.parts.push(RailPaths.decode(path));
        const lo=Math.min(order.get(a),order.get(b)),hi=Math.max(order.get(a),order.get(b));
        for(let i=lo;i<hi;i++) covered.add(i);
      }
      selection.note=selection.parts.length ? `已收录 ${covered.size}/${Math.max(0,names.length-1)} 个站间区间` : "仅有站点位置";
    } catch { if (current!==selection) return; selection.note="轨迹未载入，仅显示站点"; }
    drawBacking(selection.parts);
    $("lineFocusNote").textContent=selection.note;
  }
  function endDirectory(title) { if(current?.directory && (!title || title===current.title)) clear(); }
  return {setup,clear,set,station,metro,closestPart,directory,endDirectory,addTracks,addTile,
    get active(){return current;},refresh:()=>{
      if (!current) return;
      paint();
      if (!current.directory && current.backing) drawBacking(current.backing);
    }};
})();
