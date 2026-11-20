#!/usr/bin/env node
// Offline OSM-data conversion; no upstream application code or dependencies.
// Usage: node Scripts/build-national-metro.mjs --input overpass.json
//   --city-reference china_metro.geojson --taiwan-reference taiwan_metro.geojson
//   --output /tmp/national-metro.geojson [--drawable-output /tmp/drawable.geojson]
// The full output retains geometry:null relations. The optional drawable view
// omits only those records, explicitly listed in the adjacent report.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';

const modes = new Map([['subway', '地铁'], ['light_rail', '轻轨'], ['tram', '有轨电车'], ['monorail', '单轨']]);
const trackRoles = new Set(['', 'forward', 'backward', 'route', 'inactive']);
const colourNames = new Set('red green blue yellow orange purple brown pink black white gray grey cyan aqua magenta fuchsia teal navy lime maroon olive silver gold'.split(' '));
const normalize = value => String(value ?? '').normalize('NFKC').trim().toLowerCase().replace(/\s+/g, '');
const validColour = value => typeof value === 'string' &&
  (/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(value.trim()) || colourNames.has(value.trim().toLowerCase()));
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
const identity = element => `relation/${element.id}`;
const sorted = values => [...values].sort();
function add(index, key, city) {
  if (!key || !city) return;
  if (!index.has(key)) index.set(key, new Set());
  index.get(key).add(city);
}
function read(file) {
  const bytes = fs.readFileSync(file);
  return { document: JSON.parse(bytes), sha256: sha256(bytes) };
}
function write(file, bytes) {
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, bytes, { flag: 'wx' });
  fs.renameSync(temporary, file);
}
function taiwanCity(network, ref) {
  if (/新北/.test(network) || (/臺北|台北/.test(network) && ref === 'Y')) return '新北';
  if (/臺北|台北/.test(network)) return '台北';
  if (/桃園|桃园/.test(network)) return '桃园';
  if (/臺中|台中/.test(network)) return '台中';
  if (/高雄|環狀輕軌/.test(network)) return '高雄';
  return '';
}

