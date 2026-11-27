/* Load after station-directory/journey-guide-core.js and app.js. */
(() => {
  "use strict";
  const core = JourneyGuideCore, byID = id => document.getElementById(id);
  const asset = new URL("station-directory/journey-places.json",document.currentScript?.src || document.baseURI);
  const el = (tag,text) => { const n=document.createElement(tag); if (text!=null) n.textContent=text; return n; };
  function button(text, action) {
    const b=el("button",text); b.type="button"; b.className="text-button"; b.onclick=action; return b;
  }
  function field(text,input) {
    const label=el("label",text);
    input.setAttribute("aria-label", text);
    label.append(input);
    return label;
  }
  function details(parent,title) {
    const d=el("details"); d.append(el("summary",title)); parent.append(d); return d;
  }
  const dist = m => m<1000 ? `${m} m` : `${(m/1000).toFixed(1)} km`;
  let ui, map, route, placesPromise, pins, placeRequest=0, loadRequest=0, placeKey="", arrivalKey="";
  let sightseeing=false, lockedZoom=null, chain=[], expectedRoute, choices=[], busy=false, localCatalog, localLibrary;
  const enabled=new Set(Object.keys(core.labels));
  function isActive() {return state.playbackVisible && state.route === route && !!route;}

  function camera() {
    const follow=byID("followJourney");
    ui.sight.setAttribute("aria-pressed",String(sightseeing));
    ui.back.disabled=follow.disabled;
    ui.lock.disabled=sightseeing || !follow.checked || follow.disabled;
    ui.lock.checked=lockedZoom!==null;
    ui.cameraStatus.textContent=sightseeing?"观光中":follow.checked?"正在跟随列车":"已暂离列车";
  }
  function freeView() {
    sightseeing=true; byID("followJourney").checked=false; camera();
  }
  function resume() {
    if (!isActive() || !state.playbackMarker) return;
    sightseeing=false; byID("followJourney").checked=true;
    if (lockedZoom!==null) {
      state.journeyPreviewZoom=null;
      map.setView(state.playbackMarker.getLatLng(),lockedZoom,{animate:false});
    } else followJourneyPosition(state.playbackMarker.getLatLng(),true);
    camera();
  }
  function onZoom() {
    if (isActive() && !sightseeing && byID("followJourney").checked &&
        lockedZoom!==null && map.getZoom()!==lockedZoom)
      map.setZoom(lockedZoom,{animate:false});
  }
  function observePanning() {
    const container=map.getContainer(), pointers=new Map();
    let pinching=false;
    const detach=()=>{
      if (isActive() && byID("followJourney").checked) {
        byID("followJourney").checked=false;
        camera();
      }
    };
    // Detach on the first deliberate one-finger pan, including a pan started
    // while Leaflet is still animating the preceding camera update.
    container.addEventListener("pointerdown",event=>{
      if (!isActive() || event.button!==0 || event.target.closest(".leaflet-control")) return;
      pointers.set(event.pointerId,[event.clientX,event.clientY]);
      if (pointers.size>1) pinching=true;
    },{passive:true});
    container.addEventListener("pointermove",event=>{
      const start=pointers.get(event.pointerId);
      if (start && !pinching && Math.hypot(event.clientX-start[0],event.clientY-start[1])>=8) detach();
    },{passive:true});
    const end=event=>{pointers.delete(event.pointerId);if(!pointers.size)pinching=false;};
    window.addEventListener("pointerup",end,{passive:true});
    window.addEventListener("pointercancel",end,{passive:true});
    map.on("dragstart",detach);
  }
  function resetPins() { if (pins) {pins.remove();pins=null;} }
  async function updatePlaces(force=false) {
    if (!ui.places.open || !isActive()) {++placeRequest;placeKey="";resetPins();return;}
    const phase=RailRunInfo.position(route.stops,state.playbackSeconds);
    const position=phase && route.geometryAvailable && state.playbackMarker?.getLatLng();
    if (!position) {
      ++placeRequest; placeKey=""; resetPins(); ui.nearby.textContent="当前区间缺少可定位的轨迹或时刻。"; return;
    }
    const leg=Math.min(phase.i,route.legs.length-1), {lat,lng}=position;
    const key=[leg,Math.round(lat*500),Math.round(lng*500),...enabled].join("|");
    if (!force && key===placeKey) return;
    placeKey=key; const request=++placeRequest;
    if (!placesPromise) {
      ui.nearby.textContent="正在读取沿线地点…";
      placesPromise=fetch(asset).then(async r=>{
        if (!r.ok) throw Error(`地点资料 HTTP ${r.status}`);
        return new core.Places(await r.json(),atlasRailDirectory,StationPanel.national);
      }).catch(e=>{placesPromise=null;throw e;});
    }
    try {
      const places=await placesPromise;
      if (request!==placeRequest || !isActive()) return;
      const items=places.nearby(route.legs,leg,[lat,lng],[...enabled]);
      resetPins(); pins=L.layerGroup().addTo(map);
      ui.nearby.replaceChildren();
      if (!items.length) ui.nearby.textContent=enabled.size?"这段轨道附近暂无已收录地点。":"已关闭全部地点类别。";
      for (const p of items) {
        const row=el("div"); row.dataset.place=p.kind;
        const title=`${p.name} · ${core.labels[p.kind]}`;
        const marker=L.circleMarker([p.lat,p.lon],{radius:4,weight:2,color:"#397e77",fillOpacity:.85}).addTo(pins);
        marker.bindTooltip(el("span",title));
        row.append(button(title,()=>{
          freeView(); map.setView([p.lat,p.lon],Math.max(12,map.getZoom()),{animate:false});
          marker.openTooltip();
          if (matchMedia("(max-width: 900px)").matches) setWorkspaceOpen(false);
        }));
        const source=el("a",p.source); source.href=p.url; source.target="_blank"; source.rel="noopener noreferrer";
        row.append(el("small",`距列车 ${dist(p.metres)} · 距轨道 ${dist(p.track)}${p.note?" · "+p.note:""}　`),source);
        ui.nearby.append(row);
      }
    } catch(e) {
      if (request===placeRequest) ui.nearby.replaceChildren(el("p",e.message),button("重试地点资料",()=>updatePlaces(true)));
    }
  }
  function boards(station,date) {
    const national=StationPanel.national.board(station,date);
    // A user's imported schedule may extend the national edition. Consult timed
    // station calls only, without enumerating trains that pass through a junction.
    const lib=RailLibrary.current;
    if (!lib) return national;
    if (localLibrary!==lib) {localLibrary=lib;localCatalog=new Map();}
    const key=JSON.stringify([station,date]);
    if (!localCatalog.has(key)) {
      const local=[];
      for (const {row,i} of lib.stations.get(station)||[]) {
        const dep=row.stops[i].departure;
        if (!Number.isInteger(dep) || i===row.stops.length-1) continue;
        const origin=StationCatalog.day(date,-Math.floor(dep/1440));
        if (RailLibrary.runsOn(row,origin)) local.push({origin,dep,source:"local",detail:()=>({id:row.id,number:row.train,
          stops:row.stops.map(s=>[s.station,s.arrival,s.departure])})});
      }
      localCatalog.set(key,local);
    }
    return national.concat(localCatalog.get(key));
  }
  function currentArrival(index) {return core.arrival(route,index,state.playbackSeconds);}
  function updateStops() {
    if (!isActive() || !ui.relay.open) return;
    const options=route.stops.flatMap((s,i)=>currentArrival(i) ? [new Option(s.name,String(i))] : []);
    const key=options.map(o=>o.value).join("|");
    if (key===arrivalKey) return;
    arrivalKey=key;
    const previous=ui.stop.value;
    ui.stop.replaceChildren(...options);
    if (options.some(o=>o.value===previous)) ui.stop.value=previous;
    if (!options.length || previous!==ui.stop.value) clearChoices();
  }
  function clearChoices() {
    ++loadRequest; busy=false; choices=[]; ui.services.replaceChildren(); ui.dest.replaceChildren();
    ui.ride.disabled=true; ui.message.textContent="";
  }
  function chooseService() {
    ++loadRequest;busy=false;
    const c=choices[ui.services.selectedIndex];
    ui.dest.replaceChildren(...(c?.destinations||[]).map(d=>new Option(d.name,String(d.index))));
    if (c) ui.dest.selectedIndex=ui.dest.options.length-1;
    ui.ride.disabled=!c;
  }
  function findTransfers() {
    clearChoices();
    const arr=currentArrival(Number(ui.stop.value));
    if (!arr) {ui.message.textContent="请选择有到达时刻的本站或前方停站。";return;}
    choices=core.transfers(arr,{train:route.train,numbers:RailLibrary.trainNames(route.train),origin:route.serviceDate,trip:route.trip,
      stops:route.stops,source:route.trip?"national":"local"},
      boards,Number(ui.window.value));
    ui.services.replaceChildren(...choices.map(c=>new Option(
      `${c.boardDate} ${core.clock(c.departure)}　${c.train} → ${c.destinations.at(-1).name} · 换乘 ${c.wait} 分 · ${c.origin} 始发 · ${c.trip}`,c.id)));
    chooseService();
    ui.message.textContent=choices.length?`${choices.length} 个同站班次 · 按图定时刻接力`:"所选时间内没有已收录的同站发车。";
  }
  async function loadFull(choice,station) {
    if (choice.source==="national") return RailPaths.find({train:choice.train,date:choice.origin,trip:choice.trip});
    const row=RailLibrary.current?.stations.get(station)?.find(({row,i})=>row.id===choice.trip && i===choice.boardIndex)?.row;
    if (!row) throw Error("离线库已更换，请重新查询。");
    const table=RailLibrary.timetable(row,choice.origin);
    const base=buildRouteFromTimetable(table,state.bundledJourneys);
    if (base.geometryAvailable) return base;
    try {return {...base,...await RailPaths.find({train:base.train,date:base.serviceDate,stops:base.stops,routing:base.routing})};}
    catch(error) {
      if (!base.routing || !LocalRailCache.loaded) throw error;
      const paths=await LocalRailCache.match(base.routing,base.stops.map(s=>s.name));
      const legs=paths.map(p=>p.map(pointToLatLng)),gaps=RailPaths.gapsFor(base.stops,legs);
      return {...base,legs,gaps,geometryAvailable:!gaps.length,cacheMatched:true,
        stopCoordinates:base.stops.map((_,i)=>legs[i]?.[0] || legs[i-1]?.at(-1) || null)};
    }
  }
  async function boardNext() {
    if (busy) return;
    const old=route, i=Number(ui.stop.value), c=choices[ui.services.selectedIndex], end=Number(ui.dest.value);
    const arr=currentArrival(i);
    if (!arr || !c || c.absolute<arr.at || !c.destinations.some(d=>d.index===end)) {findTransfers();return;}
    const request=++loadRequest; busy=true; ui.ride.disabled=true; ui.message.textContent="正在核对乘车区间轨迹…";
    try {
      const full=await loadFull(c,arr.station);
      if (request!==loadRequest || old!==route || !isActive()) return;
      const now=currentArrival(i), dest=c.destinations.find(d=>d.index===end);
      if (!now || now.at>c.absolute) throw Error("列车已驶过换乘时间，请重新查询。");
      if (full.serviceDate!==c.origin || full.stops[c.boardIndex]?.name!==arr.station ||
          full.stops[c.boardIndex]?.departure!==c.departure || full.stops[end]?.name!==dest.name ||
          full.stops[end]?.arrival!==dest.arrival) throw Error("所选排图的时刻已变化，请重新查询。");
      const gaps=RailPaths.gapsFor(full.stops.slice(c.boardIndex,end+1),full.legs.slice(c.boardIndex,end));
      if (gaps.length) throw Error("接力区间缺少连续轨迹："+gaps.join("、"));
      const nextChain=[...chain,`${old.train}　${old.stops[0].name} → ${arr.station}　${core.dateAt(arr.eta)} ${core.clock(arr.eta)}`];
      state.routes=[...state.routes.filter(r=>r.id!==full.id),full];
      populateRoutePicker();selectRoute(full.id,{from:c.boardIndex,to:end,fit:false});
      expectedRoute=state.route; chain=nextChain; sync();
      startPlayback(); revealJourneyMapOnPhone();
    } catch(e) {
      if (request===loadRequest) {ui.message.textContent=e.message;ui.ride.disabled=false;}
    } finally {if(request===loadRequest) busy=false;}
  }
  function sync() {
    if (!ui || typeof state==="undefined" || !state.map) return;
    if (!map) {
      map=state.map; map.on("zoomend",onZoom); observePanning();
    }
    const next=state.playbackVisible?state.route:null;
    if (next!==route) {
      ++placeRequest;clearChoices();resetPins();placeKey="";arrivalKey=null;
      if (!next || next!==expectedRoute) {chain=[];sightseeing=false;lockedZoom=null;}
      expectedRoute=null;route=next;ui.root.hidden=!route;
      ui.chain.replaceChildren(...chain.map(s=>el("li",s)));
      if (chain.length && route) ui.chain.append(el("li",`${route.train}　${route.stops[0].name} → ${route.stops.at(-1).name}（本程）`));
    }
    if (route) {camera();if (ui.relay.open) updateStops();void updatePlaces();}
  }
  function mount() {
    if (ui || !byID("routeSummary")) return;
    const root=el("section");root.id="journeyGuide";root.hidden=true;
    (byID("routeInspector")||byID("routeSummary")).after(root);
    const style=el("style",`
      #journeyGuide:not([hidden]){display:grid;gap:8px;min-width:0}
      #journeyGuide summary{cursor:pointer}
      #journeyGuide details[open]>:not(summary){margin-top:6px}
      #journeyGuide .jg-fields{display:flex;flex-wrap:wrap;gap:7px;align-items:center}
      #journeyGuide label:has(input){display:inline-flex;align-items:center;gap:4px}
      #journeyGuide input[type=checkbox]{width:auto} #journeyGuide select{max-width:100%;width:100%}
      #journeyGuide [data-place]{display:grid;gap:2px;border-bottom:1px solid var(--line);padding:4px 0}
      #journeyGuide [data-place] button{text-align:left} #journeyGuide small,#journeyGuide a{font-size:12px}
    `);document.head.append(style);
    const controls=el("div");controls.className="jg-fields";root.append(controls);
    const sight=button("观光模式",freeView),back=button("回到列车",resume),lock=el("input"),cameraStatus=el("small");
    lock.type="checkbox";lock.onchange=()=>{lockedZoom=lock.checked?map.getZoom():null;if(lock.checked)state.journeyPreviewZoom=null;camera();};
    controls.append(sight,back,field("锁定缩放",lock),cameraStatus);
    const places=details(root,"沿线地点"), types=el("div"), nearby=el("div");types.className="jg-fields";
    for (const [id,name] of Object.entries(core.labels)) {
      const check=el("input");check.type="checkbox";check.checked=true;
      check.onchange=()=>{if(check.checked) enabled.add(id);else enabled.delete(id);void updatePlaces(true);};
      types.append(field(name,check));
    }
    places.append(types,nearby); places.ontoggle=()=>updatePlaces(true);
    const relay=details(root,"同站车次接力"), stop=el("select"), windowInput=el("select"),services=el("select"),dest=el("select");
    windowInput.append(new Option("6 小时","6"),new Option("24 小时","24"));
    const ride=button("跳到发车并接续",boardNext), message=el("p"), list=el("ol");ride.disabled=true;
    relay.append(field("换乘站",stop),field("等候范围",windowInput),button("查找同站车次",findTransfers),
      field("接续车次",services),field("接力下车站",dest),ride,message,list);
    relay.ontoggle=()=>{if(relay.open)updateStops();}; stop.onchange=windowInput.onchange=clearChoices;
    services.onchange=chooseService; dest.onchange=()=>{++loadRequest;busy=false;ride.disabled=!dest.options.length;};
    ui={root,sight,back,lock,cameraStatus,places,nearby,relay,stop,window:windowInput,services,dest,ride,message,chain:list};
    byID("followJourney").addEventListener("change",e=>{sightseeing=!e.target.checked;if(e.target.checked)resume();else camera();});
    const observer=new MutationObserver(sync);
    for (const id of ["routeSummary","playbackClock"]) observer.observe(byID(id),{childList:true,subtree:true});
    observer.observe(byID("playbackBar"),{attributes:true,attributeFilter:["hidden"]});
    sync();
  }
  globalThis.RailwayJourneyGuide={mount,refresh:sync};
  if (document.readyState==="loading") document.addEventListener("DOMContentLoaded",mount,{once:true});else mount();
})();
