import CSQLite
import Foundation
import RailwayCore

enum CacheCapacityChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw DataError.invalid("FAIL: \(label)") }
            count += 1
            print("PASS \(label)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtlasQuotaChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = 2 * 1024 * 1024
        let payload = OnlineChecks.tileFixture(tags: [
            ("feature", "rail"), ("name", "Capacity fixture"), ("description", String(repeating: "x", count: 96 * 1024))
        ])
        let now = Date().timeIntervalSince1970
        func key(_ x: Int) -> RailTileKey { RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: x, y: 775)) }
        func fixture(_ name: String, xs: [Int], fetched: Double, data: Data? = nil) throws -> URL {
            let url = root.appendingPathComponent(name + ".railcache")
            try makeDatabase(url, xs: xs, fetched: fetched, data: data ?? payload)
            return url
        }
        func diskBytes(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        }

        let directory = root.appendingPathComponent("bounded")
        let repository = RailwayTileRepository(directory: directory, cacheCapacity: capacity)
        let databaseURL = await repository.databaseURL
        let input = try fixture("large-import", xs: Array(100..<150), fetched: now - 1000)
        _ = try await repository.importCache(from: input)
        var stats = try await repository.stats()
        let retained = try await repository.cached((100..<150).map(key), source: RailwayTileRepository.defaultSource)
        try check(stats.count > 5 && stats.count < 50 && retained.contains { $0.key == key(149) }
                  && !retained.contains { $0.key == key(100) }, "capacity evicts oldest tiles and retains newest import entries")
        try check(stats.allocatedBytes == diskBytes(databaseURL) && stats.allocatedBytes <= capacity
                  && stats.allocatedBytes > stats.bytes && stats.capacityBytes == capacity,
                  "SQLite file, indexes and free pages share the hard capacity limit")

        let old = try fixture("older", xs: [149], fetched: now - 2000,
                              data: OnlineChecks.tileFixture(tags: [("feature", "rail"), ("name", "Older")]))
        _ = try await repository.importCache(from: old)
        let afterOld = try await repository.cached([key(149)], source: RailwayTileRepository.defaultSource)
        let afterOldStats = try await repository.stats()
        try check(afterOld.first?.features.lines.first?.name == "Capacity fixture"
                  && afterOldStats.count == stats.count,
                  "stale overwrite neither evicts tiles nor replaces newer data")

        let new = try fixture("newer", xs: [149], fetched: now,
                              data: OnlineChecks.tileFixture(tags: [("feature", "rail"), ("name", "Updated")]))
        _ = try await repository.importCache(from: new)
        let afterNew = try await repository.cached([key(149)], source: RailwayTileRepository.defaultSource)
        try check(afterNew.first?.features.lines.first?.name == "Updated",
                  "newer overwrite invalidates the decoded cache")

        // Repeated imports exercise freed-page reuse rather than payload-only limits.
        for batch in 0..<8 {
            let more = try fixture("cycle-\(batch)", xs: Array((200 + batch * 20)..<(220 + batch * 20)), fetched: now + Double(batch))
            _ = try await repository.importCache(from: more)
            try check(try diskBytes(databaseURL) <= capacity, "database stays bounded after eviction cycle \(batch + 1)")
        }
        stats = try await repository.stats()
        let reopened = RailwayTileRepository(directory: directory, cacheCapacity: capacity)
        let reopenedStats = try await reopened.stats()
        try check(reopenedStats.count == stats.count && reopenedStats.allocatedBytes <= capacity, "capacity and cached data survive reopening")

        let export = root.appendingPathComponent("export.railcache")
        try await repository.exportCache(to: export)
        let copy = RailwayTileRepository(directory: root.appendingPathComponent("copy"), cacheCapacity: capacity)
        _ = try await copy.importCache(from: export)
        try check((try await copy.stats()).count == stats.count && diskBytes(export) <= capacity,
                  "bounded database export and import retain all cached entries")

        // Fail after valid writes and eviction, so this proves transaction rollback.
        let corrupt = try fixture("late-corruption", xs: Array(400..<430), fetched: now + 100)
        try withDatabase(corrupt) { db in
            try sql(db, "UPDATE tiles SET data=x'FF' WHERE x=429")
        }
        var rejected = false
        do { _ = try await copy.importCache(from: corrupt) } catch { rejected = true }
        let afterFailure = try await copy.stats()
        let original = try await copy.cached((340..<360).map(key), source: RailwayTileRepository.defaultSource)
        try check(rejected && afterFailure.count == stats.count && afterFailure.bytes == stats.bytes && !original.isEmpty,
                  "invalid late import rolls back both inserted tiles and capacity evictions")

        let ancient = try fixture("ancient", xs: Array(500..<540), fetched: now - 10000)
        _ = try await copy.importCache(from: ancient)
        let stillRecent = try await copy.cached(original.map(\.key), source: RailwayTileRepository.defaultSource)
        try check(stillRecent.count == original.count, "older bulk import cannot displace newer cache entries")

        let legacyDirectory = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = legacyDirectory.appendingPathComponent("railways.railcache")
        try FileManager.default.copyItem(at: input, to: legacy)
        try check(try diskBytes(legacy) > capacity, "legacy fixture exceeds the physical database budget")
        let migrated = RailwayTileRepository(directory: legacyDirectory, cacheCapacity: capacity)
        let migratedStats = try await migrated.stats()
        let newest = try await migrated.cached([key(149)], source: RailwayTileRepository.defaultSource)
        let migratedSize = try diskBytes(legacy)
        try check(migratedStats.count > 0 && migratedStats.allocatedBytes <= capacity && diskBytes(legacy) <= capacity
                  && newest.count == 1, "oversized legacy database compacts and retains its newest tiles (\(migratedStats.count) tiles, \(migratedSize) bytes)")
        print("\(count) cache capacity checks passed.")
    }

    private static func makeDatabase(_ url: URL, xs: [Int], fetched: Double, data: Data) throws {
        try withDatabase(url) { db in
            try sql(db, """
            PRAGMA application_id=1380013132;
            PRAGMA user_version=1;
            CREATE TABLE tiles(source TEXT,layer TEXT,z INTEGER,x INTEGER,y INTEGER,fetched REAL,expires REAL,data BLOB,
                               PRIMARY KEY(source,layer,z,x,y));
            BEGIN;
            """)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO tiles VALUES('https://openrailwaymap.app','\(RailTileLayer.tracks.rawValue)',11,?,775,?,?,?)", -1,
                                     &statement, nil) == SQLITE_OK, let statement else { throw DataError.invalid("Fixture prepare") }
            defer { sqlite3_finalize(statement) }
            for (index, x) in xs.enumerated() {
                sqlite3_reset(statement)
                sqlite3_bind_int(statement, 1, Int32(x))
                sqlite3_bind_double(statement, 2, fetched + Double(index) / 1000)
                sqlite3_bind_double(statement, 3, fetched + 86400)
                let result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), nil)
                    return sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw DataError.invalid("Fixture insert") }
            }
            try sql(db, "COMMIT")
        }
    }
    private static func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw DataError.invalid("Fixture database") }
        defer { sqlite3_close(db) }
        try body(db)
    }
    private static func sql(_ db: OpaquePointer, _ statement: String) throws {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw DataError.invalid(String(cString: sqlite3_errmsg(db)))
        }
    }
}
