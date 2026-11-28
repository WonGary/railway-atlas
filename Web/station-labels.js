// Station names share one screen-space layout across markers and vector tiles.
const StationLabels = (() => {
  const markers = new Set(), byMarker = new WeakMap(), shown = new Map();
  const measure = document.createElement("canvas").getContext("2d");
  let map, tileCandidates, hovered, frame;

  function prominent(tags = {}, routes = []) {
    const rank = tags["railway:station_category"] || tags["station:class"] || tags["railway:station_class"];
    return tags.interchange === "yes" || tags.transfer === "yes" || tags["atlas:railConnection"] === "yes" ||
      tags.highspeed === "yes" || tags["railway:station:importance"] === "major" || tags.station_size === "large" ||
      ["特等站","一等站","特等","一等","0","1"].includes(String(rank)) ||
      new Set(routes.map(r => r.tags?.["atlas:routeMaster"] || r.ref || r.tags?.ref || r.id).filter(Boolean)).size > 1;
  }

  function schedule() {
    if (map && !frame) frame = requestAnimationFrame(layout);
  }

  function bind(marker, name, {id = name, important = false, minZoom = Infinity, selected, focused=false, open} = {}) {
    if (!name) return marker;
    const station = {marker, name: String(name), id, important, minZoom, selected, focused, open};
    byMarker.set(marker, station);
    if (open) MapHit.bind(marker, open, {important, focused});
    const add = () => { markers.add(station); schedule(); };
    marker.on({
      add,
      remove() {
        markers.delete(station);
        if (hovered === station) hovered = null;
        schedule();
      },
      mouseover() { hovered = station; schedule(); },
      mouseout() { if (hovered === station) hovered = null; schedule(); }
    });
    if (map?.hasLayer(marker)) add();
    return marker;
  }

  function show(station, latlng, direction, gap, kind) {
    const offset = direction === "right" ? gap : -gap;
    const className = `station-label station-label-${kind}`;
    let tip = shown.get(station);
    if (tip && map.hasLayer(tip) && tip.options.direction === direction && tip.options.offset.x === offset && tip.options.className === className) return;
    tip?.remove();
    const text = document.createElement("span");
    text.textContent = station.name;
    tip = L.tooltip({direction, offset: L.point(offset, 0), className, opacity: 1, interactive: false, permanent: true})
      .setContent(text).setLatLng(latlng).addTo(map);
    shown.set(station, tip);
  }

  function layout() {
    frame = null;
    const {showsLabels, uiScale} = AtlasPrefs.value;
    const zoom = map.getZoom(), size = map.getSize();
    const candidates = [];
    function collect(station) {
      const isHover = station === hovered, selected = station.selected?.();
      if (!isHover && !(showsLabels && zoom >= station.minZoom)) return;
      const latlng = station.marker?.getLatLng() || station.latlng;
      const {x,y} = map.latLngToContainerPoint(latlng);
      if (x < 0 || y < 0 || x > size.x || y > size.y) return;
      const kind = station.focused ? "focus" : selected ? "selected" : station.important ? "major" : "regular";
      candidates.push({station, latlng, x, y, kind, priority: station.focused ? 4 : isHover ? 3 : selected ? 2 : station.important ? 1 : 0});
    }
    markers.forEach(collect);
    if (showsLabels && zoom >= 12) tileCandidates(collect);
    candidates.sort((a,b) => b.priority - a.priority || Number(!!b.station.marker) - Number(!!a.station.marker) ||
      String(a.station.id).localeCompare(String(b.station.id)));

    const accepted = new Set(), occupied = [], byName = new Map();
    const family = getComputedStyle(map.getContainer()).fontFamily;
    for (const {station, latlng, x, y, kind} of candidates) {
      const fontSize = (kind === "regular" ? 12.5 : kind === "major" ? 13 : 14) * uiScale;
      measure.font = `${kind === "regular" ? 500 : 600} ${fontSize}px ${family}`;
      const width = Math.ceil(Math.min(140 * uiScale, measure.measureText(station.name).width));
      const height = Math.ceil(fontSize * 1.3);
      const radius = station.marker?.getRadius() ?? station.radius * 2 ** (zoom - station.tileZoom);
      const gap = Math.ceil(radius + 4 * uiScale);
      const direction = x + gap + width + 2 <= size.x ? "right" : "left";
      const left = direction === "right" ? x + gap : x - gap - width;
      const box = {left: left - 2, right: left + width + 2, top: y - height / 2 - 1, bottom: y + height / 2 + 1};
      if (box.left < 0 || box.top < 0 || box.bottom > size.y) continue;
      // Opposite platforms and overlapping data sources often name the same stop.
      const repeats = byName.get(station.name) || [];
      if (repeats.some(p => Math.hypot(x - p.x, y - p.y) < 55 * uiScale)) continue;
      if (occupied.some(r => box.left < r.right && box.right > r.left && box.top < r.bottom && box.bottom > r.top)) continue;
      occupied.push(box);
      repeats.push({x, y});
      byName.set(station.name, repeats);
      accepted.add(station);
      show(station, latlng, direction, gap, kind);
    }
    for (const [station, tip] of shown) {
      if (!accepted.has(station)) { tip.remove(); shown.delete(station); }
    }
  }

  function setup(target, eachTileStation) {
    map = target;
    tileCandidates = eachTileStation;
    map.on("moveend zoomend resize", schedule);
  }
  function pickLabel(point, focusedOnly, offer) {
    const bounds = map.getContainer().getBoundingClientRect();
    const x = point.x + bounds.left, y = point.y + bounds.top;
    for (const [station, tip] of shown) {
      if (!station.open || !map.hasLayer(tip) || (focusedOnly && !station.focused) || (station.marker && !markers.has(station))) continue;
      const rect = tip.getContent().getBoundingClientRect();
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) offer(0, 0, station.open);
    }
  }
  function hasSteadyLabel(marker) {
    const station = byMarker.get(marker);
    const tip = shown.get(station);
    return !!tip && map.hasLayer(tip) && AtlasPrefs.value.showsLabels && map.getZoom() >= station.minZoom;
  }
  return {setup, bind, prominent, schedule, pickLabel, hasSteadyLabel};
})();
