// One decision per pointer sequence, across Leaflet SVG, Canvas and rail tiles.
const MapHit = (() => {
  let map;
  const layers = new Set(), providers = [];
  const detailZoom = 11;
  const trackRadius = (zoom, touch) => zoom < detailZoom ? 0 : (zoom < 14 ? 3.5 : 4.5) + (touch ? 2 : 0);
  const dotPadding = (zoom, touch) => (zoom < detailZoom ? 1 : 2) + (touch ? 2 : 0);

  function bind(layer, open, options = {}) {
    const entry = {layer, open, ...options};
    const add = () => layers.add(entry), remove = () => layers.delete(entry);
    layer.on({add, remove});
    if (map?.hasLayer(layer)) add();
    return () => { remove(); layer.off({add, remove}); };
  }

  function insideRings(point, parts) {
    let inside = false;
    for (const ring of parts) for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const a = ring[i], b = ring[j];
      if ((a.y > point.y) !== (b.y > point.y) && point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x) inside = !inside;
    }
    return inside;
  }

  function pick(containerPoint, touch) {
    const zoom = map.getZoom(), point = map.containerPointToLayerPoint(containerPoint);
    const latlng = map.containerPointToLatLng(containerPoint), detail = zoom >= detailZoom;
    const history = map.getContainer().classList.contains("atlas-history-map");
    const focused = !!LineFocus.active && !history;
    const radius = trackRadius(zoom, touch), padding = dotPadding(zoom, touch);
    let winner;
    function offer(rank, distance, open) {
      if (!winner || rank < winner.rank || (rank === winner.rank && distance < winner.distance)) {
        winner = {rank, distance, open};
      }
    }
    if (!history) StationLabels.pickLabel(containerPoint, focused && !detail, offer);
    for (const entry of layers) {
      const {layer, open} = entry;
      if (history !== !!entry.history) continue;
      const choose = () => open({latlng: layer.getLatLng?.() || latlng, containerPoint});
      if (layer instanceof L.CircleMarker) {
        const symbol = layer.getRadius();
        const label = StationLabels.hasSteadyLabel(layer);
        if (!detail && ((focused && !entry.focused) || !(label || ((entry.important || entry.focused) && symbol >= 3)))) continue;
        const distance = point.distanceTo(layer._point);
        if (distance <= symbol + padding) offer(entry.focused ? 0 : 1, distance, choose);
      } else if (detail && layer instanceof L.Marker) {
        const rect = layer.getElement()?.getBoundingClientRect();
        if (!rect) continue;
        const anchor = map.getContainer().getBoundingClientRect();
        const x = anchor.left + containerPoint.x, y = anchor.top + containerPoint.y;
        if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) offer(0, 0, choose);
      } else if (detail && layer._parts?.length) {
        const bounds = layer._pxBounds;
        if (!bounds || point.x < bounds.min.x-radius || point.x > bounds.max.x+radius ||
            point.y < bounds.min.y-radius || point.y > bounds.max.y+radius) continue;
        if (layer instanceof L.Polygon) {
          if (insideRings(point, layer._parts)) offer(4, bounds.getSize().x*bounds.getSize().y, choose);
        } else {
          const nearest = layer.closestLayerPoint(point);
          if (nearest && nearest.distance <= radius) offer(3, nearest.distance, choose);
        }
      }
    }
    if (!history) for (const provide of providers) provide({latlng, zoom, detail, focused, radius, padding, offer});
    if (winner) winner.open();
    else if (!history) LineFocus.clear();
  }

  function setup(target) {
    map = target;
    const el = map.getContainer(), contacts = new Set();
    let press, released, pending, moving = false;
    const cancel = () => { if (press) press.cancelled = true; released = null; clearTimeout(pending); };
    const control = node => node.closest?.(".leaflet-control,.leaflet-popup,button,input,select,a");
    const listen = (element, type, fn) => element.addEventListener(type, fn, {capture:true, passive:true});
    // Track the furthest excursion, not just the difference between down and up.
    listen(el, "pointerdown", e => {
      clearTimeout(pending);
      contacts.add(e.pointerId);
      if (contacts.size > 1 || !e.isPrimary || e.button !== 0 || control(e.target)) { cancel(); return; }
      released = null;
      press = {id:e.pointerId, x:e.clientX, y:e.clientY, touch:e.pointerType === "touch", cancelled:moving};
    });
    function moved(e) {
      if (press?.id === e.pointerId && Math.hypot(e.clientX-press.x,e.clientY-press.y) >= (press.touch ? 5 : 3)) cancel();
    }
    listen(window, "pointermove", moved);
    listen(window, "pointerup", e => {
      contacts.delete(e.pointerId);
      if (press?.id !== e.pointerId) return;
      moved(e);
      released = press.cancelled ? null : press;
      press = null;
    });
    listen(window, "pointercancel", e => { contacts.delete(e.pointerId); cancel(); });
    listen(window, "blur", e => {
      if (e.target === window) { contacts.clear(); press = null; cancel(); }
    });
    listen(el, "wheel", cancel);
    listen(el, "contextmenu", cancel);
    listen(el, "dblclick", cancel);
    map.on("movestart zoomstart dragstart", () => { moving = true; cancel(); });
    map.on("moveend", () => { moving = false; });
    listen(el, "click", e => {
      if (control(e.target) || !released || e.detail > 1 || moving) return;
      const {touch} = released;
      released = null;
      const point = map.mouseEventToContainerPoint(e);
      // Leave the second press of a double-click/tap available to Leaflet zoom.
      pending = setTimeout(() => pick(point, touch), 400);
    });
    // Leaflet clients can also request a geographic pick without a DOM event.
    map.on("click", e => {
      if (!(e.originalEvent instanceof Event) && e.latlng) pick(map.latLngToContainerPoint(e.latlng), false);
    });
  }
  return {setup, bind, addProvider: fn => providers.push(fn)};
})();
