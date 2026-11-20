#!/usr/bin/env python3
"""Extract small, reproducible OSM metro snapshots from regional PBF files.

Requires pyosmium. No provider geometry, proximity-based line assignment or
coordinate conversion is used. Input SHA256 and OSM timestamps are recorded.
Usage: build-metro-snapshots.py SHANDONG.pbf TOKYO.pbf OUTPUT_DIRECTORY
"""
import argparse
import hashlib
import json
import pathlib
import sys

import osmium

URBAN = {"subway", "light_rail", "tram", "monorail"}
TYPE = {"n": "node", "w": "way", "r": "relation"}


def extract(path, identifier, bounds, source):
    def inside(lat, lon):
        return bounds[0] <= lat <= bounds[2] and bounds[1] <= lon <= bounds[3]

    # Pass one only copies urban memberships and named urban infrastructure.
    relations, ways, stations, station_areas = {}, {}, {}, {}
    wanted_nodes, wanted_ways = set(), set()
    newest = ""

    class Membership(osmium.SimpleHandler):
        def relation(self, relation):
            tags = dict(relation.tags)
            if tags.get("route") in URBAN or tags.get("route_master") in URBAN:
                members = [{"type": TYPE[m.type], "ref": m.ref, "role": m.role} for m in relation.members]
                relations[relation.id] = {"type": "relation", "id": relation.id, "tags": tags, "members": members}
                for member in members:
                    if member["type"] == "way" and member["role"] in ("", "forward", "backward"):
                        wanted_ways.add(member["ref"])
                    if member["type"] == "node" and member["role"].startswith("stop"):
                        wanted_nodes.add(member["ref"])

    Membership().apply_file(str(path))

    class Geometry(osmium.SimpleHandler):
        def way(self, way):
            nonlocal newest
            tags = dict(way.tags)
            if tags.get("railway") in {"station", "halt", "tram_stop"}:
                points = [(n.lat, n.lon) for n in way.nodes if n.location.valid()]
                if points:
                    lat = (min(p[0] for p in points) + max(p[0] for p in points)) / 2
                    lon = (min(p[1] for p in points) + max(p[1] for p in points)) / 2
                    if inside(lat, lon) and (tags.get("station") in URBAN or tags.get("subway") == "yes"):
                        station_areas[way.id] = {"type": "way", "id": way.id, "tags": tags,
                                                "center": {"lat": round(lat, 7), "lon": round(lon, 7)}}
            if way.id not in wanted_ways and tags.get("railway") not in URBAN:
                return
            points = [{"lat": round(n.lat, 7), "lon": round(n.lon, 7)} if n.location.valid() else None for n in way.nodes]
            if not any(p and inside(p["lat"], p["lon"]) for p in points):
                return
            ways[way.id] = {"type": "way", "id": way.id, "tags": tags, "geometry": points}
            newest = max(newest, way.timestamp.isoformat())

        def node(self, node):
            nonlocal newest
            tags = dict(node.tags)
            if not node.location.valid() or not inside(node.lat, node.lon):
                return
            if node.id not in wanted_nodes and not (
                tags.get("railway") in {"station", "halt", "tram_stop"} and
                (tags.get("station") in URBAN or tags.get("subway") == "yes" or tags.get("tram") == "yes")
            ):
                return
            stations[node.id] = {"type": "node", "id": node.id, "lat": round(node.lat, 7),
                                 "lon": round(node.lon, 7), "tags": tags}
            newest = max(newest, node.timestamp.isoformat())

    Geometry().apply_file(str(path), locations=True, idx="flex_mem")
    areas = {}

    class StopAreas(osmium.SimpleHandler):
        def relation(self, relation):
            if relation.tags.get("public_transport") != "stop_area":
                return
            members = [{"type": TYPE[m.type], "ref": m.ref, "role": m.role} for m in relation.members
                       if (m.type == "n" and m.ref in stations) or (m.type == "w" and m.ref in station_areas)]
            if members:
                areas[relation.id] = {"type": "relation", "id": relation.id, "tags": dict(relation.tags),
                                      "members": members}

    StopAreas().apply_file(str(path))
    # Only retain route/masters with actual in-region members. Full route tags
    # and original OSM IDs remain intact for live update and attribution.
    selected = {key: value for key, value in relations.items()
                if any(m["type"] == "way" and m["ref"] in ways for m in value["members"])}
    masters = {key: value for key, value in relations.items()
               if any(m["type"] == "relation" and m["ref"] in selected for m in value["members"])}
    selected.update(masters)
    for relation in selected.values():
        relation["members"] = [m for m in relation["members"]
                               if (m["type"] == "way" and m["ref"] in ways)
                               or (m["type"] == "node" and m["ref"] in stations)
                               or (m["type"] == "relation" and m["ref"] in selected)]
    sha = hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
    document = {
        "version": 0.6, "generator": "RailwayAtlas OSM metro snapshot",
        "atlas": {"id": identifier, "bounds": bounds, "source": source,
                  "license": "ODbL-1.0", "copyright": "OpenStreetMap contributors",
                  "inputSHA256": sha, "latestObjectTimestamp": newest},
        "elements": [selected[k] for k in sorted(selected)] + [areas[k] for k in sorted(areas)]
                    + [ways[k] for k in sorted(ways)] + [station_areas[k] for k in sorted(station_areas)]
                    + [stations[k] for k in sorted(stations)]
    }
    print(identifier, len(selected), "relations", len(ways), "ways", len(stations), "stations", newest)
    return document


if __name__ == "__main__":
    if sys.argv[1:2] == ["--city"]:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--city", required=True)
        parser.add_argument("--pbf", type=pathlib.Path, required=True)
        parser.add_argument("--bounds", type=float, nargs=4, required=True, metavar=("S", "W", "N", "E"))
        parser.add_argument("--source", required=True)
        parser.add_argument("--output", type=pathlib.Path, required=True)
        options = parser.parse_args()
        output = options.output
        jobs = [(options.pbf, options.city, options.bounds, options.source)]
    else:
        shandong, tokyo, output = map(pathlib.Path, sys.argv[1:])
        jobs = [
            (shandong, "qingdao", (35.55, 119.60, 36.75, 121.05),
             "https://download.openstreetmap.fr/extracts/asia/china/shandong.osm.pbf"),
            (shandong, "jinan", (36.25, 116.60, 37.10, 117.65),
             "https://download.openstreetmap.fr/extracts/asia/china/shandong.osm.pbf"),
            (tokyo, "tokyo", (35.5591, 139.6165, 35.7836, 139.9478),
             "https://download.bbbike.org/osm/bbbike/Tokyo/Tokyo.osm.pbf")
        ]
    output.mkdir(parents=True, exist_ok=True)
    for args in jobs:
        document = extract(*args)
        (output / f"metro-snapshot-{args[1]}.json").write_text(
            json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
