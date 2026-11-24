// Shared by the Pages map and the local macOS inspector. Minutes are measured from origin midnight.
const StationCatalog = (() => {
  const add = (map, key, value) => {
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(value);
  };
  function day(date, offset) {
    const time = Date.parse(`${date}T12:00:00Z`);
    return Number.isFinite(time) ? new Date(time + offset * 86400000).toISOString().slice(0,10) : "";
  }
  function onDay(date, a, b, runs) {
    if (a == null) a = b;
    if (b == null) b = a;
    if (a == null || b == null) return [];
    const origins = [];
    for (let offset=Math.floor(a/1440); offset<=Math.floor(b/1440); offset++) {
      const origin = day(date, -offset);
      if (runs(origin)) origins.push(origin);
    }
    return origins;
  }
  function national(data) {
    const calls = new Map(), lines = new Map(), stations = new Set(data.names);
    const calendars = data.calendars.map(dates=>new Set(dates));
    const allDates = data.calendars.flat().sort();
    for (const [title, stops] of data.lines) {
      for (const name of new Set(stops.map(s=>s[0]))) {
        stations.add(name);
        add(lines, name, {title,stops});
      }
    }
    for (const train of data.trains) {
      train[2].forEach(([id], i) => add(calls, data.names[id], {train,i}));
    }
    const unpack = ([number, , stops, id]) => ({number,id,
      stops:stops.map(([code,arr,dep],i)=>[data.names[code], i ? arr : null, i+1<stops.length ? dep : null])});
    function board(name, date) {
      const items = [];
      for (const {train,i} of calls.get(name) || []) {
        const stops=train[2], [,arr,dep]=stops[i];
        const dates=calendars[train[1]];
        if (!dates) continue;
        for (const origin of onDay(date,arr,dep,d=>dates.has(d.replaceAll("-","")))) {
          items.push({number:train[0],from:data.names[stops[0][0]],to:data.names[stops.at(-1)[0]],
            arr:i ? arr : null, dep:i+1<stops.length ? dep : null, origin, detail:()=>unpack(train)});
        }
      }
      return items;
    }
    return {stations, lines, board, edition:data.edition, range:[allDates[0],allDates.at(-1)]};
  }
  function local(index) {
    const stations = new Set([...index.lines.keys(), ...index.stations.keys()]);
    const lines = new Map([...index.lines].map(([name, rows])=>[name, rows.map(row=>({
      title:row.name, stops:row.stations.map(s=>[s.name,s.kilometre])
    }))]));
    const explicit = new Map();
    for (const row of index.services) {
      for (const name of new Set(row.routing?.nodes?.map(n=>n.station) || [])) {
        add(explicit,name,row); stations.add(name);
      }
    }
    const planFor = row => row.routing || RailLibrary.plan(row,index);
    function detail(row, plan) {
      return {number:row.train, id:row.id, stops:row.stops.map(s=>[s.station,s.arrival,s.departure]),
        plan:plan || planFor(row)};
    }
    function board(name,date) {
      const items=[];
      function append(row,origin,arr,dep,extra={}) {
        items.push({number:row.train, from:row.stops[0].station,to:row.stops.at(-1).station,arr,dep,origin,
          detail:()=>detail(row,extra.plan), ...extra});
      }
      for (const {row,i} of index.stations.get(name) || []) {
        const stop=row.stops[i];
        for (const origin of onDay(date,stop.arrival,stop.departure,d=>RailLibrary.runsOn(row,d))) {
          append(row,origin,stop.arrival,stop.departure);
        }
      }
      const candidates=new Set(explicit.get(name) || []);
      for (const line of index.lines.get(name) || []) {
        for (const train of index.trainsByLine.get(line.id) || []) {
          for (const row of index.servicesByTrain.get(train) || []) candidates.add(row);
        }
      }
      for (const row of candidates) {
        const last=row.stops.at(-1);
        if (!onDay(date,0,last.arrival ?? last.departure,d=>RailLibrary.runsOn(row,d)).length) continue;
        const plan=planFor(row);
        if (!plan?.stopIndices || !plan?.nodes) continue;
        for (let i=1;i<plan.stopIndices.length;i++) {
          const segment=plan.nodes.slice(plan.stopIndices[i-1]+1,plan.stopIndices[i]);
          if (!segment.some(node=>node.station===name)) continue;
          const before=row.stops[i-1].departure, after=row.stops[i].arrival;
          for (const origin of onDay(date,before,after,d=>RailLibrary.runsOn(row,d))) {
            append(row,origin,null,null,{pass:true,possible:Math.floor(before/1440)!==Math.floor(after/1440),plan});
          }
        }
      }
      return items;
    }
    return {stations,lines,board,edition:index.edition};
  }
  function resolve(name, catalog) {
    const base=name.trim().replace(/\s+(?:Railway Station|Railway|Station|Hong Kong.*)$/i,"");
    for (const candidate of [base,base.replace(/站$/,""),base.replace(/线路所$/,"所"),base.replace(/所$/,"线路所")]) {
      if (catalog.stations.has(candidate)) return candidate;
    }
    return base;
  }
  function clock(minute) {
    if (minute == null) return "—";
    const days = Math.floor(minute/1440);
    return (days ? `+${days}日 ` : "") + `${String(Math.floor(minute/60)%24).padStart(2,"0")}:${String(minute%60).padStart(2,"0")}`;
  }
  return {national,local,resolve,clock,day};
})();
