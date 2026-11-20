import Foundation

/// Matches a provider's ordered, mileage-checked line path to actual OSM ways.
/// Missing geometry is an error; no station-to-station straight-line fallback.
public enum RailJourneyMatcher {
    public static func normalized(_ name: String) -> String {
        let simplified = name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name
        return simplified.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? simplified
    }
    private static func stationKey(_ name: String) -> String {
        var value = normalized(name).replacingOccurrences(of: "线路所", with: "所")
        if value.hasSuffix("站") { value.removeLast() }
        return value
    }
    public static func location(_ node: LuluRoutePlan.Node, in stations: [RailStation]) -> Coordinate? {
        StationIndex(stations).location(node)
    }
    struct StationIndex {
        private var byName: [String: [RailStation]] = [:]
        private var byCode: [String: [RailStation]] = [:]
        init(_ stations: [RailStation]) {
            var normalized: [String: String] = [:]
            for station in stations {
                guard !["subway", "light_rail", "tram"].contains(station.tags["station"] ?? ""),
                      !["construction", "proposed", "disused", "abandoned"].contains(station.tags["state"] ?? "") else { continue }
                for raw in Set([station.name, station.tags["name:zh"], station.tags["name:zh-Hans"], station.tags["alt_name"]].compactMap { $0 }) where !raw.isEmpty {
                    let key = normalized[raw] ?? RailJourneyMatcher.stationKey(raw)
                    normalized[raw] = key
                    byName[key, default: []].append(station)
                }
                for key in Set([station.tags["railway:ref"], station.tags["ref"]].compactMap { $0 }) where !key.isEmpty {
                    byCode[key, default: []].append(station)
                }
            }
        }
        func location(_ node: LuluRoutePlan.Node) -> Coordinate? {
            let matches = (byCode[node.code] ?? []) + (byName[RailJourneyMatcher.stationKey(node.station)] ?? [])
            guard let first = matches.min(by: { $0.id < $1.id }), matches.allSatisfy({
                RailTrackJourney.metres($0.coordinate, first.coordinate) < 2000
            }) else { return nil }
            return first.coordinate
        }
    }
    private static func lineKey(_ name: String) -> String {
        var value = normalized(name)
        if value.hasPrefix("广深港") { return "广深港" }
        let aliases = ["京哈京沈段": "京沈", "京哈沈哈段": "哈大"]
        if let alias = aliases[value] { return alias }
        for suffix in ["客运专线", "高速铁路", "高速线", "客专线", "高铁", "客专", "铁路", "线"] {
            if value.hasSuffix(suffix) { value = String(value.dropLast(suffix.count)); break }
        }
        return value
    }
    private static func highSpeed(_ name: String) -> Bool {
        ["高铁", "高速", "客专", "客运专线", "广深港", "京哈京沈段", "京哈沈哈段"].contains { name.contains($0) }
    }
    private static func eligible(_ line: RailLine, names: Set<String>, anchors: [Coordinate], references: Set<String> = []) -> Bool {
        guard line.tags["railway"] == "rail",
              !["construction", "proposed", "disused", "abandoned", "razed"].contains(line.tags["state"] ?? ""),
              !["yard", "siding", "spur"].contains(line.tags["service"] ?? ""),
              !line.isUrbanTransit else { return false }
        if let ref = line.tags["ref"], references.contains(ref) { return true }
        let actualNames = [line.name, line.tags["name:zh"] ?? "", line.tags["alt_name"] ?? ""]
        if names.contains(where: { required in
            actualNames.contains { actual in
                lineKey(actual) == lineKey(required)
                    && (!highSpeed(required) || highSpeed(actual) || line.tags["highspeed"] == "yes")
                    && (highSpeed(required) || !(highSpeed(actual) || line.tags["highspeed"] == "yes"))
            }
        }) { return true }
        // Unnamed through tracks at a station may connect named approach ways.
        // Never admit an unrelated named main line as a shortest-path shortcut.
        let unnamed = line.tags["name"] == nil && line.tags["name:zh"] == nil && line.tags["ref"] == nil
        return unnamed && line.coordinates.allSatisfy { p in anchors.contains { RailTrackJourney.metres(p, $0) < 1200 } }
    }

