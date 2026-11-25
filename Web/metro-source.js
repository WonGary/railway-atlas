// Shared with the native client (JavaScriptCore) and the city pack builder.
globalThis.MetroSource = (() => {
  const modes = new Set(["subway", "tram", "monorail", "light_rail"]);
  const point = p => p && Number.isFinite(p.lat) && Number.isFinite(p.lon) &&
    Math.abs(p.lat) <= 85.1 && Math.abs(p.lon) <= 180 ? [p.lon, p.lat] : null;
  const objectID = m => `${m.type}/${m.ref ?? m.id}`;
  function cell(lat, lon) {
    if (!Number.isFinite(lat) || Math.abs(lat) > 85 || !Number.isFinite(lon)) return null;
    const y = Math.floor(lat * 4), x = Math.floor((((lon + 180) % 360 + 360) % 360 - 180) * 4);
    return {id:`area-${y}_${x}`, name:`地图区域 ${((y+.5)/4).toFixed(2)}°, ${((x+.5)/4).toFixed(2)}°`,
      bounds:[y/4, x/4, (y+1)/4, (x+1)/4]};
  }
  function endpoints(bounds) {
    const [s,w,n,e] = bounds, lat = (s+n)/2, lon = (w+e)/2;
    let region = "api";
    if (lon < -30) region = lat < 13 ? "api-sa" : "api-na";
    else if (lon > 60) region = lat < -10 && lon > 95 ? "api-oc" : "api-as";
    else if (lat < 35) region = "api-af";
    return [`https://ovp.dresel.systems/${region}/interpreter`, "https://overpass-api.de/api/interpreter",
      "https://overpass.private.coffee/api/interpreter"];
  }
  const memberQuery = "(node(r.r);way(r.r)[public_transport=platform];rel(r.r)[public_transport=platform];);out center;";
  function query(bounds) {
    if (!Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isFinite)) throw Error("查询范围无效");
    return `[out:json][timeout:35];rel[route~"^(subway|tram|monorail|light_rail)$"](${bounds.map(x=>x.toFixed(4)).join(",")})->.r;.r out geom;${memberQuery}`;
  }
  function convert(city, response) {
    if (response.remark || !Array.isArray(response.elements) || !response.osm3s?.timestamp_osm_base)
      throw Error("地图源返回的线路资料不完整");
    const objects = new Map(response.elements.map(e=>[objectID(e),e]));
    const routes = [], stations = new Map();
    for (const relation of response.elements) {
      const tags = relation.tags;
      if (relation.type !== "relation" || !modes.has(tags?.route) || !Array.isArray(relation.members)) continue;
      const parts = [], calls = [], platforms = [];
      let missingStops = 0;
      for (const member of relation.members) {
        const role = member.role || "", obj = objects.get(objectID(member));
        if (/^(stop|platform)(_|$)/.test(role) || (member.type === "node" && !role && obj?.tags?.railway === "tram_stop")) {
          const name = obj?.tags?.["name:zh-Hans"] || obj?.tags?.["name:zh"] || obj?.tags?.name || obj?.tags?.ref;
          const coordinate = point(obj) || point(obj?.center) || point(member);
          if (name && coordinate) (role.startsWith("platform") ? platforms : calls).push({id:objectID(member),name,coordinate,role});
          else if (!role.startsWith("platform")) missingStops++;
        } else if (member.type === "way" && ["","forward","backward","route"].includes(role)) {
          let path = [];
          for (const vertex of member.geometry || obj?.geometry || []) {
            const pair = point(vertex);
            if (pair) path.push(pair);
            else { if (path.length > 1) parts.push(path); path = []; }
          }
          if (path.length > 1) parts.push(path);
        }
      }
      // PTv2 may declare both stops and platforms. Keep the chosen member order,
      // including return visits to a station on loops.
      const stops = calls.length ? calls : platforms;
      if (!parts.length && !stops.length) continue;
      const id = objectID(relation), color = /^#[\da-f]{3}(?:[\da-f]{3})?$/i.test(tags.colour || "") ? tags.colour : "";
      const route = {id, name:tags["name:zh-Hans"] || tags["name:zh"] || tags.name || tags.ref || id,
        ref:tags.ref || "", color, type:tags.route, from:tags.from || "", to:tags.to || "",
        network:tags.network || "", operator:tags.operator || "", openingDate:tags.opening_date || "",
        tags:{construction:tags.construction || "",status:tags.status || ""}, stops, parts};
      if (missingStops || stops.length < 2) {
        route.stopCoverage = "partial";
        route.stopNote = missingStops ? `${missingStops} 个停站成员缺少名称或坐标` : (stops.length ? "只收录一个站" : "没有站序");
      }
      routes.push(route);
      for (const stop of stops) {
        if (!stations.has(stop.id)) stations.set(stop.id,{id:stop.id, name:stop.name, coordinate:stop.coordinate, routes:[]});
        const refs = stations.get(stop.id).routes;
        if (!refs.some(r=>r.id === id)) refs.push({id,name:route.name,ref:route.ref,color,city:city.name});
      }
    }
    return {version:1,id:city.id,name:city.name,bounds:city.bounds,source:"https://www.openstreetmap.org/",
      sourceDate:response.osm3s.timestamp_osm_base.slice(0,10),license:"ODbL-1.0",copyright:"OpenStreetMap contributors",
      routes,stations:[...stations.values()]};
  }
  return {cell,query,memberQuery,endpoints,convert};
})();
