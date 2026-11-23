"""Build the web overview from a Natural Earth 1:10m railroads zip (stdlib only).

python3 Portable/export-world-rail.py ne_10m_railroads.zip Web/data/rail
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import zipfile


EXTENT = 1024
SOURCE = "https://naturalearth.s3.amazonaws.com/10m_cultural/ne_10m_railroads.zip"
SOURCE_HASH = "0bce64d1bb7ce1178810f0a341322b0459acb0689a61016259ef38f75abed0a4"


def rail_paths(archive):
    data = archive.read("ne_10m_railroads.dbf")
    count, header, size = struct.unpack_from("<IHH", data, 4)
    fields, pos = {}, 1
    for i in range(32, header - 1, 32):
        width = data[i + 16]
        fields[data[i:i + 11].split(b"\0")[0].decode()] = slice(pos, pos + width)
        pos += width
    shapes = archive.read("ne_10m_railroads.shp")
    offset = 100
    for i in range(count):
        length = struct.unpack_from(">I", shapes, offset + 4)[0] * 2
        start, offset = offset + 8, offset + 8 + length
        record = data[header + i * size:header + (i + 1) * size]
        if record[0] == 42 or record[fields["featurecla"]].strip() != b"Railroad":
            continue
        rank = int(record[fields["scalerank"]])
        if rank > 8:
            continue
        assert struct.unpack_from("<I", shapes, start)[0] == 3
        parts, count_xy = struct.unpack_from("<II", shapes, start + 36)
        stops = (*struct.unpack_from(f"<{parts}I", shapes, start + 44), count_xy)
        points = start + 44 + 4 * parts
        for first, last in zip(stops, stops[1:]):
            coords = []
            for lon, lat in struct.iter_unpack("<dd", shapes[points + 16*first:points + 16*last]):
                y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2
                point = ((lon + 180) / 360, y)
                # A wrapped segment must never be drawn across the interior of the world.
                if coords and abs(point[0] - coords[-1][0]) > .5:
                    if len(coords) >= 2:
                        yield rank, coords
                    coords = []
                coords.append(point)
            if len(coords) >= 2:
                yield rank, coords


def simplify(points, tolerance):
    keep = {0, len(points) - 1}
    pending = [(0, len(points) - 1)]
    while pending:
        left, right = pending.pop()
        ax, ay = points[left]
        bx, by = points[right]
        dx, dy = bx - ax, by - ay
        length = dx*dx + dy*dy
        farthest, split = tolerance*tolerance, None
        for i in range(left + 1, right):
            x, y = points[i]
            along = max(0, min(1, ((x-ax)*dx + (y-ay)*dy) / length)) if length else 0
            distance = (x-ax-along*dx)**2 + (y-ay-along*dy)**2
            if distance > farthest:
                farthest, split = distance, i
        if split is not None:
            keep.add(split)
            pending.extend([(left, split), (split, right)])
    return [points[i] for i in sorted(keep)]


def split_tiles(points, zoom, tiles):
    side = 1 << zoom
    previous, line = None, None
    for (ax, ay), (bx, by) in zip(points, points[1:]):
        ax, ay, bx, by = ax*side, ay*side, bx*side, by*side
        dx, dy = bx-ax, by-ay
        cuts = {0, 1}
        for a, b in [(ax, bx), (ay, by)]:
            for edge in range(math.floor(min(a, b)) + 1, math.ceil(max(a, b))):
                cuts.add((edge - a) / (b - a))
        cuts = sorted(cuts)
        for t, u in zip(cuts, cuts[1:]):
            mid = (t+u)/2
            x = min(side-1, max(0, math.floor(ax+mid*dx)))
            y = min(side-1, max(0, math.floor(ay+mid*dy)))
            key = f"{x}/{y}"
            a = [round((ax+t*dx-x)*EXTENT), round((ay+t*dy-y)*EXTENT)]
            b = [round((ax+u*dx-x)*EXTENT), round((ay+u*dy-y)*EXTENT)]
            if a == b:
                continue
            if key != previous or line[-2:] != a:
                line = a[:]
                tiles.setdefault(key, []).append(line)
            line.extend(b)
            previous = key


def main(source, target):
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_HASH:
        raise ValueError("Unexpected Natural Earth edition; verify the source before updating.")
    levels = [(2, 6, {}), (4, 7, {}), (6, 8, {})]
    with zipfile.ZipFile(source) as archive:
        edition = archive.read("ne_10m_railroads.VERSION.txt").decode().strip()
        for rank, points in rail_paths(archive):
            for zoom, max_rank, tiles in levels:
                if rank <= max_rank:
                    split_tiles(simplify(points, .28 / (256 * (1 << zoom))), zoom, tiles)
    for zoom, rank, tiles in levels:
        result = dict(source=SOURCE, sha256=digest, edition=edition, license="Public domain",
                      zoom=zoom, extent=EXTENT, maxRank=rank, tiles=tiles)
        file = target / f"world-z{zoom}.json"
        file.write_text(json.dumps(result, separators=(",", ":")) + "\n")
        print(f"{file.name}: {len(tiles)} tiles, {file.stat().st_size:,} bytes")


if __name__ == "__main__":
    main(*map(Path, sys.argv[1:]))
