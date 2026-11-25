// The native library stays in this browser. Only the selected service becomes a map route.
const RailLibrary = (() => {
  let current, database;
  const civil = value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value);

  function index(archive) {
    const native = Array.isArray(archive?.services);
    const services = native ? archive.services : archive?.timetables;
    if (archive?.version !== 1 || !Array.isArray(services) || !services.length || services.length > 100000) {
      throw new Error("请选择原生版的 library.json 或 lulutong.json。");
    }
    const stations = new Map(), lines = new Map(), ids = new Set();
    function add(map, key, value) {
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(value);
    }
    for (const row of services) {
      if (!row || row.id == null || ids.has(row.id) || typeof row.train !== "string" || !Array.isArray(row.stops) ||
          row.stops.length < 2 || row.stops.length > 250 || !row.stops.every(stop => typeof stop?.station === "string" &&
          stop.station && [stop.arrival, stop.departure].some(Number.isFinite)) ||
          !(native ? civil(row.validFrom) && civil(row.validThrough) && row.validFrom <= row.validThrough : civil(row.serviceDate))) {
        throw new Error("时刻库含无效车次，原有资料已保留。");
      }
      ids.add(row.id);
      row.stops.forEach((stop, i) => add(stations, stop.station, { row, i }));
    }
    for (const line of archive.routing?.lines || []) {
      if (typeof line.name !== "string" || !Array.isArray(line.stations) ||
          !line.stations.every(stop => typeof stop?.name === "string" && Number.isFinite(stop.kilometre))) {
        throw new Error("时刻库的线路站序不完整。");
      }
      for (const name of new Set(line.stations.map(stop => stop.name))) add(lines, name, line);
    }
    const trackByID = new Map((archive.routing?.lines || []).map(line => [line.id, line]));
    const routeByTrain = new Map(), trainsByLine = new Map(), servicesByTrain = new Map();
    for (const row of services) {
      for (const name of trainNames(row.train)) add(servicesByTrain, name, row);
    }
    for (const route of archive.routing?.routes || []) {
      if (typeof route.id !== "string" || !Array.isArray(route.parts)) continue;
      const train = route.id.slice(5,10).replace(/^0+/,"");
      add(routeByTrain,train,route);
      for (const id of new Set(route.parts.map(part => part.lineID))) {
        if (!trainsByLine.has(id)) trainsByLine.set(id, new Set());
        trainsByLine.get(id).add(train);
      }
    }
    return { services, stations, lines, trackByID, routeByTrain, trainsByLine, servicesByTrain,
      edition: String(archive.edition || ""), native };
  }
  function storage() {
    if (!database) database = new Promise((resolve, reject) => {
      const request = indexedDB.open("railway-atlas-library", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("library");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    return database;
  }
  async function store(archive) {
    const db = await storage();
    await new Promise((resolve, reject) => {
      const tx = db.transaction("library", "readwrite");
      tx.objectStore("library").put(archive, "active");
      tx.oncomplete = resolve;
      tx.onabort = tx.onerror = () => reject(tx.error);
    });
  }
  async function restore() {
    const db = await storage();
    const archive = await new Promise((resolve, reject) => {
      const request = db.transaction("library").objectStore("library").get("active");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    if (archive && !current) current = index(archive);
  }
  async function install(file) {
    let archive;
    if (!file || /\.apk$/i.test(file.name)) {
      const {localPackage,desktopPackage,readPackage}=await import("./timetable-package.mjs");
      archive=await readPackage(file ? localPackage(file) : await desktopPackage());
    } else {
      if (file.size > 80000000) throw new Error("时刻库上限为 80 MB。");
      archive=JSON.parse(await file.text());
    }
    const next = index(archive);
    await store(archive);
    current = next;
  }
  function runsOn(row, date) {
    return row.serviceDate ? row.serviceDate === date : row.validFrom <= date && date <= row.validThrough;
  }
  function trainNames(name) {
    const [first, ...others] = name.toUpperCase().split("/");
    return [first, ...others.map(value => /^\d+$/.test(value) ? first.slice(0, -value.length) + value : value)];
  }
  function search(query, date) {
    if (!current || !query) return [];
    const key = query.trim().toUpperCase();
    return current.services.filter(row => runsOn(row, date) && trainNames(row.train).some(name => name.includes(key)));
  }
  function timetable(row, date) {
    return { ...row, routing: row.routing || plan(row), id: `library:${row.id}:${date}`, serviceDate: date, source: row.source || {
      title: `本机时刻库 · ${current.edition}`, note: `排图有效期 ${row.validFrom} 至 ${row.validThrough}。${row.flags && (row.flags[2] || row.flags[4] || row.flags[0]>=48) ? "含条件开行标记。" : ""}实际开行请核对 12306。`
    } };
  }
  function plan(row, library = current) {
    if (!library) return null;
    if (row.kilometreMarks?.length !== row.stops.length) return null;
    const matches = [];
    for (const train of trainNames(row.train)) {
      for (const route of library.routeByTrain.get(train) || []) {
        const nodes = [], edges = [];
        for (let i=0; i<route.parts.length; i++) {
          const part = route.parts[i], line = library.trackByID.get(part.lineID);
          const end = route.parts[i+1]?.from || route.end;
          const first = line?.stations.findIndex(s=>s.name === part.from) ?? -1;
          const last = line?.stations.findIndex(s=>s.name === end) ?? -1;
          if (first < 0 || last < 0 || first === last) { nodes.length=0; break; }
          const step = Math.sign(last-first);
          if (!nodes.length) nodes.push({station:part.from,kilometre:0});
          for (let j=first; j!==last; j+=step) {
            const dest = line.stations[j+step];
            const dx = Math.abs(dest.kilometre-line.stations[j].kilometre);
            if (!dx && dest.name === nodes.at(-1).station) continue;
            nodes.push({station:dest.name,kilometre:nodes.at(-1).kilometre+dx});
            edges.push({lineName:line.name});
          }
        }
        if (nodes[0]?.station !== row.stops[0].station || nodes.at(-1)?.station !== row.stops.at(-1).station) continue;
        let cursor=0;
        const stopIndices=[];
        for (const [index,stop] of row.stops.entries()) {
          const km=row.kilometreMarks[index]-row.kilometreMarks[0];
          while (cursor<nodes.length && (nodes[cursor].station!==stop.station || Math.abs(km-nodes[cursor].kilometre)>1)) cursor++;
          if (cursor===nodes.length) break;
          stopIndices.push(cursor++);
        }
        if (stopIndices.length === row.stops.length && stopIndices[0]===0 && stopIndices.at(-1)===nodes.length-1) {
          const match={nodes,edges,stopIndices};
          if (!matches.some(existing=>JSON.stringify(existing)===JSON.stringify(match))) matches.push(match);
        }
      }
    }
    return matches.length===1 ? matches[0] : null;
  }
  async function fromMac() {
    // The URL opens the installed app. Only a short-lived, explicit request can
    // read its public timetable, never the passport or configuration.
    const nonce=crypto.randomUUID(), link=document.createElement("a");
    link.href=`railwayatlas://timetable-sync/${nonce}`;link.click();
    const until=Date.now()+90000;
    while (Date.now()<until) {
      await new Promise(resolve=>setTimeout(resolve,900));
      try {
        const response=await fetch(`http://127.0.0.1:18765/timetable/${nonce}`,
          {credentials:"omit",cache:"no-store",signal:AbortSignal.timeout(12000)});
        if (response.ok) return new File([await response.blob()],"lulutong.json");
      } catch {}
    }
    throw Error("未连接到本机 App。可以导入官网 APK 或本机的 lulutong.json。");
  }
  return { index, install, restore, search, runsOn, timetable, plan, trainNames, fromMac, get current() { return current; } };
})();
