"""Complete an existing edition from its verified shapes and optional OSM extracts.

python Scripts/repair-route-atlas.py Web/station-directory/paths national.js plans.json OUTPUT \
    --osm regional.json --osm country.zip --report coverage.json

The first OSM source containing a complete way takes priority. The resulting
manifest uses the same format as build-route-atlas.py on both clients.
"""
import argparse
from collections import Counter, defaultdict
from functools import lru_cache
import hashlib
import importlib.util
import json
import math
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location("rail_network", Path(__file__).with_name("build-osm-route-legs.py"))
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)
codec = network.compiler


def signature(plan):
    rows = (f"{name}\t{km}\t{line}" for (name, km), line in zip(plan["nodes"], [*plan["lines"], ""]))
    return hashlib.sha256("\n".join(rows).encode()).hexdigest()


@lru_cache(maxsize=8192)
def ends(shape):
    points = codec.unpack(shape)
    return tuple(points[0]), tuple(points[-1])


class CorridorIndex:
    """Index both directions of measured operating edges inside published legs."""

    def __init__(self, locations):
        self.locations = locations
        self.by_edge = defaultdict(list)
        self.seen = set()

    def add(self, key, shape, kind):
        if not key or (key, shape) in self.seen:
            return
        self.seen.add((key, shape))
        for reverse, route in [(False, key), (True, codec.reverse_key(key))]:
            for pos, entry in enumerate(route):
                self.by_edge[entry].append((route, pos, shape, reverse, kind))

    @staticmethod
    def cut(points, location, expected, cumulative):
        # Project onto the source track so stops on long straight sections can
        # be cut even when simplification removed their nearest original vertex.
        dx = np.array([math.cos(math.radians(location[1])), 1.0]) * 111195
        starts = (points[:-1] - location) * dx
        edges = np.diff(points, axis=0) * dx
        lengths2 = (edges * edges).sum(axis=1)
        fractions = np.clip(-(starts * edges).sum(axis=1) / np.maximum(lengths2, 1e-12), 0, 1)
        offsets = np.linalg.norm(starts + edges * fractions[:, None], axis=1)
        along = cumulative[:-1] + np.diff(cumulative) * fractions
        # A return path can pass the same point twice. Constrain by chainage
        # and reject distinct near-ties instead of picking the first crossing.
        possible = np.flatnonzero((offsets <= 850) & (np.abs(along - expected) <= max(3500, .15*cumulative[-1])))
        if not len(possible):
            return None
        i = possible[offsets[possible].argmin()]
        if np.any((offsets[possible] < offsets[i]+70) & (np.abs(along[possible]-along[i]) > 1500)):
            return None
        return i + fractions[i], points[i] + fractions[i] * (points[i+1]-points[i]), along[i]

    @lru_cache(maxsize=16384)
    def slices(self, key):
        found = {}
        for route, pos, shape, reverse, kind in self.by_edge.get(key[0], ()):
            stop = pos + len(key)
            if route[pos:stop] != key:
                continue
            if pos == 0 and stop == len(route):
                encoded = codec.pack(codec.unpack(shape)[::-1]) if reverse else shape
            else:
                # Fare distances on railway ferries include a tariff multiplier.
                if any("轮渡" in e[1] for e in route):
                    continue
                points = codec.unpack(shape)
                if reverse:
                    points = points[::-1]
                scale = np.array([math.cos(math.radians(float(points[:, 1].mean()))), 1]) * 111195
                measures = np.r_[0., np.cumsum(np.linalg.norm(np.diff(points, axis=0)*scale, axis=1))]
                fare = np.r_[0, np.cumsum([e[2] for e in route])]
                if fare[-1] <= 0:
                    continue
                def at(j, station):
                    if j == 0:
                        return 0, points[0], 0.
                    if j == len(route):
                        return len(points)-1, points[-1], measures[-1]
                    loc = self.locations.get(station)
                    return self.cut(points, loc, fare[j]/fare[-1]*measures[-1], measures) if loc else None
                a, b = at(pos, key[0][0]), at(stop, key[-1][3])
                if a is None or b is None or b[0] <= a[0]:
                    continue
                km = sum(e[2] for e in key)
                if abs(b[2]-a[2]-km*1000) > max(2500, km*170):
                    continue
                encoded = codec.pack([a[1], *points[math.floor(a[0])+1:math.ceil(b[0])], b[1]])
            # Keep the provenance of OSM source shapes through reverse/slicing.
            found.setdefault(encoded, 3 if kind == 3 else 2)
        return tuple(found.items())

    def assemble(self, route, bridge):
        # Each state ends at a particular track in a station. A second track
        # at the same station can have a different onward connection.
        states = defaultdict(dict)
        states[0][None] = ((), 2)
        for a in range(len(route)):
            if not states[a]:
                continue
            order = sorted(states[a].items(), key=lambda item: len(item[1][0]))
            for b in range(len(route), a, -1):
                for fragment, kind in self.slices(route[a:b]):
                    first, last = ends(fragment)
                    for previous, (pieces, source) in order[:12]:
                        join = None
                        if previous is not None and network.distance(previous, first) > 120:
                            join = bridge(previous, first, route[a][0])
                            if not join:
                                continue
                        extension = (*pieces, join, fragment) if join else (*pieces, fragment)
                        evidence = 3 if join else max(source, kind)
                        if b == len(route):
                            return codec.pack(np.concatenate([codec.unpack(e) for e in extension])), evidence
                        old = states[b].get(last)
                        if old is None or len(extension) < len(old[0]):
                            states[b][last] = (extension, evidence)
                        break


