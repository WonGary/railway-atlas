const WorldRail = (() => {
  const editions = new Map();
  const credit = '<a href="https://www.naturalearthdata.com/downloads/10m-cultural-vectors/railroads/">Natural Earth</a>';
  const tags = {railway:"rail", source:"Natural Earth · 1:10m"};

  function edition(zoom) {
    if (!editions.has(zoom)) {
      editions.set(zoom, loadJSON(`./data/rail/world-z${zoom}.json`).catch(error => {
        editions.delete(zoom);
        throw error;
      }));
    }
    return editions.get(zoom);
  }

  function create(map, regionalTiles, style, inspect) {
    const size = 256;
    function paint(canvas) {
      const {data, coords} = canvas;
      if (!data) return;
      const {x, y, z} = coords;
      const side = 2 ** z, wrappedX = ((x % side) + side) % side;
      const scale = 2 ** (z - data.zoom);
      const paths = data.tiles[`${Math.floor(wrappedX/scale)}/${Math.floor(y/scale)}`] || [];
      const left = (wrappedX % scale) * size, top = (y % scale) * size;
      const units = size * scale / data.extent;
      const ctx = canvas.getContext("2d");
      ctx.clearRect(0, 0, size, size);
      const drawing = new Path2D();
      canvas.railPath = drawing;
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
      for (const path of paths) {
        drawing.moveTo(path[0]*units-left, path[1]*units-top);
        for (let i=2; i<path.length; i+=2) drawing.lineTo(path[i]*units-left, path[i+1]*units-top);
      }
      const visual = style(tags, true, false, z);
      ctx.save();
      ctx.clip(clip, "evenodd");
      ctx.strokeStyle = map.getContainer().dataset.stationInk === "light" ? "#b6c6d1" : "#495b68";
      ctx.globalAlpha = z <= 3 ? .87 : .94;
      ctx.lineWidth = visual.weight * (z <= 3 ? .82 : .94);
      ctx.lineJoin = ctx.lineCap = "round";
      ctx.stroke(drawing);
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
        }, error => done(error, canvas));
        return canvas;
      }
    });
    const grid = new Grid({pane:"worldRail", minZoom:2, maxZoom:9, keepBuffer:1, attribution:credit});
    map.on("click", event => {
      if (!map.hasLayer(grid) || event.sourceTarget !== map) return;
      const z = Math.round(map.getZoom()), p = map.project(event.latlng, z);
      const x = Math.floor(p.x/size), y = Math.floor(p.y/size);
      const canvas = grid._tiles[`${x}:${y}:${z}`]?.el;
      if (!canvas?.railPath || canvas.style.visibility === "hidden") return;
      const ctx = canvas.getContext("2d"), px = p.x-x*size, py = p.y-y*size;
      ctx.save();
      ctx.resetTransform();
      ctx.lineWidth = 7;
      const hit = ctx.isPointInPath(canvas.railClip, px, py, "evenodd") && ctx.isPointInStroke(canvas.railPath, px, py);
      ctx.restore();
      if (hit) inspect("全球铁路干线 · Natural Earth", tags, false, event.latlng);
    });
    grid.repaint = () => Object.values(grid._tiles || {}).forEach(tile => paint(tile.el));
    grid.showDetail = (coords, ready) => {
      const canvas = grid._tiles?.[`${coords.x}:${coords.y}:${coords.z}`]?.el;
      if (canvas) canvas.style.visibility = ready ? "hidden" : "";
    };
    return grid;
  }
  return {create, tags};
})();
