import {pathToFileURL} from "node:url";

// Only public-transport geometry and potential indoor pedestrian links, never complete city maps.
const windows = {
  beijing:  [39.65,115.97,40.25,116.82],
  jinan:    [36.45,116.73,37.02,117.38],
  qingdao:  [35.88,119.90,36.39,120.70],
  shenzhen: [22.44,113.79,22.79,114.39],
  shanghai: [30.95,121.13,31.43,121.82],
  guangzhou:[22.89,113.10,23.36,113.53]
};

export function cityRequest(city) {
  const accessOnly = city.endsWith("-access");
  const box = windows[accessOnly ? city.slice(0, -7) : city];
  if (!box) throw Error(`Unknown station extract: ${city}`);
  const [south,west,north,east] = box;
  if (accessOnly) {
    const query = `[out:json][timeout:45][bbox:${box.join(",")}];` +
      `(wr[building=train_station];wr[railway=station];)->.term;` +
      `(way.term;way(r.term:"outer");)->.walls;` +
      `(node(w.walls)[entrance];node[railway=train_station_entrance];` +
      `node[name~"[进進出]站口"][entrance];node[name~"[进進出]站口"][barrier=gate];);out body;` +
      `.term out geom;.walls out geom;`;
    return {bounds:[west,south,east,north],query,url:"https://ovp.dresel.systems/api-as/interpreter"};
  }
  const selectors = [
    'node[railway~"^(station|halt|subway_entrance|tram_stop)$"]',
    'node[public_transport="stop_position"][subway=yes]',
    'wr[railway~"^(station|halt)$"]', 'wr[building=train_station]',
    'wr[public_transport=station][subway=yes]',
    'nwr[railway~"^(platform|platform_edge|concourse)$"]',
    'nwr[public_transport=platform][subway=yes]', 'nwr[public_transport=platform][tram=yes]',
    'nwr[public_transport=platform][light_rail=yes]', 'wr[public_transport=concourse]',
    'wr["area:railway"~"^(platform|concourse)$"]', 'wr["railway:area"~"^(platform|concourse)$"]',
    'wr[room~"^(concourse|hall|ticket_hall|station_hall|entrance_hall)$"]',
    'wr[name~"站[厅廳]|穿堂層|[换換转轉]乘(通道|走廊)"]',
    'wr[indoor~"^(area|corridor)$"]', 'way[highway=corridor]', 'way[footway=corridor]',
    'way[highway~"^(footway|steps|pedestrian)$"][tunnel]',
    'way[highway~"^(footway|steps|pedestrian)$"][indoor]',
    'way[highway~"^(footway|steps|pedestrian)$"][location=underground]',
    'way[highway~"^(footway|steps|pedestrian)$"][level~"(^|;)-"]'
  ];
  const query = `[out:json][timeout:45][bbox:${box.join(",")}];(${selectors.map(s=>s+";").join("")});out geom;`;
  return {bounds:[west,south,east,north], query, url:"https://ovp.dresel.systems/api-as/interpreter"};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  process.stdout.write(cityRequest(process.argv[2]).query);