    public static func match(_ timetable: RailTimetable, features: RailTileFeatures) throws -> RailTrackJourney {
        guard let plan = timetable.routing else { throw DataError.invalid("旧时刻库未含列车径路，请先同步路路通离线库") }
        try plan.validate(for: timetable)
        let index = StationIndex(features.stations)
        let locations = plan.nodes.map(index.location)
        var required = Set(plan.stopIndices)
        for i in 1..<plan.edges.count where plan.edges[i - 1].lineID != plan.edges[i].lineID { required.insert(i) }
        let missing = required.sorted().filter { locations[$0] == nil }
        guard missing.isEmpty else { throw DataError.invalid("尚缺车站或换线点坐标：" + missing.prefix(8).map { plan.nodes[$0].station }.joined(separator: "、")) }
        let anchors = locations.indices.filter { locations[$0] != nil }
        var legs: [[Coordinate]] = [], accumulated: [Coordinate] = []
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            try Task.checkCancellation()
            var aliases = Set(plan.edges[a].aliases)
            for edge in plan.edges[a..<b] { aliases.formIntersection(edge.aliases) }
            guard !aliases.isEmpty else { throw DataError.invalid("换线点尚未定位，不能跳过径路节点") }
            let from = locations[a]!, to = locations[b]!
            let margin = max(0.12, abs(from.latitude - to.latitude) * 0.3, abs(from.longitude - to.longitude) * 0.3)
            let bounds = MapBounds(south: min(from.latitude, to.latitude) - margin, west: min(from.longitude, to.longitude) - margin,
                                   north: max(from.latitude, to.latitude) + margin, east: max(from.longitude, to.longitude) + margin)
            let nearby = features.lines.filter { $0.coordinates.contains(where: bounds.contains) }
            let references = Set(nearby.filter { eligible($0, names: aliases, anchors: [from, to]) }.compactMap { $0.tags["ref"] })
            let lines = nearby.filter { eligible($0, names: aliases, anchors: [from, to], references: references) }
            let graph = try TrackGraph(lines: lines)
            let path: [Coordinate]
            do { path = try graph.path(from: from, to: to) }
            catch { throw DataError.invalid("\(plan.nodes[a].station) → \(plan.nodes[b].station)（\(plan.edges[a].lineName)）：\(error.localizedDescription)") }
            let actual = RailTrackJourney.length(path), expected = Double(plan.nodes[b].kilometre - plan.nodes[a].kilometre) * 1000
            guard abs(actual - expected) <= max(2500, expected * 0.18) else {
                throw DataError.invalid("\(plan.nodes[a].station) → \(plan.nodes[b].station)的地图距离与径路里程不符，未采用可疑路径")
            }
            if let last = accumulated.last, RailTrackJourney.metres(last, path[0]) > 120 {
                throw DataError.invalid("换线处轨道未衔接")
            }
            accumulated += path
            if plan.stopIndices.contains(b) { legs.append(accumulated); accumulated = [] }
        }
        let value = RailTrackJourney(id: "llt-track/\(timetable.id)/\(plan.providerID)", train: timetable.train,
            serviceDate: timetable.serviceDate, stations: timetable.stops.map(\.station), legs: legs,
            source: RailEvidence(title: "路路通径路 · OpenStreetMap 铁路几何", url: "https://openrailwaymap.app/",
                retrievedOn: timetable.source.retrievedOn,
                note: "路路通版本 \(plan.edition)，径路 \(plan.providerID)。按经由线路、站序及计价里程匹配实际轨道；站场股道可能有偏差。位置按时刻与沿轨道距离插值，非实时定位。"))
        try value.validate(for: timetable)
        return value
    }

    private struct TrackGraph {
        var nodes: [Coordinate] = []
        var edges: [[(Int, Double)]] = []
        var cells: [String: [Int]] = [:]
        init(lines: [RailLine]) throws {
            for (index, line) in lines.enumerated() {
                if index % 100 == 0 { try Task.checkCancellation() }
                var previous: Int?
                for (a, b) in zip(line.coordinates, line.coordinates.dropFirst()) {
                    guard a.isValid, b.isValid else { continue }
                    let steps = max(1, Int(ceil(RailTrackJourney.metres(a, b) / 35)))
                    guard steps < 10_000 else { throw DataError.invalid("地图轨道几何异常") }
                    for j in 0...steps {
                        let f = Double(j) / Double(steps)
                        let point = Coordinate(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f)
                        let id = node(point)
                        if let last = previous, last != id {
                            let d = RailTrackJourney.metres(nodes[last], nodes[id])
                            edges[last].append((id, d)); edges[id].append((last, d))
                        }
                        previous = id
                    }
                }
                guard nodes.count < 600_000 else { throw DataError.invalid("单段轨道匹配范围过大") }
            }
        }
        mutating func node(_ p: Coordinate) -> Int {
            let x = Int(floor(p.longitude * 111195 / 25)), y = Int(floor(p.latitude * 111195 / 25))
            let dx = max(1, Int(ceil(1 / cos(p.latitude * .pi / 180))))
            var nearest: Int?, distance = 25.0
            for xx in (x - dx)...(x + dx) { for yy in (y - 1)...(y + 1) {
                for id in cells["\(xx)/\(yy)", default: []] {
                    let d = RailTrackJourney.metres(p, nodes[id])
                    if d < distance { distance = d; nearest = id }
                }
            }}
            if let nearest { return nearest }
            let id = nodes.count; nodes.append(p); edges.append([]); cells["\(x)/\(y)", default: []].append(id)
            return id
        }
        func path(from: Coordinate, to: Coordinate) throws -> [Coordinate] {
            var components = [Int](repeating: -1, count: nodes.count), component = 0
            for start in nodes.indices where components[start] == -1 {
                var queue = [start], cursor = 0; components[start] = component
                while cursor < queue.count {
                    for (next, _) in edges[queue[cursor]] where components[next] == -1 {
                        components[next] = component; queue.append(next)
                    }
                    cursor += 1
                }
                component += 1
            }
            func candidates(_ point: Coordinate) -> [Int: (Int, Double)] {
                var result: [Int: (Int, Double)] = [:]
                for id in nodes.indices {
                    let distance = RailTrackJourney.metres(nodes[id], point), group = components[id]
                    if distance < 650, distance < (result[group]?.1 ?? .infinity) { result[group] = (id, distance) }
                }
                return result
            }
            let starts = candidates(from), ends = candidates(to)
            guard let common = starts.keys.filter({ ends[$0] != nil }).min(by: {
                starts[$0]!.1 + ends[$0]!.1 < starts[$1]!.1 + ends[$1]!.1
            }) else { throw DataError.invalid("车站两端没有连续的对应线路轨道") }
            let start = starts[common]!.0, end = ends[common]!.0
            var costs = [Double](repeating: .infinity, count: nodes.count), previous = [Int](repeating: -1, count: nodes.count)
            var heap = Heap(); costs[start] = 0; heap.push((0, start))
            var count = 0
            while let (cost, id) = heap.pop() {
                if cost > costs[id] { continue }
                if id == end { break }
                count += 1; if count % 1000 == 0 { try Task.checkCancellation() }
                for (next, distance) in edges[id] where cost + distance < costs[next] {
                    costs[next] = cost + distance; previous[next] = id; heap.push((costs[next], next))
                }
            }
            guard costs[end].isFinite, start != end else { throw DataError.invalid("对应线路轨道不连续，请补充地图数据后重试") }
            var path: [Coordinate] = [], cursor = end
            while cursor >= 0 { path.append(nodes[cursor]); if cursor == start { break }; cursor = previous[cursor] }
            return path.reversed()
        }
        struct Heap {
            var items: [(Double, Int)] = []
            mutating func push(_ value: (Double, Int)) {
                items.append(value); var i = items.count - 1
                while i > 0 { let p = (i - 1) / 2; if items[p].0 <= value.0 { break }; items[i] = items[p]; i = p }
                items[i] = value
            }
            mutating func pop() -> (Double, Int)? {
                guard let first = items.first else { return nil }; let last = items.removeLast()
                if !items.isEmpty {
                    var i = 0
                    while 2 * i + 1 < items.count {
                        var c = 2 * i + 1
                        if c + 1 < items.count && items[c + 1].0 < items[c].0 { c += 1 }
                        if last.0 <= items[c].0 { break }; items[i] = items[c]; i = c
                    }
                    items[i] = last
                }
                return first
            }
        }
    }
}

