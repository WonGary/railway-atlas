const CardMap = (() => {
  let geography, contours, pending, restoring, database;
  const edition="tdt-2026-10-route-1";
  const contourBytes=1368598;
  const contourHash="bc57f2b0b12869061a936ddac2167d32c661807bd4d1b44e8923dea40a0ce6be";
  async function readContours(buffer) {
    if (!globalThis.crypto?.subtle) throw Error("请在 HTTPS 网站或本机 localhost 打开后再导入。");
    const digest=await crypto.subtle.digest("SHA-256",buffer);
    const hex=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,"0")).join("");
    if(hex!==contourHash) throw Error("文件校验未通过，请选择 0.8.11 版的 card-contours.json。");
    const data=JSON.parse(new TextDecoder().decode(buffer));
    if(data.edition!==edition) throw Error("区划轮廓版本不匹配。");
    return data;
  }
  function storage() {
    if(!database) database=new Promise((resolve,reject)=>{
      const request=indexedDB.open("railway-atlas-card-context",1);
      request.onupgradeneeded=()=>request.result.createObjectStore("outlines");
      request.onsuccess=()=>resolve(request.result);
      request.onerror=()=>reject(request.error);
    }).catch(error=>{database=null;throw error;});
    return database;
  }
  function restore() {
    return restoring ||= (async()=>{
      const db=await storage();
      const buffer=await new Promise((resolve,reject)=>{
        const request=db.transaction("outlines").objectStore("outlines").get(edition);
        request.onsuccess=()=>resolve(request.result);
        request.onerror=()=>reject(request.error);
      });
      if(buffer?.byteLength===contourBytes) contours ||= await readContours(buffer);
    })().catch(()=>{}); // A new or storage-restricted browser can still draw the physical map.
  }
  async function install(file) {
    if(file.size!==contourBytes) throw Error("文件大小不符，请选择 0.8.11 版的 card-contours.json。");
    const buffer=await file.arrayBuffer();
    const next=await readContours(buffer);
    let saved=true;
    try {
      const db=await storage();
      await new Promise((resolve,reject)=>{
        const tx=db.transaction("outlines","readwrite");
        tx.oncomplete=resolve;
        tx.onabort=tx.onerror=()=>reject(tx.error);
        tx.objectStore("outlines").put(buffer,edition);
      });
    } catch { saved=false; }
    contours=next;
    return saved;
  }
  function load() {
    pending ||= loadJSON("./station-directory/card-geography.json").then(base=>geography=base)
      .catch(error=>{pending=null;throw error;});
    return Promise.all([pending,restore()]).then(([base])=>base);
  }
  function inside(region,lat,lon) {
    const [south,west,north,east]=region.bounds;
    if(lat<south || lat>north || lon<west || lon>east) return false;
    let hit=false;
    for(const ring of region.rings) for(let i=1;i<ring.length;i++) {
      const [a,b]=ring[i-1],[c,d]=ring[i];
      if((a>lat)!==(c>lat) && lon<b+(d-b)*(lat-a)/(c-a)) hit=!hit;
    }
    return hit;
  }
  function draw(ctx,route,rect,ink,paper,weight) {
    const legs=route?.legs.filter(p=>p.length>=2);
    if(!legs?.length) return;
    const points=legs.flat(), [x,y,w,h]=rect;
    const mini=h<82 || w<180, font=mini?8:Math.min(12,Math.max(10,h/16));
    const lat=points.map(p=>p[0]),lon=points.map(p=>p[1]);
    const extent=values=>values.reduce(([low,high],v)=>[Math.min(low,v),Math.max(high,v)],[Infinity,-Infinity]);
    const [s,n]=extent(lat),[west,e]=extent(lon), midLat=(s+n)/2,midLon=(west+e)/2;
    const cos=Math.max(.1,Math.cos(midLat*Math.PI/180));
    const scale=Math.min((w-(mini?18:54))/Math.max(.012,(e-west)*cos),(h-(mini?13:34))/Math.max(.012,n-s));
    const project=([a,b])=>[x+w/2+(b-midLon)*cos*scale,y+h/2-(a-midLat)*scale];
    const xy=legs.map(leg=>leg.map(project));
    const viewport=[midLat-h/(2*scale),midLon-w/(2*scale*cos),midLat+h/(2*scale),midLon+w/(2*scale*cos)];
    const visible=parts=>parts.filter(({bounds:[s,w,n,e]})=>s<=viewport[2] && n>=viewport[0] && w<=viewport[3] && e>=viewport[1])
      .map(({points})=>points.map(project));
    function stroke(lines,colour,width,alpha=1,dash=[]) {
      ctx.beginPath();ctx.setLineDash(dash); ctx.globalAlpha=alpha;ctx.strokeStyle=colour;ctx.lineWidth=width;
      for(const part of lines) part.forEach(([a,b],i)=>i?ctx.lineTo(a,b):ctx.moveTo(a,b));
      ctx.stroke();ctx.setLineDash([]);ctx.globalAlpha=1;
    }
    ctx.save();ctx.beginPath();ctx.rect(x,y,w,h);ctx.clip();ctx.lineJoin=ctx.lineCap="round";
    const shore=contours || geography;
    if(shore) {
      stroke(visible(shore.coastLines),ink,mini?.65:.9,.46);
      // Draw the part of the Hainan shoreline in the journey's latitude band.
      // On a Beijing–Sanya trip the train, its terminus and the ferry stay in
      // frame while the southern tip beyond the terminus is outside the band.
      const top=project([n+.018,midLon])[1],bottom=project([s-.018,midLon])[1];
      ctx.save();
      if(viewport[0]<=18.163 && viewport[2]>=20.16 && viewport[1]<=108.615 && viewport[3]>=111.03) {
        ctx.beginPath();ctx.rect(x,top,w,bottom-top);ctx.clip();
      }
      stroke(visible(shore.hainan),ink,mini?.65:.9,.58);ctx.restore();
    }
    if(contours) {
      stroke(visible(contours.provinceLines),ink,mini?.65:.9,.41,mini?[2,2]:[3,3]);
      const country=mini?1.05:1.45;
      stroke(visible(contours.settled),ink,country,.82,mini?[5,2,1,2]:[7,2,1.2,2]);
      stroke(visible(contours.undelimited),ink,country,.82,mini?[4,3]:[6,4]);
    }
    stroke(xy,paper,weight+1.9,.86);
    stroke(xy,ink,weight);
    const occupied=[], labels=[];
    ctx.font=`${mini?600:550} ${font}px "PingFang SC","Microsoft YaHei",sans-serif`;
    ctx.textAlign="left";ctx.textBaseline="middle";
    const first=xy[0][0],last=xy.at(-1).at(-1);
    function dot(p,r,fill) {
      ctx.fillStyle=fill;ctx.strokeStyle=ink;ctx.lineWidth=mini?1:1.5;
      ctx.beginPath();ctx.arc(...p,r,0,2*Math.PI);ctx.fill();ctx.stroke();
    }
    function label(text,p,endpoint=false) {
      if(!text || labels.includes(text)) return false;
      const width=ctx.measureText(text).width,hh=font/2+1;
      for(const [dx,dy] of [[6,0],[-width-6,0],[4,-font-1],[-width-4,font],[4,font+1],[-width-4,-font]]) {
        const a=Math.max(x+2,Math.min(x+w-width-2,p[0]+dx)), b=Math.max(y+hh+1,Math.min(y+h-hh-1,p[1]+dy));
        const box=[a-2,b-hh,a+width+2,b+hh];
        if(occupied.some(o=>box[0]<o[2] && box[2]>o[0] && box[1]<o[3] && box[3]>o[1]))continue;
        occupied.push(box);labels.push(text);
        ctx.lineWidth=2.8;ctx.strokeStyle=paper;ctx.strokeText(text,a,b);
        ctx.fillStyle=ink;ctx.fillText(text,a,b);
        if(!endpoint) dot(p,mini?1.1:1.75,paper);
        return true;
      }
      return false;
    }
    dot(first,mini?2.3:3.6,paper);dot(last,mini?2.3:3.6,ink);
    const from=route.stops[0].name,to=route.stops.at(-1).name;
    label(from,first,true);label(to,last,true);
    if(!mini && Math.max(n-s,(e-west)*cos)<.85) {
      for(let i=1;i<route.stops.length-1 && labels.length<8;i++) {
        const at=route.legs[i]?.[0];
        if(at && label(route.stops[i].name,project(at),true)) dot(project(at),2.5,paper);
      }
    }
    const near=(p,a,b)=>{
      const dx=b[0]-a[0],dy=b[1]-a[1],t=Math.max(0,Math.min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/(dx*dx+dy*dy||1)));
      return Math.hypot(p[0]-a[0]-t*dx,p[1]-a[1]-t*dy);
    };
    let placeCount=labels.length;
    if(!mini && geography) {
      ctx.font=`500 ${font+1}px "Songti SC",serif`;
      const step=Math.max(1,Math.ceil(points.length/40));
      const samples=points.filter((_,i)=>i%step===0 || i===points.length-1);
      for(const province of contours?.provinces || []) {
        const within=samples.filter(([lat,lon])=>inside(province,lat,lon));
        if(!within.length) continue;
        const anchors=[[province.lat,province.lon],...province.anchors];
        const width=ctx.measureText(province.name).width;
        // When zoomed to a single city, a province's usual label may be off-screen.
        const [a,b]=within[Math.floor(within.length/2)];
        for(const [dx,dy] of [[-1,1],[1,1],[-1,-1],[1,-1],[0,1],[0,-1]]) {
          const anchor=[a+dy*(font+12)/scale,b+dx*(width/2+16)/(scale*cos)];
          if(inside(province,...anchor)) anchors.push(anchor);
        }
        for(const anchor of anchors) {
          const p=project(anchor),box=[p[0]-width/2-4,p[1]-font,p[0]+width/2+4,p[1]+font];
          if(box[0]<x+3 || box[1]<y+3 || box[2]>x+w-3 || box[3]>y+h-3 ||
            occupied.some(o=>box[0]<o[2] && box[2]>o[0] && box[1]<o[3] && box[3]>o[1]) ||
            xy.some(line=>line.some((q,i)=>i && near(p,line[i-1],q)<font+3))) continue;
          occupied.push(box);labels.push(province.name);
          ctx.globalAlpha=.77;ctx.fillStyle=ink;ctx.fillText(province.name,p[0]-width/2,p[1]);break;
        }
      }
    }
    const range=Math.min(mini?10:28,Math.max(6,scale*.55));
    ctx.globalAlpha=1;ctx.font=`${mini?600:550} ${font}px "PingFang SC","Microsoft YaHei",sans-serif`;
    for(const city of geography?.cities || []) {
      if(placeCount>=(mini?3:Math.min(10,Math.max(4,Math.round(w*h/6500)))))break;
      const p=project([city.lat,city.lon]);
      if(p[0]<x+3||p[0]>x+w-3||p[1]<y+3||p[1]>y+h-3)continue;
      const name=city.name.replace(/市$/,"");
      if([from,to].some(n=>n.startsWith(name) && Math.min(Math.hypot(first[0]-p[0],first[1]-p[1]),Math.hypot(last[0]-p[0],last[1]-p[1]))<18))continue;
      if(xy.some(line=>line.some((q,i)=>i && near(p,line[i-1],q)<=range)) && label(name,p))placeCount++;
    }
    ctx.restore();
    return labels;
  }
  return {load,draw,install,restore,get hasContours(){return Boolean(contours);}};
})();
