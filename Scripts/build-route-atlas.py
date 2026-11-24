"""Compile WGS84 GTFS shapes and dated services into small train-number groups.

Usage: python build-route-atlas.py FEED.zip national.js plans.json OUTPUT [osm-legs.json]
Requires NumPy and Shapely. plans.json is the output of export-route-plans.cjs.
"""
import csv
import functools
import hashlib
import io
import itertools
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile

import numpy as np
from shapely.geometry import LineString


def dump(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False))


def group(code):
    return re.sub(r"\d+$", lambda m: str(int(m[0]) // 100), code)


def pack(points):
    """Encode actual geometry at 1e-5 degrees, retaining curves and station ends."""
    shape = LineString(points).simplify(0.00018, preserve_topology=False)
    vertices = np.asarray(shape.coords)
    scale = np.array([math.cos(math.radians(vertices[0,1])),1])*111195
    if np.max(np.linalg.norm(np.diff(vertices,axis=0)*scale,axis=1))>26000:
        # A long straight can lose every intermediate source vertex. Preserve
        # original vertices along it so a native reader can still check gaps.
        raw=np.asarray(points)
        chain=np.r_[0,np.cumsum(np.linalg.norm(np.diff(raw,axis=0)*scale,axis=1))]
        pieces=[]; start=0
        while start<len(raw)-1:
            end=max(start+1,int(np.searchsorted(chain,chain[start]+18000,side="right"))-1)
            part=list(LineString(raw[start:end+1]).simplify(.00018,preserve_topology=False).coords)
            pieces.extend(part if not pieces else part[1:])
            start=end
        vertices=pieces
    pairs = [tuple(round(v * 100000) for v in p) for p in vertices]
    buf = []
    prev = (0, 0)
    for pair in pairs:
        for value, old in zip(pair, prev):
            delta = value - old
            value = (delta << 1) ^ (delta >> 31)
            while value >= 32:
                buf.append(chr(95 + (value & 31)))
                value >>= 5
            buf.append(chr(63 + value))
        prev = pair
    return "".join(buf)


@functools.lru_cache(maxsize=2048)
def unpack(encoded):
    numbers = []
    accum = shift = 0
    for char in encoded:
        value = ord(char)-63
        accum |= (value & 31) << shift
        if value < 32:
            numbers.append((accum >> 1) ^ -(accum & 1))
            accum = shift = 0
        else:
            shift += 5
    return np.cumsum(np.array(numbers).reshape((-1,2)), axis=0)/100000


def topology(plan, a, b):
    return tuple((plan["nodes"][j][0], plan["lines"][j], plan["nodes"][j+1][1]-plan["nodes"][j][1],
                  plan["nodes"][j+1][0]) for j in range(a,b))


def reverse_key(key):
    return tuple((b,l,k,a) for a,l,k,b in reversed(key))


def add_sections(bank, plan, i, encoded, locations):
    start,end=plan["stops"][i:i+2]
    points=unpack(encoded)
    last=start
    vertex=0
    for j in range(start+1,end+1):
        if j==end:
            cut_at=len(points)-1
        else:
            loc=locations.get(plan["nodes"][j][0])
            if not loc: continue
            d=(points-loc)*[math.cos(math.radians(loc[1])),1]
            squared=(d*d).sum(axis=1)
            cut_at=int(squared.argmin())
            if squared[cut_at]>(1100/111195)**2 or cut_at<=vertex: continue
        if cut_at<=vertex: continue
        key=topology(plan,last,j)
        if key not in bank and reverse_key(key) not in bank:
            fragment=points[vertex:cut_at+1]
            delta=np.diff(fragment,axis=0)*[math.cos(math.radians(fragment[0,1])),1]
            length=np.hypot(delta[:,0],delta[:,1]).sum()*111.195
            if abs(length-sum(e[2] for e in key)) <= max(2.5,length*.18):
                bank[key]=pack(fragment)
        last,vertex=j,cut_at


def assemble(bank, plan, i):
    start,end=plan["stops"][i:i+2]
    pieces={start:[]}
    for a in range(start,end):
        if a not in pieces: continue
        for b in range(end,a,-1):
            if b in pieces: continue
            key=topology(plan,a,b)
            part=bank.get(key)
            if part:
                points=unpack(part)
            elif reverse_key(key) in bank:
                points=unpack(bank[reverse_key(key)])[::-1]
            else: continue
            prev=pieces[a]
            if prev:
                dx,dy=(points[0]-prev[-1][-1])*[math.cos(math.radians(points[0,1])),1]
                if math.hypot(dx,dy)*111195>120: continue
            pieces[b]=prev+[points]
            if b==end: return pack(np.concatenate(pieces[b]))


def cut(shape, calls, coordinates):
    coords = np.asarray(shape)
    if len(coords) < 2 or not np.isfinite(coords).all():
        return []
    indices = []
    for stop, *_ in calls:
        point = coordinates[stop]
        if not point or min(point) <= 0:
            indices.append(None)
            continue
        dx = (coords[:, 0] - point[1]) * math.cos(math.radians(point[0]))
        dy = coords[:, 1] - point[0]
        distances = dx * dx + dy * dy
        vertex = int(distances.argmin())
        indices.append(vertex if distances[vertex] <= (1400 / 111195) ** 2 else None)
    valid = [i for i in indices if i is not None]
    if len(valid) > 1 and valid[0] > valid[-1]:
        return cut(coords[::-1], calls, coordinates)
    result = []
    for a, b in zip(indices, indices[1:]):
        if a is None or b is None or a >= b:
            result.append(None)
            continue
        points = coords[a:b + 1]
        delta = np.diff(points, axis=0)
        delta[:, 0] *= math.cos(math.radians(float(points[:, 1].mean())))
        # Gaps in the source must not become invented track on the main map.
        steps = np.hypot(delta[:, 0], delta[:, 1]) * 111195
        if len(points) < 2 or steps.max() > 32000 or (steps.sum() > 8000 and len(points) < 4):
            result.append(None)
        else:
            result.append(pack(points))
    return result


def segment_key(plan, i):
    a, b = plan["stops"][i:i + 2]
    nodes = plan["nodes"][a:b + 1]
    edges = tuple((l, abs(y[1] - x[1])) for l, x, y in zip(plan["lines"][a:b], nodes, nodes[1:]))
    return tuple(n[0] for n in nodes), edges


def main():
    feed, src, planfile, out, *extra = map(Path, sys.argv[1:])
    data = json.loads(src.read_text().split(" = ", 1)[1].rstrip(";\n"))
    plans = json.loads(planfile.read_text())
    extras = json.loads(extra[0].read_text()) if extra else {}
    trains = {t[3]: t for t in data["trains"]}
    rows_by_shape = defaultdict(list)
    geometries = {}
    with ZipFile(feed) as archive:
        def rows(name):
            return csv.DictReader(io.TextIOWrapper(archive.open(name + ".txt"), encoding="utf-8-sig"))
        for row in rows("trips"):
            if row["shape_id"]:
                rows_by_shape[row["shape_id"]].append(row["trip_id"])
        for shape, rows_ in itertools.groupby(rows("shapes"), key=lambda r: r["shape_id"]):
            points = [(float(r["shape_pt_lon"]), float(r["shape_pt_lat"])) for r in rows_]
            for trip in rows_by_shape[shape]:
                geometries[trip] = cut(points, trains[trip][2], data["coordinates"])

    # Other trains may share a section only if every operational station, named
    # line and inter-station distance are identical, in the same direction.
    corridors, bank = {}, {}
    locations={n:(p[1],p[0]) for n,p in zip(data["names"],data["coordinates"]) if p and min(p)>0}
    seen=set()
    for trip, legs in geometries.items():
        if trip in plans:
            for i, leg in enumerate(legs):
                if leg:
                    key=segment_key(plans[trip], i)
                    corridors.setdefault(key, leg)
                    if key not in seen:
                        add_sections(bank,plans[trip],i,leg,locations)
                        seen.add(key)
    # Reuse a verified OSM leg for every train with that same operating path.
    # Joins are specific to the neighbouring geometry and stay trip-local.
    osm_corridors = {}
    for trip, additions in extras.items():
        if trip not in plans: continue
        for index, encoded in additions.items():
            if index.isdecimal():
                osm_corridors.setdefault(segment_key(plans[trip],int(index)),encoded)
    groups = {}
    lookup = defaultdict(set)
    coverage = defaultdict(int)
    out.mkdir(parents=True, exist_ok=True)
    for number, calendar, calls, trip in data["trains"]:
        if not re.fullmatch(r"[A-Z]?\d+", number):
            continue
        bucket = group(number)
        shapes, records = groups.setdefault(bucket, ({}, defaultdict(list)))
        plan = plans.get(trip)
        raw = geometries.get(trip) or [None] * (len(calls) - 1)
        legs, kinds = [], []
        for i, encoded in enumerate(raw):
            kind = 1
            if not encoded and plan:
                key=segment_key(plan,i)
                if key not in corridors:
                    corridors[key]=assemble(bank,plan,i)
                encoded = corridors[key]
                kind = 2
            if not encoded:
                encoded = extras.get(trip, {}).get(str(i)) or (osm_corridors.get(key) if plan else None)
                kind = 3
            encoded = extras.get(trip, {}).get(f"join:{i}", encoded)
            legs.append(shapes.setdefault(encoded, len(shapes)) if encoded else -1)
            kinds.append(kind if encoded else 0)
        # Normalize a GTFS arrival erroneously placed one day after departure.
        # Only correct it when both adjacent events bound the recovered minute.
        stops = []
        for i, (idx, arr, dep) in enumerate(calls):
            if i and i < len(calls) - 1 and arr is not None and dep is not None and arr > dep:
                if stops[-1][2] <= arr - 1440 <= dep:
                    arr -= 1440
            stops.append([idx, arr if i else None, dep if i + 1 < len(calls) else None])
        aliases = plan["versions"] if plan else []
        fingerprint = None
        if plan:
            text = "\n".join(f"{n[0]}\t{n[1]}\t{line}" for n,line in zip(plan["nodes"], [*plan["lines"],""]))
            fingerprint=hashlib.sha256(text.encode()).hexdigest()
        records[number].append(dict(id=trip, c=calendar, s=stops, p=legs, k=kinds, a=aliases, r=fingerprint))
        lookup[number].add(bucket)
        for aliases_, _, _ in aliases:
            for alias in aliases_:
                lookup[alias].add(bucket)
        coverage["full" if all(kinds) else "partial" if any(kinds) else "missing"] += 1
    filenames = {}
    for name, (shapes, trains_) in groups.items():
        encoded = json.dumps(dict(paths=list(shapes), trains=trains_), ensure_ascii=False, separators=(",", ":")).encode()
        filename = f"{name}-{hashlib.sha256(encoded).hexdigest()[:12]}.json"
        (out / filename).write_bytes(encoded)
        filenames[name] = filename
    dump(out / "index.json", dict(version=1, edition=data["edition"], names=data["names"],
         calendars=data["calendars"], groups=filenames, lookup={n:sorted(g) for n,g in lookup.items()}))
    # The web map already loads the national station names and calendars. Only
    # code aliases which depart from the normal bucket need a separate entry.
    manifest = dict(version=1, edition=data["edition"], groups=filenames,
                    aliases={n:sorted(v) for n,v in lookup.items() if v != {group(n)}})
    (out / "manifest.js").write_text("globalThis.atlasPathManifest=" + json.dumps(manifest,separators=(",",":")) + ";\n")
    print(dict(coverage), len(groups), "groups", flush=True)


if __name__ == "__main__":
    main()