export function convert(source, cityReference, taiwanReference) {
  assert(!source.remark, `Incomplete Overpass response: ${source.remark}`);
  assert(Array.isArray(source.elements), 'Missing Overpass elements');
  const routes = source.elements.filter(e => e.type === 'relation' && e.tags?.type === 'route' && modes.has(e.tags.route));
  const masters = source.elements.filter(e => e.type === 'relation' && e.tags?.type === 'route_master').sort((a, b) => a.id - b.id);
  const byMaster = new Map(), wayGeometry = new Map(source.elements.filter(e => e.type === 'way').map(e => [e.id, e.geometry]));
  for (const master of masters) for (const member of master.members ?? []) {
    if (member.type !== 'relation') continue;
    if (!byMaster.has(member.ref)) byMaster.set(member.ref, []);
    byMaster.get(member.ref).push(master);
  }
  const referenceIDs = new Map(), taiwanIDs = new Map(), networks = new Map(), cities = new Set();
  for (const [document, index] of [[cityReference, referenceIDs], [taiwanReference, taiwanIDs]]) {
    assert(document.type === 'FeatureCollection' && Array.isArray(document.features), 'Invalid city reference');
    for (const { properties: p } of document.features) {
      if (!p?.city || p.city === '未归档') continue;
      add(index, Number(p.osm_id), p.city);
      add(networks, normalize(p.network), p.city);
      cities.add(p.city);
    }
  }
  const aliases = new Map([...cities].map(city => [normalize(city), city]));
  for (const [name, city] of [['臺北', '台北'], ['臺中', '台中'], ['桃園', '桃园'], ['澳門', '澳门'], ['寧波', '宁波']])
    if (cities.has(city)) aliases.set(normalize(name), city);
  function textCities(text) {
    const value = normalize(text);
    const matches = [...aliases].filter(([alias]) => value.includes(alias));
    // A longer explicit city name wins over its contained substring.
    return new Set(matches.filter(([alias]) => !matches.some(([other]) => other !== alias && other.includes(alias))).map(([, city]) => city));
  }
  function classify(route, parents) {
    for (const [index, label] of [[taiwanIDs, 'taiwan-reference'], [referenceIDs, 'github-reference']]) {
      const found = index.get(route.id);
      if (found) return { city: found.size === 1 ? [...found][0] : '未归档', evidence: `${label}:${identity(route)}` };
    }
    const records = [route, ...parents];
    const networkMatches = new Set();
    for (const record of records) {
      const network = record.tags?.network ?? '';
      const tw = taiwanCity(network, route.tags.ref ?? record.tags?.ref ?? '');
      if (tw) networkMatches.add(tw);
      else {
        for (const city of networks.get(normalize(network)) ?? []) networkMatches.add(city);
        for (const city of textCities(network)) networkMatches.add(city);
      }
    }
    if (networkMatches.size) return { city: networkMatches.size === 1 ? [...networkMatches][0] : '未归档', evidence: `network:${sorted(networkMatches).join('|')}` };
    const names = records.flatMap(r => Object.entries(r.tags ?? {}).filter(([key]) => key === 'name' || key.startsWith('name:')).map(([, value]) => value));
    const nameMatches = new Set(names.flatMap(name => [...textCities(name)]));
    return { city: nameMatches.size === 1 ? [...nameMatches][0] : '未归档',
      evidence: nameMatches.size ? `name:${sorted(nameMatches).join('|')}` : 'no-unambiguous-network-or-name' };
  }
  const seenIDs = new Set(), report = { relations: routes.length, cities: {}, missingGeometry: [], unarchived: [], missingColour: [],
    missingRef: [], nonstandardRoleRoutes: [], inactiveRoleRoutes: [], ignoredWayRoles: {}, points: 0, parts: 0 };
  const features = routes.sort((a, b) => a.id - b.id).map(route => {
    assert(Number.isSafeInteger(route.id) && route.id > 0 && !seenIDs.has(route.id), 'Invalid/duplicate relation ID');
    seenIDs.add(route.id);
    const tags = route.tags, parents = byMaster.get(route.id) ?? [], master = parents[0];
    const value = key => tags[key] ?? master?.tags?.[key] ?? '';
    const grouping = classify(route, parents), parts = [], partMembers = [], ignoredMembers = [];
    for (const [memberIndex, member] of (route.members ?? []).entries()) {
      if (member.type !== 'way') continue;
      const role = member.role ?? '';
      if (!trackRoles.has(role)) {
        report.ignoredWayRoles[role] = (report.ignoredWayRoles[role] ?? 0) + 1;
        ignoredMembers.push({ ref: member.ref, role });
        continue;
      }
      const geometry = member.geometry ?? wayGeometry.get(member.ref);
      assert(Array.isArray(geometry), `Missing way/${member.ref} geometry in ${identity(route)}`);
      let part = [];
      const flush = () => {
        if (part.length > 1) {
          parts.push(part);
          partMembers.push({ way: member.ref, role, memberIndex, partIndex: parts.length - 1 });
        }
        part = [];
      };
      for (const point of geometry) {
        if (point === null) { flush(); continue; }
        assert(point && Number.isFinite(point.lat) && Number.isFinite(point.lon) &&
          Math.abs(point.lat) <= 85 && Math.abs(point.lon) <= 180, `Invalid coordinate: way/${member.ref}`);
        part.push([point.lon, point.lat]);
      }
      flush();
    }
    const directColour = tags.colour ?? tags.color ?? '';
    const masterColour = master?.tags?.colour ?? master?.tags?.color ?? '';
    const colour = validColour(directColour) ? directColour : validColour(masterColour) ? masterColour : directColour;
    const colourSource = validColour(directColour) ? identity(route) : validColour(masterColour) ? identity(master) : '';
    const properties = { ...tags, osm_id: route.id, city: grouping.city,
      network: value('network'), line_name: value('name') || value('name:zh') || value('name:en') || value('ref') || `OSM 线路 ${route.id}`,
      route_type: tags.route, route_type_zh: modes.get(tags.route), operator: value('operator'), ref: value('ref'), colour,
      from_station: value('from'), to_station: value('to'), opening_date: value('start_date') || value('opening_date'),
      wikidata: value('wikidata'), 'atlas:routeMaster': master ? identity(master) : '',
      'atlas:routeMasters': parents.map(identity).join(';'), 'atlas:colourSourceID': colourSource,
      'atlas:citySource': grouping.evidence, 'atlas:geometryMembers': JSON.stringify(partMembers),
      'atlas:ignoredWayMembers': JSON.stringify(ignoredMembers), 'atlas:missingGeometry': parts.length ? 'no' : 'yes' };
    // Preserve original values if a display-schema field inherits or overrides it.
    for (const [key, original] of Object.entries(tags)) {
      assert(typeof original === 'string', `Non-string OSM tag ${key}`);
      if (properties[key] !== original) properties[`atlas:original:${key}`] = original;
    }
    for (const v of Object.values(properties)) assert(['string', 'number', 'boolean'].includes(typeof v), 'Properties must be scalar');
    report.cities[grouping.city] = (report.cities[grouping.city] ?? 0) + 1;
    if (!parts.length) report.missingGeometry.push(route.id);
    if (grouping.city === '未归档') report.unarchived.push({ id: route.id, name: properties.line_name });
    if (!colourSource) report.missingColour.push(route.id);
    if (!properties.ref) report.missingRef.push(route.id);
    if (partMembers.some(m => m.role === 'route')) report.nonstandardRoleRoutes.push(route.id);
    if (partMembers.some(m => m.role === 'inactive')) report.inactiveRoleRoutes.push(route.id);
    report.points += parts.reduce((sum, part) => sum + part.length, 0);
    report.parts += parts.length;
    return { type: 'Feature', properties, geometry: parts.length === 0 ? null : parts.length === 1 ?
      { type: 'LineString', coordinates: parts[0] } : { type: 'MultiLineString', coordinates: parts } };
  });
  report.cityGroups = Object.keys(report.cities).length;
  report.referenceRelationsAbsent = sorted([...referenceIDs.keys()].filter(id => !seenIDs.has(id)));
  report.referenceCityGroupsAbsent = sorted([...cities].filter(city => !report.cities[city]));
  return { document: { type: 'FeatureCollection', features,
    'atlas:osm3s': source.osm3s ?? null, 'atlas:routeMasters': masters,
    'atlas:attribution': '© OpenStreetMap contributors', 'atlas:license': 'https://opendatacommons.org/licenses/odbl/1-0/',
    'atlas:geometryPolicy': 'WGS84 original way vertices; no simplification, joining gaps, geographic city inference, or tourism/lifecycle filtering.' }, report };
}

