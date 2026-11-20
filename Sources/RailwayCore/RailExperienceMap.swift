import Foundation
import CSQLite

/// Read only: opening an experience must never migrate, evict or refresh map tiles.
public enum RailExperienceCache {
    public static func read(_ url: URL, bounds: MapBounds? = nil, metroOnly: Bool = true,
                            zoom: Int? = nil, layers: [RailTileLayer]? = nil,
                            tiles: Set<RailTile>? = nil) throws -> RailTileFeatures {
        guard FileManager.default.fileExists(atPath: url.path) else { return RailTileFeatures() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw DataError.invalid("无法只读打开地图缓存")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var query: OpaquePointer?
        let selected = layers ?? (metroOnly ? [.metroNetwork] : [.tracks, .stations])
        guard !selected.isEmpty, tiles?.isEmpty != true else { return RailTileFeatures() }
        // Constrain the rows before SQLite sorts or materializes any tile BLOBs.
        let layerList = selected.map { "'\($0.rawValue)'" }.joined(separator: ",")
        var predicates = ["layer IN (\(layerList))"]
        if let zoom { predicates.append("z = \(zoom)") }
        if let tiles, let minX = tiles.map(\.x).min(), let maxX = tiles.map(\.x).max(),
           let minY = tiles.map(\.y).min(), let maxY = tiles.map(\.y).max() {
            predicates += ["x BETWEEN \(minX) AND \(maxX)", "y BETWEEN \(minY) AND \(maxY)"]
        }
        let sql = "SELECT layer,z,x,y,data,fetched FROM tiles WHERE " + predicates.joined(separator: " AND ") + " ORDER BY fetched DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw DataError.invalid("缓存格式不受支持")
        }
        defer { sqlite3_finalize(query) }
        var result = RailTileFeatures(), seen = Set<String>(), bytes = 0
        let formatter = ISO8601DateFormatter()
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            let raw = String(cString: sqlite3_column_text(query, 0))
            let z = Int(sqlite3_column_int(query, 1))
            let tile = RailTile(z: z, x: Int(sqlite3_column_int(query, 2)), y: Int(sqlite3_column_int(query, 3)))
            if let layer = RailTileLayer(rawValue: raw), tiles?.contains(tile) != false, bounds == nil || tile.bounds.intersects(bounds!),
               seen.insert("\(raw)/\(tile.path)").inserted {
                let count = Int(sqlite3_column_bytes(query, 4))
                bytes += count
                guard bytes <= 160_000_000, count <= VectorTileDecoder.maxBytes else {
                    throw DataError.invalid("本次缓存读取过大，请缩小范围")
                }
                if count > 0, let pointer = sqlite3_column_blob(query, 4) {
                    let data = Data(bytes: pointer, count: count)
                    var value = try RailwayTileRepository.decode(data, key: RailTileKey(layer: layer, tile: tile))
                    let date = String(formatter.string(from: Date(timeIntervalSince1970: sqlite3_column_double(query, 5))).prefix(10))
                    for i in value.lines.indices { value.lines[i].tags["atlas:cacheDate"] = date }
                    result.lines += value.lines
                    result.stations += value.stations
                }
            }
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw DataError.invalid("缓存读取未完成") }
        return result
    }
}

public struct RailDatedSegment: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var coordinates: [Coordinate]
    public var opened: String?
    public var construction: String?
    public var closed: String?
    public var sourceURL: String
    public var colour: String?

    public func visible(on date: String) -> Bool {
        guard let opened, Self.upperBound(opened) <= date else { return false }
        return closed.map { Self.upperBound($0) > date } ?? true
    }
    /// A year-only date becomes certain at the end of that year.
    public static func upperBound(_ date: String) -> String {
        if date.count == 4 { return date + "-12-31" }
        if date.count == 7 {
            let year = Int(date.prefix(4)) ?? 2000, month = Int(date.suffix(2)) ?? 1
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let day = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            let last = calendar.range(of: .day, in: .month, for: day)!.count
            return date + String(format: "-%02d", last)
        }
        return date
    }
    public static func from(_ line: RailLine) -> Self {
        func date(_ keys: [String]) -> String? {
            keys.compactMap { line.tags[$0] }.first(where: RailCivilDate.validHistorical)
        }
        let osm = line.tags["atlas:osm"] ?? line.id
        return .init(id: line.id, name: line.name, coordinates: line.coordinates,
                     opened: date(["opening_date", "start_date"]),
                     construction: date(["construction:start_date"]),
                     closed: date(["end_date", "closure_date"]),
                     sourceURL: "https://www.openstreetmap.org/\(osm)",
                     colour: line.routes?.first?.color?.hex ?? line.tags["colour"])
    }
}

public struct RailHistoryRegion: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var segments: [RailDatedSegment]
    public init(id: String, title: String, segments: [RailDatedSegment]) {
        self.id = id; self.title = title; self.segments = segments
    }
    public var dates: [String] {
        Set(segments.flatMap { [$0.opened, $0.construction, $0.closed].compactMap { $0 }
            .map(RailDatedSegment.upperBound) }).sorted()
    }
    public var unknownCount: Int { segments.filter { $0.opened == nil }.count }
    public var bounds: MapBounds { MapBounds(points: segments.flatMap(\.coordinates)) }
}

