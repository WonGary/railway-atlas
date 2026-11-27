/* Route quality, physical line directory and two-train comparison on the existing map. */
(() => {
  "use strict";
  const metresPerDegree = 111195;
  const kinds = ["缺少轨迹", "本车次 GTFS 轨迹", "同线路、站序和里程匹配", "OSM 轨道或渡轮航道匹配"];
  const validPoint = p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) && Math.abs(p[0]) <= 85 && Math.abs(p[1]) <= 180;
  const radians = n => n * Math.PI / 180;
  function distance(a, b) {
    const lon = ((a[1] - b[1] + 540) % 360) - 180;
    return metresPerDegree * Math.hypot(a[0] - b[0], lon * Math.cos(radians((a[0] + b[0]) / 2)));
  }
  const nameOf = s => s?.name ?? s?.station;
  const km = metres => `${(metres / 1000).toFixed(1)} km`;
  function legPlan(route, index) {
    const plan = route.routing;
    const a = plan?.stopIndices?.[index], b = plan?.stopIndices?.[index + 1];
    if (!Number.isInteger(a) || !Number.isInteger(b) || a < 0 || b <= a ||
        !Array.isArray(plan.edges) || plan.edges.length !== plan.nodes?.length - 1 ||
        plan.nodes[a]?.station !== nameOf(route.stops[index]) || plan.nodes[b]?.station !== nameOf(route.stops[index + 1])) return null;
    const origin = plan.nodes[a].kilometre;
    return {nodes:plan.nodes.slice(a,b+1).map(n => ({...n, kilometre:n.kilometre - origin})),
      edges:plan.edges.slice(a,b), stopIndices:[0,b-a]};
  }
  function inspectLeg(route, index) {
    const points = route.legs?.[index] || [], prev = route.legs?.[index-1]?.at(-1);
    const from = nameOf(route.stops[index]), to = nameOf(route.stops[index+1]);
    const plan = legPlan(route, index);
    let length = 0, maxStep = 0;
    const valid = points.length >= 2 && points.every(validPoint);
    if (valid) for (let i = 1; i < points.length; i++) {
      const d = distance(points[i-1], points[i]);
      length += d;
      maxStep = Math.max(maxStep, d);
    }
    const metered = plan?.nodes.at(-1)?.kilometre;
    const importedChord = !route.indexed && !route.cacheMatched && route.imported && points.length === 2 && length > 8000;
    let problem = "";
    if (!valid) problem = points.length >= 2 ? "坐标无效" : Number.isFinite(metered) ? "只有经由与计价里程" : "缺少区间轨迹";
    else if (length < 0.1) problem = "轨道长度为零";
    else if (maxStep > 32000 || importedChord) problem = "轨迹顶点过疏，走向待核";
    const drawable = !problem;
    const gap = drawable && validPoint(prev) ? distance(prev,points[0]) : 0;
    if (gap > 120) problem = `${from}站内衔接相距 ${Math.round(gap)} m`;
    const kind = route.geometryKinds?.[index];
    const source = route.inspectorSources?.[index] || (route.matchedSections?.[index] || route.cacheMatched ? "本机缓存轨道匹配" :
      kind > 0 && kinds[kind] ? kinds[kind] : route.imported ? "导入的轨迹" : route.source?.title || "随包路线");
    return {index,from,to,points,plan,metered,length,source,problem,drawable,gap};
  }
  function report(route) { return route.stops.slice(1).map((_,i) => inspectLeg(route,i)); }
  function uniqueRange(stops, from, to) {
    const options = [];
    stops.forEach((s,a) => {
      if (nameOf(s) === from) for (let b=a+1; b<stops.length; b++) if (nameOf(stops[b]) === to) options.push([a,b]);
    });
    return options.length === 1 ? options[0] : null;
  }
  function slice(route, a, b) {
    const plan = route.routing, lo = plan?.stopIndices?.[a], hi = plan?.stopIndices?.[b];
    const cut = key => route[key]?.slice(a,b);
    return {...route, stops:route.stops.slice(a,b+1), legs:cut("legs"), geometryKinds:cut("geometryKinds"),
      matchedSections:cut("matchedSections"), inspectorSources:cut("inspectorSources"), stopCoordinates:route.stopCoordinates?.slice(a,b+1),
      routing:Number.isInteger(lo) && Number.isInteger(hi) && plan.nodes?.[hi] && plan.edges ?
        {nodes:plan.nodes.slice(lo,hi+1), edges:plan.edges.slice(lo,hi), stopIndices:plan.stopIndices.slice(a,b+1).map(v=>v-lo)} : null};
  }
  function tripMinutes(route) {
    const first = route.stops[0], last = route.stops.at(-1);
    const start = first.departure ?? first.arrival, end = last.arrival ?? last.departure;
    return Number.isFinite(start) && Number.isFinite(end) && end >= start ? end - start : null;
  }
  function sameShape(a,b) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length &&
      a.every((p,i) => validPoint(p) && validPoint(b[i]) && p[0] === b[i][0] && p[1] === b[i][1]);
  }
  function candidateProblem(route, index, points) {
    const local = inspectLeg({...route,legs:[points],stops:route.stops.slice(index,index+2),routing:null},0);
    if (!local.drawable) return local.problem;
    const previous = route.legs?.[index-1]?.at(-1), next = route.legs?.[index+1]?.[0];
    if (validPoint(previous) && distance(previous,points[0]) > 120) return "与前一区间的轨道端点相距超过 120 m";
    if (validPoint(next) && distance(next,points.at(-1)) > 120) return "与后一区间的轨道端点相距超过 120 m";
    const expected = legPlan(route,index)?.nodes.at(-1).kilometre;
    if (expected > 0 && Math.abs(local.length - expected*1000) > Math.max(800,expected*180)) return "候选轨道长度与计价里程不符";
    return "";
  }

  // Index actual edges in a local metric grid. Query in both directions so
  // reversed trains, unequal sampling and intermediate stops compare equally.
  // A crossing does not count: the tangent must also agree (in either direction).
  const tolerance = 45, sampleSpacing = 90, cellSize = 300;
  function compareGeometry(a, b) {
    const paths = route => report(route).filter(row=>row.drawable).map(row=>row.points);
    const pathsA = paths(a), pathsB = paths(b), origin = pathsA[0]?.[0] || pathsB[0]?.[0] || [0,0];
    const xScale = metresPerDegree * Math.cos(radians(origin[0]));
    const project = p => [(((p[1]-origin[1]+540)%360)-180)*xScale,(p[0]-origin[0])*metresPerDegree];
    const directionCosine = Math.cos(radians(25));
    const key = (x,y) => `${x}/${y}`;
    function buildIndex(parts) {
      const grid = new Map();
      for (const points of parts) {
        let [x0,y0] = project(points[0]);
        for (const p of points.slice(1)) {
          const [x1,y1] = project(p), dx = x1-x0, dy = y1-y0, len = Math.hypot(dx,dy);
          if (len > 0) {
            const edge = {x:x0,y:y0,dx,dy,len};
            const n = Math.max(1,Math.ceil(len/(cellSize/2)));
            for (let i=0; i<=n; i++) {
              const cell = key(Math.floor((x0+i/n*dx)/cellSize),Math.floor((y0+i/n*dy)/cellSize));
              if (!grid.has(cell)) grid.set(cell,[]);
              const bucket = grid.get(cell);
              if (bucket.at(-1) !== edge) bucket.push(edge);
            }
          }
          x0=x1; y0=y1;
        }
      }
      return grid;
    }
    function matches(grid,x,y,ux,uy) {
      const gx = Math.floor(x/cellSize), gy = Math.floor(y/cellSize);
      for (let i=gx-1; i<=gx+1; i++) for (let j=gy-1; j<=gy+1; j++) {
        for (const e of grid.get(key(i,j)) || []) {
          if (Math.abs(ux*e.dx + uy*e.dy) < directionCosine*e.len) continue;
          const t = Math.max(0,Math.min(1,((x-e.x)*e.dx+(y-e.y)*e.dy)/(e.len*e.len)));
          if ((x-e.x-t*e.dx)**2 + (y-e.y-t*e.dy)**2 <= tolerance**2) return true;
        }
      }
      return false;
    }
    function classify(parts, other) {
      const grid = buildIndex(other);
      const out = {shared:[], only:[], sharedMetres:0, onlyMetres:0};
      for (const points of parts) {
        let lastType, part, from = points[0];
        for (const to of points.slice(1)) {
          const [x,y] = project(from), [xx,yy] = project(to);
          const dx=xx-x, dy=yy-y, seg=Math.hypot(dx,dy), ground=distance(from,to);
          if (!seg) continue;
          const n=Math.max(1,Math.ceil(ground/sampleSpacing));
          const at = t => t === 0 ? from : t === 1 ? to : [from[0]+(to[0]-from[0])*t,from[1]+(to[1]-from[1])*t];
          for (let i=0; i<n; i++) {
            const t = (i+.5)/n;
            const type = matches(grid,x+dx*t,y+dy*t,dx/seg,dy/seg) ? "shared" : "only";
            if (type !== lastType) {
              const split = at(i/n);
              if (lastType && i) part.push(split);
              out[type].push(part=[split]); lastType=type;
            }
            out[type+"Metres"] += ground/n;
          }
          part.push(to);
          from=to;
        }
      }
      return out;
    }
    return {a:classify(pathsA,pathsB), b:classify(pathsB,pathsA)};
  }

  // Line directory edges can cover several station intervals. Follow the
  // ordered station list and actual edge endpoints, never span a missing link.
  function directoryPaths(stops, entries, from, to) {
    const names = stops.map(s=>s[0]);
    const unique = n => names.indexOf(n) === names.lastIndexOf(n) ? names.indexOf(n) : -1;
    const first=unique(from), last=unique(to);
    if (first < 0 || last < 0 || first === last) return [];
    const dir=Math.sign(last-first), edges=new Map();
    for (const [left,right,shape] of entries) {
      const l=unique(left), r=unique(right);
      if (l<0 || r<0 || l===r || Math.min(l,r)<Math.min(first,last) || Math.max(l,r)>Math.max(first,last)) continue;
      if (shape.length<2 || !shape.every(validPoint)) continue;
      const reverse=Math.sign(r-l)!==dir, start=reverse?r:l, end=reverse?l:r;
      if (!edges.has(start)) edges.set(start,[]);
      edges.get(start).push({end,path:reverse?shape.slice().reverse():shape});
    }
    const found=[];
    let budget=4000;
    function walk(node, parts) {
      if (--budget < 0 || found.length>=3) return;
      if (node===last) {
        const points=parts.flat();
        if (!found.some(p=>sameShape(p,points))) found.push(points);
        return;
      }
      for (const edge of edges.get(node) || []) {
        if (parts.length && distance(parts.at(-1).at(-1),edge.path[0])>120) continue;
        walk(edge.end,[...parts,edge.path]);
      }
    }
    walk(first,[]);
    return found;
  }

  if (typeof module === "object" && module.exports && typeof document === "undefined") {
    module.exports = {inspectLeg, report, legPlan, slice, uniqueRange, tripMinutes, compareGeometry, directoryPaths, candidateProblem, distance};
    return;
  }

  const el = (tag,text) => {
    const node = document.createElement(tag);
    if (text != null) node.textContent = text;
    return node;
  };
  const byID = id => document.getElementById(id);
  const button = (text,action) => {
    const node = el("button",text);
    node.type = "button"; node.className = "text-button";
    node.addEventListener("click", action);
    return node;
  };
  const box = (title,container) => {
    const details = el("details"), summary = el("summary", title);
    details.append(summary); container.append(details);
    return details;
  };
  const lineDirectory = new URL("station-directory/lines/", document.currentScript?.src || document.baseURI);
  const dirFiles = new Map(), colour = {a:"#087cba", b:"#c03977", shared:"#17805a"};
  let ui, current, context, overlay, renderer, comparisonSerial=0, inspectionSerial=0;
  let focusedDirectory, detachMapHandlers = () => {};
  function lineFile(file) {
    if (!dirFiles.has(file)) dirFiles.set(file,fetch(new URL(file,lineDirectory)).then(async r=>{
      if (!r.ok) throw Error(`线路图集 HTTP ${r.status}`);
      return r.json();
    }).catch(e=>{dirFiles.delete(file);throw e;}));
    return dirFiles.get(file);
  }
  function serviceContext(route) {
    const full = state.routes.find(r=>r.id===route.id) || route;
    return {full,offset:route===full ? 0 : Number(byID("routeFrom").value)};
  }
  function eligibleLines(row) {
    const directory = StationPanel.national.lines;
    const atFrom = directory.get(row.from) || [], atTo = new Set((directory.get(row.to)||[]).map(l=>l.title));
    const planned = [...new Set(row.plan?.edges.map(e=>e.lineName).filter(Boolean))];
    const local = RailLibrary.current;
    const titles = planned.length ? planned : [...new Set(atFrom.filter(l=>atTo.has(l.title)).map(l=>l.title))];
    return titles.map(title=>{
      const spanIndex = row.plan?.edges.findIndex(e=>e.lineName===title);
      const anchor = spanIndex >= 0 ? row.plan.nodes[spanIndex].station : row.from;
      let line = (directory.get(anchor)||[]).find(l=>l.title===title) || atFrom.find(l=>l.title===title);
      if (!line && local) {
        const source = (local.lines.get(anchor)||[]).find(l=>l.name===title);
        if (source) line = {title,stops:source.stations.map(s=>[s.name,s.kilometre])};
      }
      return {title,stops:line?.stops || [],planned:planned.includes(title)};
    });
  }
  function clearMap() {
    if (overlay) { overlay.clearLayers().remove(); overlay=null; }
    if (renderer) { renderer.remove(); renderer=null; }
    if (focusedDirectory) { LineFocus.endDirectory(focusedDirectory); focusedDirectory=null; }
  }
  function displayPaths(layers,anchors=[]) {
    clearMap();
    const map = state.map, pane = map.getPane("routeInspector") || map.createPane("routeInspector");
    pane.style.zIndex="623"; pane.style.pointerEvents="none";
    renderer=L.svg({pane:"routeInspector",padding:.3});
    overlay=L.featureGroup().addTo(map);
    for (const layer of layers) if (layer.parts.length) {
      const line = L.polyline(layer.parts,{pane:"routeInspector",renderer,interactive:false,
        lineCap:"round",lineJoin:"round",weight:4.6,opacity:.95,...layer.style}).addTo(overlay);
      line.getElement().dataset.inspectorInk=layer.type;
    }
    for (const p of anchors.filter(validPoint)) L.circleMarker(p,{renderer,radius:5,color:"#4a6775",fillColor:"#fff",
      fillOpacity:1,weight:2,interactive:false}).addTo(overlay);
    if (overlay.getBounds().isValid()) {
      if (state.playbackTimer) byID("followJourney").checked=false;
      map.fitBounds(overlay.getBounds().pad(.15),{maxZoom:15,animate:false});
    }
  }
  function station(name) {
    clearMap();
    selectStation(name,{pan:false});
    StationMapBoard.focus(name);
  }
  function fullLine(line) {
    clearMap();
    const names=line.stops.map(s=>s[0]);
    const rows=names.map(n=>[n,StationMapBoard.coordinate(n)]).filter(([,p])=>validPoint(p));
    focusedDirectory=line.title;
    void LineFocus.directory(line.title,rows,names,true);
    byID("infoPanel").hidden=false;
    byID("favoriteStation").hidden=true;
    byID("infoTitle").textContent=line.title;
    const content=byID("infoContent");
    const list=el("ol"); list.className="rail-sequence";
    for (const [name,mileage,note] of line.stops) {
      const item=el("li");
      item.append(button(name,()=>station(name)),el("small",[mileage!=null && mileage!=="" ? `${mileage} km` : "",note].filter(Boolean).join(" · ")));
      list.append(item);
    }
    const train=current;
    content.replaceChildren(el("strong",`${names[0]} → ${names.at(-1)} · ${names.length} 个站所`),
      button(`返回 ${train.train} 乘车区间`,()=>{clearMap(); selectRoute(context.full.id,{from:context.offset,to:context.offset+train.stops.length-1});}),
      list);
    if (matchMedia("(max-width: 900px)").matches) setWorkspaceOpen(false);
  }
  const storageKey = "railway-atlas-confirmed-route-legs-v1";
  function identity(full,index) {
    const key = [full.id, full.trip||"", full.train, full.serviceDate, full.source?.title,
      full.stops.map(s=>[nameOf(s),s.arrival??null,s.departure??null]), legPlan(full,index), index];
    return JSON.stringify(key);
  }
  function savedRows() {
    try {
      const items=JSON.parse(localStorage.getItem(storageKey));
      return Array.isArray(items) ? items : [];
    } catch { return []; }
  }
  function storeRecord(record) {
    try {
      const rows = [record,...savedRows().filter(r=>r.key!==record.key)].slice(0,32);
      if (JSON.stringify(record).length>600000) return false;
      while (JSON.stringify(rows).length>1200000) rows.pop();
      localStorage.setItem(storageKey,JSON.stringify(rows));
      return true;
    } catch {return false;}
  }
  function applyChoice(full,index,choice) {
    full.legs = Array.from({length:full.stops.length-1},(_,i)=>i===index?choice.points:full.legs?.[i]||[]);
    full.inspectorSources = Array.from({length:full.legs.length},(_,i)=>i===index ? choice.source : full.inspectorSources?.[i] || null);
    full.stopCoordinates = full.stops.map((_,i)=>full.legs[i]?.[0] || full.legs[i-1]?.at(-1) || full.stopCoordinates?.[i] || null);
    full.gaps = RailPaths.gapsFor(full.stops,full.legs);
    full.geometryAvailable = !full.gaps.length;
  }
  function reopen(full) {
    selectRoute(full.id,{from:context.offset,to:context.offset+current.stops.length-1,fit:false});
  }
  function inspect(index) {
    const serial=++inspectionSerial;
    comparisonSerial++;
    ui.result.replaceChildren();
    const route=current, row=context.rows[index], full=context.full, fullIndex=context.offset+index;
    const area=ui.detail;
    const anchors=[StationMapBoard.coordinate(row.from),StationMapBoard.coordinate(row.to)];
    displayPaths(row.drawable ? [{type:"leg",parts:[row.points],style:{color:colour.a}}] : [],row.drawable?[]:anchors);
    ui.quality.open=true;
    area.replaceChildren(el("strong",`${row.from} → ${row.to}`),
      el("p",`${row.problem || "轨迹连续"} · ${row.drawable ? `${row.source} · 轨道长度 ${km(row.length)} · ${row.points.length} 个顶点` : "待补轨道几何"}`));
    if (Number.isFinite(row.metered)) area.append(el("p",`计价里程 ${row.metered} km`));
    if (row.drawable && (full.source?.note || full.source?.title)) area.append(el("small",[full.source?.title,full.source?.note].filter(Boolean).join(" · ")));
    if (row.plan) area.append(el("p","经由站所　"+row.plan.nodes.map(n=>n.station).join(" → ")));
    const nav=el("div"); nav.className="record-actions";
    nav.append(button(row.from,()=>station(row.from)),button(row.to,()=>station(row.to)));
    if (current.stops.length!==full.stops.length)
      nav.append(button(`查看 ${full.train} 全程`,()=>selectRoute(full.id)));
    if (current.stops.length>2)
      nav.append(button("只看这个乘车区间",()=>selectRoute(full.id,{from:fullIndex,to:fullIndex+1})));
    const lines=eligibleLines(row);
    for (const line of lines) {
      const jump=button(`${line.planned?"经由":"候选"} · ${line.title}全线`,()=>fullLine(line));
      jump.disabled=!line.stops.length; nav.append(jump);
    }
    if (!lines.length) area.append(el("p","资料未列出此区间所属的线路。"));
    area.append(nav);
    const panel=el("div");
    const load=button("核对区间候选",async()=>{
      load.disabled=true; panel.replaceChildren(el("p","正在核对车次日期、经由与轨道端点…"));
      const answers=[], notes=[];
      const add=(points,source) => {
        if (!points?.length || answers.some(c=>sameShape(c.points,points))) return;
        answers.push({points,source});
      };
      const tasks=[(async()=>{
        const national=await RailPaths.find({train:full.train,date:full.serviceDate,stops:full.stops,trip:full.trip,routing:full.routing});
        add(national.legs[fullIndex],kinds[national.geometryKinds?.[fullIndex]] || "同日车次径路");
      })()];
      if (row.plan && LocalRailCache.loaded) tasks.push((async()=>{
        const [path]=await LocalRailCache.match(row.plan,[row.from,row.to]);
        add(path.map(pointToLatLng),"本机缓存 · 经由和计价里程匹配");
      })());
      for (const line of lines.filter(l=>l.stops.length)) tasks.push((async()=>{
        const indexFile=await lineFile("index.json");
        if (!indexFile[line.title]) return;
        const data=await lineFile(indexFile[line.title]);
        const entries=(data[line.title]||[]).map(([a,b,s])=>[a,b,RailPaths.decode(s)]);
        for (const points of directoryPaths(line.stops,entries,row.from,row.to)) add(points,`线路图集 · ${line.title}`);
      })());
      const results=await Promise.allSettled(tasks);
      if (serial!==inspectionSerial || route!==current) return;
      for (const r of results) if (r.status==="rejected") notes.push(r.reason.message);
      panel.replaceChildren();
      if (!answers.length) panel.append(el("p","没有找到可核对的连续候选。"+notes.join(" ")));
      for (const c of answers) {
        const already=sameShape(row.points,c.points);
        let invalid=candidateProblem(full,fullIndex,c.points);
        if (!invalid && ((validPoint(anchors[0]) && distance(anchors[0],c.points[0])>1400) ||
            (validPoint(anchors[1]) && distance(anchors[1],c.points.at(-1))>1400))) invalid="轨道端点与站点位置不符";
        panel.append(el("p",`${c.source} · ${already?"与当前轨迹相同":invalid||"端点和相邻轨迹通过核对"}`));
        const preview=button("在地图预览候选",()=>displayPaths([{type:"candidate",parts:[c.points],style:{color:"#b97624",dashArray:"6 4"}}]));
        const accept=button("采用并在本机记住",()=>{
          if (route!==current || invalid || already) return;
          const key=identity(full,fullIndex);
          const record={key,base:savedRows().find(r=>r.key===key)?.base || row.points,points:c.points,source:c.source};
          applyChoice(full,fullIndex,c);
          const stored=storeRecord(record);
          reopen(full);
          showToast(stored?"已保存此车次、日期和区间的选择。":"本次已采用，浏览器未能保存。");
        });
        accept.disabled=already||Boolean(invalid);
        panel.append(preview,accept);
      }
      load.disabled=false;
    });
    area.append(load,panel);
  }

  function compareTables(a,b,geometry) {
    const result=ui.result;
    const legText=r=>{const rows=report(r); return `${rows.filter(s=>s.drawable).length}/${rows.length} 段有轨迹`;};
    const table=el("table");
    const header=el("tr"); header.append(el("th",""),el("th",a.train),el("th",b.train)); table.append(header);
    const minutes=r=>tripMinutes(r)==null?"—":`${tripMinutes(r)} 分`;
    const lines=r=>[...new Set(r.routing?.edges?.map(e=>e.lineName).filter(Boolean)||[])].join("、") || "未标注";
    for (const [label,av,bv] of [
      ["始发日期",a.serviceDate,b.serviceDate],["停站",a.stops.length,b.stops.length],["运行时间",minutes(a),minutes(b)],
      ["几何覆盖",legText(a),legText(b)],["已收录轨道长度",km(geometry.a.onlyMetres+geometry.a.sharedMetres),km(geometry.b.onlyMetres+geometry.b.sharedMetres)],
      ["与对方重合",km(geometry.a.sharedMetres),km(geometry.b.sharedMetres)],["经由线路",lines(a),lines(b)]
    ]) { const tr=el("tr");tr.append(el("th",label),el("td",av),el("td",bv));table.append(tr); }
    result.append(table);
    const calls=box("两车逐站到发与停留",result);
    for (const r of [a,b]) {
      calls.append(el("strong",r.train));
      for (const s of r.stops) {
        const dwell=Number.isFinite(s.arrival)&&Number.isFinite(s.departure)?` · 停 ${s.departure-s.arrival} 分`:"";
        calls.append(el("div",`${nameOf(s)}　${formatClock(s.arrival)} / ${formatClock(s.departure)}${dwell}`));
      }
    }
    const sharedNames = new Set(b.stops.map(nameOf));
    const common=[...new Set(a.stops.map(nameOf).filter(n=>sharedNames.has(n)))];
    result.append(el("p",`共同停站 ${common.length} 个${common.length?" · "+common.join("、"):""}`));
  }
  async function compare() {
    const serial=++comparisonSerial, route=current;
    inspectionSerial++;
    clearMap();
    ui.result.replaceChildren(el("p","正在读取另一趟车的实际轨迹…"));
    try {
      const train=ui.train.value.trim().toUpperCase(), date=ui.date.value;
      if (!train || !date) throw Error("请填写比较车次和始发日期。");
      const loaded=state.routes.filter(r=>r.serviceDate===date&&RailLibrary.trainNames(r.train).includes(train));
      if (loaded.length>1) throw Error("本日已载入同号车次的多份排图，请先核对车次。");
      let other=loaded[0] || await RailPaths.find({train,date});
      if (serial!==comparisonSerial || current!==route) return;
      if (ui.same.checked) {
        const from=nameOf(route.stops[0]),to=nameOf(route.stops.at(-1));
        const range=uniqueRange(other.stops,from,to)||uniqueRange(other.stops,to,from);
        if (!range) throw Error("另一趟车没有唯一对应的起讫停站。可改为比较全程。");
        other=slice(other,...range);
      }
      const geometry=compareGeometry(route,other);
      const coveredA=geometry.a.onlyMetres+geometry.a.sharedMetres, coveredB=geometry.b.onlyMetres+geometry.b.sharedMetres;
      const comparable=coveredA>0&&coveredB>0;
      ui.result.replaceChildren();
      if (comparable) {
        displayPaths([{type:"a",parts:geometry.a.only,style:{color:colour.a}}, {type:"b",parts:geometry.b.only,style:{color:colour.b,dashArray:"8 4"}},
          {type:"shared",parts:geometry.a.shared,style:{color:colour.shared}}]);
      }
      ui.result.append(el("p",comparable ? `蓝实线 ${route.train} · 紫虚线 ${other.train} · 绿线为两份轨迹在 45 m 内且走向一致的部分。缺轨区间无法判断共线。` :
        "至少一趟车缺少可比较的轨道几何，以下仅列已知数据。"));
      compareTables(route,other,geometry);
      ui.result.append(button("收起比较图层",()=>{clearMap();ui.result.replaceChildren();}));
    } catch(e) {
      if (serial===comparisonSerial) ui.result.replaceChildren(el("p",e.message));
    }
  }
  let lastFull, checkedSaves=new Set();
  function refresh() {
    if (!ui || typeof state==="undefined" || !state.map) return;
    const route = state.workspaceView==="route" && state.playbackVisible ? state.route : null;
    if (route===current && (!route || context?.polylines===state.routePolylines && context.full===serviceContext(route).full)) return;
    inspectionSerial++; comparisonSerial++;
    clearMap(); detachMapHandlers();
    current=route; ui.root.hidden=!route;
    if (!route) return;
    context=serviceContext(route);
    const full=context.full;
    if (lastFull!==full) {checkedSaves=new Set();lastFull=full;}
    const stored=savedRows();
    let restored=false;
    if (stored.length) for (let i=context.offset;i<context.offset+route.stops.length-1;i++) {
      if (checkedSaves.has(i)) continue;
      checkedSaves.add(i);
      const saved=stored.find(r=>r.key===identity(full,i));
      if (saved && Array.isArray(saved.base) && Array.isArray(saved.points) && sameShape(full.legs?.[i]||[],saved.base) &&
          typeof saved.source==="string" && !candidateProblem(full,i,saved.points)) {
        applyChoice(full,i,saved); restored=true;
      }
    }
    if (restored) {current=null;selectRoute(full.id,{from:context.offset,to:context.offset+route.stops.length-1,fit:false});return;}
    context.polylines=state.routePolylines;
    context.rows=report(slice(full,context.offset,context.offset+route.stops.length-1));
    ui.label.textContent=`逐段质量 · ${context.rows.filter(s=>!s.problem).length}/${context.rows.length} 段连续`;
    ui.rows.replaceChildren();
    ui.detail.replaceChildren();
    ui.result.replaceChildren();
    ui.date.value=route.serviceDate;
    const choices=state.routes.filter(r=>r.id!==route.id);
    ui.trains.replaceChildren(...choices.map(r=>new Option(r.train)));
    if (!ui.train.value && choices.length) ui.train.value=choices[0].train;
    const handlers=[];
    for (const row of context.rows) {
      const action=()=>inspect(row.index);
      const item=button(`${row.from} → ${row.to}　${row.problem || row.source}`,action);
      item.dataset.leg=row.index; ui.rows.append(item);
      const line=state.routePolylines[row.index];
      if (line) {line.on("click",action);handlers.push([line,action]);}
    }
    detachMapHandlers=()=>{for(const [line,action] of handlers)line.off("click",action);};
  }
  function mount() {
    if (ui) return;
    const anchor=byID("routeSummary");
    if (!anchor) return;
    const root=el("section");root.id="routeInspector";root.hidden=true;
    const style=el("style",`
      #routeInspector {display:grid;gap:8px;min-width:0}
      #routeInspector details > summary {cursor:pointer}
      #routeInspector .ri-content {display:grid;gap:6px;margin:6px 0;overflow-wrap:anywhere}
      #routeInspector .ri-content p,#routeInspector table {font-size:12px;line-height:1.5}
      #routeInspector .ri-content button {text-align:left}
      #routeInspector table {width:100%;border-collapse:collapse}
      #routeInspector th,#routeInspector td {text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:3px}
      #routeInspector label:has(input[type=checkbox]) {display:flex;align-items:center;gap:6px}
      #routeInspector input[type=checkbox] {width:auto}
    `);
    document.head.append(style);anchor.after(root);
    const content=()=>{const d=el("div");d.className="ri-content";return d;};
    const quality=box("逐段质量",root), rows=content(), detail=content();
    quality.append(detail,rows);
    const comparison=box("比较两趟车的径路",root), fields=content(), result=content();
    const label=(title,input)=>{const l=el("label",title);l.append(input);return l;};
    const train=el("input"),trains=el("datalist"),date=el("input"),same=el("input");
    train.type="search";train.placeholder="例如 Z58";trains.id="riLoadedTrains";train.setAttribute("list",trains.id);
    date.type="date"; same.type="checkbox";
    fields.append(label("比较车次",train),trains,label("比较车次的始发日期",date),label("仅比较相同起讫站区间",same),button("在主地图比较",compare));
    comparison.append(fields,result);
    ui={root,quality,label:quality.firstChild,rows,detail,result,train,trains,date,same};
    const observer=new MutationObserver(refresh);
    observer.observe(anchor,{childList:true,subtree:true});
    for (const target of [document.querySelector('[data-page="route"]'),byID("playbackBar")].filter(Boolean))
      observer.observe(target,{attributes:true,attributeFilter:["hidden"]});
    refresh();
  }
  globalThis.RailwayRouteInspector={mount,refresh};
  if (document.readyState==="loading") document.addEventListener("DOMContentLoaded",mount,{once:true});
  else mount();
})();
