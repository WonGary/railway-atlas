// Compare only adjacent levels of detail. Coordinates are WGS84 [latitude, longitude].
// Two tracks from the same source (including opposite directions) never mask each other.
const MetroHandoff = (() => {
  const metres = 111320, tolerance = 60, cell = 0.02;
  const bounds = (a,b) => [Math.min(a[0],b[0]),Math.min(a[1],b[1]),Math.max(a[0],b[0]),Math.max(a[1],b[1])];
  const intersects = (a,b) => a[0]<=b[2] && a[2]>=b[0] && a[1]<=b[3] && a[3]>=b[1];
  function cells(box, visit) {
    const [s,w,n,e] = box.map(v=>Math.floor(v/cell));
    if ((n-s+1)*(e-w+1)>1024) return false;
    for (let y=s;y<=n;y++) for (let x=w;x<=e;x++) visit(`${y}/${x}`);
    return true;
  }
  class Tracks {
    constructor() { this.grid=new Map(); this.long=[]; this.all=[]; this.bounds=null; }
    add(parts, identity) {
      for (const part of parts) for (let i=1;i<part.length;i++) {
        const a=part[i-1], b=part[i], box=bounds(a,b), segment={a,b,box,identity};
        if (!this.bounds) this.bounds=box.slice();
        else for (let k=0;k<4;k++) this.bounds[k]=(k<2?Math.min:Math.max)(this.bounds[k],box[k]);
        this.all.push(segment);
        if (!cells(box,key=>{
          if (!this.grid.has(key)) this.grid.set(key,[]);
          this.grid.get(key).push(segment);
        })) this.long.push(segment);
      }
    }
    query(box, found) {
      if (!this.bounds || !intersects(this.bounds,box)) return;
      const add=s=>{ if (intersects(s.box,box)) found.add(s); };
      if (cells(box,key=>this.grid.get(key)?.forEach(add))) this.long.forEach(add);
      else this.all.forEach(add);
    }
  }
  function identity(facts, ids=[]) { return {network:facts.network,category:facts.category,ids}; }
  function matches(a,b) {
    if (a.category!==b.category) return false;
    if (a.ids.length && b.ids.length) return a.ids.some(id=>b.ids.includes(id));
    return a.network===b.network;
  }
  function remaining(parts, owner, indexes) {
    if (!indexes.some(index=>index.bounds)) return parts;
    const result=[];
    let changed=false;
    for (const part of parts) {
      let kept=[];
      const finish=()=>{ if (kept.length>1) result.push(kept); kept=[]; };
      for (let i=1;i<part.length;i++) {
        const a=part[i-1], b=part[i], scale=metres*Math.cos((a[0]+b[0])*Math.PI/360);
        const x=(b[1]-a[1])*scale, y=(b[0]-a[0])*metres, length=Math.hypot(x,y);
        if (!length) continue;
        const ux=x/length, uy=y/length, box=bounds(a,b), dy=tolerance/metres, dx=tolerance/scale;
        const query=[box[0]-dy,box[1]-dx,box[2]+dy,box[3]+dx], candidates=new Set(), spans=[];
        for (const index of indexes) index.query(query,candidates);
        for (const s of candidates) {
          if (!matches(owner,s.identity)) continue;
          const ax=(s.a[1]-a[1])*scale, ay=(s.a[0]-a[0])*metres;
          const vx=(s.b[1]-s.a[1])*scale, vy=(s.b[0]-s.a[0])*metres;
          const start=ax*ux+ay*uy, along=vx*ux+vy*uy;
          // An anonymous crossing is not evidence of the same track.
          if (Math.abs(along)<=Math.hypot(vx,vy)*(owner.ids.length && s.identity.ids.length ? .45 : .90)) continue;
          const cross=ay*ux-ax*uy, slope=vy*ux-vx*uy;
          let lo=0, hi=1;
          if (Math.abs(slope)<1e-8) { if (Math.abs(cross)>tolerance) continue; }
          else {
            const first=(-tolerance-cross)/slope, last=(tolerance-cross)/slope;
            lo=Math.max(0,Math.min(first,last)); hi=Math.min(1,Math.max(first,last));
            if (lo>hi) continue;
          }
          const p=start+lo*along, q=start+hi*along;
          const left=Math.max(0,Math.min(p,q)), right=Math.min(length,Math.max(p,q));
          if (right>left) spans.push([left,right]);
        }
        const at=d=>d<=0?a:d>=length?b:[a[0]+(b[0]-a[0])*d/length,a[1]+(b[1]-a[1])*d/length];
        const keep=(l,r)=>{ if (!kept.length) kept.push(at(l)); kept.push(at(r)); };
        let cursor=0;
        for (const [left,right] of spans.sort((u,v)=>u[0]-v[0])) {
          if (right<=cursor) continue;
          changed=true;
          if (left>cursor+.05) keep(cursor,left);
          finish(); cursor=right;
        }
        if (!cursor || length-cursor>.05) keep(cursor,length);
      }
      finish();
    }
    return changed?result:parts;
  }
  return {Tracks,identity,remaining};
})();
