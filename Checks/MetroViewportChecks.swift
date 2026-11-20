import CSQLite
import Foundation
import RailwayCore

/// Standalone hooks for the main check runner. No live service is used.
enum MetroViewportChecks {
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DataError.invalid(message) }
    }

    static func run() throws {
        let regions: [(String, MapBounds, [Coordinate])] = [
            ("京津", MapBounds(south: 38.6, west: 115.9, north: 40.6, east: 118.1),
             [Coordinate(39.9, 116.4), Coordinate(39.12, 117.2)]),
            ("广佛深港", MapBounds(south: 21.9, west: 112.9, north: 23.7, east: 114.7),
             [Coordinate(23.13, 113.26), Coordinate(23.02, 113.12),
              Coordinate(22.54, 114.06), Coordinate(22.3, 114.17)]),
            ("沪苏杭", MapBounds(south: 29.8, west: 119.5, north: 32.4, east: 121.8),
             [Coordinate(31.23, 121.47), Coordinate(31.3, 120.58), Coordinate(30.27, 120.15)])
        ]
        for (name, bounds, cities) in regions {
            let plan = RailTilePlan(bounds: bounds, width: 1200)
            let metro = plan.keys.filter { $0.layer == .metroNetwork }
            try require(plan.zoom == 9 && !metro.isEmpty && metro.count <= MetroViewport.maximumCells,
                        "\(name): regional metro coverage missing or unbounded")
            try require(Set(plan.keys).count == plan.keys.count, "\(name): duplicate tile requests")
            try require(cities.allSatisfy { city in metro.contains { $0.tile.bounds.contains(city) } },
                        "\(name): coverage chose only one city")
            let fringe = Coordinate(bounds.north + (bounds.north - bounds.south) * 0.15,
                                    bounds.east + (bounds.east - bounds.west) * 0.15)
            try require(metro.contains { $0.tile.bounds.contains(fringe) },
                        "\(name): 20% viewport fringe not covered")
            let buffered = bounds.expanded(by: 0.2)
            try require(metro.allSatisfy { $0.tile.bounds.intersects(buffered) },
                        "\(name): unrelated cells requested")
            try require(!plan.keys.contains { $0.layer == .metroStations },
                        "\(name): regional coverage fetched city-detail stations")
        }
        let wide = MapBounds(south: 29.7, west: 118.2, north: 32.8, east: 122.2)
        let widePlan = RailTilePlan(bounds: wide, width: 3000)
        let wideMetro = widePlan.keys.filter { $0.layer == .metroNetwork }
        try require(RailDisplayPolicy.zoom(longitudeSpan: 4, width: 3000) > 10
                    && RailTile.covering(wide, zoom: 10).isEmpty && widePlan.zoom == 9,
                    "Wide-screen fixture must exercise the 64-cell track-plan downgrade")
        try require(!wideMetro.isEmpty && wideMetro.count <= 64
                    && wideMetro.contains { $0.tile.bounds.contains(Coordinate(32.06, 118.8)) }
                    && wideMetro.contains { $0.tile.bounds.contains(Coordinate(31.23, 121.47)) },
                    "Wide-screen downgrade lost Nanjing or Shanghai")
        try require(RailDisplayPolicy.minimumZoom(RailCategory.urban) == 8
                    && RailDisplayPolicy.minimumZoom(RailNetwork.metro) == 8
                    && RailDisplayPolicy.minimumZoom(RailNetwork.lightRail) == 8
                    && RailDisplayPolicy.minimumZoom(RailNetwork.tram) == 8,
                    "Display gates disagree with regional metro coverage")
        try require(!RailTilePlan(bounds: .china, width: 1200).keys.contains { $0.layer.isMetro },
                    "National overview must not issue a nationwide metro query")

        let child = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 845, y: 390))
        let parent = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 9, x: 422, y: 195))
        let retained = RailTileContinuity.retainedKeys(existing: [child], requested: [parent],
            ready: [], bounds: parent.tile.bounds)
        try require(retained.contains(child), "Regional query discarded arrived city geometry before replacement")
        try require(RailTileContinuity.retainedKeys(existing: [child], requested: [parent],
            ready: [parent], bounds: parent.tile.bounds).isEmpty, "Completed regional coverage retained duplicate detail")
        let edge = child.tile.bounds
        let fringeView = MapBounds(south: edge.center.latitude - 0.1, west: edge.east + 0.01,
                                  north: edge.center.latitude + 0.1, east: edge.east + 0.31)
        let far = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 836, y: 446))
        try require(RailTileContinuity.retainedKeys(existing: [child, far], requested: [], ready: [],
            bounds: fringeView) == [child], "Buffered continuity lost nearby data or retained a departed city")
        print("PASS multi-city coverage, 20% fringe, wide-screen cap, regional display gates, and buffered continuity")
    }

    /// Exercise the actual repository using a tiny, disposable SQLite fixture.
    /// Two cities in one regional cell remain a union, but do not mark its two
    /// missing quadrants complete. A complete coarser cache also serves zoom-in.
    static func repository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RailwayAtlas-MetroViewportChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 9, x: 256, y: 256))
        let a = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 512, y: 512))
        let b = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 513, y: 513))
        let remoteParent = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 9, x: 280, y: 260))
        let remoteChild = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 560, y: 520))
        let legacyChild = RailTileKey(layer: .metroColors, tile: remoteChild.tile)
        let c = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 512, y: 513))
        let d = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 513, y: 512))
        let database = directory.appendingPathComponent("railways.railcache")
        let source = "https://metro-coverage-fixture.invalid"
        try seed(database, source: source, entries: [
            (a, a.tile.bounds.center, 1), (b, b.tile.bounds.center, 2),
            (remoteParent, remoteChild.tile.bounds.center, 3),
            (remoteChild, remoteChild.tile.bounds.center, 90),
            (legacyChild, remoteChild.tile.bounds.center, 91)
        ], expired: [remoteChild])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetroCoverageProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MetroCoverageProtocol.state.reset()
        let repository = RailwayTileRepository(directory: directory, session: session)
        let values = try await repository.cached([parent, remoteChild, a, b], source: source)
        guard let regional = values.first(where: { $0.key == parent }),
              let detail = values.first(where: { $0.key == remoteChild }),
              let cityA = values.first(where: { $0.key == a }),
              let cityB = values.first(where: { $0.key == b }) else {
            throw DataError.invalid("Cross-zoom metro cache not reused")
        }
        try require(Set(regional.features.lines.flatMap { ($0.routes ?? []).map(\.id) })
                    == ["relation/1", "relation/2"] && regional.stale && !regional.snapshot
                    && !regional.coverageComplete,
                    "Partial regional cache lost a city or claimed complete coverage")
        try require(!detail.stale && detail.coverageComplete && !detail.features.lines.isEmpty
                    && Set(detail.features.lines.flatMap { ($0.routes ?? []).map(\.id) }) == ["relation/3"]
                    && detail.features.lines.flatMap(\.coordinates).allSatisfy { remoteChild.tile.bounds.contains($0) },
                    "Expired exact/legacy data hid fresh clipped parent coverage")
        let assembly = RailFeatureAssembler.assemble(tiles: [parent: regional.features],
            palette: [:], wiki: [:], enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        try require(Set(assembly.features.lines.flatMap { ($0.routes ?? []).map(\.id) })
                    == ["relation/1", "relation/2"],
                    "Assembly merged same-number routes from different fixture cities")

        // Losing one disk child must not erase the other city's arrived data.
        try discard(b, from: database, source: source)
        guard let smaller = try await repository.cached([parent], source: source).first,
              let kept = RailTileContinuity.accepting(smaller, existing: regional.features, existingFallback: false),
              let repeated = RailTileContinuity.accepting(smaller, existing: kept, existingFallback: false) else {
            throw DataError.invalid("Partial cache could not be merged")
        }
        try require(!smaller.coverageComplete && smaller.features.lines.count < regional.features.lines.count
                    && Set(kept.lines.map(\.id)) == Set(regional.features.lines.map(\.id))
                    && repeated.lines.count == kept.lines.count && repeated.stations.count == kept.stations.count
                    && repeated.memberships == kept.memberships,
                    "Partial same-key cache erased a city or multiplied geometry/membership")

        // Use a small mixed-result fixture instead of decoding every bundled
        // city just to exercise the primary/snapshot acceptance boundary.
        var primary = cityA.features
        primary.lines[0].tags["fixture:primary"] = "yes"
        primary.stations[0].tags["fixture:primary"] = "yes"
        var mixed = regional
        mixed.snapshot = true
        var additions = cityB.features
        var sharedLine = cityA.features.lines[0], sharedStation = cityA.features.stations[0]
        sharedLine.routes = cityB.features.lines[0].routes
        sharedStation.routes = cityB.features.stations[0].routes
        additions.lines.append(sharedLine); additions.stations.append(sharedStation)
        mixed.primaryFeatures = additions
        guard let joined = RailTileContinuity.accepting(mixed, existing: primary, existingFallback: false) else {
            throw DataError.invalid("Snapshot presence rejected the newly arrived real city")
        }
        try require(Set(joined.lines.map(\.id)) == Set(regional.features.lines.map(\.id))
                    && joined.lines.first { $0.id == primary.lines[0].id }?.tags["fixture:primary"] == "yes"
                    && joined.stations.first { $0.id == primary.stations[0].id }?.tags["fixture:primary"] == "yes"
                    && Set(joined.lines.first { $0.id == sharedLine.id }?.routes?.map(\.id) ?? [])
                        == ["relation/1", "relation/2"]
                    && Set(joined.stations.first { $0.id == sharedStation.id }?.routes?.map(\.id) ?? [])
                        == ["relation/1", "relation/2"],
                    "Mixed snapshot result overwrote primary geometry or station attributes")
        mixed.primaryFeatures = nil
        try require(RailTileContinuity.accepting(mixed, existing: primary, existingFallback: false) == nil,
                    "Snapshot-only result replaced primary data")
        var backup = cityA
        backup.fallback = true
        try require(RailTileContinuity.accepting(backup, existing: primary, existingFallback: false) == nil,
                    "New partial merging weakened same-key primary protection")

        // All four fresh children outrank an expired exact cell. Expiry of one
        // child changes freshness, but must not revoke spatial completeness.
        try seed(database, source: source, entries: [
            (parent, parent.tile.bounds.center, 92), (b, b.tile.bounds.center, 2),
            (c, c.tile.bounds.center, 4), (d, d.tile.bounds.center, 5)
        ], expired: [parent])
        let complete = try await repository.load(parent, source: source)
        try require(complete.coverageComplete && !complete.stale && !complete.snapshot
                    && Set(complete.features.lines.flatMap { ($0.routes ?? []).map(\.id) })
                        == ["relation/1", "relation/2", "relation/4", "relation/5"]
                    && MetroCoverageProtocol.state.count == 0,
                    "Expired exact cell hid fresh four-child coverage or triggered networking")
        try discard(parent, from: database, source: source)
        try seed(database, source: source, entries: [(a, a.tile.bounds.center, 1)], expired: [a])
        guard let expiredComplete = try await repository.cached([parent], source: source).first else {
            throw DataError.invalid("Expired complete coverage disappeared")
        }
        try require(expiredComplete.coverageComplete && expiredComplete.stale && !expiredComplete.snapshot,
                    "Expiry was mistaken for incomplete spatial coverage")
        try seed(database, source: source, entries: [(parent, parent.tile.bounds.center, 0)])
        let empty = try await repository.load(parent, source: source)
        guard let replaced = RailTileContinuity.accepting(empty, existing: joined, existingFallback: false) else {
            throw DataError.invalid("Complete primary result was rejected")
        }
        try require(empty.coverageComplete && replaced.lines.isEmpty && replaced.stations.isEmpty
                    && replaced.memberships.isEmpty && MetroCoverageProtocol.state.count == 0,
                    "A complete empty primary result could not replace previously arrived data")

        // All URLs are intercepted. Cancel a real repository request in flight;
        // neither a late result nor an error may overwrite the arrived cache.
        let before = try await repository.stats()
        MetroCoverageProtocol.state.holdRequests()
        let missing = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 700, y: 700))
        let pending = Task { try await repository.load(missing, source: source) }
        defer { pending.cancel() }
        for _ in 0..<100 {
            if MetroCoverageProtocol.state.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        pending.cancel()
        do {
            _ = try await pending.value
            throw DataError.invalid("Cancelled repository request returned a replacement")
        } catch is CancellationError {}
        let after = try await repository.stats()
        let unchanged = try await repository.cached([remoteChild], source: source).first
        try require(MetroCoverageProtocol.state.count > 0 && MetroCoverageProtocol.state.stops > 0
                    && before.count == after.count && before.bytes == after.bytes
                    && unchanged?.features.lines.map(\.id) == detail.features.lines.map(\.id),
                    "Cancellation failed to drain the request or changed arrived cache data")
        print("PASS partial/mixed same-key continuity, fresh cross-zoom precedence, expired complete coverage, and isolated request cancellation")
    }

    /// Read the user's copied cache directly in read-only mode; never open it
    /// through the writable repository or fetch replacement data.
    static func cache(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw DataError.invalid("Cannot open copied regression cache")
        }
        defer { sqlite3_close(db) }
        func read(_ key: RailTileKey, source: String) throws -> (RailTileFeatures, Double) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data,expires FROM tiles WHERE source=? AND layer=? AND z=? AND x=? AND y=?",
                                    -1, &statement, nil) == SQLITE_OK, let q = statement else {
                throw DataError.invalid("Cannot query copied regression cache")
            }
            defer { sqlite3_finalize(q) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = source.withCString { sqlite3_bind_text(q, 1, $0, -1, transient) }
            _ = key.layer.rawValue.withCString { sqlite3_bind_text(q, 2, $0, -1, transient) }
            sqlite3_bind_int(q, 3, Int32(key.tile.z)); sqlite3_bind_int(q, 4, Int32(key.tile.x))
            sqlite3_bind_int(q, 5, Int32(key.tile.y))
            guard sqlite3_step(q) == SQLITE_ROW, let bytes = sqlite3_column_blob(q, 0) else {
                throw DataError.invalid("Missing copied regression cell: \(key.path)")
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(q, 0)))
            return (try RailwayTileRepository.decode(data, key: key), sqlite3_column_double(q, 1))
        }
        let shenzhen = RailTileKey(layer: .tracks, tile: RailTile(z: 10, x: 836, y: 446))
        let tianjin = RailTileKey(layer: .tracks, tile: RailTile(z: 10, x: 845, y: 390))
        let backup = RailTileKey(layer: .openMapTiles, tile: shenzhen.tile)
        let (primary, oldExpiry) = try read(shenzhen, source: RailwayTileRepository.defaultSource)
        let (fallback, newExpiry) = try read(backup, source: "https://tiles.openfreemap.org")
        let (tj, _) = try read(tianjin, source: RailwayTileRepository.defaultSource)
        func subways(_ features: RailTileFeatures) -> Int {
            features.lines.filter { $0.tags["railway"] == "subway" }.count
        }
        try require(subways(primary) > 0 && subways(tj) > 0 && subways(fallback) == 0 && newExpiry > oldExpiry,
                    "Copied cache no longer reproduces the fresh-backup/older-subway contrast")
        try require(!RailTileContinuity.shouldReplace(existing: primary, existingFallback: false,
                                                     incomingFallback: true),
                    "Fresh backup erased Shenzhen's arrived primary subway geometry")
        try require(RailTileContinuity.shouldReplace(existing: nil, existingFallback: false, incomingFallback: true)
                    && RailTileContinuity.shouldReplace(existing: fallback, existingFallback: true, incomingFallback: true)
                    && RailTileContinuity.shouldReplace(existing: primary, existingFallback: false, incomingFallback: false),
                    "Continuity protection blocked empty-cell fallback or primary refresh")
        try require(!RailTileContinuity.shouldReplace(existing: primary, existingFallback: false,
                                                     incomingFallback: false, incomingSnapshot: true),
                    "A partial city snapshot could replace already arrived regional coverage")
        print("PASS copied cache: Shenzhen primary \(subways(primary)), fresh backup \(subways(fallback)), Tianjin \(subways(tj)) subway fragments; primary coverage retained")
    }

    private static func discard(_ key: RailTileKey, from url: URL, source: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw DataError.invalid("Cannot open isolated cache for eviction")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM tiles WHERE source=? AND layer=? AND z=? AND x=? AND y=?",
                                -1, &statement, nil) == SQLITE_OK, let q = statement else {
            throw DataError.invalid("Cannot evict isolated cache child")
        }
        defer { sqlite3_finalize(q) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = source.withCString { sqlite3_bind_text(q, 1, $0, -1, transient) }
        _ = key.layer.rawValue.withCString { sqlite3_bind_text(q, 2, $0, -1, transient) }
        sqlite3_bind_int(q, 3, Int32(key.tile.z)); sqlite3_bind_int(q, 4, Int32(key.tile.x))
        sqlite3_bind_int(q, 5, Int32(key.tile.y))
        guard sqlite3_step(q) == SQLITE_DONE else { throw DataError.invalid("Isolated cache eviction failed") }
    }

    private static func seed(_ url: URL, source: String,
                             entries: [(RailTileKey, Coordinate, Int)], expired: Set<RailTileKey> = []) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw DataError.invalid("Cannot create isolated metro cache fixture")
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE IF NOT EXISTS tiles(source TEXT NOT NULL, layer TEXT NOT NULL, z INTEGER NOT NULL,
        x INTEGER NOT NULL, y INTEGER NOT NULL, fetched REAL NOT NULL, expires REAL NOT NULL,
        data BLOB NOT NULL, PRIMARY KEY(source,layer,z,x,y));
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw DataError.invalid("Cannot create isolated cache schema")
        }
        for (key, point, id) in entries {
            let relation: [String: Any] = [
                "type": "relation", "id": id,
                "tags": ["type": "route", "route": "subway", "ref": "1",
                         "network": "Fixture City \(id)", "name": "City \(id) Line 1", "colour": "#0077CC"],
                "members": [["type": "way", "ref": 1000 + id, "geometry": [
                    ["lat": point.latitude, "lon": point.longitude - 0.01],
                    ["lat": point.latitude, "lon": point.longitude + 0.01]
                ]], ["type": "node", "ref": 2000 + id, "role": "stop"]]
            ]
            let station: [String: Any] = ["type": "node", "id": 2000 + id,
                "lat": point.latitude, "lon": point.longitude, "tags": ["name": "City \(id) Station"]]
            let elements = id == 0 ? [] : [relation, station]
            let data = try JSONSerialization.data(withJSONObject: ["elements": elements])
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO tiles VALUES(?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK,
                  let q = statement else { throw DataError.invalid("Cannot seed isolated cache") }
            defer { sqlite3_finalize(q) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = source.withCString { sqlite3_bind_text(q, 1, $0, -1, transient) }
            _ = key.layer.rawValue.withCString { sqlite3_bind_text(q, 2, $0, -1, transient) }
            sqlite3_bind_int(q, 3, Int32(key.tile.z)); sqlite3_bind_int(q, 4, Int32(key.tile.x))
            sqlite3_bind_int(q, 5, Int32(key.tile.y))
            sqlite3_bind_double(q, 6, Date().timeIntervalSince1970)
            sqlite3_bind_double(q, 7, Date().addingTimeInterval(expired.contains(key) ? -3600 : 3600).timeIntervalSince1970)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(q, 8, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(q) == SQLITE_DONE else { throw DataError.invalid("Cannot save isolated metro fixture") }
        }
    }
}

private final class MetroCoverageProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0, stopped = 0
        private var hold = false
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopped }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            requests = 0; stopped = 0; hold = false
        }
        func holdRequests() { lock.lock(); defer { lock.unlock() }; hold = true }
        func begin() -> Bool { lock.lock(); defer { lock.unlock() }; requests += 1; return hold }
        func stop() { lock.lock(); defer { lock.unlock() }; stopped += 1 }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if !Self.state.begin() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
    override func stopLoading() { Self.state.stop() }
}
