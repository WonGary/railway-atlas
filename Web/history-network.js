/* Railway construction history. Load before app.js, then call setActive(visible, map). */
(() => {
  "use strict";

  // A civil date never goes through the browser's local time zone. Keep the raw
  // tag for display; a month or year only becomes certain at the end of the period.
  function civilDate(raw) {
    if (typeof raw !== "string") return null;
    const value = raw.trim().replace(/^(\d{4})年(\d{1,2})月(?:(\d{1,2})日)?$/, (_, y, m, d) =>
      y + "-" + m.padStart(2, "0") + (d ? "-" + d.padStart(2, "0") : ""));
    const match = /^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$/.exec(value);
    if (!match) return null;
    const year = Number(match[1]), month = Number(match[2] || 12);
    if (year < 1800 || year > 2200 || month < 1 || month > 12) return null;
    const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
    const day = Number(match[3] || last);
    if (day < 1 || day > last) return null;
    return `${match[1]}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }

  // Delta-coded OSM coordinates, retaining all seven original decimal places.
  function decodePath(path) {
    const result = [];
    let index = 0, lat = 0, lon = 0;
    function delta() {
      let value = 0, factor = 1;
      while (index < path.length && factor <= 32 ** 6) {
        const digit = path.charCodeAt(index++) - 63;
        if (digit < 0 || digit > 63) break;
        value += (digit % 32) * factor;
        if (digit < 32) return value % 2 ? -(value + 1) / 2 : value / 2;
        factor *= 32;
      }
      throw Error("区段坐标编码不完整");
    }
    while (index < path.length) {
      lat += delta();
      lon += delta();
      if (Math.abs(lat) > 90e7 || Math.abs(lon) > 180e7) throw Error("区段坐标超出范围");
      result.push([lat / 1e7, lon / 1e7]);
    }
    if (result.length < 2) throw Error("区段缺少轨道几何");
    return result;
  }

  const tagKeys = {opened: ["opening_date", "start_date"], started: ["construction:start_date"], closed: ["end_date", "closure_date"]};
  const phases = {opened: "已开通", started: "已开工，待通车", unknown: "开通日期未知"};
  const eventNames = {started: "开工", opened: "开通", closed: "停用"};

  function prepare(pack) {
    if (pack.version !== 1 || !Array.isArray(pack.segments) || !pack.segments.length) throw Error("不支持的地区资料");
    const sections = new Map();
    for (const section of pack.sections || []) for (const way of section.ways) sections.set(way, section);
    const events = new Map();
    const segments = pack.segments.map(row => {
      const section = sections.get(row.way);
      const segment = {way: row.way, name: pack.names[row.name], colour: row.colour, tags: row.dateTags || {},
        points: decodePath(row.path), section};
      for (const [type, keys] of Object.entries(tagKeys)) {
        const key = keys.find(key => civilDate(segment.tags[key]));
        const record = key ? {raw: segment.tags[key], key} : section?.[type];
        if (!record) continue;
        const date = civilDate(record.raw);
        if (!date) continue;
        segment[type] = {...record, date};
        if (!events.has(date)) events.set(date, []);
        events.get(date).push({segment, type});
      }
      return segment;
    });
    const dates = [...events.keys()].sort();
    if (!dates.length) throw Error("没有可回放的日期");
    const first = `${Number(dates[0].slice(0, 4)) - 1}-12-31`;
    return {...pack, segments, dates: [first, ...dates], events,
      unknownCount: segments.filter(segment => !segment.opened).length};
  }

  function phaseAt(segment, date, showUnknown = false) {
    if (segment.closed && date >= segment.closed.date) return null;
    if (segment.opened && date >= segment.opened.date) return "opened";
    if (segment.started) return date >= segment.started.date ? "started" : null;
    return !segment.opened && showUnknown ? "unknown" : null;
  }

  // The extractor and the data checks use the same civil date and geometry rules.
  if (typeof module === "object" && module.exports && typeof document === "undefined") {
    module.exports = {civilDate, decodePath, prepare, phaseAt};
    return;
  }

  const directory = new URL("data/history-network/", document.currentScript?.src || document.baseURI);
  const sourceURL = "https://www.openstreetmap.org/copyright";
  const licenseURL = "https://opendatacommons.org/licenses/odbl/1-0/";
  const paneName = "atlasHistory";
  const cache = new Map();
  let catalog, map, ui, session, region, loading, timer;
  let visible = false, regionID = "", date = "", showUnknown = false;
  let inspected = null;

  function link(text, href) {
    const el = document.createElement("a");
    el.textContent = text;
    el.href = href;
    el.target = "_blank";
    el.rel = "noopener noreferrer";
    return el;
  }
  function button(text, action) {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "text-button";
    el.textContent = text;
    el.addEventListener("click", action);
    return el;
  }

  function mount() {
    if (ui) return;
    const host = document.querySelector('[data-experience-page="history"]');
    if (!host) throw Error("找不到时光机面板");
    const style = document.createElement("style");
    style.textContent = `
      .has-history-network > :not(.atlas-history-panel) {display:none !important}
      .atlas-history-panel {display:grid;gap:10px;min-width:0}
      .atlas-history-panel .history-fields {display:flex;gap:8px;flex-wrap:wrap}
      .atlas-history-panel .history-fields > label {flex:1 1 105px}
      .atlas-history-panel .history-evidence {display:grid;gap:5px;overflow-wrap:anywhere}
      .atlas-history-panel details summary {cursor:pointer;font-size:12px}
      .atlas-history-panel .history-evidence a,.atlas-history-hud a {text-decoration:underline}
      .atlas-history-panel .history-evidence button {text-align:left;justify-self:start}
      .atlas-history-panel .history-unknown {display:flex;align-items:center;gap:6px}
      .atlas-history-panel .history-unknown input {width:auto}
      .atlas-history-panel output,.atlas-history-hud {font-variant-numeric:tabular-nums}
      .atlas-history-map .leaflet-map-pane > .leaflet-pane:not(.leaflet-atlasHistory-pane):not(.leaflet-vectorBasemap-pane):not(.leaflet-basemapShade-pane) {display:none !important}
      .atlas-history-map ~ .map-overlays #lineFocusBar {display:none !important}
      .atlas-history-hud {display:grid;gap:3px;padding:5px 8px;border-radius:5px;background:var(--panel,#172126);color:var(--ink,#eef3f5);line-height:1.4}
      .atlas-history-hud div {display:flex;align-items:center;gap:8px}
      .atlas-history-hud button {cursor:pointer;padding:2px 5px;font:inherit}
      .atlas-history-hud a {font-size:10px;color:inherit}
    `;
    document.head.append(style);
    const root = document.createElement("div");
    root.className = "atlas-history-panel";
    root.innerHTML = `
      <h3>铁路建设时光机</h3>
      <div class="history-fields">
        <label>地区<select data-h="region"></select></label>
        <label>查看日期<input data-h="day" type="date"></label>
      </div>
      <label>建设时间轴 <output data-h="label"></output>
        <input data-h="slider" type="range" min="0" max="0" value="0" step="1">
      </label>
      <div class="record-actions" data-h="buttons"></div>
      <label class="history-unknown"><input data-h="unknown" type="checkbox">显示开通日期未知的区段</label>
      <div class="history-event">
        <p data-h="status" role="status"></p>
        <p>实线为已开通区段，橙色虚线为已开工、待通车区段。灰色虚线仅作位置参照。数量按轨道区段统计。</p>
        <div data-h="events" class="history-evidence"></div>
        <div data-h="evidence" class="history-evidence"></div>
        <details><summary>数据范围与来源</summary><div data-h="sources" class="history-evidence"></div></details>
      </div>`;
    host.prepend(root);
    host.classList.add("has-history-network");
    ui = {root};
    for (const el of root.querySelectorAll("[data-h]")) ui[el.dataset.h] = el;
    ui.back = button("上一步", () => step(-1));
    ui.play = button("播放", togglePlayback);
    ui.next = button("下一步", () => step(1));
    ui.clear = button("清除并恢复地图", clear);
    ui.restore = button("恢复回放", () => load(regionID, true));
    ui.buttons.append(ui.back, ui.play, ui.next, ui.clear, ui.restore);
    ui.region.onchange = () => load(ui.region.value, false);
    ui.day.onchange = () => { if (region && civilDate(ui.day.value)) seek(ui.day.value); };
    ui.slider.oninput = () => { if (region) seek(region.dates[Number(ui.slider.value)]); };
    ui.unknown.onchange = () => { showUnknown = ui.unknown.checked; if (region) draw(); };
  }

  function pause() {
    clearInterval(timer);
    timer = null;
    if (ui) {
      ui.play.textContent = "播放";
      ui.play.setAttribute("aria-pressed", "false");
    }
    if (session) session.play.textContent = "播放";
  }
  function togglePlayback() {
    if (!region || !session) return;
    if (timer) { pause(); return; }
    if (date === region.dates.at(-1)) seek(region.dates[0]);
    timer = setInterval(() => {
      step(1, false);
      if (date === region?.dates.at(-1)) pause();
    }, 1500);
    ui.play.textContent = session.play.textContent = "暂停";
    ui.play.setAttribute("aria-pressed", "true");
  }
  function frame() { return region.dates.findLastIndex(item => item <= date); }
  function step(direction, stop = true) {
    if (!region) return;
    const index = frame();
    const next = direction > 0 ? index + 1 : index - Number(region.dates[index] === date);
    seek(region.dates[Math.max(0, Math.min(region.dates.length - 1, next))], stop);
  }
  function seek(day, stop = true) {
    if (stop) pause();
    const dates = region.dates;
    date = day < dates[0] ? dates[0] : day > dates.at(-1) ? dates.at(-1) : day;
    inspected = null;
    draw();
  }

  // Tile arrival, a zoom, and preference changes can re-add modern rail to many
  // panes. Mask the panes for the whole session without changing layer settings.
  function begin() {
    if (session) return;
    map.stop();
    const container = map.getContainer();
    const pane = map.getPane(paneName) || map.createPane(paneName);
    pane.style.zIndex = "625";
    const renderer = L.svg({pane: paneName, padding: 0.3});
    const group = L.layerGroup().addTo(map);
    const hud = L.control({position: "bottomleft"});
    const label = document.createElement("strong");
    const play = button("播放", togglePlayback);
    const restoreMap = button("清除", clear);
    restoreMap.setAttribute("aria-label", "清除回放并恢复地图");
    hud.onAdd = () => {
      const box = L.DomUtil.create("div", "atlas-history-hud");
      const actions = document.createElement("div");
      actions.append(play, restoreMap, link("© OpenStreetMap", sourceURL));
      box.append(label, actions);
      MapWindows.addFoldButton(box, "mapHistoryHUD", "时光机", "history");
      L.DomEvent.disableClickPropagation(box);
      L.DomEvent.disableScrollPropagation(box);
      return box;
    };
    hud.onRemove = () => MapWindows.forget(hud.getContainer());
    session = {center: map.getCenter(), zoom: map.getZoom(), container, renderer, group, hud,
      label, play, lines: new Map(), context: null};
    container.classList.add("atlas-history-map");
    // Raster street/rail tiles burn contemporary tracks into their pixels.
    // Only request a rail-free vector basemap when a raster base was online.
    let hasRaster = false;
    map.eachLayer(layer => { if (layer instanceof L.TileLayer && layer.options.pane === "tilePane") hasRaster = true; });
    if (hasRaster && typeof AtlasVectorBasemap !== "undefined") {
      session.context = AtlasVectorBasemap.create("versatiles").addTo(map);
    }
    hud.addTo(map);
  }
  function removeLines() {
    session?.group.clearLayers();
    session?.lines.clear();
  }
  function finish() {
    pause();
    if (!session) return;
    const old = session;
    session = null;
    old.group.clearLayers().remove();
    old.renderer.remove();
    old.hud.remove();
    old.context?.remove();
    old.container.classList.remove("atlas-history-map");
    map.stop().setView(old.center, old.zoom, {animate: false});
  }
  function controls(state, message) {
    ui.root.dataset.state = state;
    const ready = state === "ready", pending = state === "loading";
    for (const el of [ui.day, ui.slider, ui.back, ui.next, ui.play, ui.unknown]) el.disabled = !ready;
    ui.region.disabled = !catalog;
    ui.clear.hidden = !ready && !pending;
    ui.restore.hidden = ready || pending;
    ui.restore.textContent = state === "error" ? "重新加载" : "恢复回放";
    if (!ready) {
      ui.label.textContent = "";
      ui.events.replaceChildren();
      ui.evidence.replaceChildren();
      ui.sources.replaceChildren(link("© OpenStreetMap contributors", sourceURL), link("ODbL 1.0", licenseURL));
    }
    ui.status.textContent = message;
  }
  function cancelLoad() {
    loading?.abort();
    loading = null;
  }
  function clear() {
    cancelLoad();
    finish();
    region = inspected = null;
    if (ui) controls("cleared", "已恢复进入时的地图视野。恢复回放可回到上次查看的日期。");
  }
  async function json(file, signal) {
    const response = await fetch(new URL(file, directory), {signal});
    if (!response.ok) throw Error(`HTTP ${response.status}`);
    return response.json();
  }
  async function load(id, resume) {
    cancelLoad();
    pause();
    removeLines();
    const lastDay = resume && regionID === id ? date : "";
    if (!resume || regionID !== id) { date = ""; showUnknown = false; }
    regionID = id;
    region = inspected = null;
    const request = new AbortController();
    loading = request;
    controls("loading", "正在读取地区轨道与日期…");
    if (session) { session.label.textContent = "正在切换地区…"; session.play.disabled = true; }
    try {
      if (!catalog) {
        const index = await json("index.json", request.signal);
        if (request.signal.aborted) return;
        if (index.version !== 1 || !index.regions?.length) throw Error("地区索引无效");
        catalog = index.regions;
        ui.region.replaceChildren(...catalog.map(item => new Option(item.title, item.id)));
      }
      const entry = catalog.find(item => item.id === id) || catalog[0];
      ui.region.value = regionID = entry.id;
      ui.region.disabled = false;
      if (!cache.has(entry.id)) {
        const pack = await json(entry.file, request.signal);
        if (request.signal.aborted) return;
        if (pack.id !== entry.id) throw Error("地区资料与索引不一致");
        cache.set(entry.id, prepare(pack));
      }
      region = cache.get(entry.id);
      begin();
      map.fitBounds(region.bounds, {padding: [24, 24], maxZoom: 14, animate: false});
      date = lastDay || region.dates[0];
      session.play.disabled = false;
      ui.unknown.checked = showUnknown;
      ui.day.min = region.dates[0];
      ui.day.max = region.dates.at(-1);
      ui.slider.max = String(region.dates.length - 1);
      controls("ready", "");
      showSources(entry);
      draw();
    } catch (error) {
      if (request.signal.aborted) return;
      finish();
      region = null;
      controls("error", `无法载入时光机资料（${error.message}）。可重试或选择其他地区。`);
    } finally {
      if (loading === request) loading = null;
    }
  }

  function showSources(entry) {
    const p = document.createElement("p");
    p.textContent = `轨形取自随包 OSM 快照（最近对象编辑于 ${region.source.latestObjectTimestamp.slice(0,10)}），早年改线和拆除轨道可能缺失。日期取自区段标签或注明范围的工程记录。仅有年月的记录在月末纳入，仅有年份的在年末纳入。`;
    ui.sources.replaceChildren(p, link("© OpenStreetMap contributors", sourceURL), link("数据许可 · ODbL 1.0", licenseURL),
      link(`下载${entry.title}区段数据`, new URL(entry.file, directory)), link("原始 OSM 地区摘录", region.source.source));
    for (const section of region.sections || []) {
      const scope = document.createElement("p");
      scope.textContent = section.scope;
      ui.sources.append(scope, link(section.started.title, section.started.url), link(section.opened.title, section.opened.url),
        link(section.note.title, section.note.url));
    }
  }
  function evidence(segment) {
    inspected = segment;
    const title = document.createElement("strong");
    title.textContent = segment.name;
    const data = document.createElement("p");
    data.textContent = Object.keys(eventNames).map(type =>
      `${eventNames[type]} ${segment[type]?.raw || "未知"}`).join(" · ");
    const wayLink = link(`OSM 轨道 #${segment.way}`, `https://www.openstreetmap.org/way/${segment.way}`);
    ui.evidence.replaceChildren(title, data, wayLink);
    if (Object.keys(segment.tags).length) {
      const tags = document.createElement("small");
      tags.textContent = Object.entries(segment.tags).map(([key, value]) => `${key}=${value}`).join(" · ");
      ui.evidence.append(tags);
    }
    if (segment.section) {
      const note = document.createElement("p");
      note.textContent = segment.section.scope;
      ui.evidence.append(note);
      for (const item of [segment.section.started, segment.section.opened]) ui.evidence.append(link(item.title, item.url));
    }
  }
  function changes() {
    ui.events.replaceChildren();
    const rows = region.events.get(date) || [];
    if (!rows.length) return;
    // A route can have dozens of twin tracks changing at once. Keep a sample
    // per name and status; every rendered way can still be inspected on the map.
    const groups = new Map();
    for (const row of rows) {
      const key = `${row.type}/${row.segment.name}`;
      if (!groups.has(key)) groups.set(key, {row, count: 0});
      groups.get(key).count++;
    }
    const details = document.createElement("details"), summary = document.createElement("summary");
    summary.textContent = `本日纳入 ${rows.length} 条区段记录`;
    const list = document.createElement("div");
    list.className = "history-evidence";
    details.append(summary, list);
    for (const {row, count} of groups.values()) {
      list.append(button(`${eventNames[row.type]} · ${row.segment.name}（${count} 段）`, () => evidence(row.segment)));
    }
    ui.events.append(details);
  }
  function draw() {
    if (!region || !session) return;
    const counts = {opened: 0, started: 0, unknown: 0};
    for (const segment of region.segments) {
      const phase = phaseAt(segment, date, showUnknown), existing = session.lines.get(segment.way);
      if (phase) counts[phase]++;
      if (phase === (existing?.phase || null)) continue;
      if (existing) {
        session.group.removeLayer(existing.line);
        session.lines.delete(segment.way);
      }
      if (!phase) continue;
      const style = phase === "opened" ? {color: segment.colour || "#2dad87", weight: 3.3}
        : phase === "started" ? {color: "#de9946", weight: 3.4, dashArray: "8 5"}
        : {color: "#819096", weight: 2, dashArray: "3 6", opacity: 0.75};
      const line = L.polyline(segment.points, {renderer: session.renderer, pane: paneName, bubblingMouseEvents: false, ...style});
      MapHit.bind(line, () => evidence(segment), {history:true});
      line.addTo(session.group);
      const path = line.getElement();
      if (path) { path.dataset.way = segment.way; path.dataset.phase = phase; }
      if (phase === "unknown") line.bringToBack();
      session.lines.set(segment.way, {line, phase});
    }
    const index = frame();
    ui.slider.value = String(index);
    ui.day.value = date;
    ui.label.textContent = date === region.dates[0] ? "首条记录之前" : `截至 ${date}`;
    ui.slider.setAttribute("aria-valuetext", `截至 ${date}`);
    ui.back.disabled = date === region.dates[0];
    ui.next.disabled = date === region.dates.at(-1);
    ui.status.textContent = `已开通 ${counts.opened} 段 · 已开工待通车 ${counts.started} 段 · 开通日期未知 ${region.unknownCount} 段（当前显示 ${counts.unknown} 段）`;
    session.label.textContent = `${region.title} · ${date} · 已开通 ${counts.opened} 段`;
    changes();
    if (!inspected || !phaseAt(inspected, date, showUnknown)) {
      inspected = null;
      ui.evidence.replaceChildren();
      if (session.lines.size) ui.evidence.textContent = "点地图上的轨道可查看区段日期和来源。";
    }
  }
  function setActive(next, target) {
    if (map && target && map !== target) { clear(); visible = false; }
    if (target) map = target;
    if (!map || visible === Boolean(next)) return;
    visible = Boolean(next);
    if (!visible) { clear(); return; }
    mount();
    return load(regionID, true);
  }
  globalThis.RailwayHistoryNetwork = {setActive, clear, get active() { return Boolean(session); }};
})();
