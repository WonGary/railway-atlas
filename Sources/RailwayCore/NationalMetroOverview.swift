import Foundation
import CryptoKit

/// A simplified projection of source relations, not complete infrastructure or
/// station coverage. Source city labels are retained verbatim, including labels
/// which describe a network rather than an administrative city.
public struct NationalMetroSnapshot: Sendable {
    public let lines: [RailLine]
    public let fetchedAt: Date
    public let sourceDate: String?
    public let cityNames: [String]
    public let routeCount: Int
    public let colouredRouteCount: Int
    public var vertexCount: Int { lines.reduce(0) { $0 + $1.coordinates.count } }

    fileprivate let records: [Record]
    private let index: RailSpatialIndex
    public static let maximumBytes = 32 * 1024 * 1024
    private static let maximumVertices = 1_500_000
    private static let maximumParts = 100_000

    fileprivate init(records input: [Record], fetchedAt: Date, sourceDate: String?) {
        // One representative per source relation is enough for the existing
        // global colour policy. Preserve each relation's original colour,
        // including an explicitly empty value, before propagating a sibling's.
        var records = input
        var representatives = RailTileFeatures()
        representatives.lines = records.map {
            var route = $0.route
            if route.tags["atlas:originalColour"] == nil {
                route.tags["atlas:originalColour"] = route.tags["colour"] ?? route.tags["color"] ?? ""
            }
            if route.tags["atlas:originalColourSourceID"] == nil {
                route.tags["atlas:originalColourSourceID"] = route.colourSourceID ?? route.id
            }
            return RailLine(id: route.id, name: route.name, coordinates: $0.parts[0], tags: [:], routes: [route])
        }
        let unified = MetroIdentity.unifyColours(representatives)
        for i in records.indices {
            var route = unified.lines[i].routes![0]
            route.tags["atlas:colourSourceID"] = route.colourSourceID
            if route.tags["colourSourceID"] != nil { route.tags["colourSourceID"] = route.colourSourceID }
            records[i].route = route
        }
        self.records = records
        routeCount = Set(records.map { $0.route.visibilityKey }).count
        colouredRouteCount = Set(records.filter { $0.route.color != nil }.map { $0.route.visibilityKey }).count
        self.fetchedAt = fetchedAt
        self.sourceDate = sourceDate
        cityNames = Set(records.map(\.city).filter { !$0.isEmpty }).sorted()
        var lines: [RailLine] = [], nextPart: [String: Int] = [:]
        for record in records {
            var tags = record.route.tags
            // service=metro/normal/events on a *route* is not a depot/siding.
            // Keep these original fields on the route and name their scope on
            // the projected geometry instead of applying infrastructure rules.
            for key in ["service", "usage", "depot"] {
                if let value = tags.removeValue(forKey: key) { tags["atlas:route:\(key)"] = value }
            }
            tags["railway"] = tags["route"]
            tags["atlas:osm"] = record.route.id
            tags["atlas:nationalOverview"] = "yes"
            tags["atlas:overviewCity"] = record.city
            tags["atlas:source"] = "OpenStreetMap · 全国轨道概览"
            // No way IDs, route_master, lifecycle or station associations are
            // invented from this relation-only export.
            for part in record.parts {
                let number = nextPart[record.route.id, default: 0]
                nextPart[record.route.id] = number + 1
                lines.append(RailLine(id: "national/\(record.route.id)/\(number)",
                    name: record.route.name, coordinates: part, tags: tags, routes: [record.route]))
            }
        }
        self.lines = lines
        index = RailSpatialIndex(bounds: lines.map { MapBounds(points: $0.coordinates) })
    }

    /// Returns whole intersecting parts with stable IDs. The renderer may clip
    /// them later. Empty memberships/stations do not imply complete tile data.
    public func features(in bounds: MapBounds? = nil) -> RailTileFeatures {
        var result = RailTileFeatures()
        guard let bounds else { result.lines = lines; return result }
        guard bounds.isValid else { return result }
        result.lines = index.query(bounds).compactMap {
            let line = lines[$0]
            return RailGeometryClip.segments(line.coordinates, inside: bounds).isEmpty ? nil : line
        }
        return result
    }

