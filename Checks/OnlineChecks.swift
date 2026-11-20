import Foundation
import RailwayCore

enum OnlineChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw DataError.invalid("FAIL: \(label)") }
            count += 1
            print("PASS \(label)")
        }
        func rejects(_ label: String, _ block: () throws -> Void) throws {
            do { try block() } catch { count += 1; print("PASS \(label)"); return }
            throw DataError.invalid("FAIL: \(label)")
        }
        let key = RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1686, y: 775))
        let fixture = tileFixture()
        let features = try VectorTileDecoder.decode(fixture, key: key)
        try check(features.lines.count == 1 && features.lines[0].category == .speed350, "MVT geometry and speed")
        try check(features.lines[0].coordinates.count == 3, "MVT command sequence preserves vertices")
        try check(features.lines[0].coordinates.allSatisfy(\.isValid), "MVT projects XYZ to WGS84")
        let splitWay = tileFixture(tags: [("feature", "subway"), ("id", "330038852-3")])
        try check(try VectorTileDecoder.decode(splitWay, key: key).lines.first?.tags["atlas:osm"] == "way/330038852",
                  "documented ORM segment ID links every fragment to its OSM way")
        try rejects("truncated MVT rejected") { _ = try VectorTileDecoder.decode(Data(fixture.dropLast()), key: key) }
        try rejects("overflowing protobuf varint rejected") {
            _ = try VectorTileDecoder.decode(Data(repeating: 255, count: 12), key: key)
        }
        let national = RailTilePlan(bounds: .china, width: 920)
        try check((3...5).contains(national.zoom) && !national.keys.isEmpty && national.keys.count <= 128, "nationwide tile plan is bounded")
        try check(!national.keys.contains { $0.layer.isMetro }, "nationwide browsing never runs a nationwide Overpass query")
        try check(RailTilePlan(bounds: .shanghai, width: 900).keys.first?.layer == .metroNetwork, "metro relations start independently at city scale")
        try check(RailTilePlan(bounds: MapBounds(south: .nan, west: 0, north: 1, east: 1), width: 900).keys.isEmpty,
                  "invalid viewport rejected")
        try check(RailNetwork.classify(["railway": "rail", "usage": "industrial"]) == .industrial, "industrial railway switch")
        try check(RailNetwork.classify(["railway": "rail", "operator:type": "private"]) == .industrial, "explicit private operator switch")
        try check(RailNetwork.classify(["railway": "subway"]) == .metro, "metro and tram switches are independent")
        try check(RailNetwork.classify(["construction:railway": "tram"]) == .tram, "lifecycle retains network type")
        let metroData = Data("""
        {"elements":[{"type":"relation","id":123,"tags":{"route":"subway","ref":"1","network":"上海地铁","colour":"#00ff00"},"members":[
        {"type":"way","ref":9,"role":"","geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]},
        {"type":"way","ref":10,"role":"platform","geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]}
        ]}]}
        """.utf8)
        let metros = try MetroRouteDecoder.decode(metroData)
        try check(metros.lines.count == 1 && metros.lines[0].appearance.colors.first?.hex == "#E6002A",
                  "online metro uses official colour and excludes platforms")
        try check(metros.lines[0].appearance(showMetroColors: false).colors.isEmpty,
                  "metro colour switch also disables colours embedded in base geometry")
        let sharedMetro = Data("""
        {"elements":[
        {"type":"relation","id":1,"tags":{"type":"route_master","colour":"#112233","network":"测试地铁","ref":"A"},"members":[{"type":"relation","ref":2}]},
        {"type":"relation","id":2,"tags":{"type":"route","route":"subway"},"members":[{"type":"way","ref":9,"geometry":[null,{"lat":31,"lon":121},{"lat":31.01,"lon":121.01},null,{"lat":31.02,"lon":121.02},{"lat":31.03,"lon":121.03},null]}]},
        {"type":"relation","id":3,"tags":{"type":"route","route":"subway","colour":"#ff2200"},"members":[{"type":"way","ref":9,"geometry":[null,{"lat":31,"lon":121},{"lat":31.01,"lon":121.01},null,{"lat":31.02,"lon":121.02},{"lat":31.03,"lon":121.03},null]}]}
        ]}
        """.utf8)
        let shared = try MetroRouteDecoder.decode(sharedMetro)
        try check(shared.lines.count == 2 && shared.lines.allSatisfy { $0.coordinates.count == 2 },
                  "clipped metro geometry splits at nulls without dropping visible segments or bridging gaps")
        try check(shared.lines.allSatisfy { Set($0.appearance.colors.map(\.hex)) == ["#112233", "#FF2200"] },
                  "shared metro tracks preserve both route colours")
        try check(shared.lines[0].routes?.first?.colourSourceID == "relation/1",
                  "missing route colour inherits route_master with provenance")
        try check(shared.lines[0].appearance.strokes.filter { !$0.dash.isEmpty }.count == 2,
                  "shared route colours render as alternating strokes")
        try check(OfficialMetroPalette.color(for: ["network": "上海地铁", "ref": "1;2"]) == nil,
                  "ambiguous route ref is never assigned another line's official colour")
        let separateWays = Data("""
        {"elements":[
        {"type":"relation","id":4,"tags":{"type":"route","route":"subway","wikidata":"Q1234"},"members":[{"type":"way","ref":10,"role":""}]},
        {"type":"way","id":10,"geometry":[{"lat":31,"lon":121},{"lat":31.01,"lon":121.01}]}
        ]}
        """.utf8)
        let uncoloured = try MetroRouteDecoder.decode(separateWays)
        try check(uncoloured.lines.count == 1 && uncoloured.lines[0].routes?.first?.tags["wikidata"] == "Q1234",
                  "compact Overpass response joins separate ways and retains uncoloured routes for wiki enrichment")
        try rejects("partial metro response rejected") {
            _ = try MetroRouteDecoder.decode(Data(#"{"remark":"timeout","elements":[]}"#.utf8))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtlasOnlineChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TileProtocol.self]
        let session = URLSession(configuration: configuration)
        TileProtocol.state.configure(data: fixture, status: 200)
        let repository = RailwayTileRepository(directory: root.appendingPathComponent("a"), session: session)
        let first = try await repository.load(key)
        let second = try await repository.load(key)
        try check(!first.cached && second.cached && TileProtocol.state.requestCount == 1, "second load reads SQLite without network")
        let reopened = RailwayTileRepository(directory: root.appendingPathComponent("a"), session: session)
        let afterRestart = try await reopened.cached([key], source: RailwayTileRepository.defaultSource)
        try check(afterRestart.count == 1, "cache survives repository restart")
        TileProtocol.state.configure(data: Data(), status: 503)
        let fallback = try await repository.load(key, refresh: true)
        try check(fallback.cached && fallback.stale && !fallback.features.lines.isEmpty, "failed refresh retains and marks stale cache")
        let missing = RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1685, y: 775))
        let requests = TileProtocol.state.requestCount
        let offlineMiss = try await repository.cached([missing], source: RailwayTileRepository.defaultSource)
        try check(offlineMiss.isEmpty && TileProtocol.state.requestCount == requests, "offline cache miss never contacts network")
        let wrongSource = try await repository.cached([key], source: "https://other.example")
        try check(wrongSource.isEmpty, "different data sources do not share cache entries")
        let exported = root.appendingPathComponent("export.railcache")
        try await repository.exportCache(to: exported)
        let destination = RailwayTileRepository(directory: root.appendingPathComponent("b"), session: session)
        let imported = try await destination.importCache(from: exported)
        let importedTiles = try await destination.cached([key], source: RailwayTileRepository.defaultSource)
        try check(imported == 1 && importedTiles.count == 1,
                  "SQLite database export/import round trip")
        let bad = root.appendingPathComponent("bad.railcache")
        try Data("bad sqlite".utf8).write(to: bad)
        var rejectedImport = false
        do { _ = try await destination.importCache(from: bad) } catch { rejectedImport = true }
        let afterBadImport = try await destination.stats()
        try check(rejectedImport && afterBadImport.count == 1, "damaged database import preserves existing cache")
        TileProtocol.state.configure(data: Data(), status: 204)
        await repository.retrySources()
        let empty = try await repository.load(missing)
        let emptyCached = try await repository.cached([missing], source: RailwayTileRepository.defaultSource)
        try check(empty.features.lines.isEmpty && emptyCached.count == 1, "empty ocean tile is cached, avoiding repeated requests")
        try rejects("unsafe data source URL rejected") { _ = try RailwayTileRepository.normalizeSource("file:///tmp") }

        let versa = tileFixture(layer: "streets", tags: [("kind", "subway"), ("rail", "yes")])
        let omt = tileFixture(layer: "transportation", tags: [("class", "rail"), ("subclass", "rail")])
        let versaKey = RailTileKey(layer: .shortbread, tile: key.tile)
        let urban = try VectorTileDecoder.decode(versa, key: versaKey)
        try check(urban.lines.count == 1 && urban.lines[0].category == .urban, "Shortbread adapter distinguishes metro from roads")
        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: "slow.test", data: fixture, status: 200, delay: 4)
        TileProtocol.state.route(host: "tiles.versatiles.org", data: versa, status: 200)
        let fastRepo = RailwayTileRepository(directory: root.appendingPathComponent("latency"), session: session)
        let began = Date()
        let fastResult = try await fastRepo.load(key, source: "https://slow.test")
        try check(fastResult.fallback && Date().timeIntervalSince(began) < 2.5,
                  "slow primary yields to a valid backup before its four-second response")
        let road = tileFixture(layer: "streets", tags: [("kind", "rail"), ("rail", "no")])
        try check(try VectorTileDecoder.decode(road, key: versaKey).lines.isEmpty, "non-rail Shortbread streets excluded")
        let omtResult = try VectorTileDecoder.decode(omt, key: RailTileKey(layer: .openMapTiles, tile: key.tile))
        try check(omtResult.lines.first?.category == .unknown, "backup without speed stays unknown")
        let noColour = tileFixture(layer: "transportation_name", tags: [
            ("class", "transit"), ("subclass", "subway"), ("route_1_ref", "6"),
            ("route_1_network", "长沙轨道交通"), ("route_1_name", "6号线")])
        let uncolouredName = try VectorTileDecoder.decode(noColour, key: key)
        try check(uncolouredName.lines.first?.routes?.first?.tags["ref"] == "6",
                  "backup identity is retained even when the tile has no colour field")
        let colouredName = RailFeatureAssembler.assemble(tiles: [key: uncolouredName], palette: [:], wiki: [:],
                                                         enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        try check(colouredName.features.lines.first?.appearance.colors.first?.hex == "#005BAC",
                  "unncoloured backup route uses local palette without waiting for Overpass")
        let relationTile = tileFixture(tags: [("feature", "subway"),
            ("line_routes", #" [{"route_id":123,"label":"1号线","network":"长沙轨道交通","ref":"1"}] "#)])
        let relationFeature = try VectorTileDecoder.decode(relationTile, key: key)
        try check(relationFeature.lines.first?.routes?.first?.tags["network"] == "长沙轨道交通",
                  "ORM relation adapter retains the network and ref needed for immediate colour lookup")

        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: "tiles.versatiles.org", data: versa, status: 200)
        let backups = RailwayTileRepository(directory: root.appendingPathComponent("backups"), session: session)
        let switched = try await backups.load(key)
        try check(switched.provider == "VersaTiles" && switched.fallback && !switched.features.lines.isEmpty,
                  "primary HTTP failure automatically switches to independent vector source")
        let offlineRequests = TileProtocol.state.requestCount
        let offlineBackup = try await backups.cached([key], source: RailwayTileRepository.defaultSource)
        try check(offlineBackup.first?.provider == "VersaTiles" && TileProtocol.state.requestCount == offlineRequests,
                  "fallback cache retains source and works without networking")
        let backupStats = try await backups.stats()
        try check(backupStats.count == 1, "backup stored in its own schema namespace")
        let beforeFailure = TileProtocol.state.requestCount
        TileProtocol.state.configure(data: Data(), status: 503)
        let staleBackup = try await backups.load(key, refresh: true)
        try check(staleBackup.cached && staleBackup.stale && staleBackup.provider == "VersaTiles"
                  && TileProtocol.state.requestCount > beforeFailure, "manual refresh revalidates backup and preserves data on failure")

        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: "tiles.openfreemap.org", data: omt, status: 200)
        let metadata = Data(#"{"tiles":["https://tiles.openfreemap.org/planet/current/{z}/{x}/{y}.pbf"]}"#.utf8)
        TileProtocol.state.route(host: "tiles.openfreemap.org", path: "/planet", data: metadata, status: 200)
        let thirdSource = RailwayTileRepository(directory: root.appendingPathComponent("third"), session: session)
        let third = try await thirdSource.load(key)
        try check(third.provider == "OpenFreeMap" && third.fallback && third.features.lines.count == 1,
                  "two failed sources fall through to OpenFreeMap via TileJSON")
        try check(third.features.lines[0].tags["atlas:source"] == "OpenFreeMap / OpenMapTiles",
                  "feature provenance survives fallback")

        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: "tiles.versatiles.org", data: versa, status: 200, cacheControl: "max-age=0")
        let expiredRepo = RailwayTileRepository(directory: root.appendingPathComponent("expired"), session: session)
        _ = try await expiredRepo.load(key)
        let beforeExpired = TileProtocol.state.requestCount
        let renewed = try await expiredRepo.load(key)
        try check(!renewed.cached && TileProtocol.state.requestCount == beforeExpired + 1,
                  "expired backup cache is refreshed while failed primary backs off")

        TileProtocol.state.configure(data: Data(), status: 503)
        let lowRepo = RailwayTileRepository(directory: root.appendingPathComponent("low"), session: session)
        let beforeLow = TileProtocol.state.requestCount
        var lowRejected = false
        do { _ = try await lowRepo.load(RailTileKey(layer: .overview, tile: RailTile(z: 4, x: 12, y: 6))) }
        catch { lowRejected = true }
        try check(lowRejected && TileProtocol.state.requestCount == beforeLow + 1,
                  "low zoom never accepts a basemap with no railway coverage as success")
        let beforeBackoff = TileProtocol.state.requestCount
        do { _ = try await lowRepo.load(RailTileKey(layer: .overview, tile: RailTile(z: 4, x: 13, y: 6))) } catch {}
        try check(TileProtocol.state.requestCount == beforeBackoff, "failed provider backoff prevents repeated requests")
        await lowRepo.retrySources()
        do { _ = try await lowRepo.load(RailTileKey(layer: .overview, tile: RailTile(z: 4, x: 13, y: 6))) } catch {}
        try check(TileProtocol.state.requestCount == beforeBackoff + 1, "user retry immediately re-enables provider")

        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: URL(string: DataEndpoint.community.rawValue)!.host!, data: metroData, status: 200)
        let colorRepo = RailwayTileRepository(directory: root.appendingPathComponent("colours"), session: session)
        let colour = try await colorRepo.load(RailTileKey(layer: .metroColors, tile: RailTile(z: 10, x: 843, y: 387)))
        try check(colour.provider == DataEndpoint.community.title && colour.features.lines.count == 1,
                  "metro relation colours independently fail over between Overpass servers")
        TileProtocol.state.configure(data: fixture, status: 200)
        TileProtocol.state.route(host: URL(string: DataEndpoint.vk.rawValue)!.host!, data: Data(), status: 429)
        TileProtocol.state.route(host: URL(string: DataEndpoint.community.rawValue)!.host!, data: metroData, status: 200)
        let limitedRepo = RailwayTileRepository(directory: root.appendingPathComponent("limited"), session: session)
        _ = try await limitedRepo.load(RailTileKey(layer: .metroColors, tile: RailTile(z: 10, x: 843, y: 387)))
        let independentTrack = try await limitedRepo.load(key)
        try check(!independentTrack.fallback, "rate-limited colour service never disables the independent railway provider")

        var wikiRoute = metros.lines[0].routes![0]
        wikiRoute.tags = ["route": "subway", "network": "广州地铁", "ref": "3", "wikidata": "Q862941", "colour": "#998877"]
        try check(WikiMetroColours.identity(for: wikiRoute) == "Q862941", "wiki colour lookup uses line identity, not ambiguous route numbers")
        let paletteData = Data(##"[{"colour":"#ECA154","name":{"en":"Line 3","zh-Hans":"3号线"}}]"##.utf8)
        TileProtocol.state.configure(data: Data(), status: 503)
        TileProtocol.state.route(host: "railmapgen.github.io", data: paletteData, status: 200)
        let paletteRepo = RailwayTileRepository(directory: root.appendingPathComponent("palette"), session: session)
        let palette = try await paletteRepo.paletteColours(for: [wikiRoute], online: true)
        try check(MetroPalette.applying(palette, to: wikiRoute).color?.hex == "#ECA154",
                  "community palette falls through from Chinese-facing site to GitHub Pages")
        let beforePaletteCache = TileProtocol.state.requestCount
        _ = try await paletteRepo.paletteColours(for: [wikiRoute], online: false)
        try check(TileProtocol.state.requestCount == beforePaletteCache, "community palette works from SQLite offline")
        var unidentified = wikiRoute
        unidentified.tags.removeValue(forKey: "network")
        try check(MetroPalette.key(for: unidentified) == nil, "palette never matches a line number without its city network")
        try check(WikiMetroColours.infoboxColour("| color = #ECA154 <!-- source -->") == "#ECA154",
                  "Wikipedia explicit infobox colour is parsed")
        try check(WikiMetroColours.infoboxColour("background:#112233\n| color = {{unresolved template}}") == nil,
                  "Wikipedia prose, CSS and unresolved templates are never guessed as line colours")
        let wikiData = Data("""
        {"entities":{"Q862941":{"claims":{"P465":[
        {"rank":"normal","mainsnak":{"snaktype":"value","datavalue":{"value":"112233"}}},
        {"rank":"preferred","mainsnak":{"snaktype":"value","datavalue":{"value":"ECA154"}}}
        ]}}}}
        """.utf8)
        TileProtocol.state.configure(data: wikiData, status: 200)
        let wikiRepo = RailwayTileRepository(directory: root.appendingPathComponent("wiki"), session: session)
        let wiki = try await wikiRepo.wikiColours(for: [wikiRoute], online: true)
        let enhanced = wiki.records["Q862941"]!.applying(to: wikiRoute)
        try check(enhanced.color?.hex == "#ECA154" && enhanced.colorSourceName == "Wikidata · P465",
                  "preferred Wikidata P465 overrides fallback OSM colour with source attribution")
        var official = enhanced
        official.tags["network"] = "上海地铁"
        official.tags["ref"] = "1"
        try check(official.color?.hex == "#E6002A", "verified official metro palette remains above wiki colour")
        let beforeWikiCache = TileProtocol.state.requestCount
        _ = try await wikiRepo.wikiColours(for: [wikiRoute], online: true)
        try check(TileProtocol.state.requestCount == beforeWikiCache, "wiki metadata cache avoids repeated city requests")
        let wikiExport = root.appendingPathComponent("wiki.railcache")
        try await wikiRepo.exportCache(to: wikiExport)
        let wikiImported = RailwayTileRepository(directory: root.appendingPathComponent("wiki-import"), session: session)
        _ = try await wikiImported.importCache(from: wikiExport)
        let offlineWiki = try await wikiImported.wikiColours(for: [wikiRoute], online: false)
        try check(offlineWiki.records["Q862941"]?.hex == "#ECA154" && TileProtocol.state.requestCount == beforeWikiCache,
                  "wiki colours survive database export/import and offline reload without network")
        TileProtocol.state.configure(data: Data(), status: 503)
        var missingWiki = wikiRoute
        missingWiki.tags["wikidata"] = "Q1234567"
        let unavailableWiki = try await wikiRepo.wikiColours(for: [wikiRoute, missingWiki], online: true)
        try check(unavailableWiki.records["Q862941"]?.hex == "#ECA154" && missingWiki.color?.hex == "#998877",
                  "unreachable wiki keeps cached and OSM colours intact")
        TileProtocol.state.configure(data: Data(#"{"entities":{"Q862941":{"sitelinks":{"zhwiki":{"title":"广州地铁3号线"}}}}}"#.utf8), status: 200)
        let pageData = Data(#"{"query":{"pages":[{"title":"广州地铁3号线","revisions":[{"slots":{"main":{"content":"{{Infobox rail line\n| color = #ECA154\n}}"}}}]}]}}"#.utf8)
        TileProtocol.state.route(host: "zh.wikipedia.org", data: pageData, status: 200)
        let pageRepo = RailwayTileRepository(directory: root.appendingPathComponent("wiki-page"), session: session)
        let pageColour = try await pageRepo.wikiColours(for: [wikiRoute], online: true)
        try check(pageColour.records["Q862941"]?.hex == "#ECA154"
                  && pageColour.records["Q862941"]?.sourceName == "Wikipedia · 线路信息框",
                  "Wikidata missing P465 automatically falls back to linked Wikipedia infobox")
        print("\(count) online/cache checks passed.")
    }

    static func live(directory: URL) async throws {
        let repository = RailwayTileRepository(directory: directory)
        let samples: [(String, RailTileKey)] = [
            ("全国概览", RailTileKey(layer: .overview, tile: RailTile(z: 4, x: 12, y: 6))),
            ("北京", RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1686, y: 775))),
            ("广州", RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1668, y: 889))),
            ("成都", RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1615, y: 840))),
            ("乌鲁木齐", RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1522, y: 746))),
            ("拉萨", RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1542, y: 847))),
            ("北京车站", RailTileKey(layer: .stations, tile: RailTile(z: 11, x: 1686, y: 775))),
            ("北京线路色", RailTileKey(layer: .metroColors, tile: RailTile(z: 10, x: 843, y: 387)))
        ]
        for (name, key) in samples {
            let start = Date()
            let result = try await repository.load(key)
            guard !result.features.lines.isEmpty || !result.features.stations.isEmpty else { throw DataError.invalid("\(name) returned no features") }
            print("\(name): \(result.features.lines.count) lines, \(result.features.stations.count) stations, cache=\(result.cached), \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
        let before = try await repository.stats()
        let cached = try await repository.cached(samples.map(\.1), source: RailwayTileRepository.defaultSource)
        guard cached.count == samples.count else { throw DataError.invalid("Live cache reload failed") }
        print("LIVE PASS: \(before.count) tiles, \(before.bytes) bytes; all sample views reloaded from SQLite.")
    }

    static func tileFixture(layer name: String = "railway_line_high",
                                    tags: [(String, String)] = [("feature", "rail"), ("maxspeed", "350")]) -> Data {
        func v(_ n: UInt64) -> Data {
            var n = n, result = Data()
            repeat {
                var b = UInt8(n & 127); n >>= 7
                if n > 0 { b |= 128 }
                result.append(b)
            } while n > 0
            return result
        }
        func bytes(_ field: UInt64, _ data: Data) -> Data { v(field * 8 + 2) + v(UInt64(data.count)) + data }
        func s(_ field: UInt64, _ string: String) -> Data { bytes(field, Data(string.utf8)) }
        let geometry = [UInt64(9), 4096, 4096, 18, 200, 200, 200, 0].reduce(Data()) { $0 + v($1) }
        let pairs = tags.indices.reduce(Data()) { $0 + v(UInt64($1)) + v(UInt64($1)) }
        let feature = bytes(2, pairs) + v(24) + v(2) + bytes(4, geometry)
        let layer = s(1, name) + bytes(2, feature) + tags.reduce(Data()) { $0 + s(3, $1.0) }
            + tags.reduce(Data()) { $0 + bytes(4, s(1, $1.1)) } + v(40) + v(4096) + v(120) + v(2)
        return bytes(3, layer)
    }
}

private final class ProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var count = 0
    private var routes: [String: (Data, Int, String, TimeInterval)] = [:]
    func configure(data: Data, status: Int) {
        lock.lock(); defer { lock.unlock() }
        self.data = data; self.status = status; routes = [:]
    }
    func route(host: String, path: String = "", data: Data, status: Int, cacheControl: String = "max-age=600", delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        routes[host + path] = (data, status, cacheControl, delay)
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next(_ url: URL) -> (Data, Int, String, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return routes[(url.host ?? "") + url.path] ?? routes[url.host ?? ""] ?? (data, status, "max-age=600", 0)
    }
}

private final class TileProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProtocolState()
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status, control, delay) = Self.state.next(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Cache-Control": control])!
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) }
        else { work.perform() }
    }
    override func stopLoading() { pending?.cancel() }
}
