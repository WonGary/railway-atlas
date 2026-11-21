// Match a validated timetable plan to named OSM rail ways in the user's cache.
// Each section must be connected and agree with the timetable's kilometre marks.
const earthMetres = 6371008.8;
function metres(a,b) {
  const rad = Math.PI/180;
  const dx = (a[0]-b[0])*rad*Math.cos((a[1]+b[1])*rad/2);
  return earthMetres*Math.hypot(dx,(a[1]-b[1])*rad);
}
function lineKey(name="") { return name.replace(/客运专线$|高速铁路$|高速线$|客专线$|高铁$|客专$|铁路$|线$/,""); }
function stationKey(name="") { return name.split(/\s+/)[0].replace(/线路所$/,"所").replace(/站$/,""); }
function tileXY([lon,lat],zoom) {
  const n=2**zoom;
  return [Math.floor((lon+180)*n/360),Math.floor((1-Math.asinh(Math.tan(lat*Math.PI/180))/Math.PI)*n/2)];
}
function heapPush(heap,item) {
  let i=heap.length; heap.push(item);
  while (i>0) {
    const p=(i-1)>>1;
    if (heap[p][0]<=item[0]) break;
    heap[i]=heap[p]; i=p;
  }
  heap[i]=item;
}
function heapPop(heap) {
  const first=heap[0],last=heap.pop();
  if (heap.length) {
    let i=0;
    while (i*2+1<heap.length) {
      let j=i*2+1;
      if (j+1<heap.length && heap[j+1][0]<heap[j][0]) j++;
      if (last[0]<=heap[j][0]) break;
      heap[i]=heap[j]; i=j;
    }
    heap[i]=last;
  }
  return first;
}
function sectionPath(ways,from,to,expected,checkTime) {
  const points=[],edges=[],byCell=new Map();
  const xUnit=111195*Math.cos((from[1]+to[1])*Math.PI/360)/22, yUnit=111195/22;
  function addNode(point) {
    const x=Math.floor(point[0]*xUnit), y=Math.floor(point[1]*yUnit);
    let nearest=-1,distance=22;
    for(let i=x-1;i<=x+1;i++) for(let j=y-1;j<=y+1;j++) for(const id of byCell.get(`${i}:${j}`)||[]) {
      const d=metres(points[id],point);
      if(d<distance){nearest=id;distance=d;}
    }
    if(nearest>=0)return nearest;
    if(points.length>=250000)throw Error("此区段的轨道点超出浏览器匹配范围。");
    const id=points.length,key=`${x}:${y}`;
    points.push(point); edges.push([]);
    if(!byCell.has(key))byCell.set(key,[]);
    byCell.get(key).push(id); return id;
  }
  for(const {way,named} of ways) {
    checkTime();
    let prev=addNode(way[0]);
    for(let i=1;i<way.length;i++){
      const a=way[i-1],b=way[i],n=Math.ceil(metres(a,b)/45);
      for(let j=1;j<=n;j++){
        const id=addNode([a[0]+j/n*(b[0]-a[0]),a[1]+j/n*(b[1]-a[1])]);
        if(id===prev)continue;
        const d=metres(points[prev],points[id]);
        edges[prev].push([id,d,named]);edges[id].push([prev,d,named]);prev=id;
      }
    }
  }
  const parents=new Int32Array(points.length).fill(-1);
  const namedEdge=new Uint8Array(points.length);
  const costs=new Float64Array(points.length).fill(Infinity),finish=new Map(),heap=[];
  for (let i=0;i<points.length;i++){
    const a=metres(from,points[i]),b=metres(to,points[i]);
    if(a<800){costs[i]=a*4;heapPush(heap,[costs[i],i]);}
    if(b<800)finish.set(i,b*4);
  }
  let best=Infinity,end=-1;
  while(heap.length){
    checkTime();
    const [distance,id]=heapPop(heap);
    if(distance!==costs[id])continue;
    if(distance>=best)break;
    if(finish.has(id) && distance+finish.get(id)<best){best=distance+finish.get(id);end=id;}
    for(const [next,step,named] of edges[id]){
      const total=distance+step;
      if(total>=costs[next])continue;
      costs[next]=total;parents[next]=id;namedEdge[next]=named;heapPush(heap,[total,next]);
    }
  }
  if(end<0)throw Error("车站之间缺少连续的同线轨道。");
  const result=[];
  let namedLength=0;
  for(let i=end;i>=0;i=parents[i]){
    result.push(points[i]);
    if(namedEdge[i]) namedLength+=metres(points[i],points[parents[i]]);
  }
  result.reverse();
  let length=0;
  for(let i=1;i<result.length;i++)length+=metres(result[i-1],result[i]);
  if(result.length<2 || Math.abs(length-expected)>Math.max(800,expected*.18))throw Error("轨道长度与排图里程不符。");
  if(namedLength<Math.min(length*.35,400))throw Error("此区段缺少可核实的命名轨道。");
  return result;
}