    public static func decodeGeoJSON(_ data: Data, fetchedAt: Date = .now,
                                     sourceDate: String? = nil) throws -> Self {
        guard data.count <= maximumBytes else { throw invalid("GeoJSON 超过 32 MB") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.type == "FeatureCollection", !document.features.isEmpty,
              document.features.count <= 20_000 else { throw invalid("FeatureCollection 无效或为空") }
        var records: [Record] = [], vertices = 0, partCount = 0
        for feature in document.features {
            try Task.checkCancellation()
            guard feature.type == "Feature",
                  let rawID = feature.properties["osm_id"]?.text,
                  let id = Int64(rawID), id > 0,
                  let city = feature.properties["city"]?.text,
                  let mode = feature.properties["route_type"]?.text,
                  RailCategory.urbanTypes.contains(mode) else { throw invalid("线路 relation ID、城市或类型无效") }
            let parts = try feature.geometry.parts()
            vertices += parts.reduce(0) { $0 + $1.count }
            partCount += parts.count
            guard vertices <= maximumVertices, partCount <= maximumParts else { throw invalid("几何数量超限") }
            var tags = feature.properties.compactMapValues(\.text)
            // Retain the export's original fields as well as their OSM names.
            tags["route"] = mode
            tags["name"] = tags["line_name"] ?? tags["name"]
            tags["from"] = tags["from_station"] ?? tags["from"]
            tags["to"] = tags["to_station"] ?? tags["to"]
            let name = [tags["name:zh"], tags["name"], tags["ref"]]
                .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? "OSM 线路 \(id)"
            let colourSource = [tags["atlas:colourSourceID"], tags["colourSourceID"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "relation/\(id)"
            guard isRelationID(colourSource) else { throw invalid("颜色来源 relation ID 无效") }
            var route = RailRoute(id: "relation/\(id)", name: name, tags: tags, colourSourceID: colourSource)
            // Match exactly as detail assembly does: metadata first, then all
            // occupied start cells. Conflicting city matches remain unresolved.
            let direct = BundledMetroPalette.applying(to: route)
            if direct.tags["atlas:paletteIdentity"] != nil { route = direct }
            else {
                var cells = Set<String>(), matches: [String: RailRoute] = [:]
                for part in parts {
                    let point = part[0]
                    let cell = "\(Int(floor(point.latitude * 4))),\(Int(floor(point.longitude * 4)))"
                    guard cells.insert(cell).inserted else { continue }
                    let candidate = BundledMetroPalette.applying(to: route, near: point)
                    if let identity = candidate.tags["atlas:paletteIdentity"] { matches[identity] = candidate }
                }
                if matches.count == 1, let match = matches.values.first { route = match }
            }
            records.append(Record(route: route, city: city, parts: parts.map(simplify)))
        }
        return Self(records: coalesced(records), fetchedAt: fetchedAt, sourceDate: sourceDate)
    }

    /// Compact, versioned JSON: route metadata occurs once per relation/city,
    /// coordinates are [longitude, latitude] pairs, and gaps remain separate.
    public func encode() throws -> Data {
        try archive(manifest: nil)
    }
    fileprivate func archive(manifest: MetroFeedManifest?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Archive(version: 1, fetchedAt: fetchedAt,
                                              sourceDate: sourceDate, records: records, metroFeed: manifest))
        guard data.count <= Self.maximumBytes else { throw Self.invalid("快照超过 32 MB") }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw invalid("快照超过 32 MB") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Archive.self, from: data)
        guard value.version == 1, value.fetchedAt.timeIntervalSince1970.isFinite,
              !value.records.isEmpty, value.records.count <= 20_000,
              value.records.reduce(0, { $0 + $1.parts.count }) <= maximumParts,
              value.records.reduce(0, { $0 + $1.parts.reduce(0) { $0 + $1.count } }) <= maximumVertices else {
            throw invalid("快照版本或数量无效")
        }
        for record in value.records {
            guard isRelationID(record.route.id), isRelationID(record.route.colourSourceID ?? record.route.id),
                  RailCategory.urbanTypes.contains(record.route.tags["route"] ?? ""),
                  !record.parts.isEmpty else { throw invalid("快照线路标识或类型无效") }
        }
        return Self(records: coalesced(value.records), fetchedAt: value.fetchedAt, sourceDate: value.sourceDate)
    }

    /// Union by source relation + source city, deduplicating only identical
    /// parts. A second source's distinct geometry is never discarded.
    public func merging(_ other: Self) -> Self {
        Self(records: Self.coalesced(records + other.records),
             fetchedAt: max(fetchedAt, other.fetchedAt),
             sourceDate: sourceDate == other.sourceDate ? sourceDate : nil)
    }

    public func validateReplacement(of previous: Self) throws {
        guard Set(previous.cityNames).isSubset(of: Set(cityNames)) else {
            throw Self.invalid("更新缺少已有城市，保留原概览")
        }
        // Both source relations and UI identities matter; deduplicating
        // opposite directions must not conceal a partial/truncated download.
        let before = Set(previous.records.map { $0.route.id }).count
        let after = Set(records.map { $0.route.id }).count
        guard after * 5 >= before * 4, routeCount * 5 >= previous.routeCount * 4 else {
            throw Self.invalid("更新线路数量下降超过 20%，保留原概览")
        }
        let oldCities = Dictionary(grouping: previous.records, by: \.city)
        let newCities = Dictionary(grouping: records, by: \.city)
        for (city, old) in oldCities where (newCities[city]?.count ?? 0) * 5 < old.count * 4 {
            throw Self.invalid("\(city)的更新线路数量下降超过 20%，保留原概览")
        }
    }

    fileprivate struct Archive: Codable {
        let version: Int
        let fetchedAt: Date
        let sourceDate: String?
        let records: [Record]
        let metroFeed: MetroFeedManifest?
    }
    fileprivate struct Record: Codable, Sendable, Equatable {
        var route: RailRoute
        let city: String
        var parts: [[Coordinate]]
        init(route: RailRoute, city: String, parts: [[Coordinate]]) {
            self.route = route; self.city = city; self.parts = parts
        }
        enum CodingKeys: String, CodingKey { case route, city, parts }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            route = try values.decode(RailRoute.self, forKey: .route)
            city = try values.decode(String.self, forKey: .city)
            parts = try values.decode([[[Double]]].self, forKey: .parts).map(NationalMetroSnapshot.coordinates)
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(route, forKey: .route)
            try values.encode(city, forKey: .city)
            try values.encode(parts.map { $0.map { [$0.longitude, $0.latitude] } }, forKey: .parts)
        }
    }
    private struct RecordKey: Hashable { let relation: String; let city: String }
    private struct PartKey: Hashable {
        let values: [Double]
        init(_ coordinates: [Coordinate]) { values = coordinates.flatMap { [$0.longitude, $0.latitude] } }
    }
    private static func coalesced(_ input: [Record]) -> [Record] {
        var result: [Record] = [], indices: [RecordKey: Int] = [:], seen: [RecordKey: Set<PartKey>] = [:]
        for record in input {
            let key = RecordKey(relation: record.route.id, city: record.city)
            let position: Int
            if let old = indices[key] {
                position = old
                result[old].route.tags.merge(record.route.tags) { a, b in a.isEmpty ? b : a }
            } else {
                position = result.count
                indices[key] = position
                result.append(record)
                seen[key] = Set(record.parts.map(PartKey.init))
                continue
            }
            for part in record.parts where seen[key, default: []].insert(PartKey(part)).inserted {
                result[position].parts.append(part)
            }
        }
        return result
    }
    private struct Document: Decodable {
        let type: String
        let features: [Feature]
    }
    private struct Feature: Decodable {
        let type: String
        let properties: [String: Scalar]
        let geometry: Geometry
    }
    private struct Scalar: Decodable {
        let text: String?
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { text = nil }
            else if let string = try? value.decode(String.self) { text = string }
            else if let number = try? value.decode(Int64.self) { text = String(number) }
            else if let number = try? value.decode(Double.self), number.isFinite { text = String(number) }
            else if let flag = try? value.decode(Bool.self) { text = flag ? "yes" : "no" }
            else { throw invalid("属性不是有效标量") }
        }
    }
    private struct Geometry: Decodable {
        let paths: [[[Double]]]
        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: any Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            switch try value.decode(String.self, forKey: .type) {
            case "LineString": paths = [try value.decode([[Double]].self, forKey: .coordinates)]
            case "MultiLineString": paths = try value.decode([[[Double]]].self, forKey: .coordinates)
            default: throw invalid("仅支持 LineString / MultiLineString")
            }
        }
        func parts() throws -> [[Coordinate]] {
            guard !paths.isEmpty else { throw invalid("线路几何为空") }
            return try paths.map(NationalMetroSnapshot.coordinates)
        }
    }
    private static func coordinates(_ values: [[Double]]) throws -> [Coordinate] {
        guard values.count >= 2 else { throw invalid("分段不足两个端点") }
        return try values.map {
            guard $0.count >= 2, $0.allSatisfy(\.isFinite) else { throw invalid("坐标无效") }
            let point = Coordinate($0[1], $0[0])
            guard point.isValid else { throw invalid("坐标超出 WGS84 地图范围") }
            return point
        }
    }
    private static func isRelationID(_ value: String) -> Bool {
        let parts = value.split(separator: "/")
        guard parts.count == 2, parts[0] == "relation", let id = Int64(parts[1]), id > 0 else { return false }
        return value == "relation/\(id)"
    }

    /// Iterative RDP, in local metres with longitude adjusted for latitude.
    /// Each source part is processed independently; retained points are exact.
    private static func simplify(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 2 else { return points }
        let latitude = points.reduce(0) { $0 + $1.latitude } / Double(points.count)
        let xScale = 111_195 * cos(latitude * .pi / 180), yScale = 111_195.0
        let origin = points[0]
        let xy = points.map { (($0.longitude - origin.longitude) * xScale, ($0.latitude - origin.latitude) * yScale) }
        var kept = Array(repeating: false, count: points.count)
        kept[0] = true; kept[points.count - 1] = true
        var pending = [(0, points.count - 1)]
        while let (first, last) = pending.popLast() {
            guard last > first + 1 else { continue }
            let a = xy[first], b = xy[last], dx = b.0 - a.0, dy = b.1 - a.1
            let length = dx * dx + dy * dy
            var farthest = -1, maximum = 50.0 * 50.0
            for i in (first + 1)..<last {
                let px = xy[i].0 - a.0, py = xy[i].1 - a.1
                let t = length == 0 ? 0 : min(1, max(0, (px * dx + py * dy) / length))
                let x = px - t * dx, y = py - t * dy, distance = x * x + y * y
                if distance > maximum { maximum = distance; farthest = i }
            }
            if farthest >= 0 {
                kept[farthest] = true
                pending.append((first, farthest)); pending.append((farthest, last))
            }
        }
        return points.enumerated().compactMap { kept[$0.offset] ? $0.element : nil }
    }
    private static func invalid(_ reason: String) -> DataError { .invalid("全国轨道概览：\(reason)") }
}