public actor RailJourneyRouteRepository {
    private let directory: URL
    private let mapCache: URL
    private let tiles: RailwayTileRepository
    private var stationCache: [RailStation]?
    public init(directory: URL, mapCache: URL) {
        self.directory = directory; self.mapCache = mapCache
        self.tiles = RailwayTileRepository(directory: directory.appendingPathComponent("Tiles"))
    }
    private struct Cached: Codable { var timetable: RailTimetable; var journey: RailTrackJourney }
    public func route(_ timetable: RailTimetable, allowNetwork: Bool = true) async throws -> RailTrackJourney {
        guard allowNetwork else { return try await resolve(timetable, allowNetwork: false) }
        return try await withThrowingTaskGroup(of: RailTrackJourney.self) { group in
            group.addTask { try await self.resolve(timetable, allowNetwork: true) }
            group.addTask {
                try await Task.sleep(for: .seconds(35))
                throw DataError.invalid("35 秒内未能取得完整轨道。可重试，或在主地图缓存沿线区域。")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
    private func resolve(_ timetable: RailTimetable, allowNetwork: Bool) async throws -> RailTrackJourney {
        try timetable.validate()
        guard let plan = timetable.routing else {
            throw DataError.invalid(timetable.routingIssue ?? "该时刻快照未含列车径路，请同步路路通离线库后重新选择车次")
        }
        let key = timetable.id.utf8.map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("route-" + String(key.prefix(180)) + ".json")
        if let data = try? Data(contentsOf: file), data.count <= 20_000_000,
           let cached = try? JSONDecoder().decode(Cached.self, from: data), cached.timetable == timetable,
           (try? cached.journey.validate(for: timetable)) != nil { return cached.journey }
        if let route = RailCorridor.journey(timetable) {
            try Task.checkCancellation()
            return route
        }
        let journeyTiles = directory.appendingPathComponent("Tiles/railways.railcache")
        if stationCache == nil {
            var stored: [RailStation] = []
            for cache in [mapCache, journeyTiles] {
                stored += (try? RailExperienceCache.read(cache, zoom: 10, layers: [.stations]))?.stations ?? []
                try Task.checkCancellation()
            }
            let file = directory.appendingPathComponent("station-locations.json")
            if let data = try? Data(contentsOf: file), data.count < 10_000_000,
               let stations = try? JSONDecoder().decode([RailStation].self, from: data) {
                stored += stations.filter { $0.coordinate.isValid }
            }
            stationCache = stored
        }
        var features = RailTileFeatures()
        features.stations = stationCache ?? []
        var index = RailJourneyMatcher.StationIndex(features.stations)
        var required = Set(plan.stopIndices)
        for i in 1..<plan.edges.count where plan.edges[i - 1].lineID != plan.edges[i].lineID { required.insert(i) }
        let mandatory = required.sorted().map { plan.nodes[$0] }
        var missing = mandatory.filter { index.location($0) == nil }
        if allowNetwork, !missing.isEmpty {
            features.stations += try await facilities(missing)
            index = RailJourneyMatcher.StationIndex(features.stations)
            missing = mandatory.filter { index.location($0) == nil }
            if !missing.isEmpty { features.stations += try await locate(missing) }
            index = RailJourneyMatcher.StationIndex(features.stations)
            missing = mandatory.filter { index.location($0) == nil }
            let stations = Dictionary(features.stations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(stations)).write(to: directory.appendingPathComponent("station-locations.json"), options: .atomic)
            stationCache = Array(stations)
        }
        guard missing.isEmpty else { throw DataError.invalid("尚缺车站或换线点坐标：" + missing.map(\.station).joined(separator: "、")) }
        let positions = plan.nodes.compactMap(index.location)
        guard positions.count >= 2 else { throw DataError.invalid("地图源暂未提供该径路的车站坐标") }
        var requested = Set<RailTile>()
        for (a, b) in zip(positions, positions.dropFirst()) {
            let steps = max(1, Int(ceil(RailTrackJourney.metres(a, b) / 15_000)))
            for i in 0...steps {
                let f = Double(i) / Double(steps), lat = a.latitude + (b.latitude - a.latitude) * f, lon = a.longitude + (b.longitude - a.longitude) * f
                requested.formUnion(RailTile.covering(MapBounds(south: lat - 0.18, west: lon - 0.18, north: lat + 0.18, east: lon + 0.18), zoom: 10))
            }
        }
        for cache in [mapCache, journeyTiles] {
            features.lines += (try? RailExperienceCache.read(cache, zoom: 10, layers: [.tracks], tiles: requested))?.lines ?? []
            try Task.checkCancellation()
        }
        do {
            let result = try RailJourneyMatcher.match(timetable, features: features)
            try save(result, timetable: timetable, file: file)
            return result
        } catch {
            try Task.checkCancellation()
            if !allowNetwork { throw error }
        }
        guard requested.count <= 700 else { throw DataError.invalid("沿线轨道覆盖不足，请先缓存途经地区或选择较短的乘车区间。") }
        let keys = requested.sorted { $0.path < $1.path }.flatMap { tile in [RailTileKey(layer: .tracks, tile: tile), RailTileKey(layer: .stations, tile: tile)] }
        let repository = tiles
        try await withThrowingTaskGroup(of: RailTileFeatures?.self) { group in
            var cursor = 0
            func enqueue(_ key: RailTileKey) {
                group.addTask {
                    do { return try await repository.routingTile(key).features }
                    catch { try Task.checkCancellation(); return nil }
                }
            }
            for _ in 0..<min(4, keys.count) { enqueue(keys[cursor]); cursor += 1 }
            for try await value in group {
                if let value { features.lines += value.lines; features.stations += value.stations }
                if cursor < keys.count { enqueue(keys[cursor]); cursor += 1 }
            }
        }
        // The tile repository persists each successful download for future offline use.
        let result = try RailJourneyMatcher.match(timetable, features: features)
        try save(result, timetable: timetable, file: file)
        return result
    }
    private func save(_ journey: RailTrackJourney, timetable: RailTimetable, file: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Cached(timetable: timetable, journey: journey)).write(to: file, options: .atomic)
    }
    /// The map provider's facility search has indexed names and operational
    /// state; use it before the more expensive Overpass fallback.
    private func facilities(_ nodes: [LuluRoutePlan.Node]) async throws -> [RailStation] {
        struct Facility: Decodable {
            var osm_ids: [Int64]; var osm_types: [String]
            var name: String?; var localized_name: String?
            var feature: String?; var state: String?; var station: String?; var railway_ref: String?
            var latitude: Double; var longitude: Double
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let unique = Dictionary(nodes.map { ($0.station, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.station < $1.station }
        guard unique.count < 1000 else { throw DataError.invalid("沿线站所过多，请选择较短乘车区间") }
        var result: [RailStation] = []
        try await withThrowingTaskGroup(of: [RailStation].self) { group in
            var cursor = 0
            func enqueue(_ node: LuluRoutePlan.Node) {
                group.addTask {
                    var stations: [RailStation] = []
                    var variants = [node.station]
                    if node.station.hasSuffix("所"), !node.station.hasSuffix("线路所") {
                        variants.insert(String(node.station.dropLast()) + "线路所", at: 0)
                    }
                    variants += variants.compactMap { $0.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) }
                    var seen = Set<String>()
                    for name in variants where seen.insert(name).inserted {
                        var url = URLComponents(string: "https://openrailwaymap.app/api/facility")!
                        url.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "lang", value: "zh")]
                        do {
                            let (bytes, response) = try await session.bytes(from: url.url!)
                            defer { bytes.task.cancel() }
                            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength < 1_000_000 else { continue }
                            var data = Data()
                            for try await byte in bytes {
                                data.append(byte); if data.count > 1_000_000 { throw DataError.invalid("车站响应超限") }
                            }
                            let facilities = try JSONDecoder().decode([Facility].self, from: data)
                            stations += facilities.compactMap { item in
                                // Verified against the provider's own ui.js:
                                // the API's "latitude" contains X/lon and
                                // "longitude" contains Y/lat (center: [X,Y]).
                                let point = Coordinate(item.longitude, item.latitude)
                                guard point.isValid, let id = item.osm_ids.first, let type = item.osm_types.first else { return nil }
                                let kind = ["N": "node", "W": "way", "R": "relation"][type] ?? "node"
                                var tags = ["railway": item.feature ?? "station", "state": item.state ?? "",
                                            "station": item.station ?? "", "name": item.name ?? ""]
                                tags["railway:ref"] = item.railway_ref
                                return RailStation(id: "\(kind)/\(id)", name: item.localized_name ?? item.name ?? "",
                                    coordinate: point, tags: tags)
                            }
                            if RailJourneyMatcher.location(node, in: stations) != nil { break }
                        } catch { try Task.checkCancellation() }
                    }
                    return stations
                }
            }
            for _ in 0..<min(3, unique.count) { enqueue(unique[cursor]); cursor += 1 }
            for try await stations in group {
                result += stations
                if cursor < unique.count { enqueue(unique[cursor]); cursor += 1 }
            }
        }
        return result
    }
    private func locate(_ nodes: [LuluRoutePlan.Node]) async throws -> [RailStation] {
        struct Document: Decodable { var elements: [Element] }
        struct Element: Decodable {
            var type: String; var id: Int64; var lat: Double?; var lon: Double?
            var center: Center?; var tags: [String: String]?
        }
        struct Center: Decodable { var lat: Double; var lon: Double }
        var output: [RailStation] = []
        for start in stride(from: 0, to: nodes.count, by: 35) {
            try Task.checkCancellation()
            let batch = nodes[start..<min(nodes.count, start + 35)]
            func escaped(_ value: String) -> String {
                NSRegularExpression.escapedPattern(for: value).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            }
            let variants = batch.flatMap { node -> [String] in
                let base = node.station
                let alternative = base.hasSuffix("所") ? String(base.dropLast()) + "线路所" : base + "站"
                return [base, alternative].flatMap { [$0, $0.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? $0] }
            }
            let names = Set(variants).sorted().map(escaped).joined(separator: "|")
            let codes = batch.map { escaped($0.code) }.joined(separator: "|")
            let query = "[out:json][timeout:25];(nwr[railway][name~\"^(\(names))( |$)\"];nwr[railway][\"name:zh\"~\"^(\(names))$\"];nwr[railway][\"railway:ref\"~\"^(\(codes))$\"];nwr[railway][ref~\"^(\(codes))$\"];);out center tags;"
            let endpointResult = await withTaskGroup(of: Document?.self, returning: Document?.self) { group in
                for endpoint in [DataEndpoint.vk, .primary, .community] {
                    group.addTask {
                        var request = URLRequest(url: URL(string: endpoint.rawValue)!)
                        request.httpMethod = "POST"; request.timeoutInterval = 8
                        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        var form = URLComponents(); form.queryItems = [URLQueryItem(name: "data", value: query)]
                        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
                        do {
                            let config = URLSessionConfiguration.ephemeral
                            config.timeoutIntervalForResource = 12
                            let endpointSession = URLSession(configuration: config)
                            defer { endpointSession.invalidateAndCancel() }
                            let (bytes, response) = try await endpointSession.bytes(for: request)
                            defer { bytes.task.cancel() }
                            guard (response as? HTTPURLResponse)?.statusCode == 200,
                                  response.expectedContentLength <= 5_000_000 else { return nil }
                            var data = Data()
                            for try await byte in bytes {
                                data.append(byte)
                                if data.count > 5_000_000 { return nil }
                            }
                            return try? JSONDecoder().decode(Document.self, from: data)
                        } catch {
                            return nil
                        }
                    }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }
            let succeeded = endpointResult != nil
            if let document = endpointResult {
                output += document.elements.compactMap { e in
                    guard let lat = e.lat ?? e.center?.lat, let lon = e.lon ?? e.center?.lon, let tags = e.tags, Coordinate(lat, lon).isValid else { return nil }
                    return RailStation(id: "\(e.type)/\(e.id)", name: tags["name"] ?? "", coordinate: Coordinate(lat, lon), tags: tags)
                }
            }
            try Task.checkCancellation()
            if !succeeded { throw DataError.invalid("地图源暂未返回坐标：" + batch.map(\.station).joined(separator: "、")) }
        }
        return output
    }
}
