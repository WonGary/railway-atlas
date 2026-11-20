// Natural Earth public-domain country polygons, downloaded separately.
// This generated resource is a display-coordinate mask, not a political map.
import fs from 'node:fs';
const source = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const feature = source.features.find(f => f.properties.ADM0_A3 === 'CHN');
if (!feature || feature.geometry.type !== 'MultiPolygon') throw Error('Missing CHN geometry');
const coordinates = feature.geometry.coordinates.map(polygon =>
  polygon.map(ring => ring.map(point => point.map(value => Number(value.toFixed(6))))));
fs.mkdirSync('Sources/RailwayCore/Resources', { recursive: true });
fs.writeFileSync('Sources/RailwayCore/Resources/mainland-mask.json', JSON.stringify(coordinates));
console.log(`Generated ${coordinates.length} polygons. HK, Macao and Taiwan use separate country features.`);