/// Independent cache and explicit refresh. Neither operation opens the tile
/// cache or claims that the overview is a complete metro-network tile.
public actor NationalMetroRepository {
    public static let cacheFilename = "national-metro-overview-v1.json"
    public static let overpassURL = URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/WannaSlackOffAtWork/metro/master/data/china_metro.geojson")!
    public static let mirrorURL = URL(string: "https://cdn.jsdelivr.net/gh/WannaSlackOffAtWork/metro@master/data/china_metro.geojson")!
    public let cacheURL: URL
    private let session: URLSession
    private var current: NationalMetroSnapshot?
    private var updating = false

    public init(directory: URL, session: URLSession? = nil) {
        cacheURL = directory.appendingPathComponent(Self.cacheFilename)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func load() throws -> NationalMetroSnapshot {
        if let current { return current }
        if let data = try? Self.read(cacheURL), let cached = try? NationalMetroSnapshot.decode(data) {
            current = cached
            return cached
        }
        // Prefer the pre-simplified package. A corrupt cache/package does not
        // prevent trying the next bundled source; no load rewrites user data.
        for ext in ["json", "geojson"] {
            let urls = [
                Bundle.main.url(forResource: "china-metro-overview", withExtension: ext, subdirectory: "Resources"),
                Bundle.module.url(forResource: "china-metro-overview", withExtension: ext)
            ].compactMap { $0 }
            for url in urls {
                guard let data = try? Self.read(url) else { continue }
                let snapshot = ext == "json" ? try? NationalMetroSnapshot.decode(data) :
                    try? NationalMetroSnapshot.decodeGeoJSON(data,
                        fetchedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now)
                if let snapshot { current = snapshot; return snapshot }
            }
        }
        throw DataError.invalid("全国轨道概览尚未随附，且没有可用的独立缓存")
    }

    public func refresh() async throws -> NationalMetroSnapshot {
        _ = try? load()
        var lastError: any Error = DataError.invalid("全国轨道概览更新失败，已保留原缓存")
        for url in [Self.overpassURL, Self.sourceURL, Self.mirrorURL] {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
                request.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
                if url == Self.overpassURL {
                    request.httpMethod = "POST"
                    request.timeoutInterval = 150
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var form = URLComponents()
                    form.queryItems = [URLQueryItem(name: "data", value: NationalMetroSnapshot.overpassQuery)]
                    request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
                }
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw DataError.invalid("概览下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
                }
                guard response.expectedContentLength <= NationalMetroSnapshot.maximumBytes else {
                    throw DataError.invalid("概览响应超过 32 MB")
                }
                let data = try await Self.readBytes(bytes)
                try Task.checkCancellation()
                // The upstream file has no collection date. A successful fetch
                // must not relabel its contents as newly surveyed OSM data.
                let snapshot = url == Self.overpassURL
                    ? try NationalMetroSnapshot.decodeOverpass(data, cityReference: current)
                    : try NationalMetroSnapshot.decodeGeoJSON(data, fetchedAt: .now)
                if let current { try snapshot.validateReplacement(of: current) }
                let encoded = try snapshot.encode()
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: cacheURL, options: .atomic)
                current = snapshot
                return snapshot
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    /// The snapshot and its city fingerprints share a single atomic cache write.
    public func refreshIncrementally(from feed: URL = URL(string: "https://wongary.github.io/railway-atlas/data/metro-updates/")!)
        async throws -> (snapshot: NationalMetroSnapshot, changed: Int) {
        guard !updating else { throw DataError.invalid("全国城轨正在更新") }
        updating = true
        defer { updating = false }
        let old = try load()
        let manifestBytes = try await download(feed.appendingPathComponent("manifest.json"), limit: 128 * 1024)
        let manifest = try JSONDecoder().decode(MetroFeedManifest.self, from: manifestBytes)
        let date = try manifest.validate()
        guard (old.sourceDate ?? "") <= manifest.sourceDate else { throw DataError.invalid("本机资料日期较新") }
        var byCity = Dictionary(grouping: old.records, by: \.city)
        let next = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.city, $0) })
        for (city, rows) in byCity {
            guard let chunk = next[city], chunk.count * 5 >= rows.count * 4 else {
                throw DataError.invalid("\(city)的更新记录不完整")
            }
        }
        let receipt = (try? Self.read(cacheURL)).flatMap { try? JSONDecoder().decode(MetroFeedReceipt.self, from: $0).metroFeed }
        var known = [String: String]()
        if let receipt, (try? receipt.validate()) != nil {
            known = Dictionary(uniqueKeysWithValues: receipt.chunks.map { ($0.city, $0.hash) })
        } else if let bytes = try? Self.bundled("national-metro-baseline"),
                  let base = try? JSONDecoder().decode(MetroFeedManifest.self, from: bytes),
                  (try? base.validate()) != nil, let packaged = try? Self.bundled("china-metro-overview"),
                  Self.digest(packaged) == base.snapshotHash {
            // Older caches have no fingerprints. Reuse cities identical to the shipped edition.
            let cached = try? Self.read(cacheURL)
            if cached == nil || cached == packaged {
                known = Dictionary(uniqueKeysWithValues: base.chunks.map { ($0.city, $0.hash) })
            } else {
                let baseline = Dictionary(grouping: try NationalMetroSnapshot.decode(packaged).records, by: \.city)
                for chunk in base.chunks where baseline[chunk.city] == byCity[chunk.city] { known[chunk.city] = chunk.hash }
            }
        }
        let changes = manifest.chunks.filter { known[$0.city] != $0.hash || byCity[$0.city] == nil }
        if changes.isEmpty, old.sourceDate == manifest.sourceDate { return (old, 0) }
        for chunk in changes {
            let bytes = try await download(feed.appendingPathComponent(chunk.hash + ".json"), limit: chunk.bytes)
            guard bytes.count == chunk.bytes, Self.digest(bytes) == chunk.hash else {
                throw DataError.invalid("\(chunk.city)的文件校验失败")
            }
            let rows = try JSONDecoder().decode([NationalMetroSnapshot.Record].self, from: bytes)
            guard rows.count == chunk.count, rows.allSatisfy({ $0.city == chunk.city && !$0.parts.isEmpty }) else {
                throw DataError.invalid("\(chunk.city)的线路记录无效")
            }
            byCity[chunk.city] = rows
        }
        let records = manifest.chunks.flatMap { byCity[$0.city] ?? [] }
        // Decode through the ordinary archive validator before constructing spatial indexes.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = NationalMetroSnapshot.Archive(version: 1, fetchedAt: date, sourceDate: manifest.sourceDate,
                                                    records: records, metroFeed: manifest)
        let encoded = try encoder.encode(archive)
        let snapshot = try NationalMetroSnapshot.decode(encoded)
        try snapshot.validateReplacement(of: old)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: cacheURL, options: .atomic)
        current = snapshot
        return (snapshot, changes.count)
    }

    private static func bundled(_ name: String) throws -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url else { throw DataError.invalid("未找到随包城轨数据") }
        return try read(url)
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else {
            throw DataError.invalid("全国城轨更新文件下载失败")
        }
        return try await Self.readBytes(bytes, limit: limit)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func read(_ url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= NationalMetroSnapshot.maximumBytes else { throw DataError.invalid("概览文件超过 32 MB") }
        return try Data(contentsOf: url)
    }

    // AsyncBytes.next is nonisolated; avoid a hop to the repository actor for
    // every byte of a national response.
    private nonisolated static func readBytes(_ bytes: URLSession.AsyncBytes, limit: Int = NationalMetroSnapshot.maximumBytes) async throws -> Data {
        var data = Data()
        data.reserveCapacity(1024 * 1024)
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw DataError.invalid("概览更新超过大小限制") }
        }
        return data
    }
}

private struct MetroFeedReceipt: Decodable { let metroFeed: MetroFeedManifest? }
fileprivate struct MetroFeedManifest: Codable {
    struct Chunk: Codable { let city, hash: String; let count, bytes: Int }
    let version: Int
    let sourceDate, fetchedAt, snapshotHash: String
    let chunks: [Chunk]
    func validate() throws -> Date {
        let invalid = DataError.invalid("全国城轨更新清单无效")
        guard version == 1, sourceDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = ISO8601DateFormatter().date(from: fetchedAt), (1...512).contains(chunks.count),
              Set(chunks.map(\.city)).count == chunks.count else { throw invalid }
        var bytes = 0, count = 0
        for chunk in chunks {
            guard !chunk.city.isEmpty, chunk.hash.utf8.count == 64, chunk.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (2...NationalMetroSnapshot.maximumBytes).contains(chunk.bytes), (1...20_000).contains(chunk.count) else { throw invalid }
            bytes += chunk.bytes; count += chunk.count
        }
        guard bytes <= NationalMetroSnapshot.maximumBytes, count <= 20_000 else { throw invalid }
        return date
    }
}
