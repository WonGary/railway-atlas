// Shared by the browser and the native player's isolated JavaScriptCore context.
const JourneyGuideCore = (() => {
  "use strict";
  const labels = {station:"铁路车站", hub:"铁路交汇站", city:"城市", metro:"城轨站", landmark:"桥隧", history:"建设记录"};
  const corridor = {station:1800, hub:1800, city:8000, metro:1800, landmark:1000, history:1200};
  const gtfs = "https://github.com/wensimehrp/chinese-railway-gtfs";
  const earth = 111195, cell = 0.1, radius = 12000;
  const wrap = lon => ((lon + 540) % 360) - 180;
  const valid = p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) &&
    Math.abs(p[0]) <= 90 && Math.abs(p[1]) <= 180;
  const scale = lat => Math.max(.01, Math.cos(lat * Math.PI / 180));
  function offset(point, origin) {
    return [wrap(point[1] - origin[1]) * earth * scale(origin[0]), (point[0] - origin[0]) * earth];
  }
  function segmentDistance(p, a, b) {
    const [x,y] = offset(a,p), [x1,y1] = offset(b,p);
    const dx = x1-x, dy = y1-y, denom = dx*dx+dy*dy;
    const t = denom ? Math.max(0, Math.min(1, -(x*dx+y*dy)/denom)) : 0;
    return Math.hypot(x+t*dx, y+t*dy);
  }
  // Search the current leg and its neighbours. A missing leg has no corridor.
  class Places {
    constructor(pack, directory, catalog) {
      if (pack.version !== 1) throw Error("沿线地点资料版本不受支持");
      this.cells = new Map();
      for (const [kind,name,y,x,ref,note,evidence] of pack.rows) {
        const osm = /^(way|node|relation)\/\d+$/.test(ref);
        this.add({id:`${kind}/${ref}`, kind,name, lat:y/1e5, lon:x/1e5, note,
          source:kind==="city"?"Natural Earth · 公有领域":"© OpenStreetMap contributors · ODbL",
          url:evidence || (osm ? "https://www.openstreetmap.org/"+ref : "https://www.naturalearthdata.com/")});
      }
      directory.names.forEach((name,i) => {
        const p = directory.coordinates[i];
        if (!valid(p) || (!p[0] && !p[1])) return;
        const lines = [...new Set((catalog.lines.get(name)||[]).map(l=>l.title))];
        this.add({id:`rail/${name}`, kind:lines.length>=2?"hub":"station", name, lat:p[0],lon:p[1],
          note:lines.join("、"), source:"中国铁路 GTFS · Jeremy Gao / OpenStreetMap", url:gtfs});
      });
    }
    add(place) {
      const key = `${Math.floor(place.lat/cell)},${Math.floor(wrap(place.lon)/cell)}`;
      if (!this.cells.has(key)) this.cells.set(key,[]);
      this.cells.get(key).push(place);
    }
    nearby(legs, leg, position, kinds) {
      if (!valid(position) || !legs[leg]?.length || !kinds.length) return [];
      const [lat,lon] = position, dy = radius/earth, dx = dy/scale(lat);
      const edges = [];
      for (const path of legs.slice(Math.max(0,leg-1),leg+2)) {
        for (let i=1;i<path.length;i++) {
          const a=path[i-1], b=path[i];
          if (valid(a) && valid(b) && segmentDistance(position,a,b) <= radius + 8000) edges.push([a,b]);
        }
      }
      const rows = [];
      for (let y=Math.floor((lat-dy)/cell);y<=Math.floor((lat+dy)/cell);y++) {
        for (let x=Math.floor((lon-dx)/cell);x<=Math.floor((lon+dx)/cell);x++) {
          const ix=((x+1800)%3600+3600)%3600-1800;
          for (const place of this.cells.get(`${y},${ix}`)||[]) {
            if (!kinds.includes(place.kind)) continue;
            const p=[place.lat,place.lon], metres=Math.hypot(...offset(p,position));
            if (metres>radius) continue;
            let track=Infinity;
            for (const [a,b] of edges) track=Math.min(track,segmentDistance(p,a,b));
            if (track<=corridor[place.kind]) rows.push({...place, metres:Math.round(metres), track:Math.round(track)});
          }
        }
      }
      // Parallel OSM tracks and platforms can carry the same name. Keep the nearest.
      const seen = new Set(), counts = {};
      return rows.sort((a,b)=>a.metres-b.metres || a.id.localeCompare(b.id)).filter(p=>{
        const key=[p.kind,p.name,p.note].join("|");
        if (seen.has(key) || (counts[p.kind]||0)>=4) return false;
        seen.add(key); counts[p.kind]=(counts[p.kind]||0)+1; return true;
      });
    }
  }
  const dayMinute = date => Date.parse(date+"T00:00:00Z")/60000;
  const minute = n => Number.isInteger(n) && n >= 0;
  const clock = n => `${String(Math.floor(n/60)%24).padStart(2,"0")}:${String(n%60).padStart(2,"0")}`;
  const dateAt = absolute => new Date(absolute*60000).toISOString().slice(0,10);
  function arrival(route, index, seconds) {
    const s=route?.stops[index];
    if (!Number.isInteger(index) || index <= 0 || !s || !minute(s.arrival) || !Number.isFinite(seconds)) return null;
    // The rider may still be at the platform after the scheduled arrival.
    if (index < route.stops.length-1 && (!minute(s.departure) || seconds>s.departure*60)) return null;
    const base=dayMinute(route.serviceDate), eta=base+s.arrival;
    const at=base+Math.max(s.arrival,Math.ceil(seconds/60));
    return Number.isFinite(at) ? {station:s.name??s.station, eta, at, index} : null;
  }
  function transfers(arr, active, board, hours=24) {
    if (!arr || ![6,24].includes(hours)) return [];
    const last=arr.at+hours*60, found=new Map();
    const activeNumbers = new Set(active.numbers || [active.train]);
    const firstDay=Math.floor(arr.at/1440), lastDay=Math.floor(last/1440);
    for (let day=firstDay;day<=lastDay;day++) {
      for (const item of board(arr.station,dateAt(day*1440))) {
        if (item.pass || !minute(item.dep)) continue;
        const absolute=dayMinute(item.origin)+item.dep;
        if (!Number.isFinite(absolute) || absolute<arr.at || absolute>last) continue;
        const detail=item.detail(), origin=item.origin;
        const sameNumber=(detail.number || "").split("/").some(n=>activeNumbers.has(n));
        if (active.origin===origin) {
          if (active.trip===detail.id) continue;
          // A local library and the national board may describe one service
          // with different IDs. Compare the ridden section's calls and times.
          if (sameNumber && (!active.trip || (item.source==="local") !== (active.source==="local"))) {
            const calls=active.stops || [];
            const shift=dayMinute(active.tableDate || origin)-dayMinute(origin);
            if (!calls.length || detail.stops.some((s,start)=>s[0]===(calls[0].name??calls[0].station) &&
                calls.every((call,i)=>{
                  const stop=detail.stops[start+i];
                  return stop?.[0]===(call.name??call.station) &&
                    (!i || call.arrival==null || stop[1]===call.arrival+shift) &&
                    (i===calls.length-1 || call.departure==null || stop[2]===call.departure+shift);
                }))) continue;
          }
        }
        const stops=detail.stops;
        for (let i=0;i<stops.length-1;i++) {
          if (stops[i][0]!==arr.station || stops[i][2]!==item.dep) continue;
          const id=JSON.stringify([detail.id,origin,i]);
          if (found.has(id)) continue;
          const destinations=stops.slice(i+1).flatMap(([name,arrival],j)=>
            minute(arrival)&&arrival>item.dep ? [{name,index:i+j+1,arrival}] : []);
          if (destinations.length) found.set(id,{id,train:detail.number,trip:detail.id,origin,
            boardIndex:i,departure:item.dep,boardDate:dateAt(absolute),wait:absolute-arr.eta,absolute,
            destinations, source:item.source || "national"});
        }
      }
    }
    return [...found.values()].sort((a,b)=>a.absolute-b.absolute || a.id.localeCompare(b.id));
  }
  return {Places,labels,arrival,transfers,clock,dateAt,dayMinute};
})();
if (typeof module==="object" && module.exports) module.exports=JourneyGuideCore;
