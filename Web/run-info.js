/* Timetable minutes are measured from midnight on the train's originating date. */
const RailRunInfo = (() => {
  const metrics = new WeakMap();
  const available = value => typeof value === "number" && Number.isFinite(value);
  const minutes = (seconds, end) => Math.max(0, Math.ceil((end * 60 - seconds) / 60));

  function distances(route) {
    if (metrics.has(route)) return metrics.get(route);
    const totals = [0];
    for (const leg of route.legs) {
      let length = 0;
      for (let i = 1; i < leg.length; i++) length += L.CRS.Earth.distance(L.latLng(leg[i - 1]), L.latLng(leg[i]));
      totals.push(totals.at(-1) + length);
    }
    metrics.set(route, totals);
    return totals;
  }

  function position(stops, seconds) {
    if (!stops?.length || !Number.isFinite(seconds)) return null;
    const first = stops[0], last = stops.at(-1);
    if (available(first.departure) && seconds < first.departure * 60) return {phase: "waiting", i: 0};
    if (available(last.arrival) && seconds >= last.arrival * 60) return {phase: "arrived", i: stops.length - 1};
    for (let i = 0; i < stops.length; i++) {
      const {arrival, departure} = stops[i], end = stops[i + 1]?.arrival;
      if (available(arrival) && available(departure) && seconds >= arrival * 60 && seconds < departure * 60)
        return {phase: "dwelling", i};
      if (available(departure) && available(end) && seconds >= departure * 60 && seconds < end * 60)
        return {phase: "running", i, fraction: (seconds / 60 - departure) / (end - departure)};
    }
    return null;
  }

  function describe(route, seconds) {
    const p = position(route?.stops, seconds);
    if (!p) return {phase: "时刻未覆盖", detail: ""};
    const {i, phase} = p, stop = route.stops[i], next = route.stops[i + 1];
    const running = phase === "running";
    const label = running ? `${stop.name} → ${next.name}` :
      `${({arrived:"已抵达", waiting:"待发", dwelling:"停靠"})[phase]} · ${stop.name}`;
    const items = [];
    if (next && available(next.arrival)) items.push(`下一站 ${next.name} ${StationCatalog.clock(next.arrival)}（${minutes(seconds, next.arrival)} 分后）`);
    if (phase === "dwelling") items.push(`本站还停 ${minutes(seconds, stop.departure)} 分`);
    if (route.geometryAvailable) {
      const totals = distances(route);
      const length = next ? (totals[i + 1] - totals[i]) / 1000 : 0;
      items.push(`已行 ${(totals[i] / 1000 + length * (p.fraction || 0)).toFixed(1)} km`);
      const speed = running ? length * 60 / (next.arrival - stop.departure) : 0;
      items.push(`模拟 ${Math.round(speed)} km/h`);
    }
    const firstDeparture = route.stops[0].departure, end = route.stops.at(-1).arrival;
    if (available(firstDeparture)) items.push(`已用 ${Math.max(0, Math.floor(seconds / 60 - firstDeparture))} 分`);
    if (available(end)) items.push(`终到 ${StationCatalog.clock(end)}`);
    const plan = route.routing;
    if (next && plan?.stopIndices?.length === route.stops.length) {
      const names = [...new Set(plan.edges.slice(plan.stopIndices[i], plan.stopIndices[i + 1]).map(e => e.lineName).filter(Boolean))];
      if (names.length) items.push(names.join(" / "));
    }
    return {phase: label, detail: items.join(" · ")};
  }
  return {position, describe};
})();
