// A separate foreground pane keeps the original map layers interactive and lets
// tile arrivals, zooms and preference changes retain their normal paint styles.
const LineFocus = (() => {
  let map, ink, current, rimRenderer, trackRenderer, renderer;
  let frame, fitting = false, layoutTick = 0;
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
    // Keep a full-line camera through layout changes, until the user moves the map.
    map.on("movestart", () => {
      if (!fitting) {
        frame = null;
        if (current) current.cameraReleased = true;
      }
    });
    const schedule = () => {
      if (frame && !layoutTick) layoutTick = requestAnimationFrame(() => {
        layoutTick = 0;
        if (frame) applyFrame(frame);
      });
    };
    const panels = document.querySelectorAll(".app-shell > .left-rail,.app-shell > .right-panel,#mapTopbar,#playbackBar");
    const sizes = new ResizeObserver(schedule);
    for (const el of [map.getContainer(), ...panels]) sizes.observe(el);
    const visibility = new MutationObserver(schedule);
    for (const el of [document.querySelector(".app-shell"), ...panels])
      visibility.observe(el,{attributes:true,attributeFilter:["class","hidden","data-ui-folded","data-left-layout","data-right-layout"]});
    for (const el of panels) el.addEventListener("transitionend",schedule);
  }
  function clear() {
    frame = null;
    if (!current) return;
    current=null; ink.clearLayers();
    map.getContainer().classList.remove("line-focused","full-line-view");
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
      StationLabels.bind(marker,name,{id:id||name,minZoom:0,focused:true,open: selectStop && (()=>selectStop(name,id))});
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
    frame = null;
    current={title,parts,stops,extra:new Map(),...opts};
    map.getContainer().classList.toggle("full-line-view",Boolean(opts.fittedLine));
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
      if (selection.fittedLine && !selection.cameraReleased && paths.length) fitSelection();
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
  function fitFullLine(bounds, maxZoom) {
    if (!bounds.isValid()) return;
    frame = {bounds, maxZoom};
    applyFrame(frame);
  }
  function applyFrame(target) {
    map.invalidateSize({pan:false});
    const size = map.getSize();
    if (!size.x || !size.y) return;
    const viewport = map.getContainer().getBoundingClientRect();
    let left = 0, right = 0, top = 0, bottom = 0;
    for (const panel of document.querySelectorAll(".app-shell.workspace-open > .left-rail,.app-shell > .right-panel,#mapTopbar,#playbackBar")) {
      if (panel.hidden || panel.hasAttribute("data-ui-folded") || getComputedStyle(panel).visibility === "hidden") continue;
      const rect = panel.getBoundingClientRect();
      if (rect.right <= viewport.left || rect.left >= viewport.right || rect.bottom <= viewport.top || rect.top >= viewport.bottom) continue;
      if (panel.id === "mapTopbar") {
        top = Math.max(top, rect.bottom - viewport.top);
      } else if (panel.id === "playbackBar" || (panel.matches(".info-panel") && matchMedia("(max-width: 900px)").matches && rect.top > viewport.top + size.y * .2)) {
        bottom = Math.max(bottom, viewport.bottom - rect.top);
      } else if (panel.matches(".left-rail")) {
        left = Math.max(left, rect.right - viewport.left);
      } else {
        right = Math.max(right, viewport.right - rect.left);
      }
    }
    // When a phone drawer covers almost the entire map, fit for the map revealed on dismissal.
    if (size.x - left - right < 96) { left = 0; right = 0; }
    const insetX = (size.x - left - right) * .10;
    const insetY = (size.y - top - bottom) * .10;
    if (insetY <= 0) return;
    const layout = [size.x,size.y,left,right,top,bottom].join();
    if (target.layout === layout) return;
    target.layout = layout;
    // Quarter-step snapping can shrink a second time. Only this synchronous fit uses a continuous zoom.
    const snap = map.options.zoomSnap;
    fitting = true;
    try {
      map.options.zoomSnap = 0;
      map.fitBounds(target.bounds, {paddingTopLeft:[left + insetX,top + insetY],
        paddingBottomRight:[right + insetX,bottom + insetY],maxZoom:target.maxZoom,animate:false});
    } finally { map.options.zoomSnap = snap; fitting = false; }
  }
  function fitSelection(maxZoom = 15) {
    if (!current?.fittedLine || current.cameraReleased) return;
    const bounds = L.latLngBounds(current.parts);
    for (const [,location] of current.stops) bounds.extend(location);
    if (current.backing) bounds.extend(L.latLngBounds(current.backing));
    for (const {samples} of current.extra.values()) {
      for (const {path} of samples) bounds.extend(L.latLngBounds(path));
    }
    fitFullLine(bounds,maxZoom);
  }
  function metro(city,route,{fit = false} = {}) {
    const detail=state.metroCityLayers.get(city.id);
    const members=(detail?.routeLines || []).filter(e=>e.route.id===route.id);
    const parts=members.flatMap(e=>e.line.getLatLngs());
    const stations = new Map((detail?.detail.stations || []).filter(s=>s.routes?.some(r=>r.id===route.id)).map(s=>[s.id,s]));
    for (const s of route.stops || []) if (s.coordinate && !stations.has(s.id)) stations.set(s.id,s);
    const stops=[...stations.values()]
      .map(s=>[s.name,pointToLatLng(s.coordinate),s.id,()=>metroStopColors(detail,s)]).filter(([,p])=>p);
    const styles=members.flatMap(e=>e.line.getLatLngs().map(()=>()=>({color:e.construction ? "#d5dce0" :
      AtlasPrefs.value.showsMetroColors && e.route.color, dashArray:e.line.options.dashArray})));
    set(metroRouteLabel(route),parts,stops,{fittedLine:fit,styleForPart:i=>styles[i](),
      selectStop:(_name,id)=>{const s=detail.detail.stations.find(s=>s.id===id);if(s) selectMetroStation(city,s,{pan:false});}});
    if (fit) fitSelection();
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
    const selection=set(title,[],rows,{directory:true,fittedLine:fit,match:{name:title},note:"读取轨迹…",selectStop:n=>selectStation(n,{pan:false})});
    if (!selection) return;
    const stationBounds=L.latLngBounds(rows.map(r=>r[1]));
    if (fit) fitFullLine(stationBounds,13);
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
    if (fit && selection.parts.length && !selection.cameraReleased) {
      // A bend between stations may extend beyond the preliminary station envelope.
      const bounds=L.latLngBounds(selection.parts);
      if (!stationBounds.isValid() || !stationBounds.contains(bounds)) {
        if (stationBounds.isValid()) bounds.extend(stationBounds);
        fitFullLine(bounds,13);
      }
    }
  }
  function endDirectory(title) { if(current?.directory && (!title || title===current.title)) clear(); }
  return {setup,clear,set,station,metro,closestPart,directory,endDirectory,addTracks,addTile,fitFullLine,fitSelection,
    get active(){return current;},refresh:()=>{
      if (!current) return;
      paint();
      if (!current.directory && current.backing) drawBacking(current.backing);
    }};
})();
