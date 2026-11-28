const WorldRail = (() => {
  const editions = new Map();
  const credit = '<a href="https://www.naturalearthdata.com/downloads/10m-cultural-vectors/railroads/">Natural Earth</a> · <a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors</a>';
  const tags = {railway:"rail", source:"Natural Earth · 1:10m"};
  const speedBands = ["below160","speed160","speed200","speed250","speed300","speed350"];

  function edition(zoom, type = "world") {
    const key = `${type}-z${zoom}`;
    if (!editions.has(key)) {
      editions.set(key, loadJSON(`./data/rail/${key}.json`).catch(error => {
        editions.delete(key);
        throw error;
      }));
    }
    return editions.get(key);
  }

  function visible(category, z) {
    return $("showRail").checked && AtlasPrefs.visible({network:"railway",category}, z, {overview:true});
  }

  function enabled(z) {
    return ["unknown", ...speedBands].some(category => visible(category, z));
  }

  function create(map, regionalTiles, style) {
    const size = 256;
    function paint(canvas) {
      const {data, coords} = canvas;
      if (!data) return;
      const {x, y, z} = coords;
      const side = 2 ** z, wrappedX = ((x % side) + side) % side;
      const scale = 2 ** (z - data.zoom);
      const key = `${Math.floor(wrappedX/scale)}/${Math.floor(y/scale)}`;
      const left = (wrappedX % scale) * size, top = (y % scale) * size;
      const ctx = canvas.getContext("2d");
      ctx.clearRect(0, 0, size, size);
      function makePath(lines, extent) {
        const path = new Path2D(), units = size * scale / extent;
        for (const line of lines) {
          path.moveTo(line[0]*units-left, line[1]*units-top);
          for (let i=2; i<line.length; i+=2) path.lineTo(line[i]*units-left, line[i+1]*units-top);
        }
        return path;
      }
      // These regional Z4 tiles have more accurate geometry and speed colours.
      // They are Leaflet overlays in the original world copy only.
      const clip = new Path2D();
      clip.rect(0, 0, size, size);
      if (x === wrappedX) {
        const span = size * 2 ** (z - 4);
        for (const [rx, ry] of regionalTiles) {
          const dx = rx*span - x*size, dy = ry*span - y*size;
          if (dx < size && dy < size && dx+span > 0 && dy+span > 0) clip.rect(dx, dy, span, span);
        }
      }
      canvas.railClip = clip;
      const drawing = makePath(data.tiles[key] || [], data.extent);
      const bands = canvas.speeds?.tiles[key];
      canvas.bandPaths = new Map();
      const visual = style(tags, true, false, z);
      ctx.save();
      ctx.clip(clip, "evenodd");
      ctx.lineJoin = ctx.lineCap = "round";
      const width = visual.weight * (z <= 3 ? .85 : .98);
      if (visible("unknown", z)) {
        canvas.bandPaths.set("unknown", drawing);
        ctx.strokeStyle = AtlasPrefs.categories.unknown[1];
        ctx.lineWidth = width;
        ctx.stroke(drawing);
      }
      if (bands) {
        const paths = speedBands.filter(category => bands[category]).map(category =>
          [category, makePath(bands[category], canvas.speeds.extent)]);
        // Clear generalized gray under all recorded limits, even filtered ones.
        // Colour only the actual OSM geometry. Never transfer a limit to a nearby branch.
        const mask = new Path2D();
        for (const [, path] of paths) mask.addPath(path);
        canvas.speedMask = mask;
        ctx.globalCompositeOperation = "destination-out";
        ctx.lineWidth = width + 1.8;
        ctx.stroke(mask);
        ctx.globalCompositeOperation = "source-over";
        ctx.lineWidth = width;
        for (const [category, path] of paths) {
          if (!visible(category, z)) continue;
          ctx.strokeStyle = AtlasPrefs.categories[category][1];
          ctx.stroke(path);
          canvas.bandPaths.set(category, path);
        }
      }
      ctx.restore();
    }
    const Grid = L.GridLayer.extend({
      // Keep the display copy for masking. Source coordinates wrap in paint().
      _wrapCoords(coords) { return coords; },
      createTile(coords, done) {
        const canvas = document.createElement("canvas"), dpr = Math.min(2, devicePixelRatio || 1);
        canvas.width = canvas.height = size * dpr;
        canvas.getContext("2d").scale(dpr, dpr);
        canvas.coords = coords;
        const level = coords.z < 4 ? 2 : coords.z < 6 ? 4 : 6;
        const source = level === 2 ? edition(2) : edition(level).catch(() => edition(2));
        source.then(data => {
          canvas.data = data;
          paint(canvas);
          done(null, canvas);
          edition(data.zoom,"speed").then(speeds => {
            canvas.speeds = speeds;
            paint(canvas);
          }).catch(() => {}); // The public-domain overview is still usable on its own.
        }, error => done(error, canvas));
        return canvas;
      }
    });
    const grid = new Grid({pane:"worldRail", minZoom:2, maxZoom:9, keepBuffer:1, attribution:credit});
    grid.repaint = () => Object.values(grid._tiles || {}).forEach(tile => paint(tile.el));
    grid.showDetail = (coords, ready) => {
      const canvas = grid._tiles?.[`${coords.x}:${coords.y}:${coords.z}`]?.el;
      if (canvas) canvas.style.visibility = ready ? "hidden" : "";
    };
    return grid;
  }
  return {create, enabled};
})();
