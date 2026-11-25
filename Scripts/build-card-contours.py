"""Build the local route-card layer. Requires shapely 2.1 and pyshp 2.3.

Inputs: October 2026 Tianditu archive from dcxjegi.cn, BOUL classification
reference, Natural Earth 5.1.2 coastline and the province label input produced
by build-card-geography.cjs --label-input.
Only vertices from the Tianditu polygons are used for administrative lines.
"""
import argparse
import hashlib
import json
from collections import defaultdict
from itertools import combinations
from pathlib import Path
from zipfile import ZipFile

import shapefile
from shapely import STRtree, line_merge, union_all
from shapely.geometry import LineString, Point, box, shape


TDT_ID = "3af8294f9ad61cc2bf84c1bb7e4bbf86a6336c68d754b699a0e6ddc33ef81486"
BOUL_ID = "05fc9b8ad9b4433f21dde7fe9763a6f8fa9d7331e3e1c696feb3943803f546cd"
SOURCE = "https://dcxjegi.cn/portal/metadata/899cdd10-14f1-4cfa-8a97-c652f59e7b4e"


def checked(raw, expected):
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("Source edition differs; verify the new edition before rebuilding")
    return raw


def line_parts(geometry):
    if geometry.is_empty:
        return
    if geometry.geom_type in ("LineString", "LinearRing"):
        yield geometry
    elif hasattr(geometry, "geoms"):
        for child in geometry.geoms:
            yield from line_parts(child)


def encode(line):
    return [[round(y, 4), round(x, 4)] for x, y in line.coords]


def packed(lines):
    result = []
    for line in lines:
        # Keep all administrative vertices; split long lines for viewport culling.
        points = encode(line)
        for start in range(0, len(points) - 1, 80):
            part = points[start:start + 81]
            lat, lon = zip(*part)
            result.append({"bounds": [min(lat), min(lon), max(lat), max(lon)], "points": part})
    return result


def reference(archive):
    checked(archive.read_bytes(), BOUL_ID)
    parts, codes = [], []
    with ZipFile(archive) as data:
        reader = shapefile.Reader(shp=data.open("Boundary.shp"), shx=data.open("Boundary.shx"),
                                  dbf=data.open("Boundary.dbf"))
        for record in reader.iterShapeRecords():
            code = int(record.record["GB"])
            if code not in (620201, 620202):
                raise ValueError(f"Unexpected BOUL code {code}")
            for line in line_parts(shape(record.shape.__geo_interface__)):
                parts.append(line)
                codes.append(code)
    return STRtree(parts), parts, codes


def land_outline(mainland, reference_data):
    tree, reference_lines, codes = reference_data
    # Only the land-facing arc of the *mainland exterior* is eligible.
    # These are Tianditu vertices at the Beilun and Yalu estuaries. The long
    # arc passes around the northern border; the other arc is the seashore.
    ring = list(mainland.exterior.coords)[:-1]
    a = ring.index((108.104371, 21.531893))
    b = ring.index((124.155725, 39.817697))
    a, b = sorted([a, b])
    arc = ring[a:b + 1]
    if max(y for _, y in arc) < 50:
        arc = ring[b:] + ring[:a + 1]
    assert max(y for _, y in arc) > 53 and min(x for x, _ in arc) < 74
    classified = defaultdict(list)
    runs, current, run = [], None, []
    for start, end in zip(arc, arc[1:]):
        mid = Point((start[0] + end[0]) / 2, (start[1] + end[1]) / 2)
        index = tree.nearest(mid)
        # BOUL identifies symbols, never the coordinates we print.
        code = codes[index] if reference_lines[index].distance(mid) < .04 else None
        if code != current and run:
            runs.append((current, run))
            run = []
        if not run:
            run = [start]
        run.append(end)
        current = code
    if run:
        runs.append((current, run))
    for index, (code, points) in enumerate(runs):
        if code is None:
            # The two editions generalize rivers and ridges differently. Use
            # the surrounding symbol only where both runs agree and the line
            # is also close to a reference of that class throughout.
            before = runs[index - 1][0] if index else runs[index + 1][0]
            after = runs[index + 1][0] if index + 1 < len(runs) else before
            def same_symbol(coordinate):
                position = Point(coordinate)
                nearest = tree.nearest(position)
                return codes[nearest] == before and position.distance(reference_lines[nearest]) < .16
            if after != before or not all(same_symbol(p) for p in points):
                raise ValueError(f"Review symbol against standard sheet at {points[0]}")
            code = before
        classified[code].append(LineString(points))
    return classified


