import Foundation
#if !NATIONAL_METRO_STANDALONE
import RailwayCore
#endif

enum NationalMetroChecks {
    /// Optional full source fixture is read-only. Network checks use URLProtocol
    /// and a disposable independent directory, never the user's tile cache.
    static func run(geoJSONURL: URL? = nil) async throws {
        let sourceDate = "2026-09-14"
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = try sampleFeatures()
        let snapshot = try NationalMetroSnapshot.decodeGeoJSON(collection(samples), fetchedAt: fetched, sourceDate: sourceDate)
        let routes = snapshot.lines.compactMap { $0.routes?.first }
        try require(Set(routes.map(\.id)) == ["relation/18441518", "relation/20622642", "relation/269669"],
                    "real relation IDs survive parsing")
        let beijing = routes.first { $0.id == "relation/18441518" }!
        try require(beijing.tags["ref"] == "" && beijing.visibilityKey == "metro:beijing:bj12",
                    "Beijing 12's empty ref retains its real relation and detail palette identity")
        try require(routes.first { $0.id == "relation/269669" }?.visibilityKey == "metro:hongkong:twl",
                    "Hong Kong's nonnumeric TWL ref remains a city-specific identity")
        try require(snapshot.routeCount == 3 && snapshot.colouredRouteCount == 3
                    && snapshot.cityNames == ["北京", "武汉", "香港"],
                    "route, colour and source-city counts use the parsed data")
        try require(snapshot.lines.allSatisfy {
            $0.id.hasPrefix("national/relation/") && $0.tags["atlas:nationalOverview"] == "yes"
                && $0.tags["construction"] == nil && $0.tags["disused"] == nil && $0.tags["status"] == nil
        }, "overview provenance is explicit and operational status is not invented")
        let decoded = try NationalMetroSnapshot.decode(snapshot.encode())
        try require(decoded.fetchedAt == fetched && decoded.sourceDate == sourceDate
                    && decoded.lines.map(\.id) == snapshot.lines.map(\.id)
                    && decoded.lines.map(\.coordinates) == snapshot.lines.map(\.coordinates)
                    && decoded.lines.map(\.tags) == snapshot.lines.map(\.tags),
                    "compact snapshot round trip preserves IDs, tags, coordinates and dates")

        var colourDirections: [[String: Any]] = []
        for (id, colour) in [(701, ""), (702, "#334455")] {
            var feature = samples[0]
            feature["properties"] = [
                "osm_id": id, "city": "测试城市", "network": "Fixture network",
                "line_name": "Fixture Z99", "route_type": "subway", "ref": "Z99", "colour": colour,
                "atlas:colourSourceID": id == 702 ? "relation/900" : "relation/701"
            ] as [String: Any]
            colourDirections.append(feature)
        }
        let consistent = try NationalMetroSnapshot.decodeGeoJSON(collection(colourDirections))
        try require(consistent.routeCount == 1 && consistent.colouredRouteCount == 1
                    && consistent.lines.allSatisfy { $0.routes?.first?.color?.hex == "#334455"
                        && $0.routes?.first?.colourSourceID == "relation/900"
                        && $0.tags["atlas:colourSourceID"] == "relation/900" }
                    && Set(consistent.lines.compactMap { $0.routes?.first?.tags["atlas:originalColour"] }) == ["", "#334455"],
                    "global identity colour fills the uncoloured direction and retains original colours/real master provenance")
        let consistentReload = try NationalMetroSnapshot.decode(consistent.encode())
        try require(consistentReload.lines.map(\.routes) == consistent.lines.map(\.routes),
                    "global colour/source evidence survives compact reload")

        var gap = samples[0]
        let parts = [
            [[116.0, 40.0], [116.001, 40.00001], [116.002, 40.0]],
            [[116.02, 40.0], [116.021, 40.001], [116.022, 40.0]]
        ]
        gap["geometry"] = ["type": "MultiLineString", "coordinates": parts]
        let separated = try NationalMetroSnapshot.decodeGeoJSON(collection([gap]))
        try require(separated.lines.count == 2 && separated.lines[0].coordinates.count == 2
                    && separated.lines[1].coordinates.count == 3,
                    "50m RDP removes a small deviation but retains a large bend in its own part")
        for (line, points) in zip(separated.lines, parts) {
            try require(line.coordinates.first == Coordinate(points[0][1], points[0][0])
                        && line.coordinates.last == Coordinate(points.last![1], points.last![0]),
                        "RDP preserves exact endpoints")
        }
        let emptyGap = MapBounds(south: 39.999, west: 116.008, north: 40.002, east: 116.015)
        try require(separated.features(in: emptyGap).lines.isEmpty
                    && separated.features().stations.isEmpty && separated.features().memberships.isEmpty,
                    "gaps are not bridged and overview does not claim station/way memberships")
        let inside = MapBounds(south: 39.999, west: 116.0005, north: 40.001, east: 116.0015)
        try require(separated.features(in: inside).lines.map(\.id) == [separated.lines[0].id],
                    "spatial filtering preserves original part IDs")
        gap["geometry"] = ["type": "MultiLineString", "coordinates": [parts[1], [[116.03, 40.0], [116.04, 40.0]]]]
        let additional = try NationalMetroSnapshot.decodeGeoJSON(collection([gap]))
        let merged = separated.merging(additional)
        try require(merged.lines.count == 3 && merged.routeCount == 1
                    && Set(merged.lines.map(\.id)).count == merged.lines.count
                    && merged.merging(merged).vertexCount == merged.vertexCount,
                    "merge deduplicates identical parts of one relation/city without losing distinct geometry")
        var otherCity = gap
        var properties = otherCity["properties"] as! [String: Any]
        properties["city"] = "另一来源城市"
        otherCity["properties"] = properties
        let cityUnion = merged.merging(try NationalMetroSnapshot.decodeGeoJSON(collection([otherCity])))
        try require(cityUnion.lines.count == 5 && Set(cityUnion.lines.map(\.id)).count == 5,
                    "same relation in another source city remains independent without ID collisions")

        for invalid in [Data("not json".utf8), try collection([])] {
            try rejects { _ = try NationalMetroSnapshot.decodeGeoJSON(invalid) }
        }
        var bad = samples[0]
        properties = bad["properties"] as! [String: Any]
        properties["osm_id"] = "way/18441518"
        bad["properties"] = properties
        try rejects { _ = try NationalMetroSnapshot.decodeGeoJSON(collection([bad])) }
        bad = samples[0]
        bad["geometry"] = ["type": "LineString", "coordinates": [[116.0, 40.0], [116.0, 95.0]]]
        try rejects { _ = try NationalMetroSnapshot.decodeGeoJSON(collection([bad])) }
        bad["geometry"] = ["type": "LineString", "coordinates": [[116.0, 40.0], NSNull(), [116.1, 40.0]]]
        try rejects { _ = try NationalMetroSnapshot.decodeGeoJSON(collection([bad])) }
        print("PASS national overview: real samples, identity, compact round trip, RDP endpoints/bends, gaps, union and invalid data")

        try await repositoryChecks(samples: samples)
        if let geoJSONURL { try fullFixture(geoJSONURL) }
    }