export function matchCache(db,decode,plan,scheduledStops) {
  if (!Array.isArray(plan?.nodes) || plan.nodes.length<2 || plan.nodes.length>1500 ||
      !plan.nodes.every((n,i)=>typeof n?.station==="string" && n.station.trim() && Number.isFinite(n.kilometre) &&
          n.kilometre>=0 && (!i || n.kilometre>=plan.nodes[i-1].kilometre)) ||
      !Array.isArray(plan.edges) || plan.edges.length!==plan.nodes.length-1 ||
      !plan.edges.every(e=>typeof e?.lineName==="string" && e.lineName.trim()) ||
      !Array.isArray(scheduledStops) || !Array.isArray(plan.stopIndices) || plan.stopIndices.length!==scheduledStops.length ||
      plan.stopIndices[0]!==0 || plan.stopIndices.at(-1)!==plan.nodes.length-1 ||
      !plan.stopIndices.every((n,i)=>Number.isInteger(n) && (!i || n>plan.stopIndices[i-1]) &&
          plan.nodes[n]?.station===scheduledStops[i])) throw Error("径路站序或里程与所选车次不符。");
  const until=performance.now()+22000;
  function checkTime(){if(performance.now()>until)throw Error("匹配超过 22 秒，可先选择较短乘车区间。");}
  const source="https://openrailwaymap.app",track="railway_line_high,railway_text_km",wanted=new Set(plan.nodes.map(n=>stationKey(n.station)));
  const located=new Map(), ambiguous=new Set();
  db.exec({sql:`SELECT z,x,y,data FROM tiles WHERE source=? AND layer LIKE 'standard_railway_text_stations%' AND length(data) BETWEEN 1 AND 12000000 ORDER BY z DESC`,
    bind:[source],rowMode:"array",callback: ([z,x,y,bytes])=>{
      checkTime();
      for(const [key,layer] of Object.entries(decode(bytes).layers)){
        if(!key.startsWith("standard_railway_text_stations"))continue;
        for(let i=0;i<layer.length;i++){
          const f=layer.feature(i),t=f.properties;
          if(f.type!==1 || ["subway","tram","light_rail"].includes(t.station) || (t.state && t.state!=="present"))continue;
          for(const label of [t.name,t["name:zh"],t.localized_name]){
            if(typeof label!=="string")continue;
            const key=stationKey(label);
            if(!wanted.has(key))continue;
            const point=f.toGeoJSON(x,y,z).geometry.coordinates;
            if(!point.every(Number.isFinite))continue;
            if(!located.has(key))located.set(key,point);
            else if(metres(point,located.get(key))>2000)ambiguous.add(key);
          }
        }
      }
    }});
  const at=plan.nodes.map(n=>!ambiguous.has(stationKey(n.station)) && located.get(stationKey(n.station)));
  const stops=new Set(plan.stopIndices), anchors=[];
  const missing=plan.nodes.filter((n,i)=>!at[i] && (stops.has(i) || (i>0 && i<plan.edges.length && plan.edges[i].lineName!==plan.edges[i-1].lineName)));
  if(missing.length)throw Error("瓦片库缺少车站或换线点坐标："+missing.slice(0,8).map(n=>n.station).join("、"));
  at.forEach((point,i)=>{if(point)anchors.push(i);});
  const zooms=db.selectValues("SELECT DISTINCT z FROM tiles WHERE source=? AND layer=? AND z BETWEEN 7 AND 16",[source,track]).sort((a,b)=>Math.abs(a-10)-Math.abs(b-10));
  const legs=[]; let leg=[];
  for(let k=1;k<anchors.length;k++){
    const a=anchors[k-1],b=anchors[k],from=at[a],to=at[b],name=plan.edges[a].lineName;
    const margin=.12,west=Math.min(from[0],to[0])-margin,east=Math.max(from[0],to[0])+margin;
    const south=Math.min(from[1],to[1])-margin,north=Math.max(from[1],to[1])+margin;
    let segment, message="缺少命名轨道";
    for(const z of zooms){
      checkTime();
      const [x0,y0]=tileXY([west,north],z),[x1,y1]=tileXY([east,south],z);
      if((x1-x0+1)*(y1-y0+1)>100)continue;
      const ways=[];
      db.exec({sql:"SELECT x,y,data FROM tiles WHERE source=? AND layer=? AND z=? AND x BETWEEN ? AND ? AND y BETWEEN ? AND ? AND length(data) BETWEEN 1 AND 12000000",
        bind:[source,track,z,x0,x1,y0,y1],rowMode:"array",callback:([x,y,data])=>{
          checkTime();
          const layer=decode(data).layers.railway_line_high;
          for(let i=0;i<(layer?.length||0);i++){
            const f=layer.feature(i),t=f.properties;
            if(f.type!==2 || t.feature!=="rail" || t.state && t.state!=="present" || ["spur","yard","siding"].includes(t.service))continue;
            const names=[t.name,t["name:zh"],t.alt_name].filter(n=>typeof n==="string" && n);
            const named=names.some(n=>lineKey(n)===lineKey(name) &&
              (/高速|高铁|客专/.test(name)===!!(/高速|高铁|客专/.test(n)||t.highspeed===true)));
            if(names.length && !named)continue;
            const geom=f.toGeoJSON(x,y,z).geometry;
            for(const part of geom.type==="LineString"?[geom.coordinates]:geom.coordinates){
              if(!part.length || !part.some(([lon,lat])=>lon>=west && lon<=east && lat>=south && lat<=north))continue;
              if(!named && (t.ref || !part.every(p=>Math.min(metres(p,from),metres(p,to))<1200)))continue;
              ways.push({way:part,named});
            }
          }
        }});
      if(!ways.length)continue;
      try{segment=sectionPath(ways,from,to,(plan.nodes[b].kilometre-plan.nodes[a].kilometre)*1000,checkTime);break;}
      catch(error){message=error.message;}
    }
    if(!segment)throw Error(`${plan.nodes[a].station} → ${plan.nodes[b].station}：${message}`);
    if(leg.length && metres(leg.at(-1),segment[0])>120)throw Error("相邻轨道区段未衔接。");
    for(const point of segment)leg.push(point);
    if(stops.has(b)){legs.push(leg);leg=[];}
  }
  if(legs.length!==plan.stopIndices.length-1)throw Error("经停区间未匹配齐全。");
  return legs;
}