def build(args):
    with ZipFile(args.tianditu) as archive:
        original = checked(archive.read("GeoJSON/中国_省.geojson"), TDT_ID)
    # Line features in this source mix maritime dashes, estuary annotations
    # and other supplemental lines. None is imported as a land boundary.
    regions = {f["properties"]["name"]: shape(f["geometry"])
               for f in json.loads(original)["features"] if f["geometry"]["type"] == "MultiPolygon"}
    assert len(regions) == 34
    mainland = max(union_all(list(regions.values())).geoms, key=lambda p: p.area)
    assert all(mainland.contains(Point(p)) for p in ((91.86, 27.59), (79.8, 35.25)))
    main_island = max(regions["海南省"].geoms, key=lambda p: p.area)
    land = land_outline(mainland, reference(args.boul))
    provincial = []
    for left, right in combinations(regions.values(), 2):
        if left.intersects(right):
            common = line_merge(left.boundary.intersection(right.boundary))
            provincial.extend(line_parts(common))

    baseline = json.loads(args.base.read_bytes())
    anchors_by_name = {region["name"]: region for region in baseline["provinces"]}
    provinces = []
    for name, region in regions.items():
        old = anchors_by_name.get(name, {})
        main_part = max(region.geoms, key=lambda p: p.area)
        center = main_part.representative_point()
        lat, lon = old.get("lat", center.y), old.get("lon", center.x)
        if not region.covers(Point(lon, lat)):
            lat, lon = center.y, center.x
        local_anchors = [a for a in old.get("anchors", []) if region.covers(Point(a[1], a[0]))]
        w, s, e, n = region.bounds
        label_area = region.simplify(.012)
        rings = [encode(ring) for polygon in getattr(label_area, "geoms", [label_area])
                 for ring in [polygon.exterior, *polygon.interiors]]
        provinces.append(dict(name=name, lat=round(lat, 4), lon=round(lon, 4),
                              anchors=local_anchors, rings=rings, bounds=[s, w, n, e]))

    coast = []
    # Keep the geographic coast (including neighboring countries) as a physical
    # feature. Split Hainan out for shoreline detail at the journey's latitude.
    extent = box(98, 15, 140, 46)
    for feature in json.loads(args.coast.read_bytes())["features"]:
        for part in line_parts(shape(feature["geometry"]).intersection(extent)):
            if part.is_ring and box(108.4, 18, 111.3, 20.4).covers(part) and part.length > 4:
                continue
            coast.append(part.simplify(.01))
    result = {
        "edition": "tdt-2026-10-route-1",
        "source": {"publisher": "国家地理信息公共服务平台（天地图）",
                   "distributor": "干旱区生态与资源科学数据中心", "url": SOURCE,
                   "sourceMapNumber": "GS（2024）0650号", "crs": "EPSG:4490",
                   "inputSHA256": TDT_ID, "licence": "CC BY 4.0（分发数据集）"},
        "settled": packed(land[620201]), "undelimited": packed(land[620202]),
        "provinceLines": packed(provincial), "coastLines": packed(coast),
        "hainan": packed([main_island.exterior]), "provinces": provinces,
    }
    output = json.dumps(result, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    args.output.parent.mkdir(exist_ok=True, parents=True)
    args.output.write_text(output, encoding="utf-8")
    print(f"{args.output}: {len(output.encode())} bytes; "
          f"{len(land[620201])} settled, {len(land[620202])} undelimited, {len(provincial)} shared province lines")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("tianditu", "boul", "coast", "base", "output"):
        parser.add_argument(arg, type=Path)
    build(parser.parse_args())