    private static func repositoryChecks(samples: [[String: Any]]) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NationalMetroChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two distinct Beijing lines plus Wuhan allow separate regressions for
        // losing a city and losing >20% of routes while retaining both cities.
        var second = samples[0]
        var properties = second["properties"] as! [String: Any]
        properties["osm_id"] = 1667375
        properties["ref"] = "13"
        properties["line_name"] = "地铁 13号线: 东直门 -> 西直门"
        second["properties"] = properties
        let good = try collection([samples[0], second, samples[1]])
        let baseline = try NationalMetroSnapshot.decodeGeoJSON(good, fetchedAt: Date(timeIntervalSince1970: 1),
                                                               sourceDate: "2026-09-14")
        let cache = directory.appendingPathComponent(NationalMetroRepository.cacheFilename)
        let original = try baseline.encode()
        try original.write(to: cache, options: .atomic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NationalMetroFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let repository = NationalMetroRepository(directory: directory, session: session)
        try require(try await repository.load().routeCount == 3, "load reads the independent compact cache")
        let failures = [
            Data("<html>upstream unavailable</html>".utf8),
            try collection([samples[0], second]),
            try collection([samples[0], samples[1]])
        ]
        for failure in failures {
            NationalMetroFixtureProtocol.state.configure(primary: failure, mirror: failure)
            do {
                _ = try await repository.refresh()
                throw CheckFailure.unexpectedSuccess
            } catch CheckFailure.unexpectedSuccess { throw CheckFailure.unexpectedSuccess }
            catch {}
            let retained = try await repository.load()
            try require(try Data(contentsOf: cache) == original && retained.routeCount == baseline.routeCount
                        && retained.fetchedAt == baseline.fetchedAt,
                        "invalid/truncated update preserves disk bytes and in-memory snapshot")
        }
        NationalMetroFixtureProtocol.state.configure(primary: Data("invalid".utf8), mirror: good)
        let refreshed = try await repository.refresh()
        let requests = NationalMetroFixtureProtocol.state.requests
        try require(requests.map { $0.url! } == [NationalMetroRepository.overpassURL, NationalMetroRepository.sourceURL, NationalMetroRepository.mirrorURL]
                    && requests[0].httpMethod == "POST" && requests[0].timeoutInterval == 150
                    && requests.dropFirst().allSatisfy { $0.timeoutInterval == 90 },
                    "refresh tries live OSM then GitHub and jsDelivr without a viewport-wide 30s deadline")
        try require(refreshed.fetchedAt > baseline.fetchedAt && refreshed.sourceDate == nil
                    && refreshed.routeCount == baseline.routeCount,
                    "successful fetch updates receipt time without inventing a new source date")
        let reloaded = try await NationalMetroRepository(directory: directory, session: session).load()
        try require(reloaded.lines.map(\.coordinates) == refreshed.lines.map(\.coordinates)
                    && reloaded.sourceDate == nil,
                    "successful update persists a reloadable compact snapshot")
        print("PASS independent cache: bad data, missing city and route regression retained; mirror update persisted")
    }