public enum RailHistoricalGeometry {
    /// Dates belong to OSM ways. Never inherit a relation's first-opening date
    /// onto extensions, and never interpret an OSM edit timestamp as opening.
    public static func bundled() throws -> [RailHistoryRegion] {
        try [("hongkong", "香港"), ("beijing", "北京"), ("qingdao", "青岛"),
             ("jinan", "济南"), ("macao", "澳门"), ("tokyo", "东京")].compactMap { key, title in
            guard let url = Bundle.main.url(forResource: "metro-snapshot-\(key)", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "metro-snapshot-\(key)", withExtension: "json") else { return nil }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            let segments = document.elements.compactMap { element -> RailDatedSegment? in
                guard element.type == "way", let tags = element.tags,
                      ["rail", "subway", "light_rail", "tram", "monorail", "narrow_gauge", "funicular"].contains(tags["railway"] ?? ""),
                      !["siding", "yard", "spur"].contains(tags["service"] ?? ""),
                      let points = element.geometry, points.count >= 2,
                      points.allSatisfy({ $0.lat != nil && $0.lon != nil }) else { return nil }
                let line = RailLine(id: "way/\(element.id)", name: tags["name:zh-Hans"] ?? tags["name:zh"] ?? tags["name"] ?? "铁路区段",
                                    coordinates: points.map { Coordinate($0.lat!, $0.lon!) }, tags: tags)
                return RailDatedSegment.from(line)
            }
            guard segments.contains(where: { $0.opened != nil }) else { return nil }
            return RailHistoryRegion(id: key, title: title, segments: segments)
        }
    }
    private struct Document: Decodable { var elements: [Element] }
    private struct Element: Decodable {
        var type: String; var id: Int64; var tags: [String: String]?; var geometry: [Point]?
    }
    private struct Point: Decodable { var lat: Double?; var lon: Double? }
}

/// Each leg is continuous track geometry, ordered from one timetable stop to
/// the next. A missing leg is an error, never replaced with a straight line.
public struct RailTrackJourney: Codable, Identifiable, Sendable {
    public var id: String
    public var train: String
    public var serviceDate: String
    public var stations: [String]
    public var legs: [[Coordinate]]
    public var source: RailEvidence
    public var distance: Double { legs.reduce(0) { $0 + Self.length($1) } }
    public func validate(for timetable: RailTimetable) throws {
        try source.validate()
        guard train == timetable.train, serviceDate == timetable.serviceDate,
              stations == timetable.stops.map(\.station), legs.count == stations.count - 1 else {
            throw DataError.invalid("径路与该日期车次的经停站不一致")
        }
        guard legs.reduce(0, { $0 + $1.count }) <= 250_000 else { throw DataError.invalid("径路过大") }
        for (i, leg) in legs.enumerated() {
            guard leg.count >= 2, leg.allSatisfy(\.isValid), Self.length(leg) > 0,
                  zip(leg, leg.dropFirst()).allSatisfy({ Self.metres($0.0, $0.1) < 2_000 }) else {
                throw DataError.invalid("第 \(i + 1) 个区间存在缺失或不连续的轨道")
            }
            if i > 0, Self.metres(legs[i - 1].last!, leg[0]) > 120 {
                throw DataError.invalid("车站两侧径路没有衔接")
            }
        }
    }
    public func coordinate(at position: RailTimetable.Position) -> Coordinate? {
        guard position.phase != .unknown, !legs.isEmpty else { return nil }
        if position.phase == .running, legs.indices.contains(position.from) {
            return Self.interpolate(legs[position.from], fraction: position.fraction)
        }
        if position.from == legs.count { return legs.last?.last }
        return legs.indices.contains(position.from) ? legs[position.from].first : nil
    }
    public static func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let x = (b.longitude - a.longitude) * cos((a.latitude + b.latitude) * .pi / 360)
        return hypot(x, b.latitude - a.latitude) * 111_195
    }
    public static func length(_ points: [Coordinate]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + metres($1.0, $1.1) }
    }
    public static func interpolate(_ points: [Coordinate], fraction: Double) -> Coordinate? {
        guard let first = points.first else { return nil }
        var remaining = max(0, min(1, fraction)) * length(points)
        for (a, b) in zip(points, points.dropFirst()) {
            let d = metres(a, b)
            if remaining <= d, d > 0 {
                let t = remaining / d
                return Coordinate(a.latitude + (b.latitude - a.latitude) * t,
                                  a.longitude + (b.longitude - a.longitude) * t)
            }
            remaining -= d
        }
        return points.last ?? first
    }
    public static func bundled() throws -> [Self] {
        guard let url = Bundle.main.url(forResource: "railway-experience-routes", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "railway-experience-routes", withExtension: "json") else { return [] }
        let existing = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        let samples = try RailExperienceCatalog.timetables().compactMap(RailCorridor.sampleG337)
        return existing + samples
    }
}
