const StationMapBoard = (() => {
  let coordinates, points, overlay;
  function positions() {
    if (!coordinates) {
      coordinates=new Map();
      const {names,coordinates:locations}=globalThis.atlasRailDirectory;
      names.forEach((name,i)=>{
        const p=locations[i];
        if (p && Math.abs(p[0])>1 && Math.abs(p[1])>1) coordinates.set(name,p);
      });
    }
    for (const node of state.corridor?.nodes || []) {
      if (node.vertex==null || coordinates.has(node.name)) continue;
      const p=state.corridor.points[node.vertex];
      if (p) coordinates.set(node.name,[p[1],p[0]]);
    }
    return coordinates;
  }
  function railPoint(name,p,group) {
    const marker=L.circleMarker(p,{radius:4.5,weight:2,color:"#764322",fillColor:"#ffe1a4",fillOpacity:1,bubblingMouseEvents:false});
    const title=document.createElement("span");title.textContent=name;
    marker.bindTooltip(title);
    MapHit.bind(marker,()=>selectStation(name,{pan:false}));
    marker.addTo(group);
  }
  function setup(map) {
    points=L.layerGroup().addTo(map); overlay=L.layerGroup().addTo(map);
    map.on("moveend zoomend",refresh);
    refresh();
  }
  function refresh() {
    if (!points) return;
    points.clearLayers();
    if (!AtlasPrefs.value.showsStations || !$("showRail").checked) { overlay.clearLayers(); return; }
    if (state.map.getZoom()<10) return;
    const bounds=state.map.getBounds();
    for (const [name,p] of positions()) if (bounds.contains(p)) railPoint(name,p,points);
  }
  function mount(parent,name) {
    if (!name) return;
    const root=document.createElement("section");root.dataset.stationDirectory=name; parent.prepend(root);
    StationPanel.mount(root,name,{library:RailLibrary.current,coordinate:n=>positions().get(n),
      locate:(rows,title,names,fit)=>LineFocus.directory(title,rows,names,fit),
      endLine:LineFocus.endDirectory,trainAction:openStationTrain});
    const share=document.createElement("button");
    share.type="button";share.className="text-button";share.textContent="复制本站链接";
    share.onclick=()=>JourneyKeepsakes.copyPlace("station",name);
    root.append(share);
    if (location.origin==="http://127.0.0.1:18763") appendOriginalStationLookup(root,name);
  }
  function focus(name) {
    const p=positions().get(name);
    if (p) state.map.setView(p,Math.max(11,state.map.getZoom()),{animate:false});
  }
  function reload() {
    const old=document.querySelector("#infoContent [data-station-directory]");
    if (old) { const parent=old.parentNode, name=old.dataset.stationDirectory;old.remove();mount(parent,name); }
  }
  return {setup,mount,focus,refresh,reload,coordinate:name=>positions().get(name)};
})();

function showStationBoard(raw) {
  const name=raw.trim();
  if (!name) { showToast("请先输入站名。");return; }
  selectStation(StationCatalog.resolve(name,StationPanel.national));
}

// The user's desktop companion supplies same-origin access to the original HTTP feeds.
function appendOriginalStationLookup(parent, name) {
  const section=document.createElement("section"), start=document.createElement("button"), result=document.createElement("div");
  start.textContent="查询中国铁路地图原站"; section.append(start,result);parent.append(section);
  const get=async path=>{
    const response=await fetch("/station-feed/"+path,{cache:"no-store"});
    if (!response.ok) throw Error("原站暂时无法连接。");
    return response.json();
  };
  function row(parent,label,load) {
    const details=document.createElement("details"), summary=document.createElement("summary");
    summary.textContent=label;details.append(summary);parent.append(details);
    details.ontoggle=async()=>{
      if (!details.open || details.childElementCount>1) return;
      const text=document.createElement("div");text.style.whiteSpace="pre-line";details.append(text);
      try { text.textContent=await load(); }
      catch (error) { text.remove(); summary.title=error.message; }
    };
  }
  async function select(id) {
    const pane=document.createElement("div");
    result.replaceChildren(pane);pane.textContent="正在读取原站资料…";
    try {
      const poi=await get("poi/"+id);
      pane.replaceChildren();
      const links=poi.exd?.find(item=>!item.view || item.view==="station")?.data?.connection || [];
      for (const line of links) if (/^[a-f0-9]{32}$/.test(line.eid)) row(pane,line.linename,async()=>{
        const {data}=await get("feature/"+line.eid);
        const diagram=(data.diagram || []).flatMap(([,n,km])=>{
          const label=n?.station || n?.poi || n?.info;return label ? [`${label}　${km ?? ""}`] : [];
        });
        return (diagram.length ? diagram : (data.stations || []).map(s=>`${s.name}　${s.mileage ?? ""}`)).join("\n");
      });
      const board=await get("stationroute/"+id);
      const note=document.createElement("p");note.textContent=`原站班表 ${board.update || ""} · ${board.list?.length || 0} 条`;pane.append(note);
      for (const train of board.list || []) {
        const label=`${train.opid}　${board.hash[train.from].name} → ${board.hash[train.to].name}　${train.arr || "—"} / ${train.dep || "—"}`;
        row(pane,label,async()=>{
          if (!/^CN\/[A-Z0-9]+$/.test(train.route)) return "原站未提供这趟列车的详情编号。";
          const data=await get("train/"+train.route.slice(3));
          function clock(code) {
            const m=/^([1-9])(\d\d)(\d\d)$/.exec(code);
            return m ? `${Number(m[1])>1 ? `+${Number(m[1])-1}日 ` : ""}${m[2]}:${m[3]}` : code || "—";
          }
          return (data.sections || []).flatMap(s=>s.stops.map(call=>`${call.name}　${clock(call.arr)} / ${clock(call.dep)}`)).join("\n");
        });
      }
    } catch(error) { pane.append(document.createTextNode(error.message)); }
  }
  start.onclick=async()=>{
    start.disabled=true;
    try {
      const query=StationCatalog.resolve(name,StationPanel.national);
      const choices=(await get("search?keyword="+encodeURIComponent(query))).filter(c=>/^geo\/[a-f0-9]{32}$/.test(c.query));
      const exact=choices.filter(c=>c.name===query);
      if (exact.length===1) await select(exact[0].query.slice(4));
      else {
        result.textContent=choices.length ? "选择原站记录　" : "原站未收录这个站名。";
        for (const choice of choices) { const b=document.createElement("button");b.textContent=choice.name;b.onclick=()=>select(choice.query.slice(4));result.append(b); }
      }
    } catch(error) { result.textContent=error.message; }
    finally { start.disabled=false; }
  };
}