    private static func fullFixture(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let features = document["features"] as! [[String: Any]]
        let started = Date()
        let snapshot = try NationalMetroSnapshot.decodeGeoJSON(data, sourceDate: "2026-09-14")
        let rawIDs = Set(features.map { "relation/\(($0["properties"] as! [String: Any])["osm_id"]!)" })
        try require(Set(snapshot.lines.compactMap { $0.routes?.first?.id }) == rawIDs,
                    "full fixture retains every source relation")
        let colours = Dictionary(grouping: snapshot.lines.compactMap { $0.routes?.first }, by: \.visibilityKey)
        try require(colours.values.allSatisfy { Set($0.map { $0.color?.hex ?? "" }).count == 1 },
                    "full fixture has one colour decision per global visibility key")
        var parts = 0, vertices = 0
        let byID = Dictionary(grouping: snapshot.lines, by: { $0.routes!.first!.id })
        for feature in features {
            let props = feature["properties"] as! [String: Any], geometry = feature["geometry"] as! [String: Any]
            let coordinates = geometry["type"] as? String == "LineString"
                ? [geometry["coordinates"] as! [[Double]]] : geometry["coordinates"] as! [[[Double]]]
            let lines = byID["relation/\(props["osm_id"]!)"]!
            parts += coordinates.count
            vertices += coordinates.reduce(0) { $0 + $1.count }
            try require(lines.count == coordinates.count, "full fixture preserves each relation's part count")
            for (line, original) in zip(lines, coordinates) {
                try require(line.coordinates.first == Coordinate(original[0][1], original[0][0])
                            && line.coordinates.last == Coordinate(original.last![1], original.last![0]),
                            "full fixture preserves every original segment endpoint")
            }
        }
        let compact = try snapshot.encode()
        try require(snapshot.vertexCount <= vertices && snapshot.lines.count == parts,
                    "simplification reduces vertices without dropping source parts")
        print(String(format: "National real fixture: %d relations, %d line identities (%d coloured), %d source-city labels; %d parts; %d → %d vertices; compact %d bytes; parse/simplify/check %.3fs.",
                     rawIDs.count, snapshot.routeCount, snapshot.colouredRouteCount, snapshot.cityNames.count,
                     parts, vertices, snapshot.vertexCount, compact.count, Date().timeIntervalSince(started)))
    }