def load_groups(base, index):
    groups = {}
    for key, filename in index["groups"].items():
        raw = (base/filename).read_bytes()
        if filename != f"{key}-{hashlib.sha256(raw).hexdigest()[:12]}.json":
            raise ValueError(f"Group digest mismatch: {filename}")
        groups[key] = json.loads(raw)
    return groups


def issues(legs):
    return [i for i, line in enumerate(legs) if line is None], [
        i for i in range(1, len(legs)) if legs[i-1] and legs[i]
        and network.distance(ends(legs[i-1])[1], ends(legs[i])[0]) > 120]


def measure(counts, legs):
    missing, gaps = issues(legs)
    counts["records"] += 1
    counts["legs"] += len(legs)
    counts["missingLegs"] += len(missing)
    counts["stationGaps"] += len(gaps)
    counts["missing" if len(missing) == len(legs) else "partial" if missing or gaps else "full"] += 1
    return missing, gaps


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "national", "plans", "output"):
        p.add_argument(name, type=Path)
    p.add_argument("--osm", action="append", default=[])
    p.add_argument("--report", type=Path, required=True)
    args = p.parse_args()
    if args.baseline.resolve() == args.output.resolve():
        p.error("Build into a separate directory before installing the verified index.")
    index = json.loads((args.baseline/"index.json").read_text())
    national = json.loads(args.national.read_text().split(" = ", 1)[1].rstrip(";\n"))
    if national["edition"] != index["edition"] or national["names"] != index["names"]:
        raise ValueError("National timetable and geometry editions differ")
    groups = load_groups(args.baseline, index)
    plans = json.loads(args.plans.read_text())
    locations = {n: tuple(reversed(p)) for n,p in zip(national["names"], national["coordinates"]) if p and min(p)>0}
    donors = CorridorIndex(locations)
    for group in groups.values():
        for rows in group["trains"].values():
            for row in rows:
                plan = plans.get(row["id"])
                if not plan:
                    continue
                names = [index["names"][s[0]] for s in row["s"]]
                if row["r"] != signature(plan) or names != [plan["nodes"][j][0] for j in plan["stops"]]:
                    del plans[row["id"]]
                    continue
                for i, idx in enumerate(row["p"]):
                    if idx >= 0:
                        donors.add(codec.topology(plan, *plan["stops"][i:i+2]), group["paths"][idx], row["k"][i])
    graph = network.Network(",".join(args.osm), national) if args.osm else None
    graph_legs = {}

    @lru_cache(maxsize=8192)
    def bridge(left, right, station):
        if not graph or network.distance(left,right) > 1600:
            return None
        centre = graph.position(station)
        if centre is None or max(network.distance(centre,p) for p in (left,right)) > 900:
            return None
        link = graph.connect(left, right)
        return codec.pack([left, *link, right]) if link else None

    @lru_cache(maxsize=8192)
    def assembled(key):
        return donors.assemble(key, bridge) if len(key) > 1 else None

    @lru_cache(maxsize=8192)
    def align(left, right, station):
        a, b = ends(left)[1], ends(right)[0]
        bridge = graph.connect(a, b)
        if bridge:
            return left, codec.pack([a, *bridge, *codec.unpack(right)])
        return graph.station_throat(codec.unpack(left), codec.unpack(right), graph.position(station))

    before, after, gained = Counter(), Counter(), Counter()
    still_missing = Counter()
    args.output.mkdir(parents=True, exist_ok=True)
    for bucket, group in groups.items():
        shape_ids = {s:i for i,s in enumerate(group["paths"])}
        changed = False
        for rows in group["trains"].values():
            for row in rows:
                legs = [None if i < 0 else group["paths"][i] for i in row["p"]]
                missing, gaps = measure(before, legs)
                plan = plans.get(row["id"])
                if plan and (missing or gaps):
                    old = legs.copy()
                    for i in missing:
                        key = codec.topology(plan, *plan["stops"][i:i+2])
                        candidates = donors.slices(key) if key else ()
                        if candidates:
                            left = ends(legs[i-1])[1] if i and legs[i-1] else None
                            right = ends(legs[i+1])[0] if i+1 < len(legs) and legs[i+1] else None
                            def join_cost(candidate):
                                a, b = ends(candidate[0])
                                distances = [network.distance(x,y) for x,y in ((a,left),(b,right)) if y is not None]
                                return (sum(d>120 for d in distances), sum(distances), candidate[1])
                            legs[i], row["k"][i] = min(candidates, key=join_cost)
                            gained["matchingCorridor"] += 1
                        elif key and (combined := assembled(key)):
                            legs[i], row["k"][i] = combined
                            gained["joinedCorridors"] += 1
                        elif graph and key:
                            if key not in graph_legs:
                                trace = graph.leg(plan, i)
                                graph_legs[key] = trace
                                if trace:
                                    graph_legs.setdefault(codec.reverse_key(key), codec.pack(codec.unpack(trace)[::-1]))
                            if graph_legs[key]:
                                legs[i], row["k"][i] = graph_legs[key], 3
                                gained["osm"] += 1
                    if graph:
                        for i in issues(legs)[1]:
                            station = index["names"][row["s"][i][0]]
                            pair = align(legs[i-1], legs[i], station)
                            if pair:
                                if legs[i-1] != pair[0]:
                                    row["k"][i-1] = 3
                                legs[i-1], legs[i] = pair
                                row["k"][i] = 3
                                gained["stationJoins"] += 1
                    if old != legs:
                        changed = True
                        for i, shape in enumerate(legs):
                            if shape and shape != old[i]:
                                if shape not in shape_ids:
                                    shape_ids[shape] = len(group["paths"])
                                    group["paths"].append(shape)
                                row["p"][i] = shape_ids[shape]
                missing, gaps = measure(after, legs)
                for i in missing:
                    a, b = row["s"][i:i+2]
                    still_missing[f'{index["names"][a[0]]} → {index["names"][b[0]]}'] += 1
        if changed:
            raw = json.dumps(group, ensure_ascii=False, separators=(",",":")).encode()
            filename = f"{bucket}-{hashlib.sha256(raw).hexdigest()[:12]}.json"
            (args.output/filename).write_bytes(raw)
            index["groups"][bucket] = filename
        else:
            filename = index["groups"][bucket]
            (args.output/filename).write_bytes((args.baseline/filename).read_bytes())
    codec.dump(args.output/"index.json", index)
    manifest = dict(version=index["version"], edition=index["edition"], groups=index["groups"],
                    aliases={n:v for n,v in index["lookup"].items() if v != [codec.group(n)]})
    (args.output/"manifest.js").write_text("globalThis.atlasPathManifest="+json.dumps(manifest,separators=(",",":"))+";\n")
    report = dict(edition=index["edition"], before=before, after=after, gained=gained,
                  remainingStationPairs=dict(still_missing.most_common()))
    codec.dump(args.report, report)
    print(dict(before), "→", dict(after), dict(gained), flush=True)


if __name__ == "__main__":
    main()
