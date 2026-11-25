"""Build same-origin track cells from the HOT China railway extract and public OSM tags.

Usage: build-detail-rail.py railways.zip speeds.tsv use.tsv Web/data/rail/detail
Both TSVs are QLever OSM planet SELECT results keyed by OSM way URI (queries below).
Coordinates and names come from the extract; tags only join on the identical way ID.
"""
import collections
import hashlib
import json
import math
import pathlib
import re
import sys
import zipfile

PREFIX = "PREFIX k:<https://www.openstreetmap.org/wiki/Key:> PREFIX osm:<https://www.openstreetmap.org/> "
SPEED = PREFIX + 'SELECT ?way ?speed WHERE { ?way a osm:way; k:railway "rail"; k:maxspeed ?speed. }'
USE = PREFIX + 'SELECT ?way ?usage ?service WHERE { ?way a osm:way; k:railway "rail". { ?way k:usage ?usage } UNION { ?way k:service ?service } }'
ZOOM, EXTENT = 7, 262144


def features(archive):
    with archive.open("railways.geojson") as source:
        for line in source:
            if line.startswith(b'{ "type": "Feature"'):
                row = json.loads(line.rstrip(b",\r\n"))
                tags = row["properties"]
                if tags["id"].startswith("way/") and row["geometry"]["type"] == "LineString" and tags["railway"] == "rail":
                    yield int(tags["id"][4:]), tags, row["geometry"]["coordinates"]


def read_tags(path, header, ways):
    with open(path, encoding="utf8") as stream:
        assert stream.readline().strip().split("\t") == header
        for line in stream:
            uri, *values = line.rstrip("\r\n").split("\t")
            ident = int(uri.rsplit("/", 1)[1][:-1])
            if ident in ways:
                yield ident, [json.loads(v) if v else "" for v in values]


def encode_path(points):
    last = [0, 0]
    chars = []
    for point in points:
        for i, value in enumerate(point):
            delta = value - last[i]
            last[i] = value
            n = (delta << 1) ^ (delta >> 31)
            while n >= 32:
                chars.append(chr(63 + (n & 31) + 32))
                n >>= 5
            chars.append(chr(63 + n))
    return "".join(chars)


def project(lon, lat):
    side = (1 << ZOOM) * EXTENT
    return round((lon+180)/360*side), round((1-math.asinh(math.tan(math.radians(lat)))/math.pi)*.5*side)


def main():
    source, speeds, use, target = sys.argv[1:]
    target = pathlib.Path(target)
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        meta = json.loads(archive.read("metadata.json"))
        ways = {ident: ["", "", ""] for ident, _, _ in features(archive)}
        for ident, (value,) in read_tags(speeds, ["?way", "?speed"], ways):
            if re.fullmatch(r"\d+(?:\.\d+)?(?:\s*(?:mph|km/h|kmh|kph))?", value, re.I):
                ways[ident][0] = value
        for ident, (usage, service) in read_tags(use, ["?way", "?usage", "?service"], ways):
            if usage:
                ways[ident][1] = usage
            if service:
                ways[ident][2] = service
        cells = collections.defaultdict(list)
        for ident, tags, ll in features(archive):
            if len(ll) < 2:
                continue
            points = [project(*p[:2]) for p in ll]
            xs, ys = zip(*points)
            for x in range(min(xs)//EXTENT, max(xs)//EXTENT+1):
                for y in range(min(ys)//EXTENT, max(ys)//EXTENT+1):
                    # Keep the full way in intersecting cells; the canvas clips its own tile.
                    ox, oy = x*EXTENT, y*EXTENT
                    encoded = encode_path((px-ox, py-oy) for px, py in points)
                    cells[x,y].append([ident, tags.get("name_zh") or tags.get("name") or "", *ways[ident],
                                        min(xs)-ox, min(ys)-oy, max(xs)-ox, max(ys)-oy, encoded])
    manifest = dict(zoom=ZOOM, extent=EXTENT, source="https://data.humdata.org/dataset/hotosm_chn_railways",
                    geometryDate=meta["properties"]["oex:snapshot"], copyright="OpenStreetMap contributors",
                    license="ODbL-1.0", tagSource="https://qlever.dev/api/osm-planet", queries=[SPEED, USE],
                    inputSHA256=[hashlib.file_digest(open(p,"rb"),"sha256").hexdigest() for p in (source,speeds,use)],
                    ways=len(ways), speedWays=sum(bool(v[0]) for v in ways.values()), cells={})
    for (x, y), rows in sorted(cells.items()):
        data = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode()
        name = f"{x}-{y}-{hashlib.sha256(data).hexdigest()[:12]}.json"
        (target/name).write_bytes(data)
        manifest["cells"][f"{x}/{y}"] = name
    (target/"index.json").write_text(json.dumps(manifest,ensure_ascii=False,separators=(",",":"))+"\n")
    print(len(cells), "cells,", manifest["ways"], "ways,", manifest["speedWays"], "ways with speed")


if __name__ == "__main__":
    main()
