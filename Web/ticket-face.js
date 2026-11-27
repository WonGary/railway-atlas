(function installTicketFace(global) {
  "use strict";

  const WIDTH = 640;
  const HEIGHT = 360;
  const SERIF = '"Noto Serif CJK SC","Songti SC","STSong","SimSun","Noto Serif",serif';
  const SANS = '"Noto Sans CJK SC","PingFang SC","Microsoft YaHei","Heiti SC","Noto Sans",sans-serif';
  const MONO = '"SF Mono","Menlo","Cascadia Mono","Consolas","Liberation Mono",monospace';
  const MEMORIAL_NOTICE = "纪念样张 · 不可乘车或报销";
  let randomizationSerial = 0;

  const PALETTES = {
    red: { paper: "#f3d6d0", ink: "#2f2424", accent: "#a52d3b", pale: "#fff6f2", strip: "#d75a65" },
    blue: { paper: "#d8edf2", ink: "#172c34", accent: "#16758d", pale: "#f5ffff", strip: "#76c6d0" },
    "red-replica": { paper: "#f0d2cc", ink: "#2a2222", accent: "#b22f3e", pale: "#fff8f4", strip: "#d66b73" },
    "blue-replica": { paper: "#d6edf1", ink: "#172b35", accent: "#126f87", pale: "#f6ffff", strip: "#68bec9" },
    map: { paper: "#e7eee9", ink: "#1f302e", accent: "#237b70", pale: "#f7fbf5", strip: "#9dc3a4" },
    paper: { paper: "#efc4b9", ink: "#351c1e", accent: "#8d2734", pale: "#fff1e8", strip: "#c7615d" },
    magnetic: { paper: "#c5e0ed", ink: "#192d38", accent: "#315d78", pale: "#f5fbff", strip: "#2f4f65" },
    voucher: { paper: "#e5ebeb", ink: "#273437", accent: "#52757b", pale: "#f8fbf9", strip: "#8bbdc1" },
    "voucher-replica": { paper: "#e1eceb", ink: "#273336", accent: "#3d7379", pale: "#f7fbfa", strip: "#84c4c1" },
    night: { paper: "#182c3b", ink: "#f7ebcf", accent: "#ffc36f", pale: "#263f50", strip: "#0e1e2b" },
    ink: { paper: "#f1eee7", ink: "#242522", accent: "#454842", pale: "#fffdf6", strip: "#b7b6ac" }
  };

  const STYLE_ALIASES = {
    red: "red",
    "red-compact": "red",
    blue: "blue",
    "blue-voucher": "blue",
    "red-replica": "red-replica",
    "blue-replica": "blue-replica",
    "stock-blue": "blue-replica",
    "stock-red": "red-replica",
    map: "map",
    "route-map": "map",
    paper: "paper",
    "paper-retro": "paper",
    "paper-stub": "paper",
    magnetic: "magnetic",
    "magnetic-modern": "magnetic",
    voucher: "voucher",
    "electronic-voucher": "voucher",
    "electronic-voucher-receipt": "voucher",
    "voucher-replica": "voucher-replica",
    "map-stops": "map",
    night: "night",
    "night-express": "night",
    ink: "ink",
    "ink-line": "ink"
  };

  function element(id) {
    return global.document?.getElementById(id) || null;
  }

  function inputValue(ids, fallback = "") {
    for (const id of ids) {
      const field = element(id);
      if (!field) continue;
      const value = String(field.value ?? field.textContent ?? "").trim();
      if (value) return value;
    }
    return fallback;
  }

  function valueFromJourney(journey, keys, fallback = "") {
    for (const key of keys) {
      const value = journey?.[key];
      if (value != null && String(value).trim()) return String(value).trim();
    }
    return fallback;
  }

  function hashSeed(value) {
    let hash = 2166136261;
    for (const character of String(value)) {
      hash ^= character.charCodeAt(0);
      hash = Math.imul(hash, 16777619);
    }
    return hash >>> 0;
  }

  function random(seed) {
    let state = hashSeed(seed);
    return () => {
      state += 0x6D2B79F5;
      let result = state;
      result = Math.imul(result ^ result >>> 15, result | 1);
      result ^= result + Math.imul(result ^ result >>> 7, result | 61);
      return ((result ^ result >>> 14) >>> 0) / 4294967296;
    };
  }

  function randomDigits(next, length) {
    return Array.from({ length }, () => Math.floor(next() * 10)).join("");
  }

  function normalizeStyle(style) {
    return STYLE_ALIASES[String(style || "").trim()] || "red";
  }

  function stationName(value, fallback) {
    const name = String(value || fallback || "—").trim();
    return name.endsWith("站") ? name : `${name}站`;
  }

  const COMMON_STATION_LATIN = {
    北京: "Beijing",
    上海: "Shanghai",
    广州: "Guangzhou",
    深圳: "Shenzhen",
    天津: "Tianjin",
    重庆: "Chongqing",
    西安: "Xi'an",
    成都: "Chengdu",
    武汉: "Wuhan",
    南京: "Nanjing",
    杭州: "Hangzhou",
    郑州: "Zhengzhou",
    石家庄: "Shijiazhuang",
    太原: "Taiyuan",
    济南: "Jinan",
    合肥: "Hefei",
    南昌: "Nanchang",
    福州: "Fuzhou",
    厦门: "Xiamen",
    长沙: "Changsha",
    昆明: "Kunming",
    贵阳: "Guiyang",
    兰州: "Lanzhou",
    乌鲁木齐: "Urumqi",
    沈阳: "Shenyang",
    长春: "Changchun",
    哈尔滨: "Harbin",
    呼和浩特: "Hohhot",
    海口: "Haikou",
    珠海: "Zhuhai",
    汕头: "Shantou",
    宁波: "Ningbo",
    苏州: "Suzhou",
    无锡: "Wuxi",
    徐州: "Xuzhou",
    洛阳: "Luoyang",
    开封: "Kaifeng",
    桂林: "Guilin",
    拉萨: "Lhasa",
    香港: "Hong Kong"
  };

  function latinStation(value) {
    const raw = String(value || "").trim().replace(/站$/, "");
    return COMMON_STATION_LATIN[raw] || global.atlasStationTransliterations?.[raw] || "";
  }

  function formatDate(value) {
    const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
    return match ? `${match[1]}年${match[2]}月${match[3]}日` : (value || "乘车日期　—");
  }

  function formatMinutes(value) {
    if (value == null || String(value).trim() === "") return "";
    const minutes = Number(value);
    if (!Number.isFinite(minutes)) return "";
    const day = Math.floor(minutes / 1440);
    const minute = ((minutes % 1440) + 1440) % 1440;
    return `${String(Math.floor(minute / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")}${day ? ` +${day}日` : ""}`;
  }

  function sampleNumber(value, fallback) {
    const raw = String(value || fallback || "").trim();
    if (!raw) return "SAMPLE";
    if (/^(?:SAMPLE|MEMORIAL|纪念)(?:[-_：: ]|$)/i.test(raw)) return raw;
    return `SAMPLE-${raw.replace(/\s+/g, "-")}`;
  }

  function maskedIdentity(value) {
    const raw = String(value || "").trim();
    if (raw.length < 9 || raw.includes("*")) return raw;
    const start = Math.min(6, Math.max(4, Math.ceil(raw.length * 0.28)));
    const end = Math.min(4, Math.max(2, Math.floor(raw.length * 0.2)));
    if (start + end >= raw.length) return raw;
    return `${raw.slice(0, start)}****${raw.slice(-end)}`;
  }

  function routeName(journey, data) {
    const explicit = inputValue(["postcardRoute", "postcardPath"], "");
    if (explicit) return explicit;
    const journeyRoute = valueFromJourney(journey, ["route", "path", "routeName"], "");
    if (journeyRoute) return journeyRoute;
    const edges = journey?.routing?.edges || [];
    const names = [...new Set(edges.map(edge => edge?.lineName).filter(Boolean))];
    if (names.length) return names.join(" · ");
    const stops = journey?.stops?.map(stop => stop?.name).filter(Boolean) || [];
    if (stops.length > 2) return `${stops[0]} · ${stops[Math.floor(stops.length / 2)]} · ${stops.at(-1)}`;
    return `${data.from} → ${data.to}`;
  }

  function resolveData(journey, options = {}) {
    const source = [
      inputValue(["postcardTrain"]),
      inputValue(["postcardFrom"]),
      inputValue(["postcardTo"]),
      inputValue(["postcardDate"])
    ].join("|");
    const generatedFields = options.generateFields || new Set();
    const read = (ids, fallback) =>
      generatedFields.size && ids.some(id => generatedFields.has(id))
        ? fallback
        : inputValue(ids, fallback);
    const from = inputValue(
      ["postcardFrom"],
      valueFromJourney(journey, ["from"], journey?.stops?.[0]?.name || "出发")
    );
    const to = inputValue(
      ["postcardTo"],
      valueFromJourney(journey, ["to"], journey?.stops?.at(-1)?.name || "到达")
    );
    const train = inputValue(
      ["postcardTrain"],
      valueFromJourney(journey, ["train", "service"], "车次")
    ).toUpperCase();
    const date = inputValue(
      ["postcardDate"],
      valueFromJourney(journey, ["date", "serviceDate"], "")
    );
    const departure = inputValue(
      ["postcardDeparture", "postcardStartTime"],
      valueFromJourney(journey, ["departureTime", "departure"], formatMinutes(journey?.stops?.[0]?.departure))
    );
    const arrival = inputValue(
      ["postcardArrival", "postcardEndTime"],
      valueFromJourney(
        journey,
        ["arrivalTime", "arrival"],
        formatMinutes(journey?.stops?.at(-1)?.arrival ?? journey?.stops?.at(-1)?.departure)
      )
    );
    const fromLatin = inputValue(
      ["postcardFromLatin"],
      valueFromJourney(journey, ["fromLatin", "fromPinyin", "originLatin"], latinStation(from) || "ORIGIN")
    );
    const toLatin = inputValue(
      ["postcardToLatin"],
      valueFromJourney(journey, ["toLatin", "toPinyin", "destinationLatin"], latinStation(to) || "DESTINATION")
    );
    const generated = random(`${source}|${from}|${to}|${date}|${options.randomSeed || ""}`);
    const passenger = read(
      ["postcardPassenger", "postcardName"],
      valueFromJourney(journey, ["passenger", "name"], `旅客${String(Math.floor(generated() * 90) + 10)}`)
    );
    const ticketNo = sampleNumber(read(
      ["postcardTicketNo", "postcardTicketNumber"],
      valueFromJourney(journey, ["ticketNo", "ticketNumber"], `SAMPLE-${randomDigits(generated, 8)}`)
    ), `SAMPLE-${randomDigits(generated, 8)}`);
    const idNo = read(
      ["postcardIdNo", "postcardIdentity"],
      valueFromJourney(journey, ["idNo", "identity"], `SAMPLE-ID-${randomDigits(generated, 6)}`)
    );
    const price = read(
      ["postcardPrice", "postcardFare"],
      valueFromJourney(journey, ["price", "fare"], String(Math.round(35 + generated() * 665)))
    );
    const car = read(
      ["postcardCar", "postcardCarriage"],
      valueFromJourney(journey, ["car", "carriage"], String(Math.floor(generated() * 8) + 1).padStart(2, "0"))
    );
    const seat = read(
      ["postcardSeat"],
      valueFromJourney(
        journey,
        ["seat"],
        `${String(Math.floor(generated() * 16) + 1).padStart(2, "0")}${String.fromCharCode(65 + Math.floor(generated() * 5))}`
      )
    );
    const seatClass = read(
      ["postcardSeatClass", "postcardClass"],
      valueFromJourney(journey, ["seatClass", "className"], ["二等座", "一等座", "硬卧"][Math.floor(generated() * 3)])
    );
    const notice = read(
      ["postcardNotice"],
      valueFromJourney(journey, ["notice"], MEMORIAL_NOTICE)
    );
    const notice2 = read(
      ["postcardNotice2"],
      valueFromJourney(journey, ["notice2", "secondaryNotice"], "二维码、验证码及官方凭证编号未生成")
    );
    const gate = read(
      ["postcardGate"],
      valueFromJourney(journey, ["gate", "checkIn", "checkin"], "检票：样张")
    );
    const mark = read(
      ["postcardMark"],
      valueFromJourney(journey, ["mark", "ticketMark"], "样张")
    );
    const issuer = read(
      ["postcardIssuer"],
      valueFromJourney(journey, ["issuer", "seller", "ticketOffice"], "铁路图鉴 · 纪念样张")
    );
    const bottomNo = sampleNumber(read(
      ["postcardBottomNo", "postcardDocumentNo"],
      valueFromJourney(journey, ["bottomNo", "documentNo"], `SAMPLE-${randomDigits(generated, 10)}`)
    ), `SAMPLE-${randomDigits(generated, 10)}`);
    const watermark = read(
      ["postcardWatermark", "postcardMemorial"],
      valueFromJourney(journey, ["watermark", "memorial"], "纪念图 / SAMPLE")
    );
    const caption = inputValue(
      ["postcardCaption"],
      valueFromJourney(journey, ["note"], "山川迢迢，来日方长。")
    );
    const stops = journey?.stops?.map(stop => stop?.name).filter(Boolean) || [];

    return {
      from,
      to,
      fromTicket: stationName(from, "出发"),
      toTicket: stationName(to, "到达"),
      train,
      date,
      dateText: formatDate(date),
      departure,
      arrival,
      fromLatin,
      toLatin,
      passenger,
      ticketNo,
      idNo,
      idNoDisplay: maskedIdentity(idNo),
      price: price.replace(/^¥\s*/, ""),
      car,
      seat,
      seatClass,
      gate,
      mark,
      issuer,
      notice,
      notice2,
      bottomNo,
      watermark,
      memorialNotice: MEMORIAL_NOTICE,
      caption,
      route: routeName(journey, { from, to }),
      stops
    };
  }

  function setFont(ctx, size, family, weight = 400) {
    ctx.font = `${weight} ${size}px ${family}`;
  }

  function fitSize(ctx, value, maxWidth, size, family, weight = 400, minimum = 8) {
    let current = size;
    while (current > minimum) {
      setFont(ctx, current, family, weight);
      if (ctx.measureText(String(value)).width <= maxWidth) return current;
      current -= 0.5;
    }
    setFont(ctx, minimum, family, weight);
    return minimum;
  }

  function text(ctx, value, x, y, size, options = {}) {
    const {
      family = SANS,
      weight = 400,
      align = "left",
      colour = "#000",
      maxWidth = Infinity,
      baseline = "alphabetic",
      opacity = 1
    } = options;
    const content = String(value ?? "");
    if (Number.isFinite(maxWidth)) {
      fitSize(ctx, content, maxWidth, size, family, weight, Math.max(6, Math.min(size, 8)));
    } else {
      setFont(ctx, size, family, weight);
    }
    ctx.save();
    ctx.textAlign = align;
    ctx.textBaseline = baseline;
    ctx.fillStyle = colour;
    ctx.globalAlpha = opacity;
    if (Number.isFinite(maxWidth)) ctx.fillText(content, x, y, maxWidth);
    else ctx.fillText(content, x, y);
    ctx.restore();
  }

  function line(ctx, x1, y1, x2, y2, colour, width = 1, dash = []) {
    ctx.save();
    ctx.strokeStyle = colour;
    ctx.lineWidth = width;
    ctx.setLineDash(dash);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
    ctx.restore();
  }

  function roundedRect(ctx, x, y, width, height, radius, fill, stroke, lineWidth = 1) {
    ctx.save();
    ctx.beginPath();
    if (ctx.roundRect) {
      ctx.roundRect(x, y, width, height, radius);
    } else {
      ctx.moveTo(x + radius, y);
      ctx.arcTo(x + width, y, x + width, y + height, radius);
      ctx.arcTo(x + width, y + height, x, y + height, radius);
      ctx.arcTo(x, y + height, x, y, radius);
      ctx.arcTo(x, y, x + width, y, radius);
      ctx.closePath();
    }
    if (fill) {
      ctx.fillStyle = fill;
      ctx.fill();
    }
    if (stroke) {
      ctx.strokeStyle = stroke;
      ctx.lineWidth = lineWidth;
      ctx.stroke();
    }
    ctx.restore();
  }

  function paperTexture(ctx, palette, mode = "fine") {
    ctx.save();
    ctx.globalAlpha = mode === "dark" ? 0.12 : 0.16;
    ctx.strokeStyle = palette.accent;
    ctx.lineWidth = 0.45;
    for (let row = -1; row < 30; row += 1) {
      ctx.beginPath();
      for (let x = 0; x <= WIDTH; x += 5) {
        const y = row * 13 + 2 * Math.sin(x * 0.08 + row * 0.7) + 0.7 * Math.cos(x * 0.19 - row);
        if (x) ctx.lineTo(x, y);
        else ctx.moveTo(x, y);
      }
      ctx.stroke();
    }
    if (mode !== "dark") {
      ctx.globalAlpha = 0.14;
      ctx.fillStyle = palette.accent;
      for (let y = 7; y < HEIGHT; y += 11) {
        for (let x = 7; x < WIDTH; x += 11) ctx.fillRect(x, y, 0.7, 0.7);
      }
    }
    ctx.restore();
  }

  function perforations(ctx, x, y, width, height, colour) {
    ctx.save();
    ctx.fillStyle = colour;
    for (let cursor = y + 6; cursor < y + height - 4; cursor += 8) {
      ctx.beginPath();
      ctx.arc(x, cursor, 1.15, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(x + width, cursor, 1.15, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }

  function watermark(ctx, data, palette, angle = -0.12) {
    ctx.save();
    ctx.translate(WIDTH / 2, HEIGHT / 2 + 18);
    ctx.rotate(angle);
    setFont(ctx, 28, SANS, 800);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = palette.accent;
    ctx.globalAlpha = 0.16;
    ctx.fillText(data.watermark, 0, 0);
    ctx.restore();
  }

  function cardMapApi() {
    if (global.CardMap?.draw) return global.CardMap;
    try {
      if (typeof CardMap !== "undefined" && CardMap?.draw) return CardMap;
    } catch {
      // The map script may not have been evaluated yet.
    }
    return null;
  }

  function routeMap(ctx, route, rect, palette, options = {}) {
    const map = cardMapApi();
    if (route && map?.draw) {
      try {
        const labels = map.draw(
          ctx,
          route,
          rect,
          palette.accent,
          palette.paper,
          options.weight || 2.2,
          {
            showProvince: !["simple","cities"].includes(inputValue(["cardMapPreset"])),
            showCountry: !["simple","cities"].includes(inputValue(["cardMapPreset"])),
            showCities: !["simple","boundaries"].includes(inputValue(["cardMapPreset"])),
            showStations: inputValue(["cardMapPreset"]) === "stations" || (inputValue(["cardMapPreset"], "standard") === "standard" && Boolean(options.showStations)),
            fitPadding: options.fitPadding ?? 0.16,
            cityLimit: options.cityLimit ?? 8,
            cityRank: options.cityRank ?? 5
          }
        );
        const validRoute = Array.isArray(route.legs) &&
          route.legs.length === (route.stops?.length || 0) - 1 &&
          route.geometryAvailable !== false &&
          !route.gaps?.length;
        if (validRoute || labels.length) return true;
      } catch {
        // Keep the ticket usable when an optional map overlay cannot draw.
      }
    }
    const [x, y, width, height] = rect;
    roundedRect(ctx, x, y, width, height, 4, palette.pale, `${palette.accent}80`, 0.7);
    text(ctx, "乘车区间待匹配", x + width / 2, y + height / 2, Math.min(15, height / 2.5), {
      family: SERIF,
      align: "center",
      baseline: "middle",
      colour: palette.accent
    });
    return false;
  }

  function stationHeader(ctx, data, palette, options = {}) {
    const top = options.top ?? 82;
    const left = options.left ?? 32;
    const right = options.right ?? WIDTH - 32;
    const stationSize = options.stationSize ?? 34;
    text(ctx, data.fromTicket, left, top, stationSize, {
      family: options.family || SANS,
      weight: 800,
      colour: palette.ink,
      maxWidth: (right - left) * 0.36
    });
    text(ctx, data.toTicket, right, top, stationSize, {
      family: options.family || SANS,
      weight: 800,
      align: "right",
      colour: palette.ink,
      maxWidth: (right - left) * 0.36
    });
    text(ctx, data.train || "车次", (left + right) / 2, top - 10, 25, {
      family: MONO,
      weight: 800,
      align: "center",
      colour: palette.ink,
      maxWidth: 120
    });
    line(ctx, (left + right) / 2 - 54, top + 11, (left + right) / 2 + 54, top + 11, palette.ink, 1.35);
    line(ctx, (left + right) / 2 + 54, top + 11, (left + right) / 2 + 45, top + 5, palette.ink, 1.35);
  }

  function footer(ctx, data, palette, options = {}) {
    const y = options.y ?? 347;
    const left = options.left ?? 28;
    const right = options.right ?? WIDTH - 28;
    text(ctx, data.bottomNo, left, y, options.size ?? 10, {
      family: MONO,
      colour: palette.ink,
      maxWidth: right - left - 170
    });
    text(ctx, options.credit || "RAILWAY ATLAS · COMMEMORATIVE SAMPLE", right, y, 9, {
      family: MONO,
      align: "right",
      colour: palette.ink,
      maxWidth: 250
    });
  }

  function drawRedTicket(ctx, data, palette, route) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette);
    roundedRect(ctx, 12, 12, 616, 336, 5, null, palette.accent, 1.1);
    perforations(ctx, 12, 12, 616, 336, `${palette.accent}60`);
    watermark(ctx, data, palette);

    text(ctx, data.ticketNo, 28, 39, 18, { family: MONO, weight: 700, colour: palette.accent, maxWidth: 142 });
    text(ctx, "铁路客票 · 纪念样张", WIDTH / 2, 38, 19, {
      family: SERIF, weight: 800, align: "center", colour: palette.accent, maxWidth: 250
    });
    text(ctx, "检票：SAMPLE", 612, 38, 13, { family: SANS, weight: 700, align: "right", colour: palette.ink });
    stationHeader(ctx, data, palette, { top: 103, stationSize: 36, family: SERIF });
    text(ctx, data.dateText, 30, 145, 19, { family: SERIF, weight: 700, colour: palette.ink, maxWidth: 185 });
    text(ctx, data.departure ? `${data.departure} 开` : "开车时间　—", 320, 145, 18, {
      family: SERIF, weight: 700, align: "center", colour: palette.ink, maxWidth: 145
    });
    text(ctx, data.arrival ? `${data.arrival} 到` : "到达时间　—", 610, 145, 15, {
      family: SERIF, weight: 700, align: "right", colour: palette.ink, maxWidth: 125
    });
    text(ctx, `¥ ${data.price}`, 31, 177, 22, { family: MONO, weight: 800, colour: palette.ink, maxWidth: 120 });
    text(ctx, data.seatClass, 319, 177, 19, {
      family: SERIF, weight: 700, align: "center", colour: palette.ink, maxWidth: 110
    });
    text(ctx, `${data.car}车 ${data.seat}号`, 610, 177, 18, {
      family: SERIF, weight: 700, align: "right", colour: palette.ink, maxWidth: 180
    });
    line(ctx, 28, 190, 612, 190, `${palette.accent}9c`, 0.8);
    routeMap(ctx, route, [30, 198, 320, 117], palette, { showStations: false, weight: 2.6 });
    text(ctx, "乘车径路", 365, 216, 13, { family: SERIF, weight: 700, colour: palette.accent });
    text(ctx, data.route, 365, 237, 15, { family: SERIF, weight: 600, colour: palette.ink, maxWidth: 235 });
    text(ctx, data.passenger, 365, 267, 18, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 220 });
    text(ctx, data.idNoDisplay, 365, 288, 12, { family: MONO, colour: palette.ink, maxWidth: 235 });
    text(ctx, data.notice, 365, 313, 12, { family: SANS, weight: 700, colour: palette.accent, maxWidth: 235 });
    line(ctx, 28, 329, 612, 329, `${palette.accent}a0`, 0.75, [2, 2]);
    footer(ctx, data, palette, { y: 344, credit: "RAILWAY ATLAS · 纪念图" });
  }

  function drawBlueVoucher(ctx, data, palette, route) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette, "fine");
    roundedRect(ctx, 8, 8, 624, 344, 6, null, `${palette.accent}b0`, 1);
    watermark(ctx, data, palette, -0.08);

    text(ctx, data.ticketNo, 28, 40, 19, { family: MONO, weight: 700, colour: "#d74455", maxWidth: 150 });
    text(ctx, "电子客票报销凭证 · 纪念样张", 320, 39, 18, {
      family: SERIF, weight: 800, align: "center", colour: palette.ink, maxWidth: 330
    });
    text(ctx, "检票：SAMPLE", 612, 39, 13, { family: SANS, weight: 700, align: "right", colour: palette.ink });
    stationHeader(ctx, data, palette, { top: 102, stationSize: 36, family: SANS });
    text(ctx, data.dateText, 30, 145, 18, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 190 });
    text(ctx, data.departure || "—", 320, 145, 20, {
      family: MONO, weight: 800, align: "center", colour: palette.ink, maxWidth: 90
    });
    text(ctx, `${data.car}车 ${data.seat}号`, 610, 145, 16, {
      family: SANS, weight: 700, align: "right", colour: palette.ink, maxWidth: 175
    });
    text(ctx, `¥ ${data.price}`, 30, 176, 21, { family: MONO, weight: 800, colour: palette.ink, maxWidth: 120 });
    text(ctx, data.seatClass, 320, 176, 18, {
      family: SANS, weight: 700, align: "center", colour: palette.ink, maxWidth: 110
    });
    text(ctx, "仅供收藏使用", 610, 176, 16, {
      family: SANS, weight: 800, align: "right", colour: "#c83237", maxWidth: 180
    });
    roundedRect(ctx, 26, 190, 588, 73, 2, `${palette.pale}aa`, `${palette.accent}90`, 0.7);
    text(ctx, "旅客姓名", 39, 214, 13, { family: SANS, colour: palette.accent });
    text(ctx, data.passenger, 111, 214, 16, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 120 });
    text(ctx, "证件号", 245, 214, 13, { family: SANS, colour: palette.accent });
    text(ctx, data.idNoDisplay, 305, 214, 13, { family: MONO, colour: palette.ink, maxWidth: 285 });
    text(ctx, "说明", 39, 244, 13, { family: SANS, colour: palette.accent });
    text(ctx, data.notice, 83, 244, 13, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 500 });
    routeMap(ctx, route, [28, 274, 350, 51], palette, { showStations: false, weight: 1.7, fitPadding: 0.18 });
    text(ctx, data.route, 393, 294, 12, { family: SERIF, colour: palette.ink, maxWidth: 205 });
    text(ctx, "无二维码 · 无验证码 · 不具乘车或报销效力", 393, 316, 10, {
      family: SANS, weight: 700, colour: palette.accent, maxWidth: 205
    });
    ctx.fillStyle = palette.strip;
    ctx.fillRect(8, 331, 624, 21);
    text(ctx, data.bottomNo, 30, 346, 10, { family: MONO, colour: "#173b43", maxWidth: 360 });
    text(ctx, "RAILWAY ATLAS · SAMPLE", 610, 346, 9, { family: MONO, align: "right", colour: "#173b43" });
  }

  function drawVoucher(ctx, data, palette, route) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette);
    roundedRect(ctx, 18, 14, 604, 332, 2, palette.pale, palette.accent, 0.9);
    watermark(ctx, data, palette, -0.1);

    text(ctx, "铁路旅程报销凭证 · 纪念样张", 320, 38, 22, {
      family: SERIF, weight: 800, align: "center", colour: palette.ink, maxWidth: 380
    });
    text(ctx, "SAMPLE", 44, 38, 11, { family: MONO, weight: 700, colour: palette.accent });
    text(ctx, data.ticketNo, 596, 38, 12, { family: MONO, align: "right", colour: palette.accent, maxWidth: 180 });
    line(ctx, 30, 51, 610, 51, palette.accent, 0.75);
    text(ctx, "旅客", 40, 76, 12, { family: SANS, colour: palette.accent });
    text(ctx, data.passenger, 80, 76, 16, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 125 });
    text(ctx, "证件", 250, 76, 12, { family: SANS, colour: palette.accent });
    text(ctx, data.idNoDisplay, 289, 76, 12, { family: MONO, colour: palette.ink, maxWidth: 310 });
    stationHeader(ctx, data, palette, { top: 122, stationSize: 32, family: SANS });
    text(ctx, data.dateText, 33, 158, 16, { family: SANS, colour: palette.ink, maxWidth: 165 });
    text(ctx, data.departure || "—", 320, 158, 17, { family: MONO, align: "center", colour: palette.ink });
    text(ctx, data.seatClass, 606, 158, 15, { family: SANS, align: "right", colour: palette.ink });
    roundedRect(ctx, 32, 174, 576, 71, 1, null, `${palette.accent}a0`, 0.7);
    text(ctx, "票价", 47, 200, 12, { family: SANS, colour: palette.accent });
    text(ctx, `¥ ${data.price}`, 92, 200, 18, { family: MONO, weight: 700, colour: palette.ink });
    text(ctx, "席位", 203, 200, 12, { family: SANS, colour: palette.accent });
    text(ctx, `${data.car}车 ${data.seat}号`, 245, 200, 16, { family: SANS, weight: 700, colour: palette.ink });
    text(ctx, "径路", 404, 200, 12, { family: SANS, colour: palette.accent });
    text(ctx, data.route, 442, 200, 12, { family: SERIF, colour: palette.ink, maxWidth: 152 });
    text(ctx, data.notice, 47, 228, 12, { family: SANS, weight: 700, colour: palette.accent, maxWidth: 530 });
    routeMap(ctx, route, [32, 256, 576, 65], palette, { showStations: false, weight: 2 });
    footer(ctx, data, palette, { y: 339, credit: "纪念样张 · 不生成官方凭证信息" });
  }

  function replicaFrame(ctx, palette, title, options = {}) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette, options.texture || "fine");
    roundedRect(ctx, 8, 8, 624, 344, options.radius ?? 5, null, `${palette.accent}b8`, options.borderWidth ?? 1);
    text(ctx, title, WIDTH / 2, 31, options.titleSize ?? 18, {
      family: options.titleFamily || SERIF,
      weight: 800,
      align: "center",
      colour: palette.ink,
      maxWidth: 330
    });
  }

  function replicaTop(ctx, data, palette, options = {}) {
    text(ctx, data.ticketNo, 28, options.ticketY ?? 32, options.ticketSize ?? 17, {
      family: MONO,
      weight: 700,
      colour: options.ticketColour || palette.accent,
      maxWidth: 170
    });
    text(ctx, data.gate, WIDTH - 28, options.gateY ?? 32, options.gateSize ?? 13, {
      family: SANS,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 175
    });
  }

  function replicaStations(ctx, data, palette, options = {}) {
    const left = options.left ?? 30;
    const right = options.right ?? WIDTH - 30;
    const top = options.top ?? 91;
    const stationSize = options.stationSize ?? 31;
    const latinSize = options.latinSize ?? 13;
    const centre = (left + right) / 2;
    text(ctx, data.fromTicket, left, top, stationSize, {
      family: options.stationFamily || SERIF,
      weight: 800,
      colour: palette.ink,
      maxWidth: 180
    });
    text(ctx, data.fromLatin, left + 2, top + 21, latinSize, {
      family: SANS,
      weight: 600,
      colour: palette.ink,
      maxWidth: 170
    });
    text(ctx, data.train || "车次", centre, top - 8, options.trainSize ?? 26, {
      family: MONO,
      weight: 800,
      align: "center",
      colour: palette.ink,
      maxWidth: 120
    });
    line(ctx, centre - 49, top + 12, centre + 49, top + 12, palette.ink, 1.3);
    line(ctx, centre + 49, top + 12, centre + 40, top + 6, palette.ink, 1.3);
    text(ctx, data.toTicket, right, top, stationSize, {
      family: options.stationFamily || SERIF,
      weight: 800,
      align: "right",
      colour: palette.ink,
      maxWidth: 180
    });
    text(ctx, data.toLatin, right - 2, top + 21, latinSize, {
      family: SANS,
      weight: 600,
      align: "right",
      colour: palette.ink,
      maxWidth: 170
    });
  }

  function replicaFooter(ctx, data, palette, options = {}) {
    const y = options.y ?? 347;
    line(ctx, 24, y - 16, WIDTH - 24, y - 16, `${palette.accent}a0`, 0.75, [2, 2]);
    text(ctx, data.bottomNo, 28, y, options.numberSize ?? 10, {
      family: MONO,
      colour: palette.ink,
      maxWidth: 245
    });
    text(ctx, data.memorialNotice, WIDTH - 28, y, options.noticeSize ?? 10, {
      family: SANS,
      weight: 800,
      align: "right",
      colour: palette.accent,
      maxWidth: 325
    });
  }

  function drawRedReplica(ctx, data, palette, route) {
    replicaFrame(ctx, palette, "铁路客票 · 纪念样张", {
      titleFamily: SERIF,
      titleSize: 19,
      radius: 4,
      borderWidth: 1.1
    });
    perforations(ctx, 8, 8, 624, 344, `${palette.accent}55`);
    watermark(ctx, data, palette, -0.08);
    replicaTop(ctx, data, palette, { ticketColour: palette.accent, gateSize: 13 });
    replicaStations(ctx, data, palette, { top: 91, stationSize: 33, stationFamily: SERIF });
    text(ctx, data.dateText, 30, 145, 17, {
      family: SERIF,
      weight: 700,
      colour: palette.ink,
      maxWidth: 190
    });
    text(ctx, data.departure ? `${data.departure} 开` : "开车时间　—", WIDTH / 2, 145, 16, {
      family: SERIF,
      weight: 700,
      align: "center",
      colour: palette.ink,
      maxWidth: 140
    });
    text(ctx, data.arrival ? `${data.arrival} 到` : "到达时间　—", WIDTH - 30, 145, 15, {
      family: SERIF,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 130
    });
    text(ctx, `¥ ${data.price}`, 30, 174, 21, {
      family: MONO,
      weight: 800,
      colour: palette.ink,
      maxWidth: 120
    });
    text(ctx, data.mark, WIDTH / 2, 174, 17, {
      family: SERIF,
      weight: 800,
      align: "center",
      colour: palette.accent,
      maxWidth: 120
    });
    text(ctx, `${data.car}车 ${data.seat}号 · ${data.seatClass}`, WIDTH - 30, 174, 15, {
      family: SERIF,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 205
    });
    line(ctx, 26, 187, WIDTH - 26, 187, `${palette.accent}9c`, 0.8);
    routeMap(ctx, route, [28, 196, 302, 105], palette, {
      showStations: false,
      weight: 2.55,
      fitPadding: 0.16,
      cityLimit: 6
    });
    text(ctx, "乘车径路", 350, 210, 12, {
      family: SERIF,
      weight: 800,
      colour: palette.accent
    });
    text(ctx, data.route, 350, 230, 14, {
      family: SERIF,
      weight: 600,
      colour: palette.ink,
      maxWidth: 255
    });
    text(ctx, data.passenger, 350, 254, 17, {
      family: SANS,
      weight: 700,
      colour: palette.ink,
      maxWidth: 255
    });
    text(ctx, data.idNoDisplay, 350, 273, 11, {
      family: MONO,
      colour: palette.ink,
      maxWidth: 255
    });
    text(ctx, data.issuer, 350, 291, 11, {
      family: SANS,
      colour: palette.ink,
      maxWidth: 255
    });
    text(ctx, data.notice, 350, 309, 11, {
      family: SANS,
      weight: 700,
      colour: palette.accent,
      maxWidth: 255
    });
    text(ctx, data.notice2, 350, 326, 10, {
      family: SANS,
      colour: palette.ink,
      maxWidth: 255
    });
    replicaFooter(ctx, data, palette, { y: 347, noticeSize: 10 });
  }

  function drawBlueReplica(ctx, data, palette, route) {
    replicaFrame(ctx, palette, "电子客票 · 纪念样张", {
      titleFamily: SANS,
      titleSize: 18,
      radius: 5,
      borderWidth: 1
    });
    watermark(ctx, data, palette, -0.09);
    replicaTop(ctx, data, palette, {
      ticketColour: "#c53c51",
      ticketSize: 18,
      gateSize: 13
    });
    replicaStations(ctx, data, palette, {
      top: 91,
      stationSize: 33,
      stationFamily: SANS,
      latinSize: 13
    });
    text(ctx, data.dateText, 30, 145, 17, {
      family: SANS,
      weight: 700,
      colour: palette.ink,
      maxWidth: 190
    });
    text(ctx, data.departure || "—", WIDTH / 2, 145, 19, {
      family: MONO,
      weight: 800,
      align: "center",
      colour: palette.ink,
      maxWidth: 86
    });
    text(ctx, data.arrival ? `${data.arrival} 到` : "—", WIDTH - 30, 145, 15, {
      family: SANS,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 128
    });
    text(ctx, `¥ ${data.price}`, 30, 174, 21, {
      family: MONO,
      weight: 800,
      colour: palette.ink,
      maxWidth: 120
    });
    text(ctx, data.mark, WIDTH / 2, 174, 17, {
      family: SANS,
      weight: 800,
      align: "center",
      colour: palette.accent,
      maxWidth: 135
    });
    text(ctx, `${data.car}车 ${data.seat}号`, WIDTH - 30, 166, 15, {
      family: SANS,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 175
    });
    text(ctx, data.seatClass, WIDTH - 30, 184, 14, {
      family: SANS,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 175
    });
    roundedRect(ctx, 25, 193, 590, 126, 2, `${palette.pale}b5`, `${palette.accent}88`, 0.7);
    routeMap(ctx, route, [33, 201, 308, 106], palette, {
      showStations: false,
      weight: 2.2,
      fitPadding: 0.16,
      cityLimit: 6
    });
    text(ctx, "旅客姓名", 360, 214, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.passenger, 424, 214, 14, {
      family: SANS,
      weight: 700,
      colour: palette.ink,
      maxWidth: 185
    });
    text(ctx, "证件号", 360, 236, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.idNoDisplay, 424, 236, 11, {
      family: MONO,
      colour: palette.ink,
      maxWidth: 185
    });
    text(ctx, "售票处", 360, 258, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.issuer, 424, 258, 11, {
      family: SANS,
      colour: palette.ink,
      maxWidth: 185
    });
    text(ctx, data.notice, 360, 280, 11, {
      family: SANS,
      weight: 800,
      colour: palette.accent,
      maxWidth: 240
    });
    text(ctx, data.notice2, 360, 299, 10, {
      family: SANS,
      colour: palette.ink,
      maxWidth: 240
    });
    text(ctx, data.route, 360, 316, 10, {
      family: SERIF,
      colour: palette.ink,
      maxWidth: 240
    });
    ctx.fillStyle = palette.strip;
    ctx.fillRect(8, 329, 624, 23);
    text(ctx, data.bottomNo, 28, 345, 10, {
      family: MONO,
      colour: palette.ink,
      maxWidth: 270
    });
    text(ctx, data.memorialNotice, WIDTH - 28, 345, 10, {
      family: SANS,
      weight: 800,
      align: "right",
      colour: palette.ink,
      maxWidth: 320
    });
  }

  function drawVoucherReplica(ctx, data, palette, route) {
    replicaFrame(ctx, palette, "铁路电子报销凭证 · 纪念样张", {
      titleFamily: SERIF,
      titleSize: 17,
      radius: 2,
      borderWidth: 0.9
    });
    watermark(ctx, data, palette, -0.1);
    replicaTop(ctx, data, palette, {
      ticketColour: palette.accent,
      ticketSize: 14,
      gateSize: 12
    });
    text(ctx, data.issuer, 28, 49, 10, {
      family: SANS,
      colour: palette.accent,
      maxWidth: 240
    });
    text(ctx, data.mark, WIDTH - 28, 50, 11, {
      family: SANS,
      weight: 800,
      align: "right",
      colour: palette.accent,
      maxWidth: 170
    });
    replicaStations(ctx, data, palette, {
      top: 91,
      stationSize: 30,
      stationFamily: SANS,
      latinSize: 12,
      trainSize: 24
    });
    text(ctx, data.dateText, 31, 143, 15, {
      family: SANS,
      weight: 700,
      colour: palette.ink,
      maxWidth: 190
    });
    text(ctx, data.departure ? `${data.departure} 开` : "开车时间　—", WIDTH / 2, 143, 14, {
      family: MONO,
      weight: 700,
      align: "center",
      colour: palette.ink,
      maxWidth: 120
    });
    text(ctx, data.arrival ? `${data.arrival} 到` : "到达时间　—", WIDTH - 31, 143, 14, {
      family: MONO,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 135
    });
    roundedRect(ctx, 27, 153, 586, 34, 1, null, `${palette.accent}8a`, 0.7);
    text(ctx, `票价 ¥ ${data.price}`, 39, 175, 13, {
      family: MONO,
      weight: 800,
      colour: palette.ink,
      maxWidth: 118
    });
    text(ctx, data.seatClass, WIDTH / 2, 175, 13, {
      family: SANS,
      weight: 700,
      align: "center",
      colour: palette.ink,
      maxWidth: 110
    });
    text(ctx, `${data.car}车 ${data.seat}号`, WIDTH - 39, 175, 13, {
      family: SANS,
      weight: 700,
      align: "right",
      colour: palette.ink,
      maxWidth: 160
    });
    routeMap(ctx, route, [29, 197, 348, 91], palette, {
      showStations: false,
      weight: 2,
      fitPadding: 0.16,
      cityLimit: 5
    });
    text(ctx, "径路", 399, 212, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.route, 399, 230, 12, {
      family: SERIF,
      colour: palette.ink,
      maxWidth: 205
    });
    text(ctx, "旅客", 399, 250, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.passenger, 439, 250, 13, {
      family: SANS,
      weight: 700,
      colour: palette.ink,
      maxWidth: 165
    });
    text(ctx, "证件", 399, 268, 11, { family: SANS, colour: palette.accent });
    text(ctx, data.idNoDisplay, 439, 268, 10, {
      family: MONO,
      colour: palette.ink,
      maxWidth: 165
    });
    text(ctx, data.notice, 29, 310, 11, {
      family: SANS,
      weight: 800,
      colour: palette.accent,
      maxWidth: 348
    });
    text(ctx, data.notice2, 29, 328, 10, {
      family: SANS,
      colour: palette.ink,
      maxWidth: 348
    });
    replicaFooter(ctx, data, palette, { y: 347, noticeSize: 10 });
  }

  function drawPaperTicket(ctx, data, palette, route, stub = false) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette, "fine");
    roundedRect(ctx, 14, 14, 612, 332, 3, null, palette.accent, 1);
    perforations(ctx, 14, 14, 612, 332, `${palette.accent}80`);
    ctx.save();
    ctx.translate(42, 245);
    ctx.rotate(-Math.PI / 2);
    text(ctx, "铁路客票 · 早期纸质车票样张", 0, 0, 14, { family: SERIF, weight: 700, colour: palette.accent });
    ctx.restore();
    text(ctx, data.ticketNo, 34, 43, 17, { family: MONO, weight: 700, colour: palette.accent, maxWidth: 160 });
    text(ctx, "旅程留念", 606, 43, 15, { family: SERIF, weight: 700, align: "right", colour: palette.accent });
    stationHeader(ctx, data, palette, { top: 104, stationSize: 35, family: SERIF });
    text(ctx, `${data.dateText}　${data.departure || "—"}`, 67, 145, 17, { family: SERIF, weight: 700, colour: palette.ink, maxWidth: 320 });
    text(ctx, data.seatClass, 606, 145, 17, { family: SERIF, weight: 700, align: "right", colour: palette.ink });
    text(ctx, `¥ ${data.price}`, 67, 177, 21, { family: MONO, weight: 800, colour: palette.ink });
    text(ctx, `${data.car}车 ${data.seat}号`, 606, 177, 17, { family: SERIF, weight: 700, align: "right", colour: palette.ink });
    routeMap(ctx, route, [67, 201, 500, 86], palette, { showStations: true, weight: 2.3, cityLimit: 6 });
    text(ctx, `${data.passenger} · ${data.idNoDisplay}`, 67, 309, 13, { family: SANS, colour: palette.ink, maxWidth: 500 });
    text(ctx, data.notice, 606, 309, 12, { family: SANS, weight: 700, align: "right", colour: palette.accent, maxWidth: 300 });
    if (stub) {
      ctx.save();
      ctx.strokeStyle = `${palette.accent}a0`;
      ctx.lineWidth = 0.7;
      ctx.setLineDash([3, 3]);
      ctx.beginPath();
      ctx.moveTo(548, 20);
      ctx.lineTo(548, 340);
      ctx.stroke();
      ctx.restore();
      text(ctx, "存根", 590, 82, 16, { family: SERIF, weight: 700, align: "center", colour: palette.accent });
      text(ctx, data.train, 590, 122, 17, { family: MONO, weight: 700, align: "center", colour: palette.ink, maxWidth: 66 });
      text(ctx, data.price, 590, 165, 16, { family: MONO, weight: 700, align: "center", colour: palette.ink, maxWidth: 66 });
      text(ctx, data.dateText, 590, 207, 10, { family: SANS, align: "center", colour: palette.ink, maxWidth: 82 });
      text(ctx, "SAMPLE", 590, 300, 10, { family: MONO, weight: 700, align: "center", colour: palette.accent, maxWidth: 72 });
    }
    footer(ctx, data, palette, { y: 338, credit: "纸票复刻风格 · 纪念图" });
  }

  function drawMagneticTicket(ctx, data, palette, route) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette);
    roundedRect(ctx, 10, 10, 620, 340, 5, null, palette.accent, 1);
    ctx.fillStyle = palette.strip;
    ctx.fillRect(10, 292, 620, 58);
    for (let x = 14; x < 626; x += 9) {
      ctx.fillStyle = `${palette.pale}55`;
      ctx.fillRect(x, 292, 3, 58);
    }
    watermark(ctx, data, palette, -0.1);
    text(ctx, "铁路磁介质客票 · 纪念样张", 30, 40, 19, { family: SANS, weight: 800, colour: palette.accent, maxWidth: 330 });
    text(ctx, data.ticketNo, 610, 40, 14, { family: MONO, align: "right", colour: palette.ink, maxWidth: 170 });
    stationHeader(ctx, data, palette, { top: 104, stationSize: 35, family: SANS });
    text(ctx, `${data.dateText}　${data.departure || "—"}`, 31, 146, 17, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 285 });
    text(ctx, `${data.car}车 ${data.seat}号`, 610, 146, 17, { family: SANS, weight: 700, align: "right", colour: palette.ink, maxWidth: 180 });
    text(ctx, `¥ ${data.price}`, 31, 177, 21, { family: MONO, weight: 800, colour: palette.ink });
    text(ctx, data.seatClass, 610, 177, 17, { family: SANS, weight: 700, align: "right", colour: palette.ink });
    routeMap(ctx, route, [31, 195, 350, 79], palette, { showStations: false, weight: 2.1 });
    text(ctx, data.route, 401, 216, 14, { family: SERIF, colour: palette.ink, maxWidth: 195 });
    text(ctx, data.passenger, 401, 245, 16, { family: SANS, weight: 700, colour: palette.ink, maxWidth: 195 });
    text(ctx, data.notice, 401, 268, 11, { family: SANS, weight: 700, colour: palette.accent, maxWidth: 195 });
    text(ctx, data.bottomNo, 30, 327, 10, { family: MONO, colour: "#e7f4f6", maxWidth: 360 });
    text(ctx, "SAMPLE · 无乘车效力", 610, 327, 10, { family: MONO, align: "right", colour: "#e7f4f6" });
  }

  function drawRouteCard(ctx, data, palette, route, variant) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    paperTexture(ctx, palette, variant === "night" ? "dark" : "fine");
    if (variant === "night") {
      ctx.save();
      ctx.fillStyle = "#f6d58e";
      for (let index = 0; index < 36; index += 1) {
        const x = (index * 97) % WIDTH;
        const y = (index * 53) % 170;
        ctx.globalAlpha = 0.28 + (index % 4) * 0.08;
        ctx.fillRect(x, y, 1.2, 1.2);
      }
      ctx.restore();
    }
    roundedRect(ctx, 20, 16, 600, 322, 5, null, `${palette.accent}9c`, 0.8);
    text(ctx, variant === "night" ? "夜行铁路 · 路线明信片" : "铁路漫游 · 路线明信片", 31, 42, 18, {
      family: SERIF, weight: 800, colour: palette.accent, maxWidth: 280
    });
    text(ctx, data.train || "车次", 609, 41, 19, { family: MONO, weight: 800, align: "right", colour: palette.ink, maxWidth: 100 });
    text(ctx, `${data.from} → ${data.to}`, 31, 71, 25, {
      family: variant === "night" ? SANS : SERIF,
      weight: 800,
      colour: palette.ink,
      maxWidth: 565
    });
    routeMap(ctx, route, [31, 85, 578, 177], palette, {
      showStations: true,
      weight: variant === "night" ? 3.2 : 2.8,
      cityLimit: 12,
      fitPadding: 0.18
    });
    text(ctx, data.caption, 31, 292, 16, { family: SERIF, colour: palette.ink, maxWidth: 365 });
    text(ctx, data.dateText, 609, 292, 13, { family: MONO, align: "right", colour: palette.ink, maxWidth: 180 });
    line(ctx, 31, 311, 609, 311, `${palette.accent}90`, 0.8);
    text(ctx, `${data.route} · ${data.stops.length || "—"}站`, 31, 330, 11, { family: SANS, colour: palette.ink, maxWidth: 370 });
    text(ctx, `${data.watermark} · ${data.memorialNotice}`, 609, 330, 10, { family: SANS, weight: 700, align: "right", colour: palette.accent, maxWidth: 245 });
  }

  function drawInkCard(ctx, data, palette, route) {
    ctx.fillStyle = palette.paper;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    ctx.save();
    ctx.globalAlpha = 0.12;
    for (let x = 0; x < WIDTH; x += 12) {
      line(ctx, x, 0, x + HEIGHT, HEIGHT, palette.ink, 0.35);
    }
    ctx.restore();
    roundedRect(ctx, 20, 16, 600, 322, 0, null, palette.ink, 1);
    text(ctx, "铁路路线图 · 黑白线稿样张", 31, 42, 18, { family: SERIF, weight: 800, colour: palette.ink, maxWidth: 310 });
    text(ctx, data.train || "车次", 609, 41, 18, { family: MONO, weight: 800, align: "right", colour: palette.ink });
    text(ctx, `${data.from} → ${data.to}`, 31, 72, 24, { family: SERIF, weight: 800, colour: palette.ink, maxWidth: 560 });
    routeMap(ctx, route, [31, 86, 578, 177], palette, {
      showStations: true,
      weight: 2,
      cityLimit: 12,
      fitPadding: 0.18
    });
    text(ctx, data.caption, 31, 294, 16, { family: SERIF, colour: palette.ink, maxWidth: 370 });
    text(ctx, `${data.dateText} · ${data.watermark}`, 609, 294, 11, { family: MONO, align: "right", colour: palette.ink, maxWidth: 240 });
    line(ctx, 31, 312, 609, 312, palette.ink, 0.7);
    text(ctx, data.memorialNotice, 31, 330, 11, { family: SANS, weight: 700, colour: palette.ink });
    text(ctx, data.bottomNo, 609, 330, 10, { family: MONO, align: "right", colour: palette.ink, maxWidth: 200 });
  }

  function stockTicket(ctx, data, blue) {
    const paper = ctx.createLinearGradient(0,0,0,404);
    paper.addColorStop(0, blue ? "#d3e9ec" : "#f4d7d0");
    paper.addColorStop(.6, blue ? "#e6f0ec" : "#f8e1d4");
    paper.addColorStop(1, blue ? "#bbdce0" : "#edc4bd");
    ctx.fillStyle=paper;ctx.fillRect(0,0,640,404);
    const ink="#212621", tint=blue?"#418995":"#a25857";
    const row=(v,x,y,size,width,align="left",family=SERIF,weight=600,colour=ink)=>
      text(ctx,v,x,y,size,{maxWidth:width,align,family,weight,colour});
    // Ticket stock has a station suffix in a smaller face on the same baseline.
    function station(value, latin, x) {
      const name=value.replace(/站$/,""), chars=Array.from(name);
      row(chars.length===2 ? chars.join("　") : name,x-10,95,38,174,"center");
      const w=Math.min(174,ctx.measureText(chars.length===2 ? chars.join("　") : name).width);
      row("站",x-7+w/2,94,19,22);
      row(latin,x,119,17,180,"center",SERIF);
    }
    paperTexture(ctx,{accent:tint});
    row(data.ticketNo,25,37,24,230,"left",SERIF,600,"#aa3543");
    row(/^检票[：:]/.test(data.gate)?data.gate:`检票：${data.gate}`,615,37,19,268,"right",SANS);
    station(data.fromTicket,data.fromLatin==="ORIGIN" ? "" : data.fromLatin,140);
    station(data.toTicket,data.toLatin==="DESTINATION" ? "" : data.toLatin,494);
    row(data.train,320,90,32,116,"center",MONO);
    line(ctx,261,98,379,98,ink,1.6);line(ctx,372,93,379,98,ink,1.6);
    row(`${data.dateText} ${data.departure || "—"} 开`,26,156,23,365);
    row(`${data.car}车 ${data.seat.replace(/号$/,"")}号`,480,156,22,217,"center");
    row(`¥ ${data.price} 元`,26,192,24,190,"left",SERIF);
    row(data.mark,320,192,19,103,"center");
    row(data.seatClass,480,192,23,190,"center");
    row("铁路图鉴 · 纪念样张",320,230,22,350,"center",SANS,700,blue?"#81a9af":"#bd8c86");
    row(data.notice,27,267,18,445,"left",SANS);
    row(`${data.idNoDisplay}　${data.passenger}`,27,293,19,448,"left",SANS);
    ctx.save();ctx.strokeStyle=tint;ctx.setLineDash([4,3]);ctx.strokeRect(32,307,420,53);ctx.restore();
    const defaultNotice="二维码、验证码及官方凭证编号未生成";
    row(data.notice2===defaultNotice ? (element("printRideQR")?.checked ? "扫码查看这段铁路行程" : "铁路旅程收藏") : data.notice2,242,328,14,401,"center");
    row("纪念样张 · 不可乘车或报销",242,351,17,400,"center");
    const qr=element("rideShareQR");
    if (qr && element("printRideQR")?.checked && !element("rideShareResult")?.hidden) {
      ctx.save();ctx.imageSmoothingEnabled=false;ctx.drawImage(qr,492,245,111,111);ctx.restore();
    } else {
      ctx.strokeStyle=tint;ctx.lineWidth=2;ctx.strokeRect(510,259,77,77);
      row("铁路",549,292,21,66,"center",SERIF,600,tint);
      row("纪念",549,321,21,66,"center",SERIF,600,tint);
    }
    ctx.fillStyle=blue?"#8ac5cb":"#db9d98";ctx.fillRect(0,370,640,34);
    row(data.bottomNo,27,394,17,318,"left",MONO);
    row(data.issuer,614,394,15,243,"right");
  }

  function drawTicketFace(ctx, style, palette, journey) {
    const key = normalizeStyle(style);
    const variant = String(style || "");
    const colours = { ...PALETTES[key], ...(palette || {}) };
    const data = resolveData(journey);
    ctx.save();
    ctx.clearRect(0, 0, WIDTH, HEIGHT);
    if (variant === "stock-red" || variant === "stock-blue") stockTicket(ctx,data,variant === "stock-blue");
    else if (key === "red-replica") drawRedReplica(ctx, data, colours, journey);
    else if (key === "blue-replica") drawBlueReplica(ctx, data, colours, journey);
    else if (key === "voucher-replica") drawVoucherReplica(ctx, data, colours, journey);
    else if (key === "red") drawRedTicket(ctx, data, colours, journey);
    else if (key === "blue") drawBlueVoucher(ctx, data, colours, journey);
    else if (key === "voucher") drawVoucher(ctx, data, colours, journey);
    else if (key === "paper") drawPaperTicket(ctx, data, colours, journey, variant === "paper-stub");
    else if (key === "magnetic") drawMagneticTicket(ctx, data, colours, journey);
    else if (key === "night") drawRouteCard(ctx, data, colours, journey, "night");
    else if (key === "ink") drawInkCard(ctx, data, colours, journey);
    else drawRouteCard(ctx, data, colours, journey, variant === "map-stops" ? "map-stops" : "map");
    ctx.restore();
    return data;
  }

  global.drawTicketFace = drawTicketFace;
  global.RailwayTicketFace = {
    draw: drawTicketFace,
    styles: Object.keys(STYLE_ALIASES),
    palettes: PALETTES,
    readData: resolveData,
    randomizeFields({ onlyEmpty = true } = {}) {
      const from = inputValue(["postcardFrom"], "出发");
      const to = inputValue(["postcardTo"], "到达");
      const seed = `${Date.now()}-${++randomizationSerial}-${from}-${to}`;
      const next = random(seed);
      const fields = {
        postcardTicketNo: `SAMPLE-${randomDigits(next, 8)}`,
        postcardPassenger: `旅客${String(Math.floor(next() * 90) + 10)}`,
        postcardIdNo: `SAMPLE-ID-${randomDigits(next, 6)}`,
        postcardPrice: String(Math.round(35 + next() * 665)),
        postcardCar: String(Math.floor(next() * 8) + 1).padStart(2, "0"),
        postcardSeat: `${String(Math.floor(next() * 16) + 1).padStart(2, "0")}${String.fromCharCode(65 + Math.floor(next() * 5))}`,
        postcardSeatClass: ["二等座", "一等座", "商务座", "硬卧", "软卧"][Math.floor(next() * 5)],
        postcardGate: "检票：样张",
        postcardMark: "纪念样张",
        postcardFromLatin: latinStation(from) || "ORIGIN",
        postcardToLatin: latinStation(to) || "DESTINATION",
        postcardIssuer: "铁路图鉴 · 纪念样张",
        postcardNotice: MEMORIAL_NOTICE,
        postcardNotice2: "二维码、验证码及官方凭证编号未生成",
        postcardBottomNo: `SAMPLE-${randomDigits(next, 10)}`,
        postcardWatermark: "纪念图 / SAMPLE"
      };
      const applied = {};
      for (const [id, value] of Object.entries(fields)) {
        const field = element(id);
        if (field && (!onlyEmpty || !String(field.value ?? field.textContent ?? "").trim())) {
          field.value = value;
        }
        applied[id] = field ? String(field.value ?? field.textContent ?? "").trim() : value;
      }
      return applied;
    }
  };
})(globalThis);
