/* Public ride links describe a timetable interval. The passport stays on this device. */
const JourneyKeepsakes = (() => {
  const publicSite = "https://wongary.github.io/railway-atlas/";
  const activityKey = "railway-atlas-passport-activity-v1";
  const stampTitles = {travelled:"乘坐章", simulated:"模拟章", browsed:"浏览章"};
  const colours = {travelled:"#a34236", simulated:"#226f85", browsed:"#657448"};
  let miniMap, routeLayer, footprintVersion = 0, shareVersion = 0, sharedLink = "", openVersion = 0;
  const idFor = item => JSON.stringify([item.train, item.date, item.from, item.to, item.departure || ""]);

  function recordedSection(route) {
    const first = route?.stops?.[0], last = route?.stops?.at(-1);
    if (!route?.serviceDate || !first || !last || !Number.isFinite(first.departure)) return null;
    return {date:StationCatalog.day(route.serviceDate, Math.floor(first.departure / 1440)), train:route.train,
      from:first.name, to:last.name, departure:formatClock(first.departure % 1440), source:"journey"};
  }

  function remember(route, kind) {
    const entry = recordedSection(route);
    if (!entry) return;
    const history = readStored(activityKey, []);
    if (!Array.isArray(history)) return;
    const key = idFor(entry);
    if (history.some(item => item.kind === kind && item.key === key)) return;
    writeStored(activityKey, [{...entry, kind, key}, ...history].slice(0, 1000));
  }

  function saveRide() {
    const entry = recordedSection(state.route);
    if (!entry) return showToast("请先选择车次和乘车区间。");
    const form = $("journeyForm");
    setWorkspaceView("experiences");
    setWorkspaceOpen(true);
    setExperiencePage("passport");
    for (const name of ["date","train","from","to","departure"]) form.elements[name].value = entry[name];
    form.elements.status.value = "travelled";
    form.dataset.routeKey = idFor(entry);
    form.scrollIntoView({block:"nearest"});
    showToast("请核对日期和区间，点「保存记录」记入乘坐足迹。");
  }

  function routeLength(route) {
    let metres = 0;
    for (const leg of route.legs) for (let i = 1; i < leg.length; i++)
      metres += L.latLng(leg[i - 1]).distanceTo(L.latLng(leg[i]));
    return metres;
  }

  function initFootprintMap() {
    if (!miniMap) {
      miniMap = L.map($("footprintMap"), {attributionControl:false, scrollWheelZoom:false})
        .setView([34, 106], 3);
      routeLayer = L.layerGroup().addTo(miniMap);
      // All reference geometry is bundled. Opening a personal map does not request base tiles.
      fetch("./station-directory/card-geography.json").then(r => r.json()).then(data => {
        for (const coast of data.coastLines) {
          L.polyline(coast.points, {color:"#929b8c",weight:1,interactive:false})
            .addTo(miniMap).bringToBack();
        }
      }).catch(() => {});
    }
    miniMap.invalidateSize({pan:false});
    routeLayer.clearLayers();
  }

  async function refreshPassport() {
    const version = ++footprintVersion;
    if (!$("footprintPanel")?.open || $("footprintPanel").closest("section").hidden) return;
    initFootprintMap();
    const kind = $("footprintKind").value;
    const history = readStored(activityKey, []);
    const records = kind === "travelled" ? state.journeys.filter(item => item.status === kind)
      : (Array.isArray(history) ? history.filter(item => item.kind === kind) : []);
    const bounds = L.latLngBounds([]), stations = new Set(), trains = new Set(), stamps = new Set();
    let distance = 0, longest = null, missing = 0;
    const colour = colours[kind];
    $("footprintStats").textContent = `正在核对 ${records.length} 条区间…`;
    $("footprintStamps").replaceChildren();
    // Small batches avoid opening a national path group for every old entry at once.
    for (let offset = 0; offset < records.length; offset += 8) {
      const batch = records.slice(offset, offset + 8);
      const routes = await Promise.all(batch.map(record => passengerSection(record).catch(() => null)));
      if (version !== footprintVersion) return;
      routes.forEach((route, i) => {
        const entry = batch[i];
        for (const name of [entry.from, entry.to]) if (name) stations.add(name);
        if (entry.train) trains.add(entry.train);
        if (!route) { missing++; return; }
        const length = routeLength(route);
        distance += length;
        if (!longest || length > longest.length) longest = {length, train:entry.train};
        const line = L.polyline(route.legs, {color:colour,weight:3,opacity:.82}).addTo(routeLayer);
        const tip = document.createElement("span");
        tip.textContent = `${entry.train} ${entry.from} → ${entry.to}`;
        line.bindTooltip(tip);
        bounds.extend(line.getBounds());
        for (const stop of route.stops) stations.add(stop.name);
        for (const [name, point] of [[entry.from,route.legs[0][0]], [entry.to,route.legs.at(-1).at(-1)]]) {
          const label = document.createElement("span"); label.textContent = name;
          L.circleMarker(point,{radius:4,color:colour,fillOpacity:1}).bindTooltip(label).addTo(routeLayer);
        }
        if (length >= 1e6) stamps.add("千公里旅程");
        if (Math.floor(route.stops[0].departure / 1440) < Math.floor(route.stops.at(-1).arrival / 1440)) stamps.add("跨夜列车");
        for (const edge of route.routing?.edges || []) if (edge.lineName) stamps.add(edge.lineName);
      });
    }
    if (version !== footprintVersion) return;
    if (bounds.isValid()) miniMap.fitBounds(bounds.pad(.12), {maxZoom:12,animate:false});
    else miniMap.setView([34,106],3,{animate:false});
    const km = Math.round(distance / 1000);
    const parts = [`${records.length} 条记录`, `${stations.size} 座经停车站`, `已匹配 ${km} km`];
    if (longest) parts.push(`最长 ${longest.train} ${Math.round(longest.length / 1000)} km`);
    if (missing) parts.push(`${missing} 条待补径路`);
    $("footprintStats").textContent = parts.join(" · ");
    for (const title of [...stamps, ...trains, ...stations]) {
      const badge = document.createElement("span");
      badge.className = "footprint-stamp"; badge.style.color = colour;
      badge.textContent = `${stampTitles[kind]} · ${title}`;
      $("footprintStamps").append(badge);
    }
  }

  function rideURL(record, trip) {
    const hash = new URLSearchParams({ride:"1",train:record.train,day:record.date,from:record.from,to:record.to});
    if (record.departure) hash.set("depart",record.departure);
    if (trip && /^[a-zA-Z0-9]{12}$/.test(trip)) hash.set("trip",trip);
    return publicSite + "#" + hash;
  }
  function readRide(hash) {
    if (hash.length > 2400) throw Error("路线分享链接过长。");
    const p = new URLSearchParams(hash.replace(/^#/,""));
    if (p.get("ride") !== "1") return null;
    const train = p.get("train"), date = p.get("day"), from = p.get("from"), to = p.get("to");
    const trip = p.get("trip") || undefined, departure = p.get("depart") || "";
    if (!/^[A-Z0-9/]{1,40}$/i.test(train || "") || !/^\d{4}-\d{2}-\d{2}$/.test(date || "") ||
      StationCatalog.day(date,0) !== date || ![from,to].every(s => s?.trim() && s.length <= 80) ||
      (trip && !/^[A-Z0-9]{12}$/i.test(trip)) || (departure && !/^([01]\d|2[0-3]):[0-5]\d$/.test(departure)))
      throw Error("链接中的车次、日期或区间无效。");
    return {train,date,from,to,trip,departure,boarding:true};
  }
  function resetShare() {
    shareVersion++;
    sharedLink = "";
    $("rideShareResult").hidden = true;
    $("printRideQR").checked = false;
    $("rideShareLink").removeAttribute("href");
    $("cardExportStatus").textContent = "";
  }
  function drawQR(url) {
    const code = qrcode(0, "M");
    code.addData(url,"Byte"); code.make();
    const modules = code.getModuleCount(), scale = Math.floor(360 / (modules + 8));
    const canvas = $("rideShareQR"); canvas.width = canvas.height = (modules + 8) * scale;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff"; ctx.fillRect(0,0,canvas.width,canvas.height); ctx.fillStyle = "#111";
    for (let y = 0; y < modules; y++) for (let x = 0; x < modules; x++)
      if (code.isDark(y,x)) ctx.fillRect((x+4)*scale,(y+4)*scale,scale,scale);
  }
  async function share() {
    resetShare();
    const serial = shareVersion, route = cardRoute;
    if (!route?.geometryAvailable) return showToast("请先匹配实际乘车区间。");
    const entry = recordedSection(route);
    if (!entry) return;
    try {
      const url = rideURL(entry,route.trip), verified = await RailPaths.find(readRide(new URL(url).hash));
      if (serial !== shareVersion) return;
      if (!verified.geometryAvailable || verified.stops.length !== route.stops.length ||
          !verified.stops.every((s,i) => s.name === route.stops[i].name && s.arrival === route.stops[i].arrival && s.departure === route.stops[i].departure))
        throw Error("公开时刻库与这个区间不符，可导出明信片图片。");
      sharedLink = rideURL(entry, verified.trip);
      drawQR(sharedLink);
      $("rideShareLink").href = sharedLink;
      $("rideShareResult").hidden = false;
    } catch (err) { if (serial === shareVersion) $("cardExportStatus").textContent = err.message; }
  }
  async function openSharedRide() {
    const id = ++openVersion, request = journeyRequest;
    if (!location.hash.startsWith("#ride=")) return;
    try {
      const query = readRide(location.hash);
      if (!query) return;
      const section = await RailPaths.find(query);
      const full = await RailPaths.find({train:section.train,date:section.serviceDate,trip:section.trip});
      if (openVersion !== id || journeyRequest !== request) return;
      const from = full.stops.findIndex(s => s.name === query.from && s.departure === section.stops[0].departure);
      const to = from + section.stops.length - 1;
      if (from < 0 || full.stops[to]?.name !== query.to) throw Error("分享区间与排图不符。");
      displayTimetableJourney(full);
      selectRoute(full.id,{from,to});
      revealJourneyMapOnPhone();
    } catch (err) { if (openVersion === id && journeyRequest === request) showToast(err.message); }
  }

  // Single-image PDF. Byte offsets are counted after encoding, including the binary JPEG stream.
  function pdf(image, page, frame, pixels) {
    const enc = new TextEncoder(), chunks = [], offsets = [0];
    let length = 0;
    function add(value) { const bytes = typeof value === "string" ? enc.encode(value) : value; chunks.push(bytes); length += bytes.length; }
    function object(id, body) { offsets[id] = length; add(`${id} 0 obj\n`); for (const part of body) add(part); add("\nendobj\n"); }
    add("%PDF-1.4\n");
    object(1,["<</Type /Catalog /Pages 2 0 R>>"]);
    object(2,["<</Type /Pages /Kids [3 0 R] /Count 1>>"]);
    object(3,[`<</Type /Page /Parent 2 0 R /MediaBox [0 0 ${page.join(" ")}] /Resources <</XObject <</Card 4 0 R>>>> /Contents 5 0 R>>`]);
    object(4,[`<</Type /XObject /Subtype /Image /Width ${pixels[0]} /Height ${pixels[1]} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${image.length}>>\nstream\n`,image,"\nendstream"]);
    const [x,y,w,h] = frame, commands = `q\n${w} 0 0 ${h} ${x} ${y} cm\n/Card Do\nQ\n`;
    object(5,[`<</Length ${commands.length}>>\nstream\n`,commands,"endstream"]);
    const xref = length;
    add(`xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(n => String(n).padStart(10,"0")+" 00000 n \n").join("")}trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`);
    return new Blob(chunks,{type:"application/pdf"});
  }
  function imageBlob(canvas,type="image/png") {
    return new Promise((resolve,reject) => canvas.toBlob(b => b ? resolve(b) : reject(Error("图片编码失败。")),type,.98));
  }
  async function exportFormat() {
    if (!cardRoute?.geometryAvailable) return showToast("请先匹配实际乘车区间。");
    drawPostcard();
    const canvas = $("postcardPreview"), format = $("cardExportFormat").value;
    try {
      if (format === "svg") {
        const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${canvas.width}" height="${canvas.height}"><image width="100%" height="100%" href="${canvas.toDataURL()}"/></svg>`;
        downloadFile("路线明信片.svg",new Blob([svg],{type:"image/svg+xml"}));
      } else if (format === "wallpaper") {
        const wall = document.createElement("canvas"); wall.width=1080; wall.height=1920;
        const ctx=wall.getContext("2d");
        ctx.fillStyle="#e9e5d8";ctx.fillRect(0,0,1080,1920);
        const height=1000*canvas.height/canvas.width;
        ctx.drawImage(canvas,40,(1920-height)/2,1000,height);
        downloadFile("路线明信片-壁纸.png",await imageBlob(wall));
      } else {
        const point = 72/25.4, ticket = [85.6*point,54*point];
        const page = format === "a4" ? [210*point,297*point] : ticket;
        const h = ticket[0]*canvas.height/canvas.width;
        const bytes = new Uint8Array(await (await imageBlob(canvas,"image/jpeg")).arrayBuffer());
        downloadFile(`路线明信片-${format === "a4" ? "A4" : "票据"}.pdf`,
          pdf(bytes,page,[(page[0]-ticket[0])/2,(page[1]-h)/2,ticket[0],h],[canvas.width,canvas.height]));
      }
    } catch (err) { $("cardExportStatus").textContent=err.message; }
  }
  function setup() {
    $("footprintPanel").addEventListener("toggle",refreshPassport);
    $("footprintKind").addEventListener("change",refreshPassport);
    $("recordRidden").onclick=saveRide;
    $("routeToCard").onclick=() => {
      const entry=recordedSection(state.route);
      if (!entry) return showToast("请先选择车次和乘车区间。");
      setWorkspaceView("experiences");setWorkspaceOpen(true);fillPostcard(entry);
    };
    $("cardMapPreset").onchange=drawPostcard;
    $("printRideQR").onchange=drawPostcard;
    $("createRideShare").onclick=share;
    $("exportCardFormat").onclick=exportFormat;
    $("copyRideShare").onclick=() => sharedLink && copyToClipboard(sharedLink,"已复制路线链接。");
    $("saveRideShare").onclick=async() => { if (sharedLink) downloadFile("铁路区间分享码.png",await imageBlob($("rideShareQR"))); };
    window.addEventListener("hashchange",openSharedRide);
  }
  return {setup,remember,refreshPassport,resetShare,openSharedRide,idFor,rideURL,readRide,pdf};
})();
