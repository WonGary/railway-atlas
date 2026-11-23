// Shared by JavaScriptCore, the web map and the snapshot builder.
// Coordinates stay in WGS84. A point is never expanded into a footprint.
globalThis.StationLayoutOSM = (() => {
  const minimumZoom = {outline: 14, concourse: 15, platform: 15, passage: 16, entrance: 16};
  const accessible = t => ![t.access,t.foot].some(v => /^(private|no|employees|staff|military)$/.test(v))
    && !t.construction && !t.proposed && !t["proposed:building"] && t.landuse!=="construction" &&
    !["construction","proposed"].includes(t.building) && t.disused !== "yes" && t.abandoned !== "yes";
  const close = (a,b) => a && b && a[0] === b[0] && a[1] === b[1];
  const ring = p => p.length >= 4 && close(p[0], p[p.length-1]);
  function inside(p, r) {
    let yes = false;
    for (let i=0,j=r.length-1;i<r.length;j=i++) {
      const a=r[i], b=r[j];
      if ((a[1]>p[1]) !== (b[1]>p[1]) && p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]) yes=!yes;
    }
    return yes;
  }
  function join(parts) {
    const result=[], pending=parts.slice();
    while (pending.length) {
      let path=pending.pop().slice();
      while (!ring(path)) {
        const end=path[path.length-1];
        const i=pending.findIndex(p=>close(p[0],end) || close(p[p.length-1],end));
        if (i<0) return null; // Incomplete relation: never close a gap with an invented edge.
        const p=pending.splice(i,1)[0];
        path=path.concat((close(p[0],end) ? p : p.slice().reverse()).slice(1));
      }
      result.push(path);
    }
    return result;
  }
  function mode(t) {
    if (t.subway==="yes" || t.station==="subway" || t.railway==="subway_entrance" || t.route==="subway") return "metro";
    if (t.tram==="yes" || t.route==="tram" || t.railway==="tram_stop") return "tram";
    if (t.light_rail==="yes" || t.monorail==="yes" || ["light_rail","monorail"].includes(t.station) ||
        ["light_rail","monorail"].includes(t.route)) return "lightRail";
    if (t.train==="yes" || t.route==="train") return "railway";
    return null;
  }
  const isPlatform = t => ["platform","platform_edge"].includes(t.railway) || t["area:railway"]==="platform" ||
    t["railway:area"]==="platform" || (!!mode(t) && (t.public_transport==="platform" || t.highway==="platform"));
  const isOutline = t => t.building==="train_station" || ["station","halt"].includes(t.railway) ||
    (t.public_transport==="station" && !!mode(t));
  const walkSurface = t => ["footway","pedestrian"].includes(t["area:highway"]) ||
    (["footway","pedestrian"].includes(t.highway) && t.area==="yes");
  const railHall = t => [t.railway,t.public_transport,t["railway:area"],t["area:railway"]].includes("concourse");
  const transferWalk = t => [t.name,t["name:zh"],t["name:en"]].some(v=>v &&
    /[换換转轉]乘(?:通道|走廊)|\b(?:transfer|interchange) (?:passage(?:way)?|corridor)\b/i.test(v));
  const mappedTransfer = t => transferWalk(t) &&
    (["footway","steps","corridor","pedestrian"].includes(t.highway) || !!t.building || t.indoor==="corridor");
  const namedHall = t => [t.room,t.railway,t.public_transport,t["railway:area"],t["area:railway"]].some(
    v=>["concourse","ticket_hall","station_hall","entrance_hall"].includes(v)) ||
    [t.name,t["name:zh"],t["name:en"],t["level:ref"]].some(v=>v && /站[厅廳]|[票大][厅廳]层|穿堂層|コンコース|\b(concourse|ticket hall)\b/i.test(v));
  const concourse = t => !t.shop && !t.amenity && !t.stairs && !t.conveying && (!isOutline(t) || namedHall(t)) &&
    !["steps","elevator","corridor"].includes(t.highway) && t.indoor!=="corridor" &&
    (namedHall(t) || (t.room==="hall" && ["room","area"].includes(t.indoor)) ||
      (!t.room && t.indoor==="area" && (walkSurface(t) || !t.highway)));
  const belowGround = t => t.location==="underground" || [t.level,t.layer].some(v=>
    String(v ?? "").split(";").some(level=>parseFloat(level)<0));
  const indoorWalk = t => ["yes","corridor"].includes(t.indoor) || t.location==="underground" ||
    ["yes","building","building_passage"].includes(t.tunnel) || belowGround(t);
  const isPassage = t => t.indoor==="corridor" || t.highway==="corridor" || t.footway==="corridor" ||
    (t.indoor==="room" && t.stairs==="yes") || walkSurface(t) ||
    (["footway","pedestrian","steps"].includes(t.highway) && (indoorWalk(t) || t.level!=null || t.covered==="yes"));
  const gateRole = role => /^(entrance|exit|entry_only|exit_only|entrance_only|entrance_exit|station_entrance)$/.test(role || "");
  const passengerDoor = t => !t.shop && !t.amenity && !t.emergency && !t.fixme &&
    !["no","service","private","emergency","garage","home","residence","delivery","staff"].includes(t.entrance) &&
    !/员工|職員|应急|應急|消防|停车场|停車場|货运|貨運/.test(t["name:zh"] || t.name || "");
  const signedGate = name => /[进進出]站[口門门]|[进進出]站通道/.test(name || "");
  function accessSign(t,kind,role="") {
    const name = String(t["name:zh"] || t.name || t["name:en"] || "").trim();
    const normalized = value => String(value ?? "").normalize("NFKC")
      .replace(/[٠-٩]/g,c=>String(c.charCodeAt(0)-0x660)).replace(/[۰-۹]/g,c=>String(c.charCodeAt(0)-0x6f0)).trim();
    const code = /^[A-Z]{1,2}(?:[-.]?\d{1,3}[A-Z]?)?$|^\d{1,3}[A-Z]?$/i;
    const short = v => typeof v==="string" && code.test(normalized(v)) ? normalized(v).toUpperCase() : "";
    const isGate = kind==="entrance";
    const fromName = isGate
      ? /(?:^|[^A-Za-z0-9])([A-Z]{1,2}(?:[-.]?\d{1,3}[A-Z]?)?|\d{1,3}[A-Z]?)\s*(?:号|號)?\s*(?:出入口|[进進出入]站口|出口|入口|口)|\b(?:exit|entrance|gate)\s+([A-Z]{1,2}\d{0,3}|\d{1,3}[A-Z]?)\b/i
      : /(?:^|[^A-Za-z0-9])([A-Z]{1,2}\d{0,3}|\d{1,3}[A-Z]?)\s*(?:号|號)?\s*(?:通道|走廊)|(?:通道|走廊|\bpassage(?:way)?|\bcorridor)\s*([A-Z]{1,2}\d{0,3}|\d{1,3}[A-Z]?)(?:号|號)?(?:$|[^A-Za-z0-9])/i;
    const names = [name,t.name,t["name:en"],t["name:ja"],t["name:ko"]].filter(Boolean).map(normalized);
    const signedInternational = /(?:sortie|entrée|ausgang|eingang|salida|saída|uscita|wyjście|výstup|выход|вихід|خروج|مخرج|출구|出口)\s*(?:n[°ºo.]?|№|#)?\s*([A-Z]{1,2}\d{0,3}|\d{1,3}[A-Z]?)(?=$|[\s、,()–-])/i;
    const signedEastAsian = /(?:^|[^A-Za-z0-9])([A-Z]{1,2}\d{0,3}|\d{1,3}[A-Z]?)\s*(?:番(?:号)?\s*出口|번\s*출구)/i;
    let signed="";
    for (const text of names) {
      const match=fromName.exec(text) || (isGate && (signedEastAsian.exec(text) || signedInternational.exec(text)));
      const token=match?.[1] || match?.[2] || "";
      signed=/^[A-Za-z]+$/.test(token) && token!==token.toUpperCase() ? "" : short(token);
      if (signed) break;
    }
    const number = short(t.local_ref) || short(t.ref) || signed || (isGate ? short(name) : "");
    const dir = /([东東西南北]{1,2})(?:侧|側|广场|廣場)?\s*(?:[进進出]站(?:口|通道)|出入口|出口|入口|门|門)/.exec(name)?.[1];
    const flow = /[进進]站/.test(name) || t.entrance==="entrance" || t.entrance==="entrance_only" || ["entry_only","entrance_only"].includes(role) ? "进" :
      /出站/.test(name) || ["exit","exit_only"].includes(t.entrance) || ["exit","exit_only"].includes(role) ? "出" : "";
    const label = number || (isGate ? (dir?.replace("東","东") || "") + flow : transferWalk(t) ? "换" : "");
    const title = name && name !== number ? name : [number, isGate ? (flow==="出" ? "出站口" : flow==="进" ? "进站口" : "出入口") : "通道"].filter(Boolean).join(" ");
    return {accessLabel:label,accessTitle:title};
  }
  function extract(doc) {
    if (!Array.isArray(doc.elements) || doc.remark) throw Error("车站资料不完整");
    const asOf = (doc.osm3s?.timestamp_osm_base || new Date().toISOString()).slice(0,10);
    const unopened = t => /^\d{4}(-\d\d(-\d\d)?)?$/.test(t.start_date) && t.start_date > asOf.slice(0,t.start_date.length);
    const nodes=new Map(), ways=new Map(), relationModes=new Map(), platformMembers=new Set(), entranceNodes=new Set(), anchors=[];
    const key=e=>e.type+"/"+(e.ref ?? e.id);
    const elements=new Map();
    for (const e of doc.elements) {
      if (!elements.has(key(e)) || e.geometry) elements.set(key(e),e);
      const t=e.tags || {};
      if (e.type==="node") {
        nodes.set(e.id,e);
        if (!accessible(t)) continue;
        if (t.railway==="subway_entrance" || (t.entrance && mode(t))) entranceNodes.add(e.id);
        if (mode(t) && (["station","halt","tram_stop","subway_entrance"].includes(t.railway) ||
            ["station","stop_position"].includes(t.public_transport)))
          anchors.push({point:[e.lon,e.lat],network:mode(t),entrance:entranceNodes.has(e.id)});
      } else if (e.type==="way") ways.set(e.id,e);
    }
    // A route can identify the mode of a stop_area through a shared stop. Read routes first.
    for (const stopArea of [false,true]) for (const e of elements.values()) {
      const t=e.tags || {}, members=e.members || [];
      if (e.type!=="relation" || !accessible(t) || (stopArea ? t.public_transport!=="stop_area" :
          !["train","subway","tram","light_rail","monorail"].includes(t.route))) continue;
      const network=mode(t) || members.map(m=>relationModes.get(key(m)) || mode(elements.get(key(m))?.tags || {})).find(Boolean);
      if (!network) continue;
      for (const m of members) {
        const platform=/^platform(?:_entry_only|_exit_only)?$/.test(m.role);
        if (!stopArea && !platform && !/^stop(?:_entry_only|_exit_only)?$/.test(m.role)) continue;
        const id=key(m);
        if (!relationModes.has(id)) relationModes.set(id,network);
        if (platform) platformMembers.add(id);
        if (m.type==="node" && (m.role?.toLowerCase()==="entrance" || nodes.get(m.ref)?.tags?.entrance) &&
            accessible(nodes.get(m.ref)?.tags || {})) entranceNodes.add(m.ref);
      }
    }
    function platform(e,t) {
      // Stations and train stopping positions sometimes appear in route relations with
      // a platform role. Their geometry and ref still describe the station or stop.
      if (["station","stop_position"].includes(t.public_transport) ||
          ["station","halt","stop","subway_entrance"].includes(t.railway) || t.entrance ||
          t.railway==="tram_stop" && t.public_transport!=="platform") return false;
      if (isPlatform(t)) return true;
      if ((t.bus==="yes" || t.highway==="bus_stop" || t.ferry==="yes") && !mode(t)) return false;
      return platformMembers.has(key(e)) || (t.public_transport==="platform" && relationModes.has(key(e)));
    }
    function coordinates(e) {
      const points=e.geometry || (e.nodes || []).map(n=>nodes.get(n));
      return points.length >= 2 && points.every(p=>p && Number.isFinite(p.lat) && Number.isFinite(p.lon))
        ? points.map(p=>[p.lon,p.lat]) : [];
    }
    function geometries(e) {
      if (e.type==="way") {
        const p=coordinates(e);
        return p.length ? [[p]] : [];
      }
      if (e.tags.type!=="multipolygon") return [];
      const outer=[], inner=[];
      for (const m of e.members || []) {
        if (m.type!=="way" || !["","outer","inner"].includes(m.role)) continue;
        const path=coordinates(m.geometry ? m : ways.get(m.ref) || {});
        if (!path.length) return [];
        (m.role==="inner"?inner:outer).push(path);
      }
      const shells=join(outer), holes=join(inner);
      if (!shells || !holes || holes.some(h=>!shells.some(s=>inside(h[0],s)))) return [];
      return shells.map(s=>[s,...holes.filter(h=>inside(h[0],s))]);
    }
    function nearMode(point) {
      let best=null, dist=0.004**2;
      for (const a of anchors) {
        const d=((a.point[0]-point[0])*Math.cos(point[1]*Math.PI/180))**2+(a.point[1]-point[1])**2;
        if (d<dist) {dist=d;best=a.network;}
      }
      return best;
    }
    const features=[], shells=[], linked=new Set(entranceNodes), relationWays=new Set(), passages=[];
    const wallModes=new Map(), wallGateNames=new Map(), entranceRoles=new Map(), entranceByNode=new Map();
    for (const e of elements.values()) {
      if (e.tags?.public_transport!=="stop_area" || !accessible(e.tags)) continue;
      for (const m of e.members || []) if (m.type==="node" && gateRole(m.role)) entranceRoles.set(m.ref,m.role);
    }
    const candidates=[...elements.values()].filter(e=>e.type==="way" || e.tags?.type==="multipolygon")
      .filter(e=>accessible(e.tags || {}) && !unopened(e.tags || {}));
    // Process area relations first. Their member ways can carry the same tags.
    candidates.sort((a,b)=>Number(b.type==="relation")-Number(a.type==="relation") || a.id-b.id);
    const within=(pt,paths)=>inside(pt,paths[0]) && !paths.slice(1).some(h=>inside(pt,h));
    for (const kind of ["outline","platform","concourse","passage"]) {
      for (const e of candidates) {
        const t=e.tags || {}, source=key(e);
        if (relationWays.has(kind+"/"+source)) continue;
        if (kind==="outline" && ((!isOutline(t) && t.building!=="transportation") || concourse(t) || platform(e,t) || mappedTransfer(t))) continue;
        if (kind==="platform" && !platform(e,t)) continue;
        if (kind==="concourse" && (!concourse(t) || platform(e,t))) continue;
        if (kind==="passage" && ((!isPassage(t) || isOutline(t)) && !mappedTransfer(t) || platform(e,t) || t.fixme)) continue;
        if (t.amenity==="bus_station" || ((t.bus==="yes" || t.highway==="bus_stop") && !mode(t) && !platformMembers.has(source))) continue;
        for (const [part,paths] of geometries(e).entries()) {
          const p=paths[0], area=ring(p) && t.area!=="no" && t.railway!=="platform_edge" &&
            (kind!=="passage" || walkSurface(t) || t.indoor==="corridor" || t.indoor==="room" || t.area==="yes" ||
              (mappedTransfer(t) && !!t.building));
          if ((kind==="outline" || kind==="concourse") && !area) continue;
          if (kind==="passage" && concourse(t) && ring(p) && t.area!=="no") continue;
          const stationPoint=area && anchors.find(a=>!a.entrance && within(a.point,paths));
          const containing=shells.find(s=>p.every(c=>within(c,s.paths)));
          const vertices=e.nodes || (e.members || []).flatMap(m=>ways.get(m.ref)?.nodes || []);
          const direct=relationModes.has(source) || vertices.some(n=>linked.has(n));
          if (kind==="outline" && !isOutline(t) && !(mode(t) || stationPoint || relationModes.has(source))) continue;
          // Public indoor links can emerge above a subway station. Outdoors, a covered
          // pavement or crossing over the same footprint is not evidence of a station path.
          const indoorLink = t.indoor==="yes" || t.indoor==="corridor" || t.highway==="corridor" || t.footway==="corridor";
          const insideStation=containing && (!belowGround(containing) || belowGround(t) || indoorLink ||
            (t.level==null && t.layer==null && (indoorWalk(t) || t.indoor==="area")));
          const namedBelowStation = namedHall(t) && belowGround(t) && nearMode(p[0]);
          if (kind==="concourse" && !railHall(t) && !insideStation && !direct && !mode(t) && !namedBelowStation &&
              !(stationPoint && (namedHall(t) || belowGround(t)))) continue;
          const surfaceTerminal = kind==="outline" && t.building==="train_station" && t.name && Number(t.layer)>0;
          // A long platform can project beyond the terminal building at both ends.
          const namedTerminal = kind==="platform" && t.name && shells.find(s=>s.name &&
            t.name.startsWith(s.name) && p.some((c,i)=>inside(c,s.paths[0]) || i>0 &&
              inside([(c[0]+p[i-1][0])/2,(c[1]+p[i-1][1])/2],s.paths[0])));
          const hallMode = kind==="concourse" && /\b(underground station|subway station)\b/i.test(t.name || "") ? "metro" : null;
          const network=mode(t) || (surfaceTerminal ? "railway" : null) || relationModes.get(source) || hallMode ||
            stationPoint?.network || containing?.network || namedTerminal?.network || nearMode(p[Math.floor(p.length/2)]) || "railway";
          const feature={id:source+(part?"#"+part:""),kind,network,area,paths};
          for (const key of ["level","layer","location","local_ref","ref","name"]) if (t[key]!=null) feature[key]=t[key];
          if (kind==="passage") passages.push({feature,vertices,direct:direct || insideStation ||
            (mappedTransfer(t) && nearMode(p[Math.floor(p.length/2)])),
            extend:indoorWalk(t) || t.highway==="corridor" || t.footway==="corridor"});
          else features.push(feature);
          if (kind==="outline" || kind==="concourse") shells.push(feature);
          if (kind==="outline") {
            for (const id of vertices) wallModes.set(id,network);
            if (t.building==="train_station" && signedGate(t.name) && passengerDoor(t)) {
              const doors=vertices.filter(id=>{
                const door=nodes.get(id)?.tags;
                return door && (door.entrance || door.railway==="train_station_entrance" || door.railway==="subway_entrance") &&
                  accessible(door) && passengerDoor(door);
              });
              for (const id of doors) wallGateNames.set(id,t.name);
              if (!doors.length) {
                const anchor=labelAnchors(feature)[0];
                if (anchor) features.push({id:feature.id+"#access",kind:"entrance",network,area:false,paths:[[anchor]],
                  name:t.name,...accessSign(t,"entrance"),positionSource:"building"});
              }
            }
          }
          if (kind==="platform" || kind==="concourse") for (const n of vertices) linked.add(n);
          if (e.type==="relation") for (const m of e.members || []) if(m.type==="way") relationWays.add(kind+"/way/"+m.ref);
        }
      }
    }
    for (const [id,e] of nodes) {
      const t=e.tags || {}, role=entranceRoles.get(id), source="node/"+id;
      if (!accessible(t) || unopened(t) || !passengerDoor(t) || !Number.isFinite(e.lon) || !Number.isFinite(e.lat)) continue;
      const subway=t.railway==="subway_entrance", railway=t.railway==="train_station_entrance";
      const memberMode=relationModes.get(source), wallMode=wallModes.get(id);
      if (!subway && !railway && !(role && memberMode) && !(t.entrance && (wallMode || memberMode))) continue;
      const name=t["name:zh"] || t.name || wallGateNames.get(id);
      const feature={id:source,kind:"entrance",network:subway?"metro":railway?"railway":wallMode || memberMode,
        area:false, paths:[[[e.lon,e.lat]]], local_ref:t.local_ref,ref:t.ref,name:t.name,level:t.level,
        ...accessSign({...t,name},"entrance",role)};
      features.push(feature);
      entranceByNode.set(id,feature);
    }
    // Paths often split at stairs. Follow mapped shared nodes inside the station; an exit
    // may anchor a segment but does not turn a chain of covered street sidewalks into passages.
    let pending=passages;
    for (let depth=0;pending.length && depth<10;depth++) {
      const next=[], added=[];
      for (const item of pending) {
        if (!item.direct && !item.vertices.some(n=>linked.has(n))) { next.push(item); continue; }
        const passage=item.feature;
        const sign=accessSign(passage,"passage");
        if (sign.accessLabel) Object.assign(passage,sign);
        else {
          const exits=[...new Set(item.vertices.map(id=>entranceByNode.get(id)?.accessLabel).filter(Boolean))];
          if (exits.length===1 && /^[A-Z0-9][A-Z0-9.-]*$/i.test(exits[0]))
            Object.assign(passage,{accessLabel:"→"+exits[0],accessTitle:`通往 ${exits[0]} 口`});
        }
        features.push(passage);
        if (item.extend) added.push(...item.vertices);
      }
      if (added.every(n=>linked.has(n))) break;
      for (const n of added) linked.add(n);
      pending=next;
    }
    for (const [id,e] of nodes) {
      const t=e.tags || {}, source="node/"+id;
      if (!accessible(t) || unopened(t) || !platform(e,t) ||
          t.highway==="bus_stop" || (t.bus==="yes" && !mode(t)) ||
          !Number.isFinite(e.lon) || !Number.isFinite(e.lat)) continue;
      const point=[e.lon,e.lat];
      features.push({id:source,kind:"platform",network:mode(t) || relationModes.get(source) || nearMode(point) || "railway",
        area:false, paths:[[point]], local_ref:t.local_ref,ref:t.ref,name:t.name,level:t.level,layer:t.layer});
    }
    return prepareFeatures(features);
  }
  // A number identifies the platform itself. Never borrow a route number, stop ID or floor.
  function platformNumber(f) {
    for (const ref of [f.local_ref, f.ref]) {
      if (typeof ref !== "string") continue;
      const parts = ref.trim().split(/\s*[;；,/、]\s*/);
      if (parts.length <= 4 && parts.every(s => /^(?:[A-Z]?\d{1,3}[A-Z]?|[A-Z])$/i.test(s)))
        return [...new Set(parts)].join("/");
    }
    const name = String(f.name || "");
    const matches = [...name.matchAll(/(?:第\s*)?(\d{1,3}[A-Za-z]?(?:\s*[-–、/]\s*\d{1,3}[A-Za-z]?)*)\s*(?:号|號)?\s*(?:站台|站臺|月台|月臺)/g)];
    if (matches.length && matches.length <= 4) return matches.map(m=>m[1].replace(/\s/g,"")).join("/");
    return /^(?:platform|track)\s+([A-Z]?\d{1,3}[A-Z]?|[A-Z])$/i.exec(name)?.[1] || "";
  }
  // Three candidate anchors let neighbouring platforms carry short, non-overlapping labels.
  // For a polygon, intersect a cross section with every ring and choose an interior interval.
  function labelAnchors(f) {
    const path = f.paths[0], fractions = [.5,.27,.73];
    if (!f.area) {
      const lengths = path.slice(1).map((b,i) => Math.hypot((b[0]-path[i][0])*Math.cos(b[1]*Math.PI/180), b[1]-path[i][1]));
      const total = lengths.reduce((sum,n)=>sum+n,0);
      if (!total) return [];
      return fractions.map(fraction=>{
        let left = total*fraction;
        for (let i=0;i<lengths.length;i++) {
          if (lengths[i]>0 && left<=lengths[i]) return path[i].map((v,j)=>v+(path[i+1][j]-v)*left/lengths[i]);
          left-=lengths[i];
        }
        return path[path.length-1];
      });
    }
    const low = [...path[0]], high = [...path[0]];
    for (const p of path) for (let j=0;j<2;j++) { low[j]=Math.min(low[j],p[j]); high[j]=Math.max(high[j],p[j]); }
    const axis = (high[0]-low[0])*Math.cos(low[1]*Math.PI/180) >= high[1]-low[1] ? 0 : 1, other=1-axis;
    return fractions.flatMap(fraction=>{
      const cut=low[axis]+fraction*(high[axis]-low[axis]), hits=[];
      for (const r of f.paths) for (let i=1;i<r.length;i++) {
        const a=r[i-1], b=r[i];
        if ((a[axis]>cut)!==(b[axis]>cut)) hits.push(a[other]+(cut-a[axis])*(b[other]-a[other])/(b[axis]-a[axis]));
      }
      hits.sort((a,b)=>a-b);
      let width=0, midpoint;
      for (let i=1;i<hits.length;i+=2) {
        const gap=hits[i]-hits[i-1];
        if (gap>width) { width=gap; midpoint=(hits[i]+hits[i-1])/2; }
      }
      return width ? [axis===0?[cut,midpoint]:[midpoint,cut]] : [];
    });
  }
  function withPlatformLabel(feature) {
    if (feature.kind!=="platform") return feature;
    const label=platformNumber(feature);
    if (label && feature.paths?.[0]?.length) {
      feature.platformLabel=label;
      feature.labelAnchors=feature.paths[0].length===1 ? [feature.paths[0][0]] : labelAnchors(feature);
    }
    return feature;
  }
  function prepareFeatures(features) {
    const facesByVertex=new Map();
    for (const f of features) {
      withPlatformLabel(f);
      if (f.kind==="entrance" || (f.kind==="passage" && f.accessLabel))
        f.labelAnchors=f.paths[0].length===1 ? [f.paths[0][0]] : labelAnchors(f);
      if (!f.platformLabel || !f.area) continue;
      for (const p of f.paths[0]) {
        const key=p.join(",");
        if (!facesByVertex.has(key)) facesByVertex.set(key,new Set());
        facesByVertex.get(key).add(f);
      }
    }
    // A platform edge may be mapped separately from its polygon. Keep both
    // geometries. Share the label only with a face along the same mapped edge.
    for (const f of features) {
      if (f.area || !f.platformLabel) continue;
      const points=f.paths[0], refs=f.platformLabel.split("/");
      for (const face of facesByVertex.get(points[0].join(",")) || []) {
        if (f.level && face.level && f.level!==face.level || f.layer && face.layer && f.layer!==face.layer) continue;
        if (refs.every(ref=>face.platformLabel.split("/").includes(ref)) &&
            points.every(p=>facesByVertex.get(p.join(","))?.has(face))) {
          f.labelOwner=face.id;
          break;
        }
      }
    }
    return features;
  }
  // Each parent route supplies membership, never full route or national geometry.
  function query(s,w,n,e) {
    const box=[s,w,n,e].map(Number);
    if (!box.every(Number.isFinite) || s < -90 || n > 90 || w < -180 || e > 180 ||
        n<=s || e<=w || n-s>0.061 || e-w>0.081) throw Error("请再放大一级");
    const b=box.map(v=>v.toFixed(5)).join(",");
    const selectors=[
      'nwr[railway~"^(station|halt|tram_stop|subway_entrance|train_station_entrance|platform|platform_edge)$"]',
      'node[entrance]',
      'node[railway=stop]',
      'nwr[public_transport~"^(platform|station|stop_position)$"]',
      'wr["area:railway"~"^(platform|concourse)$"]',
      'wr["railway:area"~"^(platform|concourse)$"]',
      'wr[railway=concourse]',
      'wr[public_transport=concourse]',
      'wr[building~"^(train_station|transportation)$"]',
      'wr[indoor~"^(corridor|room|area)$"]',
      'wr[room~"^(concourse|hall|station_hall|ticket_hall|entrance_hall)$"]',
      'wr[name~"站[厅廳]|穿堂層|[换換转轉]乘(通道|走廊)"]',
      'wr["area:highway"~"^(footway|pedestrian)$"]',
      'wr[highway~"^(corridor|platform)$"]',
      'way[footway=corridor]',
      'way[highway~"^(footway|steps|pedestrian)$"][indoor]',
      'way[highway~"^(footway|steps|pedestrian)$"][tunnel]',
      'way[highway~"^(footway|steps|pedestrian)$"][covered]',
      'way[highway~"^(footway|steps|pedestrian)$"][level]',
      'way[highway~"^(footway|steps|pedestrian)$"][layer]',
      'way[highway~"^(footway|steps|pedestrian)$"][location=underground]',
      'way[highway~"^(footway|steps|pedestrian)$"][area=yes]'
    ];
    const parents=["bn","bw","br"].flatMap(from=>[
      `rel(${from}.local)[public_transport=stop_area];`,
      `rel(${from}.local)[route~"^(subway|tram|light_rail|monorail|train)$"];`
    ]).join("");
    return `[out:json][timeout:15];(`+
      selectors.map(selector=>`${selector}(${b});`).join("")+
      `)->.local;(${parents})->.parents;`+
      // A few platforms have only a member role. Fetch their geometry only in this cell.
      `(.local;`+["node","way","rel"].flatMap(type=>
        ["platform","platform_entry_only","platform_exit_only"].map(role=>`${type}(r.parents:"${role}")(${b});`)
      ).join("")+["entrance","exit","entry_only","exit_only","entrance_only","entrance_exit","station_entrance"].map(
        role=>`node(r.parents:"${role}")(${b});`).join("")+`);out geom;.parents out body;`;
  }
  const globalSource = "https://overpass-api.de/api/interpreter";
  // The coarse bounds pick a preferred mirror, never decide whether a station exists.
  function sources(lat,lon,preferred=globalSource) {
    const host="https://ovp.dresel.systems";
    const regionName = [
      ["api-oc",-49,-10,110,180],["api-sa",-57,11,-82,-34],["api-ca",7,18,-93,-76],
      ["api-na",18,72,-169,-52],["api-af",-36,36,-18,52],["api",36,71,-24,37],
      ["api-as",-11,57,53,150]
    ].find(([,s,n,w,e])=>lat>=s && lat<=n && lon>=w && lon<=e)?.[0];
    const region = regionName ? host+"/"+regionName+"/interpreter" : null;
    return [...new Set([region,preferred,globalSource,"https://overpass.private.coffee/api/interpreter"].filter(Boolean))].slice(0,3);
  }
  return {extract,query,sources,minimumZoom,prepareFeatures};
})();
