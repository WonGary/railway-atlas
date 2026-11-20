// Reproducible conversion of a read-only ORM cache export to one dated route.
// No downloading; only named operational corridors are eligible. Fails on gaps.
import fs from 'node:fs';
const [input, timetableFile, output] = process.argv.slice(2);
if (!output) throw Error('usage: node build-experience-route.mjs cache.json timetable.json output.json');
const data = JSON.parse(fs.readFileSync(input));
const timetable = JSON.parse(fs.readFileSync(timetableFile)).timetables[0];
const distance = (a, b) => Math.hypot((a.longitude - b.longitude) * Math.cos((a.latitude + b.latitude) * Math.PI / 360),
    a.latitude - b.latitude) * 111195;
const stopLocations = data.stations.filter(s => timetable.stops.some(t => t.station === s.name
    || t.station === '香港西九龙' && s.name.startsWith('香港西九龍'))).map(s => s.coordinate);
const lines = data.lines.filter(l => l.tags.state === 'present' && l.tags.railway === 'rail'
    && (['3021', '3029'].includes(l.tags.ref)
        || l.tags.highspeed === 'yes' && l.coordinates.some(p => stopLocations.some(s => distance(p, s) < 1000)))
    && !['yard', 'siding', 'spur'].includes(l.tags.service));
const nodes = [], edges = [], cells = new Map();
const xy = p => [p.longitude * 102500, p.latitude * 111195];
function node(p) {
    const [x, y] = xy(p), gx = Math.floor(x / 25), gy = Math.floor(y / 25);
    let best, bestD = 25;
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
        for (const id of cells.get(`${gx + dx},${gy + dy}`) || []) {
            const d = distance(p, nodes[id]);
            if (d < bestD) { bestD = d; best = id; }
        }
    }
    if (best !== undefined) return best;
    const id = nodes.length;
    nodes.push(p); edges.push([]);
    const key = `${gx},${gy}`; if (!cells.has(key)) cells.set(key, []);
    cells.get(key).push(id);
    return id;
}
for (const line of lines) {
    let last;
    for (let i = 1; i < line.coordinates.length; i++) {
        const a = line.coordinates[i - 1], b = line.coordinates[i];
        const steps = Math.max(1, Math.ceil(distance(a, b) / 35));
        for (let j = i === 1 ? 0 : 1; j <= steps; j++) {
            const id = node({latitude: a.latitude + (b.latitude - a.latitude) * j / steps,
                longitude: a.longitude + (b.longitude - a.longitude) * j / steps});
            if (last !== undefined && last !== id) {
                const d = distance(nodes[last], nodes[id]);
                edges[last].push([id, d]); edges[id].push([last, d]);
            }
            last = id;
        }
    }
}
const component = new Int32Array(nodes.length).fill(-1), sizes = [];
for (let start = 0; start < nodes.length; start++) {
    if (component[start] >= 0) continue;
    const id = sizes.length, queue = [start]; component[start] = id;
    for (let i = 0; i < queue.length; i++) for (const [v] of edges[queue[i]]) {
        if (component[v] < 0) { component[v] = id; queue.push(v); }
    }
    sizes.push(queue.length);
}
const main = sizes.indexOf(Math.max(...sizes));
console.log('connected corridor nodes', sizes[main], 'of', nodes.length);
const stationIDs = timetable.stops.map(stop => {
    const names = stop.station === '香港西九龙' ? ['香港西九龍 Hong Kong West Kowloon'] : [stop.station];
    const stations = data.stations.filter(s => names.includes(s.name) && s.tags.feature !== 'subway');
    if (!stations.length) throw Error(`missing station ${stop.station}`);
    let best, d = Infinity;
    for (const s of stations) for (let id = 0; id < nodes.length; id++) {
        if (component[id] !== main) continue;
        const v = distance(s.coordinate, nodes[id]);
        if (v < d) { best = id; d = v; }
    }
    if (d > 450) throw Error(`${stop.station}: nearest operational corridor ${d.toFixed(1)}m`);
    console.log(`${stop.station}: station snap ${d.toFixed(1)}m`);
    return best;
});
function path(start, end) {
    const distances = new Float64Array(nodes.length).fill(Infinity), previous = new Int32Array(nodes.length).fill(-1);
    const heap = [];
    const push = item => {
        heap.push(item); let i = heap.length - 1;
        while (i > 0) {
            const p = (i - 1) >> 1; if (heap[p][0] <= item[0]) break;
            heap[i] = heap[p]; i = p;
        }
        heap[i] = item;
    };
    const pop = () => {
        const first = heap[0], last = heap.pop();
        if (heap.length) {
            let i = 0;
            while (2 * i + 1 < heap.length) {
                let c = 2 * i + 1;
                if (c + 1 < heap.length && heap[c + 1][0] < heap[c][0]) c++;
                if (last[0] <= heap[c][0]) break;
                heap[i] = heap[c]; i = c;
            }
            heap[i] = last;
        }
        return first;
    };
    distances[start] = 0; push([0, start]);
    while (heap.length) {
        const [cost, u] = pop();
        if (cost !== distances[u]) continue;
        if (u === end) break;
        for (const [v, length] of edges[u]) if (cost + length < distances[v]) {
            distances[v] = cost + length; previous[v] = u; push([distances[v], v]);
        }
    }
    if (!Number.isFinite(distances[end])) {
        const connected = [], disconnected = [];
        for (let i = 0; i < nodes.length; i++) (Number.isFinite(distances[i]) ? connected : disconnected).push(i);
        let gap = Infinity, pair;
        for (const a of connected) for (const b of disconnected) {
            const d = distance(nodes[a], nodes[b]); if (d < gap) { gap = d; pair = [nodes[a], nodes[b]]; }
        }
        console.error('nearest component gap', gap, pair);
        throw Error(`disconnected track at ${JSON.stringify(nodes[end])}`);
    }
    const result = [];
    for (let u = end; u !== -1; u = previous[u]) { result.push(nodes[u]); if (u === start) break; }
    console.log(`leg ${(distances[end] / 1000).toFixed(2)} km, ${result.length} vertices`);
    return result.reverse();
}
const legs = stationIDs.slice(1).map((end, i) => path(stationIDs[i], end));
const archive = [{
    id: 'g6580-20261108-track', train: timetable.train, serviceDate: timetable.serviceDate,
    stations: timetable.stops.map(s => s.station), legs,
    source: {
        title: 'OpenStreetMap / OpenRailwayMap · 广深港、南广正线走廊',
        url: 'https://openrailwaymap.app/',
        retrievedOn: '2026-11-08',
        note: '由 2026-11-05 起的地图缓存匹配经停站，采用运营中的 3021 / 3029 正线。几何为 Z10 公开轨道概览；站点吸附及并行股道可能有偏差，不代表调度指定股道。区间位置按时刻与沿轨道距离插值。'
    }
}];
fs.writeFileSync(output, JSON.stringify(archive));
console.log(`wrote ${output}; eligible source ways: ${new Set(lines.map(l => l.tags['atlas:osm'])).size}`);
