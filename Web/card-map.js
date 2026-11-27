const CardMap = (() => {
  let geography;
  let contours;
  let pending;
  let restoring;
  let database;
  let lastRoute = null;

  const edition = "tdt-2026-10-route-1";
  const contourBytes = 1368598;
  const contourHash = "bc57f2b0b12869061a936ddac2167d32c661807bd4d1b44e8923dea40a0ce6be";

  async function readContours(buffer) {
    if (!globalThis.crypto?.subtle) {
      throw Error("请在 HTTPS 网站或本机 localhost 打开后再导入。");
    }
    const digest = await crypto.subtle.digest("SHA-256", buffer);
    const hex = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
    if (hex !== contourHash) {
      throw Error("文件校验未通过，请选择 0.8.11 版的 card-contours.json。");
    }
    const data = JSON.parse(new TextDecoder().decode(buffer));
    if (data.edition !== edition) {
      throw Error("区划轮廓版本不匹配。");
    }
    return data;
  }

  function storage() {
    if (!database) {
      database = new Promise((resolve, reject) => {
        const request = indexedDB.open("railway-atlas-card-context", 1);
        request.onupgradeneeded = () => request.result.createObjectStore("outlines");
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      }).catch(error => {
        database = null;
        throw error;
      });
    }
    return database;
  }

  function restore() {
    return restoring ||= (async () => {
      const db = await storage();
      const buffer = await new Promise((resolve, reject) => {
        const request = db.transaction("outlines").objectStore("outlines").get(edition);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      if (buffer?.byteLength === contourBytes) {
        contours ||= await readContours(buffer);
      }
    })().catch(() => {
      // A new or storage-restricted browser can still draw the physical map.
    });
  }

  async function install(file) {
    if (file.size !== contourBytes) {
      throw Error("文件大小不符，请选择 0.8.11 版的 card-contours.json。");
    }
    const buffer = await file.arrayBuffer();
    const next = await readContours(buffer);
    let saved = true;
    try {
      const db = await storage();
      await new Promise((resolve, reject) => {
        const tx = db.transaction("outlines", "readwrite");
        tx.oncomplete = resolve;
        tx.onabort = tx.onerror = () => reject(tx.error);
        tx.objectStore("outlines").put(buffer, edition);
      });
    } catch {
      saved = false;
    }
    contours = next;
    return saved;
  }

  function load() {
    pending ||= loadJSON("./station-directory/card-geography.json")
      .then(base => {
        geography = base;
        return base;
      })
      .catch(error => {
        pending = null;
        throw error;
      });
    return Promise.all([pending, restore()]).then(([base]) => base);
  }

  function finitePoint(point) {
    return Array.isArray(point) && point.length >= 2 &&
      Number.isFinite(point[0]) && Number.isFinite(point[1]) &&
      Math.abs(point[0]) <= 90 && Math.abs(point[1]) <= 180;
  }

  // passengerSection normally supplies an already sliced route. Callers that
  // still hold the full train can request one unambiguous forward interval.
  function section(route, from, to) {
    const stops = route?.stops;
    if (!Array.isArray(stops) || stops.length < 2 || !Array.isArray(route.legs)) return null;
    const start = from || stops[0].name;
    const end = to || stops.at(-1).name;
    if (stops[0].name === start && stops.at(-1).name === end) {
      return route.geometryAvailable === false || route.gaps?.length ? null : route;
    }
    let interval;
    for (let a = 0; a < stops.length - 1; a++) {
      if (stops[a].name !== start) continue;
      for (let b = a + 1; b < stops.length; b++) {
        if (stops[b].name !== end) continue;
        if (interval) return null;
        interval = [a, b];
      }
    }
    if (!interval) return null;
    const [a, b] = interval;
    const legs = route.legs.slice(a, b);
    const selected = stops.slice(a, b + 1);
    if (legs.length !== b - a || legs.some(leg => !Array.isArray(leg) || leg.length < 2 || !leg.every(finitePoint))) return null;
    if (typeof RailPaths !== "undefined" && RailPaths.gapsFor(selected, legs).length) return null;
    return {...route, stops: selected, legs, stopCoordinates: route.stopCoordinates?.slice(a, b + 1),
      geometryKinds: route.geometryKinds?.slice(a, b), routing: null, gaps: [], geometryAvailable: true};
  }

  function inside(region, lat, lon) {
    const [south, west, north, east] = region.bounds || [];
    if (![south, west, north, east].every(Number.isFinite) ||
      lat < south || lat > north || lon < west || lon > east) {
      return false;
    }
    let hit = false;
    for (const ring of region.rings || []) {
      for (let index = 1; index < ring.length; index += 1) {
        const [a, b] = ring[index - 1];
        const [c, d] = ring[index];
        if ((a > lat) !== (c > lat) && lon < b + (d - b) * (lat - a) / (c - a)) {
          hit = !hit;
        }
      }
    }
    return hit;
  }

  // Coordinates are [latitude, longitude], one leg per consecutive stop pair.
  // The optional seventh argument controls overlays for this canvas only.
  function draw(ctx, route, rect, ink, paper, weight = 2.5, options = {}) {
    const legs = route?.legs;
    const [x, y, w, h] = rect;
    if (!Array.isArray(legs) || !legs.length || route.geometryAvailable === false || route.gaps?.length ||
        legs.length !== route.stops?.length - 1 || !(w > 0 && h > 0)) return [];
    lastRoute = route;
    let south = Infinity, north = -Infinity, west = Infinity, east = -Infinity;
    const points = [];
    for (const leg of legs) {
      if (!Array.isArray(leg) || leg.length < 2) return [];
      for (const point of leg) {
        if (!finitePoint(point)) return []; // Skipping a bad vertex would invent a connector.
        const [lat, lon] = point;
        south = Math.min(south, lat); north = Math.max(north, lat);
        west = Math.min(west, lon); east = Math.max(east, lon);
        points.push(point);
      }
    }
    const mini = h < 82 || w < 180;
    const font = mini ? 8 : Math.min(12, Math.max(10, h / 16));
    const fitPadding = Number.isFinite(options.fitPadding)
      ? Math.max(0.04, Math.min(0.28, options.fitPadding)) : (mini ? 0.1 : 0.12);
    const showProvince = options.showProvince ?? true;
    const showCountry = options.showCountry ?? true;
    const showCities = options.showCities ?? true;
    const showStations = options.showStations ?? (!mini && Math.max(north - south, east - west) < 0.85);
    const cityLimit = Number.isFinite(options.cityLimit) ? options.cityLimit : (mini ? 3 : 10);
    const cityRank = Number.isFinite(options.cityRank) ? options.cityRank : Infinity;
    const routeHalo = options.routeHalo ?? true;

    const midLat = (south + north) / 2;
    const midLon = (west + east) / 2;
    const cos = Math.max(0.1, Math.cos(midLat * Math.PI / 180));
    const latSpan = Math.max(0.012, north - south);
    const lonSpan = Math.max(0.012, (east - west) * cos);
    const scale = Math.min(
      (w * (1 - fitPadding * 2)) / lonSpan,
      (h * (1 - fitPadding * 2)) / latSpan
    );
    const project = ([lat, lon]) => [
      x + w / 2 + (lon - midLon) * cos * scale,
      y + h / 2 - (lat - midLat) * scale
    ];
    const viewport = [
      midLat - h / (2 * scale),
      midLon - w / (2 * scale * cos),
      midLat + h / (2 * scale),
      midLon + w / (2 * scale * cos)
    ];

    const visible = parts => (parts || [])
      .filter(part => {
        const bounds = part?.bounds;
        return Array.isArray(bounds) && bounds.length === 4 &&
          bounds[0] <= viewport[2] && bounds[2] >= viewport[0] &&
          bounds[1] <= viewport[3] && bounds[3] >= viewport[1];
      })
      .map(part => (part.points || []).filter(finitePoint).map(project))
      .filter(part => part.length >= 2);

    function stroke(lines, colour, lineWidth, alpha = 1, dash = []) {
      if (!lines?.length) return;
      ctx.beginPath();
      ctx.setLineDash(dash);
      ctx.globalAlpha = alpha;
      ctx.strokeStyle = colour;
      ctx.lineWidth = lineWidth;
      for (const line of lines) {
        line.forEach(([a, b], index) => {
          if (index) ctx.lineTo(a, b);
          else ctx.moveTo(a, b);
        });
      }
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
    }

    function nearestDistance(point, a, b) {
      const dx = b[0] - a[0];
      const dy = b[1] - a[1];
      const t = Math.max(
        0,
        Math.min(1, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / (dx * dx + dy * dy || 1))
      );
      return Math.hypot(point[0] - a[0] - t * dx, point[1] - a[1] - t * dy);
    }

    const xy = legs.map(leg => leg.map(project));
    const first = xy[0][0];
    const last = xy.at(-1).at(-1);
    const occupied = [];
    const labels = [];

    function dot(point, radius, fill) {
      ctx.fillStyle = fill;
      ctx.strokeStyle = ink;
      ctx.lineWidth = mini ? 1 : 1.5;
      ctx.beginPath();
      ctx.arc(point[0], point[1], radius, 0, 2 * Math.PI);
      ctx.fill();
      ctx.stroke();
    }

    function label(text, point, endpoint = false, fill = ink) {
      if (!text || labels.includes(text)) return false;
      const width = ctx.measureText(text).width;
      if (width > w - 8) return false;
      const halfHeight = font / 2 + 1;
      const offsets = [
        [6, 0], [-width - 6, 0], [4, -font - 1],
        [-width - 4, font], [4, font + 1], [-width - 4, -font]
      ];
      for (const [dx, dy] of offsets) {
        const a = Math.max(x + 2, Math.min(x + w - width - 2, point[0] + dx));
        const b = Math.max(y + halfHeight + 1, Math.min(y + h - halfHeight - 1, point[1] + dy));
        const box = [a - 2, b - halfHeight, a + width + 2, b + halfHeight];
        if (occupied.some(item => box[0] < item[2] && box[2] > item[0] && box[1] < item[3] && box[3] > item[1])) {
          continue;
        }
        occupied.push(box);
        labels.push(text);
        ctx.lineWidth = mini ? 2 : 2.8;
        ctx.strokeStyle = paper;
        ctx.strokeText(text, a, b);
        ctx.fillStyle = fill;
        ctx.fillText(text, a, b);
        if (!endpoint) dot(point, mini ? 1.1 : 1.75, paper);
        return true;
      }
      return false;
    }

    function stopPoint(index) {
      const coordinate = route?.stopCoordinates?.[index];
      if (finitePoint(coordinate)) return project(coordinate);
      return xy[index][0];
    }

    ctx.save();
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.clip();
    ctx.lineJoin = ctx.lineCap = "round";

    const shore = contours || geography;
    if (shore && options.showCoast !== false) {
      stroke(visible(shore.coastLines), ink, mini ? 0.65 : 0.9, 0.46);
      if (shore.hainan?.length) {
        const top = project([north + 0.018, midLon])[1];
        const bottom = project([south - 0.018, midLon])[1];
        ctx.save();
        if (viewport[0] <= 18.163 && viewport[2] >= 20.16 &&
          viewport[1] <= 108.615 && viewport[3] >= 111.03) {
          ctx.beginPath();
          ctx.rect(x, top, w, bottom - top);
          ctx.clip();
        }
        stroke(visible(shore.hainan), ink, mini ? 0.65 : 0.9, 0.58);
        ctx.restore();
      }
    }

    if (contours && showProvince) {
      stroke(visible(contours.provinceLines), ink, mini ? 0.65 : 0.9, 0.41, mini ? [2, 2] : [3, 3]);
    }
    if (contours && showCountry) {
      const countryWidth = mini ? 1.05 : 1.45;
      stroke(visible(contours.settled), ink, countryWidth, 0.82, mini ? [5, 2, 1, 2] : [7, 2, 1.2, 2]);
      stroke(visible(contours.undelimited), ink, countryWidth, 0.82, mini ? [4, 3] : [6, 4]);
    }

    if (routeHalo) {
      stroke(xy, paper, weight + (mini ? 1.2 : 2.4), 0.9);
    }
    stroke(xy, ink, weight);

    ctx.font = `${mini ? 600 : 550} ${font}px "PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif`;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";

    const stops = Array.isArray(route?.stops) ? route.stops : [];
    const from = stops[0]?.name || "出发站";
    const to = stops.at(-1)?.name || "到达站";
    dot(first, mini ? 2.3 : 3.6, paper);
    dot(last, mini ? 2.3 : 3.6, ink);
    label(from, first, true);
    label(to, last, true);

    if (showStations && !mini) {
      for (let index = 1; index < stops.length - 1; index += 1) {
        const point = stopPoint(index);
        dot(point, 2.25, paper);
        label(stops[index].name, point, true);
      }
    }

    if (showProvince && !mini && contours?.provinces?.length) {
      ctx.font = `500 ${font + 1}px "Songti SC","STSong","SimSun","Noto Serif CJK SC",serif`;
      const step = Math.max(1, Math.ceil(points.length / 40));
      const samples = points.filter((_, index) => index % step === 0 || index === points.length - 1);
      for (const province of contours.provinces) {
        const within = samples.filter(([lat, lon]) => inside(province, lat, lon));
        if (!within.length) continue;
        const anchors = [[province.lat, province.lon], ...(province.anchors || [])];
        const width = ctx.measureText(province.name).width;
        const [anchorLat, anchorLon] = within[Math.floor(within.length / 2)];
        for (const [dx, dy] of [[-1, 1], [1, 1], [-1, -1], [1, -1], [0, 1], [0, -1]]) {
          const anchor = [
            anchorLat + dy * (font + 12) / scale,
            anchorLon + dx * (width / 2 + 16) / (scale * cos)
          ];
          if (inside(province, ...anchor)) anchors.push(anchor);
        }
        for (const anchor of anchors) {
          const point = project(anchor);
          const box = [
            point[0] - width / 2 - 4, point[1] - font,
            point[0] + width / 2 + 4, point[1] + font
          ];
          if (
            box[0] < x + 3 || box[1] < y + 3 ||
            box[2] > x + w - 3 || box[3] > y + h - 3 ||
            occupied.some(item => box[0] < item[2] && box[2] > item[0] && box[1] < item[3] && box[3] > item[1]) ||
            xy.some(line => line.some((pointOnLine, index) =>
              index && nearestDistance(point, line[index - 1], pointOnLine) < font + 3
            ))
          ) {
            continue;
          }
          occupied.push(box);
          labels.push(province.name);
          ctx.globalAlpha = 0.77;
          ctx.fillStyle = ink;
          ctx.fillText(province.name, point[0] - width / 2, point[1]);
          ctx.globalAlpha = 1;
          break;
        }
      }
    }

    if (showCities && geography?.cities?.length) {
      const range = Math.min(mini ? 10 : 28, Math.max(6, scale * 0.55));
      ctx.font = `${mini ? 600 : 550} ${font}px "PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif`;
      let cityCount = 0;
      // The packaged list is already ordered by rank and population.
      for (const city of geography.cities) {
        if (cityCount >= cityLimit) break;
        if (city.rank > cityRank) continue;
        const point = project([city.lat, city.lon]);
        if (point[0] < x + 3 || point[0] > x + w - 3 || point[1] < y + 3 || point[1] > y + h - 3) {
          continue;
        }
        const name = String(city.name || "").replace(/市$/, "");
        if ([from, to].some(endpoint => endpoint.startsWith(name))) continue;
        const nearRoute = xy.some(line => line.some((linePoint, index) =>
          index && nearestDistance(point, line[index - 1], linePoint) <= range
        ));
        if (nearRoute && label(name, point)) cityCount += 1;
      }
    }

    ctx.restore();
    return labels;
  }

  return {
    load,
    draw,
    section,
    install,
    restore,
    get hasContours() {
      return Boolean(contours);
    },
    get lastRoute() {
      return lastRoute;
    }
  };
})();

// Keep the module available to canvas renderers that run in a separate script
// scope. The app still uses the lexical CardMap binding above.
globalThis.CardMap = CardMap;
