import Foundation
import RailwayCore

@main
struct Checks {
    static func main() async {
        do { try await run() }
        catch {
            print("CHECK FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--assistant-regression" {
            try await AssistantChecks.run()
            try ConfigurationChecks.run()
            return
        }
        if arguments.count >= 2, arguments[1] == "--scale-regression" {
            try MapScaleChecks.run()
            try ContinuityChecks.run()
            try RenderingChecks.run()
            try UrbanTransitChecks.run()
            return
        }
        if arguments.count == 4, arguments[1] == "--scale-cache" {
            try MapScaleChecks.cache(arguments[2], output: arguments[3])
            return
        }
        if arguments.count == 4, arguments[1] == "--llt-route-network" {
            let library = try LuluTimetableSnapshot.read(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            guard let service = library.services.first(where: { $0.train == "G6580" }) else { throw DataError.invalid("missing sample") }
            let timetable = try library.timetable(service, on: "2026-11-09").passengerSection(from: "深圳北", to: "光明城")
            let directory = URL(fileURLWithPath: arguments[3])
            let repository = RailJourneyRouteRepository(directory: directory, mapCache: directory.appendingPathComponent("not-preseeded.railcache"))
            let route = try await repository.route(timetable)
            try route.validate(for: timetable)
            guard route.legs.count == 1, (14_000...18_000).contains(route.distance) else { throw DataError.invalid("network segment mismatch") }
            let reopened = RailJourneyRouteRepository(directory: directory, mapCache: directory.appendingPathComponent("not-preseeded.railcache"))
            let offline = try await reopened.route(timetable, allowNetwork: false)
            guard offline.legs == route.legs else { throw DataError.invalid("offline route cache changed") }
            print("PASS fresh-cache online station lookup, bounded railway tile downloads, route matching, persistence and offline reopen: 深圳北 → 光明城, \(Int(route.distance)) m.")
            return
        }
        if arguments.count == 6, arguments[1] == "--llt-route-check" {
            try JourneyRouteChecks.real(snapshot: arguments[2], routing: arguments[3], geometry: arguments[4], output: arguments[5])
            return
        }
        if arguments.count == 3, arguments[1] == "--llt-download" {
            let value = try await LuluTimetableClient.download()
            try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
            print("LLT verified complete public package: \(value.services.count) services; \(value.stationCount) station names; \(value.stopCount) stops; edition \(value.edition)")
            return
        }
        if arguments.count == 5, arguments[1] == "--export-experience-cache", let zoom = Int(arguments[4]) {
            try ExperienceCacheExport.run(arguments[2], output: arguments[3], zoom: zoom)
            return
        }
        if arguments.count == 2, arguments[1] == "--experience-regression" {
            try ExperienceChecks.run()
            try ExperienceExpansionChecks.run()
            try JourneyRouteChecks.run()
            return
        }
        if arguments.count == 2, arguments[1] == "--urban-transit-regression" {
            try UrbanTransitChecks.run()
            try ConfigurationChecks.run()
            return
        }
        if arguments.count == 4, arguments[1] == "--national-source-regression" {
            let source = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let bundled = try NationalMetroSnapshot.decode(Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            let refreshed = try NationalMetroSnapshot.decodeOverpass(source, cityReference: bundled)
            let expected = Set(bundled.lines.flatMap { ($0.routes ?? []).map(\.id) })
            let actual = Set(refreshed.lines.flatMap { ($0.routes ?? []).map(\.id) })
            guard expected == actual, Set(bundled.cityNames).isSubset(of: Set(refreshed.cityNames)),
                  refreshed.sourceDate == "2026-11-05" else {
                throw DataError.invalid("National refresh lost relation geometry, city grouping or source timestamp")
            }
            print("PASS live-snapshot conversion: \(actual.count) source relations, \(refreshed.routeCount) route keys, \(refreshed.cityNames.count) city/network groups, \(refreshed.colouredRouteCount) coloured; original OSM timestamp retained.")
            return
        }
        if arguments.count == 5, arguments[1] == "--build-national-overview" {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let snapshot = try NationalMetroSnapshot.decodeGeoJSON(data, sourceDate: arguments[4])
            let encoded = try snapshot.encode()
            try encoded.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
            print("OVERVIEW: \(snapshot.cityNames.count) city/network groups, \(snapshot.routeCount) unique route keys, \(snapshot.colouredRouteCount) coloured, \(snapshot.lines.count) parts, \(snapshot.vertexCount) vertices, \(encoded.count) bytes.")
            let missing = Dictionary(snapshot.lines.flatMap { $0.routes ?? [] }.filter { $0.color == nil }
                .map { ($0.visibilityKey, $0) }, uniquingKeysWith: { a, _ in a })
            for route in missing.values.sorted(by: { $0.id < $1.id }) {
                print("NO COLOUR", route.id, route.tags["city"] ?? "", route.tags["route"] ?? "", route.name)
            }
            return
        }
        if arguments.count >= 2, arguments[1] == "--national-overview-regression" {
            try await NationalMetroChecks.run(geoJSONURL: arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil)
            try NationalMetroDisplayChecks.run()
            return
        }
        if arguments.count == 2, arguments[1] == "--interchange-regression" {
            try StationInterchangeChecks.run()
            return
        }
        if arguments.count == 3, arguments[1] == "--multicity-regression" {
            try MetroViewportChecks.cache(URL(fileURLWithPath: arguments[2]))
        }
        if arguments.count == 2, arguments[1] == "--route-titles-regression" {
            try MetroRouteTitleChecks.run()
            return
        }
        if arguments.count == 3, arguments[1] == "--metro-identity-regression" {
            try MetroIdentityChecks.run()
            try await MetroIdentityChecks.cities(directory: URL(fileURLWithPath: arguments[2]))
            return
        }
        if arguments.count == 3, arguments[1] == "--wuhan-regression" {
            try ContinuityChecks.run()
            try await ContinuityChecks.wuhan(directory: URL(fileURLWithPath: arguments[2]))
            return
        }
        if arguments.count == 8, arguments[1] == "--inspect-cache",
           let z = Int(arguments[3]), let x = Int(arguments[4]), let y = Int(arguments[5]),
           let endX = Int(arguments[6]), let endY = Int(arguments[7]),
           (10...15).contains(z), x <= endX, y <= endY, (endX - x + 1) * (endY - y + 1) <= 64 {
            let tiles = (x...endX).flatMap { x in (y...endY).map { RailTile(z: z, x: x, y: $0) } }
            let keys = tiles.flatMap { tile in
                [RailTileKey(layer: .tracks, tile: tile), RailTileKey(layer: .stations, tile: tile),
                 RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: tile.x >> max(0, z - 10), y: tile.y >> max(0, z - 10)))]
            }
            let repository = RailwayTileRepository(directory: URL(fileURLWithPath: arguments[2]))
            let values = try await repository.cached(Array(Set(keys)), source: RailwayTileRepository.defaultSource)
            let started = Date()
            let tileFeatures = Dictionary(values.map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
            let result = RailFeatureAssembler.assemble(tiles: tileFeatures, palette: [:], wiki: [:],
                                                       enrichWiki: false, ledger: RailIdentityLedger(), preview: nil).features
            print("ASSEMBLY", Date().timeIntervalSince(started), "s")
            let warmStart = Date()
            _ = RailFeatureAssembler.assemble(tiles: tileFeatures, palette: [:], wiki: [:],
                                               enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
            print("WARM ASSEMBLY", Date().timeIntervalSince(warmStart), "s")
            let groups = Dictionary(grouping: result.lines.flatMap { $0.routes ?? [] }, by: \.visibilityKey)
            for (key, routes) in groups.sorted(by: { $0.key < $1.key }) {
                print("ROUTE", key, Set(routes.compactMap { $0.color?.hex }), routes.first!.name)
            }
            let base = tileFeatures.filter { !$0.key.layer.isMetro }
            let early = RailFeatureAssembler.assemble(tiles: base, palette: [:], wiki: [:],
                                                      enrichWiki: false, ledger: RailIdentityLedger(), preview: nil).features
            print("BEFORE RELATIONS", early.lines.filter { $0.category == .urban && !$0.appearance.colors.isEmpty }.count,
                  "/", early.lines.filter { $0.category == .urban }.count, "coloured urban fragments")
            let missing = result.lines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
            print("UNCOLOURED \(missing.count) / \(result.lines.filter { $0.category == .urban }.count) urban fragments")
            for line in missing.prefix(6) {
                print(line.name, line.tags, line.coordinates.first!, line.coordinates.last!)
            }
            let mainMissing = missing.filter { $0.tags["service"] == nil }
            print("UNCOLOURED MAIN TRACKS", mainMissing.count)
            print(Dictionary(grouping: mainMissing, by: { "\($0.tags["atlas:source"] ?? "") | \($0.tags["name"] ?? "")" })
                .mapValues(\.count).sorted { $0.value > $1.value }.prefix(30))
            for line in mainMissing.prefix(12) { print("MAIN", line.name, line.tags, line.coordinates.first!, line.coordinates.last!) }
            let urbanStations = result.stations.filter { $0.network == .metro }
            print("UNCOLOURED STATIONS", urbanStations.filter { ($0.routes ?? []).isEmpty }.count, "/", urbanStations.count)
            for station in urbanStations.filter({ ($0.routes ?? []).isEmpty }).prefix(6) {
                print(station.name, station.tags, station.coordinate)
            }
            return
        }
        if arguments.count == 4, arguments[1] == "--convert-metro-preview" {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            var dataset = try RailwayCodec.decodeOverpass(data, bounds: MapBounds(south: 28.3, west: 115.5, north: 29.0, east: 116.3),
                                                        name: "南昌地铁 · 整线预览", sourceURL: DataEndpoint.vk.rawValue)
            dataset.stations = try MetroRouteDecoder.decode(data).stations
            for index in dataset.lines.indices {
                dataset.lines[index].tags["atlas:osm"] = dataset.lines[index].id
                dataset.lines[index].tags["atlas:routeOverlay"] = "yes"
                dataset.lines[index].tags["atlas:source"] = "OSM · 南昌整线预览（2026-11-03）"
            }
            try RailwayCodec.encode(dataset).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
            print("Saved preview \(dataset.lines.count) ways, \(dataset.stations.count) station objects")
            return
        }
        if arguments.count == 3, arguments[1] == "--inspect-metro" {
            let value = try MetroRouteDecoder.decode(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let unified = MetroIdentity.unify(lines: value.lines, stations: value.stations)
            let routes = Dictionary(grouping: unified.lines.flatMap { $0.routes ?? [] }, by: \.visibilityKey)
            print("METRO \(unified.lines.count) ways, \(unified.stations.count) separate station objects, \(routes.count) lines")
            for (key, values) in routes.sorted(by: { $0.key < $1.key }) {
                print(key, Set(values.compactMap { $0.color?.hex }), values.first!.name)
            }
            return
        }
        try ExperienceChecks.run()
        try ExperienceExpansionChecks.run()
        try BorderChecks.run()
        try SpatialChecks.run()
        try ContinuityChecks.run()
        try MapScaleChecks.run()
        try MetroIdentityChecks.run()
        try MetroRouteTitleChecks.run()
        try MetroViewportChecks.run()
        try StationInterchangeChecks.run()
        try await NationalMetroChecks.run()
        try NationalMetroDisplayChecks.run()
        try await MetroViewportChecks.repository()
        try RenderingChecks.run()
        try MetroPaletteChecks.run()
        try await MetroSnapshotChecks.run()
        try await AssistantChecks.run()
        try ConfigurationChecks.run()
        try UrbanTransitChecks.run()
        if arguments.count == 7, arguments[1] == "--inspect-tile",
           let layer = RailTileLayer(rawValue: arguments[3]),
           let z = Int(arguments[4]), let x = Int(arguments[5]), let y = Int(arguments[6]) {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let value = try RailwayTileRepository.decode(data, key: RailTileKey(layer: layer, tile: RailTile(z: z, x: x, y: y)))
            print("TILE \(data.count) bytes; \(value.lines.count) lines; \(value.stations.count) stations")
            print(Dictionary(grouping: value.lines, by: \.category).mapValues(\.count))
            for line in value.lines.prefix(3) { print(line.name, line.tags, line.coordinates.prefix(2)) }
            for station in value.stations.prefix(3) { print(station.name, station.tags) }
            return
        }
        if arguments.count == 4, arguments[1] == "--convert-overpass" {
            let input = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let dataset = try RailwayCodec.decodeOverpass(
                input, bounds: .shanghai, name: "上海 · 虹桥与中心城区",
                sourceURL: "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
            )
            try RailwayCodec.encode(dataset).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
            print("Converted \(dataset.lines.count) real rail segments, \(dataset.stations.count) station objects.")
            return
        }
        if arguments.count == 3, arguments[1] == "--validate" {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let dataset = try RailwayCodec.decode(data)
            print("VALID: \(dataset.name); \(dataset.lines.count) segments, \(dataset.stations.count) stations.")
            print("OSM: \(dataset.osmTimestamp ?? "unknown"); \(data.count) bytes.")
            return
        }
        if arguments.count == 3, arguments[1] == "--fetch-smoke" {
            let repository = RailwayRepository(directory: FileManager.default.temporaryDirectory)
            let dataset = try await repository.fetch(
                bounds: MapBounds(south: 31.19, west: 121.32, north: 31.20, east: 121.33),
                endpoint: .vk)
            try RailwayCodec.encode(dataset).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
            print("FETCH PASS: \(dataset.lines.count) segments, \(dataset.stations.count) stations.")
            return
        }
        if arguments.count == 3, arguments[1] == "--online-smoke" {
            try await OnlineChecks.live(directory: URL(fileURLWithPath: arguments[2]))
            return
        }

        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw DataError.invalid("FAIL: \(label)") }
            count += 1
            print("PASS \(label)")
        }
        func rejects(_ label: String, operation: () throws -> Void) throws {
            do { try operation() } catch { count += 1; print("PASS \(label)"); return }
            throw DataError.invalid("FAIL: \(label) was accepted")
        }
        let fixture = Data("""
        {"osm3s":{"timestamp_osm_base":"2026-11-02T00:00:00Z"},"elements":[
        {"type":"way","id":1,"tags":{"railway":"rail","highspeed":"yes","name":"测试高铁"},"geometry":[{"lat":31.20,"lon":121.30},{"lat":31.21,"lon":121.31}]},
        {"type":"way","id":2,"tags":{"railway":"construction","construction":"rail"},"geometry":[{"lat":31.22,"lon":121.30},{"lat":31.23,"lon":121.31}]},
        {"type":"way","id":3,"tags":{"railway":"rail","service":"siding"},"geometry":[{"lat":31.24,"lon":121.30},{"lat":31.25,"lon":121.31}]},
        {"type":"node","id":4,"tags":{"railway":"station","name":"上海虹桥"},"lat":31.2,"lon":121.3},
        {"type":"way","id":5,"tags":{"railway":"station","name":"站区"},"center":{"lat":31.21,"lon":121.31}},
        {"type":"way","id":6,"tags":{"railway":"platform"},"geometry":[{"lat":31.2,"lon":121.3},{"lat":31.3,"lon":121.3}]},
        {"type":"way","id":7,"tags":{"railway":"rail","ref":"1号线"},"geometry":[{"lat":31.26,"lon":121.30},{"lat":31.27,"lon":121.31}]},
        {"type":"relation","id":101,"tags":{"type":"route","route":"subway","name":"上海地铁1号线","ref":"1","network":"上海地铁","colour":"#00ff00"},"members":[{"type":"way","ref":7,"role":""}]},
        {"type":"relation","id":102,"tags":{"type":"route_master","route_master":"subway","name":"上海地铁1号线","ref":"1","network":"上海地铁"},"members":[{"type":"relation","ref":101,"role":""}]}
        ]}
        """.utf8)
        let dataset = try RailwayCodec.decodeOverpass(fixture, bounds: .shanghai, name: "Test", sourceURL: "https://example.test")
        try check(dataset.lines.count == 4, "platform geometry is excluded")
        try check(dataset.stations.count == 2, "node and area stations are decoded")
        try check(dataset.lines[0].coordinates[1] == Coordinate(31.21, 121.31), "geometry is preserved exactly")
        try check(dataset.lines[0].category == .unknown, "missing speed remains unknown")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "350"]) == .speed350,
                  "350 km/h classification")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "349"]) == .speed300,
                  "300–349 km/h boundary")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "300"]) == .speed300,
                  "300 km/h lower boundary")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "299"]) == .speed250,
                  "250–299 km/h boundary")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "249"]) == .speed200,
                  "200–249 km/h boundary")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "199"]) == .speed160,
                  "160–199 km/h boundary")
        try check(RailCategory.classify(["railway": "rail", "maxspeed": "159"]) == .below160,
                  "below 160 km/h boundary")
        try check(RailSpeed.parse("100 mph")! > 160, "mph speed conversion")
        try check(dataset.lines[1].category == .construction, "construction takes precedence")
        try check(dataset.lines[2].category == .service, "siding classification")
        try check(RailCategory.classify(["railway": "subway", "highspeed": "yes"]) == .urban, "urban classification precedence")
        try check(RailCategory.classify(["railway": "rail"]) == .unknown, "missing speed is not guessed")
        try check(RailCategory.classify(["railway": "disused", "maxspeed": "350"]) == .disused,
                  "disused status takes precedence")
        try check(RailCategory.classify(["railway": "rail", "usage": "industrial", "maxspeed": "350"]) == .freight,
                  "freight purpose takes precedence")
        try check(RailCategory.classify(["railway": "rail", "usage": "branch", "maxspeed": "350"]) == .branch,
                  "branch purpose takes precedence")
        let metro = try checkLine(dataset, ref: "1号线")
        try check(metro.category == .urban, "route relation promotes urban track")
        try check(metro.routes?.count == 1, "route membership is preserved")
        try check(metro.appearance.colors.first?.hex == "#E6002A", "official Shanghai palette overrides stale OSM colour")
        try check(RailwaySearch.normalized("上海虹桥").contains("shanghaihongqiao"), "Chinese pinyin search")
        try check(RailwaySearch.normalized(" Shàng Hǎi ") == "shanghai", "case and tone normalization")
        try check(MapBounds.shanghai.canDownload, "regional requests are permitted")
        try check(!MapBounds(south: 20, west: 100, north: 40, east: 120).canDownload, "bulk requests rejected")
        try check(!MapBounds(south: 40, west: 100, north: 20, east: 110).isValid, "inverted bounds rejected")
        try check(!Coordinate(.nan, 120).isValid, "non-finite coordinates rejected")
        let encoded = try RailwayCodec.encode(dataset)
        let roundtrip = try RailwayCodec.decode(encoded)
        try check(roundtrip.lines[0].coordinates == dataset.lines[0].coordinates, "package round-trip geometry")
        try check(roundtrip.lines[0].tags == dataset.lines[0].tags, "package round-trip OSM attributes")
        try check(roundtrip.lines.first(where: { $0.ref == "1号线" })?.routes?.first?.tags["route"] == "subway",
                  "package round-trip route relation")
        try check(roundtrip.licenseURL?.contains("odbl") == true, "export retains data license")
        try rejects("truncated input rejected") { _ = try RailwayCodec.decode(Data(encoded.prefix(50))) }
        try rejects("Overpass HTTP-200 partial timeout rejected") {
            _ = try RailwayCodec.decodeOverpass(
                Data("{\"remark\":\"runtime error: Query timed out\",\"elements\":[]}".utf8),
                bounds: .shanghai, name: "bad", sourceURL: "")
        }
        var bad = dataset
        bad.lines[0].coordinates[0] = Coordinate(200, 121)
        try rejects("invalid imported coordinates rejected") { try bad.validate() }
        bad = dataset
        bad.lines.append(bad.lines[0])
        try rejects("duplicate OSM IDs rejected") { try bad.validate() }
        bad = dataset
        bad.schemaVersion = 99
        try rejects("unknown package schema rejected") { try bad.validate() }
        bad = dataset
        bad.stations[0].id = "invalid id"
        try rejects("invalid source reference rejected") { try bad.validate() }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RailwayAtlasCheck-\(UUID().uuidString)")
        let repository = RailwayRepository(directory: temporary)
        try await repository.save(dataset)
        let loaded = try await repository.load()
        try check(loaded?.lines.count == dataset.lines.count, "offline persistence")
        do { try await repository.save(bad) } catch {}
        let afterFailure = try await repository.load()
        try check(afterFailure?.schemaVersion == 1, "invalid update preserves last usable package")
        // Remove only the dedicated directory created by this test.
        try FileManager.default.removeItem(at: temporary)
        print("\(count) checks passed. No XCTest/Xcode dependency required.")
        try await OnlineChecks.run()
        try await CacheCapacityChecks.run()
    }

    private static func checkLine(_ dataset: RailwayDataset, ref: String) throws -> RailLine {
        guard let line = dataset.lines.first(where: { $0.tags["ref"] == ref }) else {
            throw DataError.invalid("FAIL: route fixture line missing")
        }
        return line
    }
}

private extension RailLine {
    var ref: String? { tags["ref"] }
}