function selfTest() {
  const reference = { type: 'FeatureCollection', features: [{ properties: { osm_id: 1, city: '北京', network: '北京地铁' } }] };
  const empty = { type: 'FeatureCollection', features: [] };
  const geometry = [{ lat: 1, lon: 2 }, { lat: 2, lon: 3 }, null, { lat: 3, lon: 4 }, { lat: 4, lon: 5 }];
  const r = (id, tags, role = 'route') => ({ type: 'relation', id, tags: { type: 'route', route: 'subway', ...tags },
    members: [{ type: 'way', ref: id + 100, role, geometry }] });
  const source = { elements: [r(1, { ref: '', tourism: 'yes', colour: 'invalid', wikidata: 'Q1', city: 'source-city' }),
    r(2, { network: '北京地铁' }, 'inactive'), r(3, {}), { ...r(4, {}), members: [] },
    { type: 'relation', id: 9, tags: { type: 'route_master', colour: '#123456', ref: 'master-ref', wikidata: 'Q9' }, members: [{ type: 'relation', ref: 1 }] }] };
  const { document, report } = convert(source, reference, empty);
  assert.equal(document.features.length, 4);
  const p = document.features[0].properties;
  assert.equal(p.ref, ''); assert.equal(p.tourism, 'yes'); assert.equal(p.wikidata, 'Q1');
  assert.equal(p['atlas:routeMaster'], 'relation/9'); assert.equal(p['atlas:colourSourceID'], 'relation/9');
  assert.equal(p['atlas:original:colour'], 'invalid'); assert.equal(p['atlas:original:city'], 'source-city');
  assert.equal(document.features[0].geometry.coordinates.length, 2);
  assert.equal(document.features[1].properties.city, '北京');
  assert.equal(document.features[2].properties.city, '未归档'); // Same coordinates cannot assign identity/city.
  assert.equal(document.features[3].geometry, null);
  assert.deepEqual(document['atlas:routeMasters'][0], source.elements[4]);
  assert.deepEqual(report.inactiveRoleRoutes, [2]);
  assert.throws(() => convert({ ...source, remark: 'timeout' }, reference, empty));
  console.log('PASS: scalar tags, source/master colours, empty ref, tourism, route/inactive roles, gaps, unknown city, null geometry, incomplete response.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: {
    input: { type: 'string' }, 'city-reference': { type: 'string' }, 'taiwan-reference': { type: 'string' },
    output: { type: 'string' }, 'drawable-output': { type: 'string' }, 'self-test': { type: 'boolean' }, help: { type: 'boolean' },
  } });
  if (values['self-test']) selfTest();
  else if (values.help) console.log('node Scripts/build-national-metro.mjs --input overpass.json --city-reference china_metro.geojson --taiwan-reference taiwan_metro.geojson --output /tmp/national.geojson [--drawable-output /tmp/drawable.geojson]\nOffline; full output preserves geometry:null. Creates gzip and report alongside output. --self-test runs local regression checks.');
  else {
    for (const key of ['input', 'city-reference', 'taiwan-reference', 'output']) assert(values[key], `Missing --${key}`);
    const inputPaths = ['input', 'city-reference', 'taiwan-reference'].map(key => fs.realpathSync(values[key]));
    const output = path.resolve(values.output);
    const targets = [output, output + '.gz', output + '.report.json', ...(values['drawable-output'] ? [path.resolve(values['drawable-output'])] : [])];
    assert.equal(new Set(targets).size, targets.length, 'Output paths overlap');
    for (const file of targets) {
      assert(fs.statSync(path.dirname(file)).isDirectory(), 'Output parent must exist');
      assert(!inputPaths.includes(fs.existsSync(file) ? fs.realpathSync(file) : file), 'Cannot overwrite source input');
      assert(!fs.existsSync(file) || !fs.lstatSync(file).isSymbolicLink(), 'Output must not be a symlink');
    }
    const inputs = inputPaths.map(read), { document, report } = convert(...inputs.map(i => i.document));
    document['atlas:inputSHA256'] = Object.fromEntries(['overpass', 'githubCityReference', 'taiwanCityReference'].map((key, i) => [key, inputs[i].sha256]));
    const bytes = Buffer.from(JSON.stringify(document)), gzip = zlib.gzipSync(bytes);
    write(output, bytes); write(output + '.gz', gzip);
    Object.assign(report, { output, sourceDate: document['atlas:osm3s']?.timestamp_osm_base ?? null,
      bytes: bytes.length, gzipBytes: gzip.length, sha256: sha256(bytes), colours: report.relations - report.missingColour.length });
    if (values['drawable-output']) {
      const drawable = { ...document, features: document.features.filter(f => f.geometry !== null),
        'atlas:omittedGeometrylessRelations': report.missingGeometry };
      write(path.resolve(values['drawable-output']), Buffer.from(JSON.stringify(drawable)));
      report.drawableOutput = path.resolve(values['drawable-output']);
    }
    write(output + '.report.json', JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
  }
}
