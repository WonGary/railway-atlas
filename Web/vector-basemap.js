const AtlasVectorBasemap = (() => {
  const TILE_SIZE = 256;
  const MAX_NATIVE_ZOOM = 14;
  const sources = {
    openfreemap: {
      title: "OpenFreeMap",
      metadata: "https://tiles.openfreemap.org/planet",
      attribution: '<a href="https://openfreemap.org/">OpenFreeMap</a> · <a href="https://openmaptiles.org/">&copy; OpenMapTiles</a> · <a href="https://www.openstreetmap.org/copyright">&copy; OpenStreetMap contributors</a>'
    },
    versatiles: {
      title: "VersaTiles",
      tileTemplate: "https://tiles.versatiles.org/tiles/osm-vector/{z}/{x}/{y}",
      attribution: '<a href="https://versatiles.org/">VersaTiles</a> · <a href="https://www.openstreetmap.org/copyright">&copy; OpenStreetMap contributors</a>'
    }
  };
  const templates = new Map();
  let darkTheme = false;

  const light = {
    ocean: "#c7dce7",
    water: "#b9d7e6",
    waterLine: "#77aec4",
    land: "#edf0eb",
    park: "#dcebd3",
    forest: "#d3e5c8",
    farmland: "#e9edcf",
    residential: "#ece9e4",
    industrial: "#e4e0d9",
    building: "#d8d5d0",
    roadCasing: "#d8d4ce",
    road: "#fffdf8",
    motorway: "#edb36c",
    primary: "#f0cc8f",
    secondary: "#f7e0ad",
    rail: "#b98b79",
    boundary: "#a99e9a",
    label: "#39474c",
    labelHalo: "rgba(255,255,255,.82)"
  };
  const dark = {
    ocean: "#182c39",
    water: "#1e4556",
    waterLine: "#6da8bb",
    land: "#27312f",
    park: "#2d4a3b",
    forest: "#345342",
    farmland: "#4a4b38",
    residential: "#353a38",
    industrial: "#41403b",
    building: "#555550",
    roadCasing: "#1b2424",
    road: "#6f7772",
    motorway: "#c18d55",
    primary: "#c7a46e",
    secondary: "#9a9c8e",
    rail: "#c79b82",
    boundary: "#8e9b96",
    label: "#e2e7df",
    labelHalo: "rgba(20,28,29,.88)"
  };

  function palette() {
    return darkTheme ? dark : light;
  }

  function nameOf(properties = {}) {
    return properties["name:zh-Hans"] || properties["name_zh-Hans"] || properties["name:zh"] ||
      properties.name_zh || properties.name || properties["name:en"] || properties.name_en || "";
  }

  function kindOf(layerName, properties = {}) {
    return String(properties.class || properties.subclass || properties.kind ||
      properties.type || properties.railway || layerName || "").toLowerCase();
  }

  function isRailway(layerName, properties) {
    return properties.rail === true || properties.rail === 1 ||
      ["rail", "railway", "light_rail", "subway", "tram", "monorail", "narrow_gauge", "funicular"].includes(
        kindOf(layerName, properties)
      ) ||
      /railway|railway_line|transportation/.test(layerName) && /rail|transit/.test(
        String(properties.class || properties.subclass || properties.kind || "")
      );
  }

  function fillColor(layerName, properties, colors) {
    const kind = kindOf(layerName, properties);
    if (layerName === "ocean" || /^(ocean|sea)$/.test(kind)) return colors.ocean;
    if (/water/.test(layerName) || ["water", "river", "lake", "reservoir", "ocean"].includes(kind)) return colors.water;
    if (/forest|wood/.test(kind)) return colors.forest;
    if (layerName === "park" || /park|grass|scrub|wetland|nature|green/.test(kind)) return colors.park;
    if (/farmland|farm|orchard|vineyard|meadow/.test(kind)) return colors.farmland;
    if (/residential|suburb|neighbourhood/.test(kind)) return colors.residential;
    if (/industrial|commercial|retail/.test(kind)) return colors.industrial;
    if (/building/.test(layerName)) return colors.building;
    if (/landuse/.test(layerName)) return colors.residential;
    return colors.land;
  }

  function lineStyle(layerName, properties, colors, zoom) {
    const kind = kindOf(layerName, properties);
    if (layerName === "ferries" || kind === "ferry") {
      return { color: colors.waterLine, width: 1, casing: 0, dash: [3, 5] };
    }
    if (/water/.test(layerName) || ["river", "stream", "canal", "drain", "ditch"].includes(kind)) {
      return { color: colors.waterLine, width: Math.max(0.7, (zoom - 4) * 0.14), casing: 0 };
    }
    if (layerName === "boundary" || layerName === "boundaries") {
      return { color: colors.boundary, width: 0.8, casing: 0, dash: [4, 4] };
    }
    if (isRailway(layerName, properties)) {
      return { color: colors.rail, width: Math.min(2.1, 0.8 + (zoom - 5) * 0.16), casing: 0.7, dash: [4, 3] };
    }
    if (/motorway|trunk/.test(kind)) return { color: colors.motorway, width: Math.min(4.1, 1.5 + (zoom - 5) * 0.22), casing: 1.4 };
    if (/primary/.test(kind)) return { color: colors.primary, width: Math.min(3.4, 1.2 + (zoom - 5) * 0.19), casing: 1.1 };
    if (/secondary|tertiary/.test(kind)) return { color: colors.secondary, width: Math.min(2.6, 0.9 + (zoom - 6) * 0.15), casing: 0.8 };
    return { color: colors.road, width: Math.max(0.5, Math.min(2.2, 0.55 + (zoom - 7) * 0.12)), casing: 0.45 };
  }

  function drawPath(context, path, factor, close = false) {
    if (!path?.length) return;
    path.forEach((point, index) => {
      const x = point.x * factor;
      const y = point.y * factor;
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    if (close) context.closePath();
  }

  function drawPolygon(context, feature, factor, color) {
    const paths = feature.loadGeometry();
    context.fillStyle = color;
    context.beginPath();
    for (const path of paths) drawPath(context, path, factor, true);
    if (paths.length) context.fill("evenodd");
  }

  function drawLine(context, feature, factor, style) {
    context.save();
    context.lineCap = "round";
    context.lineJoin = "round";
    context.strokeStyle = style.casing ? palette().roadCasing : style.color;
    context.lineWidth = style.width + (style.casing || 0);
    context.setLineDash(style.dash || []);
    context.beginPath();
    for (const path of feature.loadGeometry()) drawPath(context, path, factor);
    context.stroke();
    if (style.casing) {
      context.strokeStyle = style.color;
      context.lineWidth = style.width;
      context.stroke();
    }
    context.restore();
  }

  function labelPoint(feature, factor) {
    const paths = feature.loadGeometry();
    const path = paths[0];
    if (!path?.length) return null;
    const point = path[Math.floor(path.length / 2)];
    return { x: point.x * factor, y: point.y * factor };
  }

  function labelAllowed(layerName, properties, zoom) {
    if (!nameOf(properties)) return false;
    if (/place/.test(layerName)) return zoom >= 4;
    if (/water/.test(layerName)) return zoom >= 7;
    if (/street|transportation/.test(layerName)) return zoom >= 10;
    if (/boundary/.test(layerName)) return zoom >= 6;
    return zoom >= 12;
  }

  function drawLabel(context, text, point, zoom, important) {
    const size = important ? 12 : zoom >= 12 ? 10 : 11;
    context.save();
    context.font = `${important ? 600 : 500} ${size}px system-ui, -apple-system, sans-serif`;
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.lineJoin = "round";
    context.lineWidth = 3;
    context.strokeStyle = palette().labelHalo;
    context.strokeText(text, point.x, point.y);
    context.fillStyle = palette().label;
    context.fillText(text, point.x, point.y);
    context.restore();
  }

  // OpenMapTiles and Shortbread use different layer names. Paint in map order,
  // independent of the order in which a provider serialized the layers.
  const polygonLayers = ["land", "landuse", "landcover", "park", "sites", "ocean", "water",
    "water_polygons", "street_polygons", "building", "buildings"];
  const lineLayers = ["waterway", "water_lines", "ferries", "boundary", "boundaries", "transportation", "streets"];
  const labelLayers = ["place", "place_labels", "water_name", "water_polygons_labels",
    "water_lines_labels", "transportation_name", "street_labels", "street_labels_points"];

  function collect(layers, names, type) {
    const output = [];
    for (const name of names) {
      const layer = layers[name];
      if (!layer) continue;
      for (let i = 0; i < layer.length; i++) {
        const feature = layer.feature(i);
        if (!type || feature.type === type) output.push({name, feature});
      }
    }
    return output;
  }

  function decodeTile(buffer) {
    const {layers} = AtlasVector.decode(new Uint8Array(buffer));
    return {
      areas: collect(layers, polygonLayers, 3),
      lines: collect(layers, lineLayers, 2),
      names: collect(layers, labelLayers)
    };
  }

  function drawTile(canvas, tile, coords, scale) {
    const context = canvas.getContext("2d");
    const colors = palette();
    const size = TILE_SIZE * scale;
    const dx = (coords.x % scale) * TILE_SIZE, dy = (coords.y % scale) * TILE_SIZE;
    function visible(record) {
      if (scale === 1) return true;
      const box = record.bounds ??= record.feature.bbox();
      const factor = size / record.feature.extent;
      return box[0] * factor <= dx + TILE_SIZE + 4 && box[2] * factor >= dx - 4 &&
        box[1] * factor <= dy + TILE_SIZE + 4 && box[3] * factor >= dy - 4;
    }
    context.fillStyle = colors.land;
    context.fillRect(0, 0, TILE_SIZE, TILE_SIZE);
    context.save();
    context.translate(-dx, -dy);
    for (const record of tile.areas) {
      if (!visible(record)) continue;
      const {name, feature} = record;
      drawPolygon(context, feature, size / feature.extent, fillColor(name, feature.properties, colors));
    }
    for (const record of tile.lines) {
      if (!visible(record)) continue;
      const {name, feature} = record;
      drawLine(context, feature, size / feature.extent, lineStyle(name, feature.properties, colors, coords.z));
    }
    context.restore();

    const labels = [];
    for (const record of tile.names) {
      const {name, feature} = record, tags = feature.properties;
      if (!labelAllowed(name, tags, coords.z) || !visible(record)) continue;
      const point = labelPoint(feature, size / feature.extent);
      if (!point) continue;
      point.x -= dx; point.y -= dy;
      if (point.x < 0 || point.x > TILE_SIZE || point.y < 8 || point.y > TILE_SIZE - 8) continue;
      const text = nameOf(tags);
      const rank = Number(tags.rank ?? ({country:1, state:3, city:5, town:8})[kindOf(name, tags)] ?? 20);
      labels.push({text, point, rank, important: name.startsWith("place") && rank <= 8});
    }
    labels.sort((a, b) => a.rank - b.rank);
    const placed = [];
    for (const {text, point, important} of labels) {
      context.font = `${important ? 600 : 500} ${important ? 12 : coords.z >= 12 ? 10 : 11}px system-ui, -apple-system, sans-serif`;
      const half = context.measureText(text).width / 2 + 3;
      const left = point.x - half, right = point.x + half;
      if (left < 0 || right > TILE_SIZE || placed.some(box => Math.abs(box.y - point.y) < 14 &&
          box.right > left && box.left < right)) continue;
      drawLabel(context, text, point, coords.z, important);
      placed.push({left, right, y:point.y});
      if (placed.length >= 32) break;
    }
  }

  async function templateFor(source) {
    if (source.tileTemplate) return source.tileTemplate;
    if (!templates.has(source.metadata)) {
      templates.set(source.metadata, fetch(source.metadata, { cache: "no-cache" })
        .then(response => {
          if (!response.ok) throw new Error(`矢量底图元数据 HTTP ${response.status}`);
          return response.json();
        })
        .then(info => {
          const template = info.tiles?.[0];
          if (!template?.startsWith("https://tiles.openfreemap.org/") ||
              !["{z}", "{x}", "{y}"].every(token => template.includes(token))) {
            throw new Error("OpenFreeMap 没有返回有效的瓦片地址");
          }
          return template;
        })
        .catch(error => {
          templates.delete(source.metadata);
          throw error;
        }));
    }
    return templates.get(source.metadata);
  }

  async function fetchTile(url, signal) {
    for (let attempt = 0; ; attempt++) {
      try {
        const response = await fetch(url, {signal, cache:attempt ? "reload" : "default"});
        if (!response.ok) {
          const error = new Error(`HTTP ${response.status}`);
          error.transient = response.status === 408 || response.status >= 500;
          throw error;
        }
        return await response.arrayBuffer();
      } catch (error) {
        if (attempt || signal.aborted || globalThis.navigator?.onLine === false ||
            !(error instanceof TypeError || error.transient)) throw error;
        await new Promise(resolve => setTimeout(resolve, 400));
        signal.throwIfAborted();
      }
    }
  }

  // Children above Z14 share their parent's request and decoded geometry.
  // Keep a small in-memory cache per provider. Unloading the last waiting
  // tile aborts the request if it is still in flight.
  function tileStore(source) {
    const ready = new Map(), pending = new Map();
    return function acquire(z, x, y) {
      const key = `${z}/${x}/${y}`;
      if (ready.has(key)) {
        const tile = ready.get(key);
        ready.delete(key);
        ready.set(key, tile);
        return {promise: Promise.resolve(tile), release() {}};
      }
      let request = pending.get(key);
      if (!request) {
        const controller = new AbortController();
        request = {controller, users:0};
        pending.set(key, request);
        request.promise = (async () => {
          const template = await templateFor(source);
          const url = template.replace("{z}", z).replace("{x}", x).replace("{y}", y);
          const buffer = await fetchTile(url, controller.signal);
          controller.signal.throwIfAborted();
          const tile = decodeTile(buffer);
          ready.set(key, tile);
          if (ready.size > 24) ready.delete(ready.keys().next().value);
          return tile;
        })().finally(() => { if (pending.get(key) === request) pending.delete(key); });
      }
      request.users++;
      return {
        promise:request.promise,
        release() {
          if (--request.users === 0 && pending.get(key) === request) {
            pending.delete(key);
            request.controller.abort();
          }
        }
      };
    };
  }

  function create(sourceID) {
    const source = sources[sourceID], acquire = tileStore(source);
    const Grid = L.GridLayer.extend({
      createTile(coords, done) {
        const canvas = document.createElement("canvas");
        const pixelRatio = Math.min(2, window.devicePixelRatio || 1);
        canvas.width = canvas.height = Math.round(TILE_SIZE * pixelRatio);
        canvas.getContext("2d").scale(canvas.width / TILE_SIZE, canvas.height / TILE_SIZE);
        const z = Math.min(coords.z, MAX_NATIVE_ZOOM);
        const scale = 2 ** (coords.z - z);
        const request = acquire(z, Math.floor(coords.x / scale), Math.floor(coords.y / scale));
        let unloaded = false;
        canvas.abortTile = () => {
          if (unloaded) return;
          unloaded = true;
          request.release();
        };
        request.promise.then(tile => { if (!unloaded) drawTile(canvas, tile, coords, scale); })
          .then(() => { if (!unloaded) done(null, canvas); }, error => { if (!unloaded) done(error, canvas); });
        return canvas;
      }
    });
    const layer = new Grid({
      pane: "vectorBasemap",
      minZoom: 2,
      maxZoom: 19,
      keepBuffer: 2,
      updateWhenIdle: true,
      attribution: source.attribution
    });
    const missing = new Map();
    const warning = document.getElementById("baseLayerWarning");
    function updateWarning() {
      warning.hidden = !missing.size;
      warning.title = missing.values().next().value || "";
      warning.textContent = missing.size ? `${source.title} 底图部分未加载，可在「图层」切换来源` : "";
    }
    layer.on("tileerror", ({tile, error}) => { missing.set(tile, error.message); updateWarning(); });
    layer.on("tileunload", ({tile}) => {
      tile.abortTile();
      if (missing.delete(tile)) updateWarning();
    });
    layer.on("remove", () => { missing.clear(); updateWarning(); });
    return layer;
  }

  function setTheme(isDark, selected, map) {
    if (darkTheme === isDark) return;
    darkTheme = isDark;
    if (selected?.options.pane === "vectorBasemap" && map.hasLayer(selected)) selected.redraw();
  }

  return { create, setTheme, openFreeMapAttribution: sources.openfreemap.attribution };
})();
