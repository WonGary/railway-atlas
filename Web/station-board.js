function showStationBoard(name) {
  name = name.trim();
  if (!name) { showToast("请先输入站名。"); return; }
  const dialog = $("stationDialog");
  const date = $("libraryDate").value || todayLocal();
  $("dialogTitle").textContent = `${name} · 线路与车次`;
  const content = $("dialogContent");
  content.innerHTML = "";
  const section = document.createElement("div");
  content.append(section);
  const link = "http://cnrail.geogv.org/zhcn/" + (name === "北京西" ? "geo/c66921b087bc48879016d166036aa861" : "");
  section.innerHTML = `<p><a target="_blank" rel="noopener noreferrer" href="${link}">打开中国铁路地图原站</a></p>`;
  const library = RailLibrary.current;
  const entries = library ? (library.stations.get(name) || []).filter(({row}) => RailLibrary.runsOn(row, date)) :
    state.routes.flatMap(row => row.stops.flatMap((stop, i) => stop.name === name ? [{row,i}] : []));
  const lines = library?.lines.get(name) || [];
  function boardRows(parent, rows, title) {
    const wrapper = document.createElement("section");
    parent.append(wrapper);
    wrapper.innerHTML = `<h3>${escapeHTML(title)}</h3><label>筛选车次<input type="search" placeholder="例如 G337"></label><p class="panel-note" role="status"></p><div class="table-wrap"></div>`;
    const filter = wrapper.querySelector("input");
    const render = () => {
      const found = rows.filter(row => row[0].toUpperCase().includes(filter.value.trim().toUpperCase()));
      wrapper.querySelector("p").textContent = `${found.length} / ${rows.length} 条`;
      wrapper.querySelector(".table-wrap").innerHTML = `<table><thead><tr><th>车次</th><th>起点</th><th>终点</th><th>到达</th><th>出发</th></tr></thead><tbody>${found.map(row => `<tr>${row.map(cell => `<td>${escapeHTML(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
    };
    filter.oninput = render;
    render();
  }
  const nearby = library ? lines.map(line => ({
    name: line.name, stops: line.stations.map(stop => [stop.name, stop.kilometre])
  })) : [];
  if (!nearby.length && state.corridor?.nodes.some(node => node.name === name)) {
    const nodes = state.corridor.nodes;
    const i = nodes.findIndex(node => node.name === name);
    const names = unique([nodes[i - 1]?.line, nodes[i]?.line]);
    for (const line of names) nearby.push({name: `${line} · 随包经由区段`, stops: nodes.flatMap((node, j) =>
      node.line === line || nodes[j - 1]?.line === line ? [[node.name, node.km]] : [])});
  }
  function lineItem(parent, title, getStops) {
    const item = document.createElement("details");
    item.innerHTML = `<summary>${escapeHTML(title)}</summary><div></div>`;
    parent.append(item);
    item.ontoggle = async () => {
      if (!item.open || item.dataset.busy) return;
      item.dataset.busy = "1";
      const panel = item.querySelector("div");
      panel.textContent = "正在读取站序…";
      try {
        const stops = await getStops();
        panel.innerHTML = `<ol>${stops.map(([station, km, note]) => `<li>${escapeHTML(station)}　${km != null && km !== "" ? `${escapeHTML(km)} km` : ""} ${escapeHTML(note || "")}</li>`).join("")}</ol>`;
      } catch { panel.textContent = "暂时未能读取站序。收起后可重试。"; delete item.dataset.busy; }
    };
  }
  for (const line of nearby) lineItem(section, line.name, () => line.stops);
  boardRows(section, entries.map(({row,i}) => [row.train, row.stops[0].station || row.stops[0].name,
    row.stops.at(-1).station || row.stops.at(-1).name, formatClock(row.stops[i].arrival), formatClock(row.stops[i].departure)]),
    library ? `本机排图 · ${date}` : "随包经停快照");
  if (location.origin === "http://127.0.0.1:18763") {
    const online = document.createElement("section");
    content.prepend(online);
    online.innerHTML = `<button class="text-button">查询中国铁路地图站表</button><div></div>`;
    const button = online.querySelector("button"), result = online.querySelector("div");
    const get = async path => {
      const response = await fetch(`/station-feed/${path}`, {cache:"no-store"});
      if (!response.ok) throw new Error("中国铁路地图暂时无法连接。");
      return response.json();
    };
    async function display(id) {
      result.textContent = "正在读取原站资料…";
      try {
        const poi = await get(`poi/${id}`);
        const fields = poi.exd?.find(item => !item.view || item.view === "station")?.data;
        result.replaceChildren();
        for (const line of fields?.connection || []) {
          if (!/^[a-f0-9]{32}$/.test(line.eid)) continue;
          lineItem(result, line.linename, async () => {
            const {data} = await get(`feature/${line.eid}`);
            const diagram = (data.diagram || []).filter(row => row[1]?.station || row[1]?.poi || row[1]?.info);
            return diagram.length ? diagram.map(([,node,km]) => [node.station || node.poi || node.info, km, node.station ? node.info || node.poi : ""]) :
              (data.stations || []).map(stop => [stop.name, stop.mileage]);
          });
        }
        const board = await get(`stationroute/${id}`);
        boardRows(result, board.list.map(row => [row.opid, board.hash[row.from].name, board.hash[row.to].name,
          board.hash[row.from].kid === id ? "始发" : row.arr || "—", board.hash[row.to].kid === id ? "终到" : row.dep || "—"]),
          `中国铁路地图 · 更新 ${board.update || "日期未注明"}`);
      } catch (err) { result.append(document.createTextNode(err.message)); }
    }
    button.onclick = async () => {
      button.disabled = true;
      result.textContent = "正在查询站名…";
      try {
        const choices = (await get(`search?keyword=${encodeURIComponent(name)}`)).filter(item => /^geo\/[a-f0-9]{32}$/.test(item.query));
        const exact = choices.filter(item => item.name === name);
        if (exact.length === 1 || choices.length === 1) await display((exact[0] || choices[0]).query.slice(4));
        else {
          result.textContent = choices.length ? "选择车站 " : "原站未找到这个站名。";
          for (const choice of choices) {
            const select = document.createElement("button");
            select.className = "text-button"; select.textContent = choice.name;
            select.onclick = () => display(choice.query.slice(4)); result.append(select);
          }
        }
      } catch (err) { result.textContent = err.message; }
      finally { button.disabled = false; }
    };
  }
  if (!dialog.open) dialog.showModal();
}
