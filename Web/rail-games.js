/* Load as a classic script after app.js. Only the detective opens an extra asset. */
(() => {
  "use strict";
  const DAY = 86400000;
  const SHANGHAI = 8 * 3600000;
  const civilDay = (time = Date.now()) => new Date(time + SHANGHAI).toISOString().slice(0, 10);
  const shiftDay = (date, delta) => new Date(Date.parse(date + "T00:00Z") + delta * DAY).toISOString().slice(0, 10);
  const iso = compact => `${compact.slice(0, 4)}-${compact.slice(4, 6)}-${compact.slice(6)}`;
  const pick = (array, random) => array[Math.floor(random() * array.length)];
  const ordered = (a, b) => a < b ? -1 : a > b ? 1 : 0;
  const same = (a, b) => a.length === b.length && a.every((value, i) => value === b[i]);
  const minute = value => Number.isSafeInteger(value) && value >= 0;

  function shuffled(array, random = Math.random) {
    const copy = array.slice();
    for (let i = copy.length - 1; i > 0; i--) {
      const j = Math.floor(random() * (i + 1));
      [copy[i], copy[j]] = [copy[j], copy[i]];
    }
    return copy;
  }

  function dailyRandom(key) {
    let seed = 2166136261;
    for (const ch of key) seed = Math.imul(seed ^ ch.charCodeAt(0), 16777619);
    return () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed / 4294967296;
    };
  }

  function clock(value, originDay = 0) {
    const days = Math.floor(value / 1440) - originDay;
    const hh = String(Math.floor(value / 60) % 24).padStart(2, "0");
    const mm = String(value % 60).padStart(2, "0");
    return `${days ? `+${days}日 ` : ""}${hh}:${mm}`;
  }

  function catalog(data) {
    if (!data?.trains?.length || !data.calendars?.length || !data.names?.length) throw Error("全国时刻快照尚未载入。");
    const calendars = data.calendars.map(list => new Set(list));
    const days = [...new Set(data.calendars.flat())].sort().map(iso);
    const byTrip = new Map();
    for (const [train, calendar, stops, trip] of data.trains) {
      if (!trip || !calendars[calendar]?.size || stops.length < 2) continue;
      // Use only sequences whose advertised times are sufficient to grade an answer.
      if (!stops.every(([id, arr, dep], i) => data.names[id] &&
        (!i || (minute(arr) && arr >= stops[i - 1][2])) &&
        (i === stops.length - 1 || (minute(dep) && (!i || dep >= arr))))) continue;
      byTrip.set(trip, {train, trip, stops, calendar});
    }
    const rows = [...byTrip.values()].sort((a, b) => ordered(a.trip, b.trip));
    if (!rows.length || !days.length) throw Error("快照里没有可用的时刻。");
    const name = (row, i) => data.names[row.stops[i][0]];
    const runs = (row, date) => calendars[row.calendar].has(date.replaceAll("-", ""));
    function serviceDay(day) {
      const after = days.findIndex(date => date >= day);
      if (after < 0) return days.at(-1);
      if (after === 0 || days[after] === day) return days[after];
      return Date.parse(days[after]) - Date.parse(day) < Date.parse(day) - Date.parse(days[after - 1])
        ? days[after] : days[after - 1];
    }
    // A station index is useful only for the blind box. Build it on its first draw.
    let departures;
    function at(station) {
      if (!departures) {
        departures = new Map();
        for (const row of rows) for (let i = 0; i + 1 < row.stops.length; i++) {
          const key = name(row, i);
          if (!departures.has(key)) departures.set(key, []);
          departures.get(key).push([row, i]);
        }
      }
      return departures.get(station) || [];
    }
    return {edition: data.edition, days, names: data.names, rows, byTrip, name, runs, serviceDay, at};
  }

  function blindTrip(db, station, date, budget, random = Math.random) {
    if (!/^\d{4}-\d\d-\d\d$/.test(date) || !minute(budget) || !budget) return null;
    const matches = [];
    const originDates = new Map();
    for (const [row, from] of db.at(station.trim())) {
      const dep = row.stops[from][2], offset = Math.floor(dep / 1440);
      if (!originDates.has(offset)) originDates.set(offset, shiftDay(date, -offset));
      const origin = originDates.get(offset);
      if (!db.runs(row, origin)) continue;
      const ends = [];
      for (let i = from + 1; i < row.stops.length; i++) {
        const elapsed = row.stops[i][1] - dep;
        if (elapsed > budget) break;
        if (elapsed > 0) ends.push(i);
      }
      if (ends.length) matches.push({row, from, origin, ends});
    }
    if (!matches.length) return null;
    const {row, from, origin, ends} = pick(matches, random);
    return {row, origin, from, to: pick(ends, random)};
  }

  function makePuzzle(db, date, random = Math.random) {
    const rows = db.rows.filter(row => row.stops.length >= 4 && db.runs(row, date));
    for (const row of shuffled(rows, random)) {
      const length = Math.min(6, row.stops.length);
      const from = Math.floor(random() * (row.stops.length - length + 1));
      const answer = row.stops.slice(from, from + length).map(call => db.names[call[0]]);
      if (new Set(answer).size !== length) continue;
      const pieces = shuffled(answer, random);
      if (same(pieces, answer)) [pieces[0], pieces[1]] = [pieces[1], pieces[0]];
      return {row, origin: date, from, to: from + length - 1, answer, pieces};
    }
    throw Error("这一天没有足够的连续停站可以拼图。");
  }

  function dailyTask(db, day) {
    const origin = db.serviceDay(day);
    const random = dailyRandom("rail-games/timetable/1/" + day);
    const row = pick(db.rows.filter(item => db.runs(item, origin) && item.stops.at(-1)[1] > item.stops[0][2]), random);
    if (!row) throw Error("这个服务日期没有可出题的车次。");
    const stops = row.stops, dwell = [];
    for (let i = 1; i < stops.length - 1; i++) if (stops[i][2] > stops[i][1]) dwell.push(i);
    const atStation = dwell.length > 0 && random() < 0.4;
    let from, to, answer;
    if (atStation) {
      from = pick(dwell, random);
      to = from + 1;
      answer = stops[from][2] - stops[from][1];
    } else {
      const starts = stops.slice(0, -1).map((_, i) => i).filter(i => stops.at(-1)[1] > stops[i][2]);
      from = pick(starts, random);
      const ends = stops.map((_, i) => i).filter(i => i > from && stops[i][1] > stops[from][2]);
      to = pick(ends, random);
      answer = stops[to][1] - stops[from][2];
    }
    const kind = atStation ? "dwell" : "ride";
    const key = [day, db.edition, row.trip, origin, kind, from, to, answer].join("/");
    return {day, origin, row, kind, from, to, answer, key};
  }

  function gradeMinutes(task, input) {
    const text = String(input).trim();
    return /^\d+$/.test(text) && Number.isSafeInteger(Number(text)) && Number(text) === task.answer;
  }

  function detectiveDeck(db, pack) {
    if (pack.edition !== db.edition) throw Error("题图和时刻快照的版本不同。请更新网页后重试。");
    const deck = [];
    for (const [trip, pixels] of pack.outlines) {
      const row = db.byTrip.get(trip);
      if (!row || !db.runs(row, pack.date) || row.stops.length < 3) continue;
      const bytes = atob(pixels);
      if (bytes.length < 6 || bytes.length % 2) continue;
      const points = [];
      for (let i = 0; i < bytes.length; i += 2) points.push([bytes.charCodeAt(i), bytes.charCodeAt(i + 1)]);
      const last = row.stops.length - 1;
      const label = `${db.name(row, 0)} → ${db.name(row, last)}`;
      if (!deck.some(card => card.label === label)) deck.push({row, origin: pack.date, from: 0, to: last, label, points});
    }
    if (deck.length < 4) throw Error("可用的路形不足四条，请更新题图。");
    return deck;
  }

  function detectiveRound(db, deck, previous, random = Math.random) {
    const card = pick(deck.filter(item => item !== previous), random);
    const others = shuffled(deck.filter(item => item !== card), random).slice(0, 3);
    const {row, to} = card;
    return {card, choices: shuffled([card, ...others], random).map(item => item.label), clues: [
      `全程有 ${to + 1} 个停站，含始发站和终到站。`,
      `列车从始发到终到共用 ${row.stops[to][1] - row.stops[0][2]} 分钟。`,
      `途中停靠${db.name(row, Math.floor(to / 2))}站。`
    ]};
  }

  if (typeof module === "object" && module.exports) {
    module.exports = {civilDay, clock, catalog, blindTrip, makePuzzle, dailyTask, gradeMinutes, detectiveDeck, detectiveRound};
  }
  if (typeof document === "undefined") return;

  function el(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function button(text, action, className = "text-button") {
    const node = el("button", text, className);
    node.type = "button";
    node.addEventListener("click", action);
    return node;
  }
  const note = text => el("p", text, "panel-note");
  function status(text = "") {
    const node = note(text);
    node.setAttribute("role", "status");
    return node;
  }
  function labelled(text, input) {
    const label = el("label", text);
    label.append(input);
    return label;
  }
  function submit(text) {
    const b = el("button", text, "primary-button");
    b.type = "submit";
    return b;
  }

  // Use the same dated route resolver, map, stop range and player as the station board.
  function journeyButton(db, trip) {
    const box = el("div", undefined, "local-form"), feedback = status();
    const action = button("在主地图沿线旅行", async () => {
      const {row, origin, from, to} = trip;
      action.disabled = true;
      feedback.textContent = "正在读取这段径路…";
      try {
        if (globalThis.RailGameHost) {
          await RailGameHost.travel({train: row.train, trip: row.trip, origin, from, to,
            first: db.name(row, from), last: db.name(row, to), departure: row.stops[from][2], arrival: row.stops[to][1]});
          feedback.textContent = "已在主地图打开。";
          return;
        }
        const route = await RailPaths.find({train: row.train, date: origin, trip: row.trip});
        if (route.stops.length !== row.stops.length || !route.stops.every((stop, i) => stop.name === db.name(row, i)))
          throw Error("径路的站序和本题不一致。");
        const missing = RailPaths.gapsFor(route.stops.slice(from, to + 1), route.legs.slice(from, to));
        if (missing.length) throw Error("这个区间还缺少径路：" + missing.join("、"));
        if (!action.isConnected || action.closest("[hidden], .workspace-closed")) return;
        displayTimetableJourney(route);
        if (from || to !== route.stops.length - 1) selectRoute(route.id, {from, to});
        feedback.textContent = "";
      } catch (error) {
        feedback.textContent = `暂时无法回放。${error.message}`;
      } finally {
        action.disabled = false;
        if (feedback.textContent.startsWith("正在")) feedback.textContent = "";
      }
    });
    box.append(action, feedback);
    return box;
  }

  function blindPage(panel, db) {
    const form = el("form", undefined, "local-form"), station = el("input"), date = el("input"), limit = el("input");
    station.type = "search";
    station.required = true;
    station.value = db.names.includes("北京西") ? "北京西" : db.name(db.rows[0], 0);
    station.setAttribute("list", "rail-games-stations");
    const suggestions = el("datalist");
    suggestions.id = "rail-games-stations";
    function suggest() {
      const key = station.value.trim();
      suggestions.replaceChildren(...db.names.filter(name => name.startsWith(key)).slice(0, 28).map(name => new Option(name)));
    }
    station.addEventListener("input", suggest);
    date.type = "date"; date.required = true; date.value = db.serviceDay(civilDay());
    limit.type = "number"; limit.required = true; limit.min = "1"; limit.step = "1"; limit.value = "180";
    form.append(labelled("上车站", station), suggestions, labelled("上车日期", date), labelled("最多乘车（分钟）", limit), submit("抽一段行程"));
    const result = el("div", undefined, "local-form");
    panel.append(note(`从所选站上车，逐站揭晓目的地。快照收录的始发日期为 ${db.days[0]} 至 ${db.days.at(-1)}。`), form, result);
    form.addEventListener("input", () => result.replaceChildren());
    form.addEventListener("submit", event => {
      event.preventDefault();
      result.replaceChildren();
      const trip = blindTrip(db, station.value, date.value, Number(limit.value));
      if (!trip) {
        result.append(status("没有符合条件的区间。请核对站名、上车日期，或放宽乘车时长。"));
        return;
      }
      const {row, from, to} = trip;
      const boardingDay = Math.floor(row.stops[from][2] / 1440);
      const list = el("ol"), message = status();
      let revealed = from;
      list.append(el("li", `${db.name(row, from)}　${clock(row.stops[from][2], boardingDay)} 开`));
      const next = button("揭晓下一站", () => {
        revealed++;
        const call = row.stops[revealed], name = db.name(row, revealed);
        const dep = revealed < to ? ` / ${clock(call[2], boardingDay)} 开` : "";
        list.append(el("li", `${name}　${clock(call[1], boardingDay)} 到${dep}`));
        message.textContent = `第 ${revealed - from + 1} 站，${name}。`;
        if (revealed === to) {
          next.remove();
          message.textContent = `到站了！${row.train} 次，${db.name(row, from)} → ${name}，共 ${call[1] - row.stops[from][2]} 分钟。`;
          result.append(note(`列车始发日 ${trip.origin} · 上车日 ${date.value}`), journeyButton(db, trip));
        }
      }, "primary-button");
      result.append(list, next, message);
    });
  }

  function drawOutline(canvas, points) {
    const ctx = canvas.getContext("2d");
    ctx.save();
    ctx.scale(canvas.width / 240, canvas.height / 150);
    ctx.fillStyle = "#142b33"; ctx.fillRect(0, 0, 240, 150);
    ctx.strokeStyle = "#f2d482"; ctx.lineWidth = 2.5; ctx.lineJoin = ctx.lineCap = "round";
    ctx.beginPath();
    points.forEach(([x, y], i) => i ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
    ctx.stroke();
    ctx.fillStyle = "#fff4d0";
    ctx.beginPath(); ctx.arc(...points[0], 4, 0, 2 * Math.PI); ctx.fill();
    const [x, y] = points.at(-1);
    ctx.fillRect(x - 3.5, y - 3.5, 7, 7);
    ctx.restore();
  }

  function detectivePage(panel, db) {
    const header = note("看路形选出起终点。上方朝北，圆点是起点，方块是终点。");
    const content = el("div", undefined, "local-form");
    panel.append(header, content);
    let deck, previous;
    async function load() {
      content.replaceChildren(status("正在读取路形…"));
      try {
        let pack = globalThis.RailGameHost?.outlines;
        if (!pack) {
          const response = await fetch(new URL("games/outlines.json", document.baseURI));
          if (!response.ok) throw Error(`题图读取失败（${response.status}）。`);
          pack = await response.json();
        }
        deck = detectiveDeck(db, pack);
        deal();
      } catch (error) {
        content.replaceChildren(status(error.message), button("重新读取题图", load));
      }
    }
    function deal() {
      const {card, choices, clues} = detectiveRound(db, deck, previous);
      previous = card;
      const canvas = el("canvas", undefined, "quiz-canvas");
      canvas.width = 480; canvas.height = 300;
      canvas.setAttribute("role", "img"); canvas.setAttribute("aria-label", "本题的铁路线形");
      drawOutline(canvas, card.points);
      const list = el("ol"), actions = el("div", undefined, "quiz-choices"), message = status();
      list.hidden = true;
      let hints = 0;
      const hint = button("给我一条线索", () => {
        list.hidden = false;
        list.append(el("li", clues[hints++]));
        hint.disabled = hints === clues.length;
        message.textContent = clues[hints - 1];
      });
      const controls = choices.map(label => {
        const choice = button(label, () => {
          choice.disabled = true;
          if (label !== card.label) {
            choice.classList.add("incorrect");
            message.textContent = "这条路形对不上。可以看下一条线索，再选一次。";
            return;
          }
          choice.classList.add("correct");
          controls.forEach(b => { b.disabled = true; });
          hint.disabled = true;
          message.textContent = `猜中了！${card.row.train} 次，${label}。你用了 ${hints} 条线索。`;
          content.append(note(`始发日 ${card.origin} · China Railway GTFS / © OpenStreetMap contributors`), journeyButton(db, card));
        }, "quiz-choice");
        return choice;
      });
      actions.append(...controls);
      content.replaceChildren(canvas, hint, list, actions, message, button("换条线路", deal));
    }
    void load();
  }

  function saveCard(game) {
    const canvas = el("canvas");
    canvas.width = 720; canvas.height = 295 + game.answer.length * 48;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#17343b"; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = "#e6c784"; ctx.fillRect(0, 0, 12, canvas.height);
    ctx.font = "24px sans-serif"; ctx.fillText("铁道漫游  /  站序拼图完成卡", 44, 62);
    ctx.fillStyle = "#f9f5e7"; ctx.font = "bold 44px sans-serif"; ctx.fillText(game.row.train, 44, 130);
    ctx.font = "24px sans-serif"; ctx.fillText(`列车始发日 ${game.origin}`, 44, 175);
    game.answer.forEach((name, i) => {
      const call = game.row.stops[game.from + i], last = i === game.answer.length - 1;
      ctx.fillText(`${String(i + 1).padStart(2, "0")}    ${name}`, 44, 240 + i * 48, 405);
      ctx.fillText(`${clock(last ? call[1] : call[2])} ${last ? "到" : "开"}`, 475, 240 + i * 48);
    });
    const name = `铁路拼图-${game.row.train}-${game.origin}.png`, image = canvas.toDataURL("image/png");
    if (globalThis.RailGameHost) return RailGameHost.saveCard({name, png: image.slice(image.indexOf(",") + 1)});
    const link = el("a"); link.download = name; link.href = image;
    link.click();
  }

  function puzzlePage(panel, db) {
    const body = el("div", undefined, "local-form");
    panel.append(body);
    function deal() {
      const game = makePuzzle(db, db.serviceDay(civilDay()));
      const {row, answer, pieces} = game;
      const chosen = [], bank = el("div", undefined, "quiz-choices"), list = el("ol"), message = status();
      const help = note(`点选站名，拼出 ${row.train} 次从${answer[0]}到${answer.at(-1)}的连续 ${answer.length} 站。列车始发日 ${game.origin}。`);
      const undo = button("撤回一站", () => { chosen.pop(); refresh(); message.textContent = ""; });
      const check = button("核对站序", () => {
        if (!same(chosen, answer)) {
          message.textContent = "站序没对上。可撤回末站，或点已选站名将它取回。";
          return;
        }
        const card = el("article", undefined, "history-event");
        card.append(el("h3", "铁路拼图完成卡"), el("p", `${row.train} 次 · 始发日 ${game.origin}`), el("p", answer.join(" → ")));
        const saved = status();
        body.replaceChildren(card, button("保存完成卡 PNG", async () => {
          try { await saveCard(game); } catch (error) { saved.textContent = `完成卡未保存。${error.message}`; }
        }), saved, journeyButton(db, game), button("再拼一段", deal));
      }, "primary-button");
      const tiles = pieces.map(name => button(name, () => {
        chosen.push(name); refresh(); message.textContent = `已选 ${chosen.length} / ${answer.length} 站。`;
      }, "quiz-choice"));
      bank.append(...tiles);
      function refresh() {
        tiles.forEach((tile, i) => { tile.disabled = chosen.includes(pieces[i]); });
        list.replaceChildren(...chosen.map((name, i) => {
          const item = el("li");
          const take = button(name, () => { chosen.splice(i, 1); refresh(); message.textContent = `已取回${name}。`; });
          take.setAttribute("aria-label", `取回${name}`); item.append(take);
          return item;
        }));
        undo.disabled = !chosen.length;
        check.disabled = chosen.length !== answer.length;
      }
      refresh();
      body.replaceChildren(help, bank, list, undo, check, message, button("换一段拼图", deal));
    }
    deal();
  }

  function dailyPage(panel, db) {
    const storageKey = "railway-atlas-game-daily-v1";
    let current, timer;
    function refresh() {
      const day = civilDay();
      if (current?.day === day) return false;
      const task = dailyTask(db, day);
      current = task;
      clearTimeout(timer);
      timer = setTimeout(refresh, DAY - (Date.now() + SHANGHAI) % DAY + 30);
      const {row, origin, from, to} = task;
      const a = db.name(row, from), b = db.name(row, to), stops = row.stops;
      const dwell = task.kind === "dwell";
      const question = dwell ? `这趟车在${a}停几分钟？` : `从${a}开出，到${b}下车，要坐几分钟？`;
      const excerpt = el("ul");
      const entries = dwell ? [[a, stops[from][1], "到"], [a, stops[from][2], "开"]]
        : [[a, stops[from][2], "开"], [b, stops[to][1], "到"]];
      for (const [name, time, event] of entries) excerpt.append(el("li", `${name}　${clock(time)} ${event}`));
      const form = el("form", undefined, "local-form"), input = el("input"), message = status();
      input.type = "number"; input.min = "0"; input.step = "1"; input.required = true; input.inputMode = "numeric";
      form.append(labelled("你的答案（分钟）", input), submit("提交答案"));
      const headline = el("h3", `${day} 每日时刻任务`);
      const schedule = note(`${row.train} 次 · 快照始发日 ${origin}。每天北京时间零点换题。`);
      panel.replaceChildren(headline, schedule, el("p", question), excerpt, form, message);
      let attempts = 0;
      function finish() {
        form.hidden = true;
        message.textContent = `答对了，${task.answer} 分钟。共作答 ${attempts} 次。`;
        panel.append(journeyButton(db, task));
      }
      try {
        const saved = JSON.parse(localStorage.getItem(storageKey));
        if (saved?.key === task.key && minute(saved.attempts)) {
          attempts = saved.attempts;
          if (saved.solved) finish();
          else if (attempts) message.textContent = `已试过 ${attempts} 次，可以继续作答。`;
        }
      } catch { /* Play also works without browser storage. */ }
      form.addEventListener("submit", event => {
        event.preventDefault();
        if (refresh()) return;
        const solved = gradeMinutes(task, input.value);
        attempts++;
        try { localStorage.setItem(storageKey, JSON.stringify({key: task.key, attempts, solved})); } catch { /* Optional. */ }
        if (solved) finish();
        else { message.textContent = "还差一点，再核对到开时刻和跨日标记。"; input.select(); }
      });
      return true;
    }
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
    window.addEventListener("pageshow", refresh);
    refresh();
    return refresh;
  }

  function register() {
    const workspace = document.querySelector('[data-page="experiences"]');
    const tabs = workspace?.querySelector(".experience-tabs");
    if (!tabs || tabs.querySelector('[data-experience="rail-blind"]')) return;
    let db;
    for (const [id, title, setup] of [
      ["rail-blind", "车次盲盒", blindPage], ["rail-detective", "铁路侦探", detectivePage],
      ["rail-puzzle", "站序拼图", puzzlePage], ["rail-daily", "每日时刻", dailyPage]
    ]) {
      const panel = el("section", undefined, "experience-page");
      panel.dataset.experiencePage = id; panel.id = "rail-games-page-" + id; panel.hidden = true;
      panel.setAttribute("aria-label", title);
      let ready = false, onReopen;
      const tab = button(title, () => {
        setExperiencePage(id);
        if (ready) { onReopen?.(); return; }
        try {
          db ||= catalog(globalThis.atlasRailDirectory);
          panel.replaceChildren();
          onReopen = setup(panel, db);
          ready = true;
        } catch (error) { panel.replaceChildren(status(error.message)); }
      }, "experience-tab");
      tab.dataset.experience = id; tab.setAttribute("aria-controls", panel.id);
      tabs.append(tab); workspace.append(panel);
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", register, {once: true});
  else register();
})();
