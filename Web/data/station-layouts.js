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
    if (t.tram==="yes" || t.route==="tram" || t.railway==="tram_stop") return "tram";
    if (t.light_rail==="yes" || t.monorail==="yes" || ["light_rail","monorail"].includes(t.station) ||
        ["light_rail","monorail"].includes(t.route)) return "lightRail";
    if (t.train==="yes" || t.route==="train") return "railway";
    return null;
  }
  const isPlatform = t => t.railway==="platform" || t.railway==="platform_edge" || t["area:railway"]==="platform" ||
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
        if (mode(t) && (["station","halt","tram_stop","subway_entrance"].includes(t.railway) || t.public_transport==="stop_position"))
          anchors.push({point:[e.lon,e.lat],network:mode(t)});
      } else if (e.type==="way") ways.set(e.id,e);
    }
    for (const e of doc.elements) {
      const t=e.tags || {};
      if (e.type!=="relation" || !(t.public_transport==="stop_area" || ["train","subway","tram","light_rail","monorail"].includes(t.route))) continue;
      const members=e.members || [];
      const network=mode(t) || members.map(m=>mode((m.type==="node"?nodes:ways).get(m.ref)?.tags || {})).find(Boolean);
      if (!network) continue;
      for (const m of members) {
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
          // A long platform can project beyond the terminal building at both ends.
          const namedTerminal = kind==="platform" && t.name && shells.find(s=>s.name &&
            t.name.startsWith(s.name) && p.some((c,i)=>inside(c,s.paths[0]) || i>0 &&
              inside([(c[0]+p[i-1][0])/2,(c[1]+p[i-1][1])/2],s.paths[0])));
          const network=mode(t) || (surfaceTerminal ? "railway" : null) || relationModes.get(source) ||
            containing?.network || namedTerminal?.network || nearMode(p[Math.floor(p.length/2)]) || "railway";
          const feature={id:source+(part?"#"+part:""),kind,network,area,paths};
          for (const key of ["level","layer","local_ref","ref","name"]) if (t[key]!=null) feature[key]=t[key];
          features.push(feature);
          if (kind==="outline") shells.push(feature);
          if (kind==="platform") for (const n of e.nodes || []) linked.add(n);
          if (e.type==="relation") for (const m of e.members || []) if(m.type==="way") relationWays.add(kind+"/way/"+m.ref);
        }
      }
    }
    for (const [id,e] of nodes) {
      const t=e.tags || {}, source="node/"+id;
      if (!accessible(t) || !(isPlatform(t) || (t.public_transport==="platform" && railMembers.has(source))) ||
          t.highway==="bus_stop" || (t.bus==="yes" && !mode(t)) || !platformNumber(t) ||
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
  // A user-requested small view; use Overpass for read-only live queries.
  function query(s,w,n,e) {
    const box=[s,w,n,e].map(Number);
    if (!box.every(Number.isFinite) || n<=s || e<=w || n-s>0.061 || e-w>0.081) throw Error("请再放大一级");
    const b="("+box.map(v=>v.toFixed(5)).join(",")+")";
    return `[out:json][timeout:15];(`+
      ["nwr[railway~\"^(station|halt|tram_stop|subway_entrance|platform|platform_edge)$\"]","nwr[public_transport~\"^(platform|station|stop_position)$\"]","wr[\"area:railway\"=platform]",
       "wr[building=train_station]","wr[indoor=corridor]","way[highway=corridor]","way[footway=corridor]",
       ...["indoor","tunnel","level","location"].map(k=>`way[highway~"^(footway|steps|pedestrian)$"][${k}]`)].map(sel=>sel+b+";").join("")+
      `)->.local;.local out geom;`+
      `(`+["bn","bw","br"].map(from=>`rel(${from}.local)[public_transport=stop_area];`+
        `rel(${from}.local)[route~"^(subway|tram|light_rail|monorail|train)$"];`).join("")+`);out body;`;
  }
  return {extract,query,minimumZoom,prepareFeatures};
})();
