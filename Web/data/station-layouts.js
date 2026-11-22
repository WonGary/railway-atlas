// Shared by JavaScriptCore, the web map and the snapshot builder.
// Coordinates stay in WGS84. A point is never expanded into a footprint.
globalThis.StationLayoutOSM = (() => {
  const minimumZoom = {outline: 16, platform: 17, passage: 18};
  const accessible = t => ![t.access,t.foot].some(v => /^(private|no|employees|staff|military)$/.test(v))
    && !t.construction && !t.proposed && t.disused !== "yes" && t.abandoned !== "yes";
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
    if (t.tram==="yes" || t.route==="tram") return "tram";
    if (t.light_rail==="yes" || ["light_rail","monorail"].includes(t.station) || t.route==="light_rail") return "lightRail";
    if (t.train==="yes" || t.route==="train") return "railway";
    return null;
  }
  const isPlatform = t => t.railway==="platform" || t.railway==="platform_edge" ||
    (t.public_transport==="platform" && !!mode(t));
  const isOutline = t => t.building==="train_station" || t.railway==="station" ||
    (t.public_transport==="station" && (!!mode(t) || t.building==="transportation"));
  const isPassage = t => t.indoor==="corridor" || t.highway==="corridor" || t.footway==="corridor" ||
    (["footway","pedestrian","steps"].includes(t.highway) &&
      (t.indoor==="yes" || t.location==="underground" || ["yes","building_passage"].includes(t.tunnel) || t.level!=null));
  function extract(doc) {
    if (!Array.isArray(doc.elements) || doc.remark) throw Error("车站资料不完整");
    const nodes=new Map(), ways=new Map(), relationModes=new Map(), railMembers=new Set(), entranceNodes=new Set(), anchors=[];
    for (const e of doc.elements) {
      const t=e.tags || {};
      if (e.type==="node") {
        nodes.set(e.id,e);
        if (!accessible(t)) continue;
        if (t.railway==="subway_entrance" || (t.entrance && mode(t))) entranceNodes.add(e.id);
        if (mode(t) && (t.railway==="station" || t.railway==="halt" || t.public_transport==="stop_position" || t.railway==="subway_entrance"))
          anchors.push({point:[e.lon,e.lat],network:mode(t)});
      } else if (e.type==="way") ways.set(e.id,e);
    }
    for (const e of doc.elements) {
      const t=e.tags || {};
      if (e.type!=="relation" || !(t.public_transport==="stop_area" || ["train","subway","tram","light_rail","monorail"].includes(t.route))) continue;
      const members=e.members || [];
      const network=mode(t) || members.map(m=>mode((m.type==="node"?nodes:ways).get(m.ref)?.tags || {})).find(Boolean);
      if (!network) continue;
      for (const m of members.filter(m=>m.type==="way" || m.type==="relation")) {
        if (!m.role?.startsWith("platform") && t.public_transport!=="stop_area") continue;
        const id=m.type+"/"+m.ref;
        railMembers.add(id);
        if (!relationModes.has(id)) relationModes.set(id,network);
      }
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
    const features=[], shells=[], linked=new Set(entranceNodes), relationWays=new Set();
    const candidates=doc.elements.filter(e=>e.type!=="node" && e.tags && accessible(e.tags));
    // Process area relations first. Their member ways can carry the same tags.
    candidates.sort((a,b)=>Number(b.type==="relation")-Number(a.type==="relation") || a.id-b.id);
    for (const kind of ["outline","platform","passage"]) {
      for (const e of candidates) {
        const t=e.tags, source=e.type+"/"+e.id;
        if (relationWays.has(kind+"/"+source)) continue;
        if (kind==="outline" && !isOutline(t)) continue;
        if (kind==="platform" && !(isPlatform(t) || (t.public_transport==="platform" && railMembers.has(source)))) continue;
        if (kind==="passage" && (!isPassage(t) || isPlatform(t) || isOutline(t) || t.fixme)) continue;
        if ((t.bus==="yes" || t.highway==="bus_stop") && !mode(t) && !railMembers.has(source)) continue;
        for (const [part,paths] of geometries(e).entries()) {
          const p=paths[0], area=ring(p) && t.area!=="no" && t.railway!=="platform_edge" &&
            (kind!=="passage" || t.area==="yes" || t.indoor==="corridor");
          if (kind==="outline" && !area) continue;
          const containing=shells.find(s=>p.every(c=>inside(c,s.paths[0]) && !s.paths.slice(1).some(h=>inside(c,h))));
          const direct=(e.nodes || []).some(n=>linked.has(n)) || railMembers.has(source);
          if (kind==="passage" && !containing && !direct) continue;
          const surfaceTerminal = kind==="outline" && t.building==="train_station" && t.name && Number(t.layer)>0;
          const network=mode(t) || relationModes.get(source) || containing?.network || (surfaceTerminal ? "railway" : nearMode(p[Math.floor(p.length/2)])) || "railway";
          const feature={id:source+(part?"#"+part:""),kind,network,area,paths};
          for (const key of ["level","layer","ref","name"]) if (t[key]!=null) feature[key]=t[key];
          features.push(feature);
          if (kind==="outline") shells.push(feature);
          if (kind==="platform") for (const n of e.nodes || []) linked.add(n);
          if (e.type==="relation") for (const m of e.members || []) if(m.type==="way") relationWays.add(kind+"/way/"+m.ref);
        }
      }
    }
    return features;
  }
  // A user-requested small view; use Overpass for read-only live queries.
  function query(s,w,n,e) {
    const box=[s,w,n,e].map(Number);
    if (!box.every(Number.isFinite) || n<=s || e<=w || n-s>0.061 || e-w>0.081) throw Error("请再放大一级");
    const b="("+box.map(v=>v.toFixed(5)).join(",")+")";
    return `[out:json][timeout:15];(`+
      ["nwr[railway~\"^(station|halt|subway_entrance|platform|platform_edge)$\"]","nwr[public_transport~\"^(platform|station|stop_position)$\"]",
       "wr[building=train_station]","wr[indoor=corridor]","way[highway=corridor]","way[footway=corridor]",
       ...["indoor","tunnel","level","location"].map(k=>`way[highway~"^(footway|steps|pedestrian)$"][${k}]`)].map(sel=>sel+b+";").join("")+
      `);out geom;`;
  }
  return {extract,query,minimumZoom};
})();
