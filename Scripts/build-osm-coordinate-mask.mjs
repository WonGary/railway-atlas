// Reproducible WGS84 display mask from OSM administrative geometry (ODbL).
// Inputs: polygons.openstreetmap.fr/get_geojson.py?id=270056|913110|1867188&params=0
// Keep full precision: simplifying a national border moves nearby railway points.
import fs from 'node:fs';
const [chinaPath, hongKongPath, macaoPath, output] = process.argv.slice(2);
if (!output) throw Error('Usage: node build-osm-coordinate-mask.mjs CHN.json HK.json MO.json OUTPUT.json');
function polygons(path) {
  const geometry = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (geometry.type !== 'MultiPolygon') throw Error(`Invalid geometry: ${path}`);
  for (const polygon of geometry.coordinates) for (const ring of polygon) {
    if (ring.length < 4 || ring.some(p => p.length !== 2 || !p.every(Number.isFinite))) {
      throw Error(`Invalid ring: ${path}`);
    }
  }
  return geometry.coordinates;
}
const data = { include: polygons(chinaPath), exclude: [...polygons(hongKongPath), ...polygons(macaoPath)] };
fs.writeFileSync(output, JSON.stringify(data) + '\n');
console.log(`WGS84 mask: ${data.include.length} included and ${data.exclude.length} excluded polygons.`);
