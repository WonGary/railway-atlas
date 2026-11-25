// A separate foreground pane keeps the original map layers interactive and lets
// tile arrivals, zooms and preference changes retain their normal paint styles.
const LineFocus = (() => {
  let map, ink, current, renderer;
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
    renderer=L.svg({pane:"lineFocus"});
    ink=L.layerGroup().addTo(map);
    $("clearLineFocus").onclick=()=>clear();
    document.addEventListener("keydown",e=>{
      if (e.key==="Escape" && current && !e.target.closest?.("input,textarea,dialog,select")) clear();
    });
    map.on("click",e=>{
      if (e.sourceTarget===map && !e.originalEvent?.atlasFeatureHit) clear();
    });
    map.on("moveend",()=>{if (current?.directory) paint();});
  }
  function clear() {
    if (!current) return;
    current=null; ink.clearLayers();
    map.getContainer().classList.remove("line-focused");
    $("lineFocusBar").hidden=true;
    StationLabels.schedule();
  }
  function paint() {
    ink.clearLayers();
    if (!current) return;
    const {parts,stops,selectStop}=current;
    const options={pane:"lineFocus",renderer,interactive:false,lineCap:"round",lineJoin:"round"};
    function tracks(paths,styles) {
      if (!paths.length) return;
      L.polyline(paths,{...options,color:"#ffffff",weight:7.5,opacity:.9}).addTo(ink);
      const groups=new Map();
      paths.forEach((path,i)=>{
        const style=styles?.(i) || {}, color=style.color || AtlasPrefs.value.focusColor;
        const key=[color,style.dashArray || ""].join("|");
        if (!groups.has(key)) groups.set(key,{color,dashArray:style.dashArray,parts:[]});
        groups.get(key).parts.push(path);
      });
      for (const {color,dashArray,parts} of groups.values())
        L.polyline(parts,{...options,color,dashArray,weight:4.4,opacity:1}).addTo(ink);
    }
    tracks(parts,current.styleForPart);
    if (current.directory) {
      const known=RailMapLayers.namedTracks(current.title);
      tracks(known.map(s=>s.path),i=>known[i].style);
    }
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
    current={title,parts,stops,...opts};
    paint();
    return current;
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
  function metro(city,route) {
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
    const selection=set(title,[],rows,{directory:true,note:"读取轨迹…",selectStop:n=>selectStation(n,{pan:false})});
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
    paint();
  }
  function endDirectory(title) { if(current?.directory && (!title || title===current.title)) clear(); }
  return {setup,clear,set,station,metro,closestPart,directory,endDirectory,
    get active(){return current;},refresh:()=>{if(current)paint();}};
})();
