"""Build the shared station inspector from a China Railway GTFS release and its lines.json."""
import argparse
import csv
import io
import json
import re
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile


def minute(value):
    if not value:
        return None
    hour, minutes, _ = map(int, value.split(":"))
    return hour * 60 + minutes


def build(archive, line_file, edition):
    def rows(name):
        return csv.DictReader(io.TextIOWrapper(archive.open(name + ".txt"), encoding="utf-8-sig"))

    stations = list(rows("stops"))
    names = [row["stop_name"] for row in stations]
    ids = {row["stop_id"]: i for i, row in enumerate(stations)}
    coordinates = [[float(r["stop_lat"]), float(r["stop_lon"])] if r["stop_lat"] and r["stop_lon"] else None for r in stations]
    calendars = defaultdict(list)
    for row in rows("calendar_dates"):
        if row["exception_type"] != "1":
            raise ValueError("Expected an additions-only service calendar")
        calendars[row["service_id"]].append(row["date"])
    calendar_ids = {key: i for i, key in enumerate(calendars)}
    calls = defaultdict(list)
    for row in rows("stop_times"):
        times = [minute(row["arrival_time"]), minute(row["departure_time"])]
        calls[row["trip_id"]].append((int(row["stop_sequence"]), [ids[row["stop_id"]], *times]))
    trains = []
    for row in rows("trips"):
        stops = [stop for _, stop in sorted(calls.pop(row["trip_id"]))]
        if len(stops) < 2:
            raise ValueError(f"Missing stops for {row['trip_id']}")
        trains.append([row["trip_short_name"], calendar_ids[row["service_id"]], stops, row["trip_id"]])
    if calls:
        raise ValueError("Stop times reference unknown trips")
    lines = []
    for name, records in json.loads(line_file.read_text()).items():
        stops = []
        for row in records:
            km = next((int(v[:-2]) for v in row[2:] if re.fullmatch(r"[0-9]+km", v.strip())), None)
            stops.append([row[1], km])
        if stops:
            lines.append([name, stops])
    return dict(edition=edition, names=names, coordinates=coordinates, trains=trains,
                calendars=list(calendars.values()), lines=lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path)
    parser.add_argument("lines", type=Path)
    parser.add_argument("edition")
    parser.add_argument("output", type=Path)
    parser.add_argument("--map-points", type=Path)
    parser.add_argument("--corridors", type=Path)
    args = parser.parse_args()
    with ZipFile(args.zip) as archive:
        directory = build(archive, args.lines, args.edition)
    body = json.dumps(directory, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    args.output.write_text("globalThis.atlasRailDirectory = " + body + ";\n")
    if args.map_points:
        points = {}
        for name, pair in zip(directory["names"], directory["coordinates"]):
            if pair and 0 < pair[0] < 65 and 65 < pair[1] < 145:
                points[name] = dict(id="national:"+name, name=name, coordinate=dict(latitude=pair[0], longitude=pair[1]),
                                    tags={"railway":"station","source":"China Railway GTFS / OpenStreetMap"})
        for corridor in json.loads(args.corridors.read_text()) if args.corridors else []:
            for stop in corridor["nodes"]:
                if stop["vertex"] is not None and stop["name"] not in points:
                    lon, lat = corridor["points"][stop["vertex"]]
                    name = stop["name"]
                    points[name] = dict(id="corridor:"+name, name=name, coordinate=dict(latitude=lat, longitude=lon),
                                        tags={"railway":"station","source":"铁道漫游经由区段 / OpenStreetMap"})
        args.map_points.write_text(json.dumps(list(points.values()), ensure_ascii=False, separators=(",",":"))+"\n")
    print(f"{len(directory['trains'])} trips, {len(directory['names'])} passenger stations, {len(directory['lines'])} lines")