    /// Original properties and consecutive geometry excerpts from the supplied
    /// 2026-09-14 GeoJSON. These small samples are not full route geometries.
    private static func sampleFeatures() throws -> [[String: Any]] {
        let data = Data("""
        [
          {"type":"Feature","properties":{"osm_id":18441518,"city":"北京","network":"北京地铁","line_name":"地铁 12号线: 东坝北 → 四季青桥","route_type":"subway","route_type_zh":"地铁","operator":"","ref":"","colour":"#9B5A1A","from_station":"东坝北","to_station":"四季青桥"},
           "geometry":{"type":"LineString","coordinates":[[116.5519397,39.9746382],[116.5480506,39.9742577],[116.5459454,39.9740405]]}},
          {"type":"Feature","properties":{"osm_id":20622642,"city":"武汉","network":"武汉地铁","line_name":"武汉地铁12号线","route_type":"subway","route_type_zh":"地铁","operator":"","ref":"12","colour":"#00A3E9","from_station":"墨水湖公园","to_station":"钢都花园"},
           "geometry":{"type":"MultiLineString","coordinates":[[[114.2096881,30.5532736],[114.2086193,30.551845],[114.2066766,30.5491746]]]}},
          {"type":"Feature","properties":{"osm_id":269669,"city":"香港","network":"港鐵 MTR","line_name":"港鐵荃灣綫 MTR Tsuen Wan Line (南行 Southbound)","route_type":"subway","route_type_zh":"地铁","operator":"香港鐵路有限公司 MTR Corporation","ref":"TWL","colour":"#ed1d24","from_station":"荃灣 Tsuen Wan","to_station":"中環 Central","opening_date":"1982-05-10"},
           "geometry":{"type":"LineString","coordinates":[[114.1090487,22.379243],[114.1099014,22.3790011],[114.1099891,22.3789731]]}}
        ]
        """.utf8)
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }
    private static func collection(_ features: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }
    private enum CheckFailure: Error { case unexpectedSuccess }
    private static func rejects(_ operation: () throws -> Void) throws {
        do { try operation(); throw CheckFailure.unexpectedSuccess }
        catch CheckFailure.unexpectedSuccess { throw CheckFailure.unexpectedSuccess }
        catch {}
    }
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw DataError.invalid("NationalMetro: \(message)") }
    }
}

private final class NationalMetroFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var primary = Data(), mirror = Data()
    private var recorded: [URLRequest] = []
    func configure(primary: Data, mirror: Data) {
        lock.lock(); defer { lock.unlock() }
        self.primary = primary; self.mirror = mirror; recorded = []
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func data(for request: URLRequest) -> Data {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return request.url == NationalMetroRepository.sourceURL ? primary : mirror
    }
}

private final class NationalMetroFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = NationalMetroFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.state.data(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/geo+json", "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

#if NATIONAL_METRO_STANDALONE
// Standalone checks use the real source resources without a package build.
extension Bundle {
    static let module = Bundle(path: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/RailwayCore").path)!
}
@main private enum NationalMetroCheckRunner {
    static func main() async throws {
        try await NationalMetroChecks.run(geoJSONURL: CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) })
    }
}
#endif
