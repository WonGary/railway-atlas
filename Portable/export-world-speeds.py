"""Build three small speed overlays from the QLever query in SOURCE_QUERY.

Request text/tab-separated-values with gzip encoding. Pass the compressed
response, the OSM planet edition (YYYY-MM-DD), and the Web/data/rail directory.
Only mainline OSM ways with explicit numeric speed limits enter the overlays.
"""
import collections
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import sys


SOURCE_QUERY = """PREFIX k:<https://www.openstreetmap.org/wiki/Key:>
PREFIX geo:<http://www.opengis.net/ont/geosparql#>
PREFIX osm:<https://www.openstreetmap.org/>
SELECT ?way ?speed ?shape WHERE {
  ?way a osm:way; k:railway "rail"; k:usage "main"; k:maxspeed ?speed; geo:hasGeometry/geo:asWKT ?shape.
}"""
EXTENT = 512
LEVELS = (2, 4, 6)
SPEED = re.compile(r"(\d+(?:\.\d+)?)\s*(mph|km/h|kmh|kph)?", re.I)
CLASSES = ((350, "speed350"), (300, "speed300"), (250, "speed250"), (200, "speed200"),
           (160, "speed160"), (0, "below160"))


def band(raw):
    m = SPEED.fullmatch(raw.strip().strip('"').strip())
    if not m:
        return None
    v = float(m[1]) * (1.609344 if (m[2] or "").lower() == "mph" else 1)
    if not 0 < v < 700:
        return None
    return next(label for limit, label in CLASSES if v >= limit)


def edges_by_tile(points, scale, tiles, category):
    side = 1 << scale
    prev = None
    for point in points:
        cur = tuple(round(a * EXTENT * side) for a in point)
        if cur == prev:
            continue
        if prev is not None and abs(cur[0] - prev[0]) <= side * EXTENT / 2:
            ax, ay = prev
            dx, dy = cur[0] - ax, cur[1] - ay
            cuts = {0, 1}
            for a, b in zip(prev, cur):
                for edge in range(min(a, b) // EXTENT + 1, (max(a, b) - 1) // EXTENT + 1):
                    cuts.add((edge * EXTENT - a) / (b - a))
            cuts = sorted(cuts)
            for l, r in zip(cuts, cuts[1:]):
                mid = (l + r) / 2
                tx = min(side - 1, max(0, int((ax + mid * dx) // EXTENT)))
                ty = min(side - 1, max(0, int((ay + mid * dy) // EXTENT)))
                def vertex(t):
                    return (round(ax + t * dx) - tx * EXTENT) * (EXTENT + 1) + round(ay + t * dy) - ty * EXTENT
                u, v = vertex(l), vertex(r)
                if u != v:
                    tiles[(tx, ty, category)].add((min(u, v), max(u, v)))
        prev = cur


def paths(edges):
    graph = collections.defaultdict(set)
    for u, v in edges:
        graph[u].add(v)
        graph[v].add(u)
    junctions = {v for v in graph if len(graph[v]) != 2}
    def trace(u):
        line = [u]
        while graph[u]:
            v = min(graph[u])
            graph[u].remove(v)
            graph[v].remove(u)
            line.append(v)
            u = v
            if v in junctions:
                break
        return line
    out = []
    for u in [*sorted(junctions), *sorted(graph)]:
        while graph[u]:
            out.append([n for v in trace(u) for n in divmod(v, EXTENT + 1)])
    return out


def main(source, edition, target):
    levels = {z: collections.defaultdict(set) for z in LEVELS}
    digest = hashlib.sha256()
    counts = collections.Counter()
    rows = 0
    with gzip.open(source, "rb") as handle:
        if handle.readline().strip() != b"?way\t?speed\t?shape":
            raise ValueError("Unexpected query response")
        for raw in handle:
            digest.update(raw)
            way, speed, wkt = raw.decode().rstrip().split("\t")
            if not way.startswith("<https://www.openstreetmap.org/way/"):
                raise ValueError(way)
            rows += 1
            category = band(speed)
            if not category or not wkt.startswith('"LINESTRING('):
                continue
            coords = wkt[12:wkt.index(")")].split(",")
            points = []
            for coordinate in coords:
                lon, lat = map(float, coordinate.split())
                if abs(lat) > 85.05112878 or abs(lon) > 180:
                    break
                points.append(((lon + 180) / 360, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2))
            else:
                counts[category] += 1
                # Collapse points that land in the same finest display cell.
                # Preserve distinct coarser endpoints by quantizing each edition independently.
                for z, tiles in levels.items():
                    edges_by_tile(points, z, tiles, category)
    if rows < 100000 or set(counts) != {name for _, name in CLASSES}:
        raise ValueError(f"Incomplete export: {rows}, {counts}")
    for z, tiles in levels.items():
        result = {}
        for (x, y, category), edges in sorted(tiles.items()):
            result.setdefault(f"{x}/{y}", {})[category] = paths(edges)
        data = {"zoom": z, "extent": EXTENT, "edition": edition, "tiles": result}
        (target / f"speed-z{z}.json").write_text(json.dumps(data, separators=(",", ":")) + "\n")
    attribution = dict(source="https://qlever.dev/api/osm-planet", query=SOURCE_QUERY, osmPlanet=edition,
                       copyright="OpenStreetMap contributors", license="ODbL-1.0", rows=rows,
                       drawnWays=dict(counts), sha256TSVRows=digest.hexdigest())
    (target / "world-speed-source.json").write_text(json.dumps(attribution, indent=2) + "\n")
    print(rows, dict(counts))


if __name__ == "__main__":
    main(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]))
