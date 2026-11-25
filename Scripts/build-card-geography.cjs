// Natural Earth v5.1.2, WGS84. Pass populated places, coastline and an output
// path for the public resource, or --label-input, admin-1 polygons and an
// output path for the private build-card-contours.py label-placement input.
const fs = require("node:fs");
const [first, second, output] = process.argv.slice(2);
const features = file => JSON.parse(fs.readFileSync(file)).features;
const region = new Set(["CHN","TWN","HKG","MAC"]);
const round = n => Math.round(n*1000)/1000;
function simplify(points, tolerance = .012) {
  const result = [points[0]];
  function split(a,b) {
    const [x,y]=points[a], dx=points[b][0]-x, dy=points[b][1]-y, length=dx*dx+dy*dy;
    let far=0, at=a;
    for (let i=a+1;i<b;i++) {
      const u=points[i][0]-x,v=points[i][1]-y;
      const t=length ? Math.max(0,Math.min(1,(u*dx+v*dy)/length)) : 0;
      const d=(u-t*dx)**2+(v-t*dy)**2;
      if (d>far) {far=d;at=i;}
    }
    if (far>tolerance*tolerance) {split(a,at);split(at,b);}
    else result.push(points[b]);
  }
  split(0,points.length-1);
  return result.map(([lon,lat])=>[round(lat),round(lon)]);
}
function places(cityFile) {
  return features(cityFile).filter(f=>region.has(f.properties.ADM0_A3)).map(f=>{
  const p=f.properties,[lon,lat]=f.geometry.coordinates;
  return {name:p.NAME_ZH || p.NAME,lat:round(lat),lon:round(lon),rank:p.SCALERANK,pop:p.POP_MAX};
  }).sort((a,b)=>a.rank-b.rank || b.pop-a.pop || a.name.localeCompare(b.name,"zh"));
}
function coastlines(coastFile) {
  const coasts=[];
  for (const f of features(coastFile)) {
  for(const line of (f.geometry.type==="MultiLineString" ? f.geometry.coordinates : [f.geometry.coordinates])) {
    let part=[];
    const finish=()=>{if(part.length>1) coasts.push(simplify(part));part=[];};
    for(const p of line) {
      if(p[0]<103 || p[0]>135 || p[1]<17 || p[1]>45) finish();
      else part.push(p);
    }
    finish();
  }
  }
  return coasts;
}
function contains(rings, lat, lon) {
  let inside=false;
  for(const ring of rings) for(let i=1;i<ring.length;i++) {
    const [a,b]=ring[i-1], [c,d]=ring[i];
    if((a>lat)!==(c>lat) && lon<b+(d-b)*(lat-a)/(c-a)) inside=!inside;
  }
  return inside;
}
function labelInput(provinceFile) {
  const provinces=features(provinceFile).filter(f=>f.properties.adm0_a3==="CHN").map(({properties:p,geometry})=>{
  const polygons=geometry.type==="MultiPolygon" ? geometry.coordinates : [geometry.coordinates];
  const rings=polygons.flatMap(polygon=>polygon.map(r=>simplify(r,.032))).filter(r=>r.length>=4);
  const lat=round(p.latitude),lon=round(p.longitude),anchors=[];
  // Alternative label positions are accepted only inside the administrative area.
  for(const radius of [.4,.85,1.45,2.1,2.8]) for(let i=0;i<24;i++) {
    const a=round(lat+radius*Math.sin(i*Math.PI/12)), b=round(lon+radius*Math.cos(i*Math.PI/12));
    if(contains(rings,a,b)) anchors.push([a,b]);
  }
  const pts=rings.flat(),ys=pts.map(q=>q[0]),xs=pts.map(q=>q[1]);
  return {name:p.name_zh,lat,lon,anchors,rings,bounds:[Math.min(...ys),Math.min(...xs),Math.max(...ys),Math.max(...xs)]};
  });
  return {provinces};
}
function coastalContext(cityFile,coastFile) {
  const coastLines=[], hainan=[];
  for (const line of coastlines(coastFile)) {
    const isHainan=line.length>20 && line.every(([lat,lon])=>lat>=18 && lat<=20.4 && lon>=108.4 && lon<=111.3);
    for (let i=0;i<line.length-1;i+=80) {
      const points=line.slice(i,i+81);
      const lat=points.map(p=>p[0]),lon=points.map(p=>p[1]);
      (isHainan?hainan:coastLines).push({bounds:[Math.min(...lat),Math.min(...lon),Math.max(...lat),Math.max(...lon)],points});
    }
  }
  return {source:"Natural Earth v5.1.2 · public domain",cities:places(cityFile),coastLines,hainan};
}
const result=first==="--label-input" ? labelInput(second) : coastalContext(first,second);
fs.writeFileSync(output,JSON.stringify(result));
console.log(`${output}: ${Object.keys(result).join(", ")}`);
