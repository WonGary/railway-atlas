import CSQLite
import Foundation

public struct RailCacheStats: Sendable {
    public static let capacity = 8 * 1024 * 1024 * 1024
    public var count: Int = 0
    /// Encoded tile payloads; excludes SQLite pages and indexes.
    public var bytes: Int = 0
    /// Allocated main database size, including reusable free pages.
    public var allocatedBytes: Int = 0
    public var capacityBytes: Int = Self.capacity
    public var minimumZoom: Int = 0
    public var maximumZoom: Int = 0
    public var oldest: Date?
    public init() {}
}

struct CachedRailTile: Sendable {
    let data: Data
    let fetched: Date
    let expires: Date
}

/// All access is serialized by RailwayTileRepository. A connection is never
/// shared with the UI or a network callback.
final class RailwayTileCache: @unchecked Sendable {
    static let applicationID = 0x5241544C
    static let budget = RailCacheStats.capacity
    let db: OpaquePointer
    private let capacity: Int
    private var pageSize = 4096
    private var maximumPages = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false, capacity: Int = RailwayTileCache.budget) throws {
        self.capacity = min(Self.budget, max(256 * 1024, capacity))
        var handle: OpaquePointer?
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DataError.invalid("无法打开铁路缓存数据库")
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        do {
            try execute("PRAGMA trusted_schema=OFF")
            if readOnly {
                guard try scalar("PRAGMA application_id") == Self.applicationID,
                      try scalar("PRAGMA user_version") == 1 else { throw DataError.invalid("不是支持的 Railway Atlas 缓存数据库") }
                let integrity = try prepare("PRAGMA quick_check")
                defer { sqlite3_finalize(integrity) }
                guard sqlite3_step(integrity) == SQLITE_ROW, text(integrity, 0) == "ok" else {
                    throw DataError.invalid("缓存数据库已损坏")
                }
            } else {
                let version = try scalar("PRAGMA user_version")
                guard version == 0 || version == 1 else { throw DataError.invalid("缓存数据库版本过新") }
                try execute("""
                PRAGMA application_id=\(Self.applicationID);
                PRAGMA user_version=1;
                CREATE TABLE IF NOT EXISTS tiles (
                    source TEXT NOT NULL, layer TEXT NOT NULL, z INTEGER NOT NULL,
                    x INTEGER NOT NULL, y INTEGER NOT NULL, fetched REAL NOT NULL,
                    expires REAL NOT NULL, data BLOB NOT NULL,
                    PRIMARY KEY(source,layer,z,x,y)
                );
                CREATE INDEX IF NOT EXISTS tiles_fetched ON tiles(fetched);
                """)
                // NORMAL halves fsyncs per tile write while keeping the rollback
                // journal, so the main file size still equals the capacity budget.
                // The cache is re-fetchable, so FULL durability is unnecessary.
                try? execute("PRAGMA synchronous=NORMAL")
                try? execute("PRAGMA cache_size=-32768")
                try? execute("PRAGMA temp_store=MEMORY")
            }
            pageSize = try scalar("PRAGMA page_size")
            maximumPages = self.capacity / pageSize
            if !readOnly {
                // Older versions limited blob bytes only. Reclaim their free
                // pages once when necessary; ordinary writes reuse pages.
                if try scalar("PRAGMA page_count") > maximumPages {
                    _ = try reclaim(until: maximumPages * 9 / 10, olderThan: nil)
                    try execute("VACUUM")
                }
                guard try scalar("PRAGMA max_page_count=\(maximumPages)") <= maximumPages else {
                    throw DataError.invalid("无法将铁路缓存压缩至容量上限")
                }
            }
        } catch { throw error }
    }
    deinit { sqlite3_close(db) }

    func read(_ key: RailTileKey, source: String) throws -> CachedRailTile? {
        let q = try prepare("SELECT data,fetched,expires FROM tiles WHERE source=? AND layer=? AND z=? AND x=? AND y=?")
        defer { sqlite3_finalize(q) }
        bind(key, source: source, to: q)
        let status = sqlite3_step(q)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        return try row(q)
    }

    func save(_ key: RailTileKey, source: String, entry: CachedRailTile) throws {
        guard entry.data.count <= VectorTileDecoder.maxBytes else { throw DataError.invalid("缓存瓦片超过大小限制") }
        let old = try prepare("SELECT fetched FROM tiles WHERE source=? AND layer=? AND z=? AND x=? AND y=?")
        bind(key, source: source, to: old)
        let status = sqlite3_step(old)
        let newer = status == SQLITE_ROW && sqlite3_column_double(old, 0) > entry.fetched.timeIntervalSince1970
        sqlite3_finalize(old)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
        if newer { return }
        // Reserve overflow and B-tree split pages before writing. max_page_count
        // is the hard bound; this headroom avoids SQLITE_FULL rolling back a
        // larger import transaction. Include a whole replacement blob because
        // SQLite may allocate it before releasing the previous value.
        let payload = entry.data.count + source.utf8.count + key.layer.rawValue.utf8.count + 128
        let reserve = (payload + (pageSize - 64) - 1) / (pageSize - 64) + 16
        guard reserve + 4 <= maximumPages else { return } // Oversize tiles can still be displayed online.
        try execute("SAVEPOINT rail_cache_write")
        do {
            if try livePages() + reserve > maximumPages {
                let target = max(4, maximumPages - max(reserve, maximumPages / 20))
                guard try reclaim(until: target, olderThan: entry.fetched) else {
                    // An older import must not displace newer cached tiles.
                    try execute("ROLLBACK TO rail_cache_write; RELEASE rail_cache_write")
                    return
                }
            }
            try insert(key, source: source, entry: entry)
            try execute("RELEASE rail_cache_write")
        } catch {
            try? execute("ROLLBACK TO rail_cache_write; RELEASE rail_cache_write")
            throw error
        }
    }

    private func insert(_ key: RailTileKey, source: String, entry: CachedRailTile) throws {
        let q = try prepare("""
        INSERT INTO tiles(source,layer,z,x,y,fetched,expires,data) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(source,layer,z,x,y) DO UPDATE SET fetched=excluded.fetched,expires=excluded.expires,data=excluded.data
        WHERE excluded.fetched >= tiles.fetched
        """)
        defer { sqlite3_finalize(q) }
        bind(key, source: source, to: q)
        sqlite3_bind_double(q, 6, entry.fetched.timeIntervalSince1970)
        sqlite3_bind_double(q, 7, entry.expires.timeIntervalSince1970)
        if entry.data.isEmpty { sqlite3_bind_zeroblob(q, 8, 0) }
        else {
            _ = entry.data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(q, 8, bytes.baseAddress, Int32(bytes.count), transient)
            }
        }
        guard sqlite3_step(q) == SQLITE_DONE else { throw error() }
    }

    func stats() throws -> RailCacheStats {
        let q = try prepare("SELECT COUNT(*), COALESCE(SUM(length(data)),0), MIN(z),MAX(z),MIN(fetched) FROM tiles")
        defer { sqlite3_finalize(q) }
        guard sqlite3_step(q) == SQLITE_ROW else { throw error() }
        var result = RailCacheStats()
        result.count = Int(sqlite3_column_int64(q, 0))
        result.bytes = Int(sqlite3_column_int64(q, 1))
        result.allocatedBytes = try scalar("PRAGMA page_count") * pageSize
        result.capacityBytes = maximumPages * pageSize
        result.minimumZoom = Int(sqlite3_column_int(q, 2))
        result.maximumZoom = Int(sqlite3_column_int(q, 3))
        if result.count > 0 { result.oldest = Date(timeIntervalSince1970: sqlite3_column_double(q, 4)) }
        return result
    }

    private func livePages() throws -> Int {
        try scalar("PRAGMA page_count") - scalar("PRAGMA freelist_count")
    }

    /// Deletes small oldest-first batches using the timestamp index. Database
    /// overhead and empty tiles count towards the same page budget as blobs.
    private func reclaim(until target: Int, olderThan: Date?) throws -> Bool {
        var pages = try livePages(), batch = 1
        while pages > target {
            let q = try prepare("""
            DELETE FROM tiles WHERE rowid IN (
                SELECT rowid FROM tiles \(olderThan == nil ? "" : "WHERE fetched <= ?")
                ORDER BY fetched, rowid LIMIT \(batch)
            )
            """)
            if let olderThan { sqlite3_bind_double(q, 1, olderThan.timeIntervalSince1970) }
            let status = sqlite3_step(q)
            sqlite3_finalize(q)
            guard status == SQLITE_DONE else { throw error() }
            let deleted = Int(sqlite3_changes(db))
            if deleted == 0 { return false }
            let remaining = try livePages()
            let pagesPerRow = max(1, (pages - remaining) / deleted)
            batch = min(64, max(1, (remaining - target + pagesPerRow - 1) / pagesPerRow))
            pages = remaining
        }
        return true
    }

    func export(to url: URL) throws {
        let target = try RailwayTileCache(url: url, capacity: capacity)
        guard let backup = sqlite3_backup_init(target.db, "main", db, "main") else { throw error() }
        let status = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw error() }
    }

    func merge(from url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.budget + 128 * 1024 * 1024 else { throw DataError.invalid("缓存文件超过 8 GB 容量限制") }
        let source = try RailwayTileCache(url: url, readOnly: true)
        let stats = try source.stats()
        guard stats.count <= 1_000_000, stats.bytes <= Self.budget else { throw DataError.invalid("缓存数据库过大") }
        let q = try source.prepare("SELECT data,fetched,expires,source,layer,z,x,y FROM tiles ORDER BY fetched, rowid")
        defer { sqlite3_finalize(q) }
        try execute("BEGIN IMMEDIATE")
        do {
            var count = 0
            while true {
                let status = sqlite3_step(q)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw source.error() }
                guard let layer = RailTileLayer(rawValue: source.text(q, 4)) else {
                    throw DataError.invalid("缓存含有不支持的图层")
                }
                let tile = RailTile(z: Int(sqlite3_column_int(q, 5)), x: Int(sqlite3_column_int(q, 6)), y: Int(sqlite3_column_int(q, 7)))
                guard tile.isValid else { throw DataError.invalid("缓存坐标无效") }
                let key = RailTileKey(layer: layer, tile: tile)
                let entry = try source.row(q)
                // Validate every entry before commit; a damaged import preserves the old cache.
                _ = try RailwayTileRepository.decode(entry.data, key: key)
                let namespace = source.text(q, 3)
                guard namespace.count < 2048, URL(string: namespace)?.scheme == "https" else {
                    throw DataError.invalid("缓存数据源无效")
                }
                try save(key, source: namespace, entry: entry)
                count += 1
            }
            try execute("COMMIT")
            return count
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func row(_ q: OpaquePointer) throws -> CachedRailTile {
        let size = Int(sqlite3_column_bytes(q, 0))
        guard size <= VectorTileDecoder.maxBytes else { throw DataError.invalid("缓存瓦片超过大小限制") }
        let data: Data
        if size == 0 { data = Data() }
        else {
            guard let bytes = sqlite3_column_blob(q, 0) else { throw error() }
            data = Data(bytes: bytes, count: size)
        }
        let fetched = sqlite3_column_double(q, 1), expires = sqlite3_column_double(q, 2)
        guard fetched.isFinite, expires.isFinite,
              fetched <= Date().timeIntervalSince1970 + 86400 else { throw DataError.invalid("缓存时间无效") }
        return CachedRailTile(data: data, fetched: Date(timeIntervalSince1970: fetched),
                              expires: Date(timeIntervalSince1970: expires))
    }
    private func bind(_ key: RailTileKey, source: String, to q: OpaquePointer) {
        sqlite3_bind_text(q, 1, source, -1, transient)
        sqlite3_bind_text(q, 2, key.layer.rawValue, -1, transient)
        sqlite3_bind_int(q, 3, Int32(key.tile.z))
        sqlite3_bind_int(q, 4, Int32(key.tile.x))
        sqlite3_bind_int(q, 5, Int32(key.tile.y))
    }
    private func text(_ q: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(q, column).map { String(cString: $0) } ?? ""
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func scalar(_ sql: String) throws -> Int {
        let q = try prepare(sql)
        defer { sqlite3_finalize(q) }
        guard sqlite3_step(q) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(q, 0))
    }
    private func error() -> DataError { .invalid("铁路缓存读写失败：\(String(cString: sqlite3_errmsg(db)))") }
}
