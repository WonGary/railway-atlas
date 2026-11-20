import Foundation

public struct RailTileResult: Sendable {
    public let key: RailTileKey
    public let features: RailTileFeatures
    public let cached: Bool
    public let stale: Bool
    public var provider = "OpenRailwayMap"
    public var fallback = false
    public var snapshot = false
    /// Spatial completeness, independent of expiry. Partial/legacy/snapshot
    /// results remain stale as well, for callers that only inspect freshness.
    public var coverageComplete = true
    /// Only mixed snapshot results carry this additive, non-snapshot subset.
    /// It lets arrived primary data improve without accepting snapshot data
    /// as a replacement for the rest of the cell.
    public var primaryFeatures: RailTileFeatures? = nil
}

public struct RailSourceStatus: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
}

public actor RailwayTileRepository {
    public static let defaultSource = "https://openrailwaymap.app"
    public let databaseURL: URL
    private var cache: RailwayTileCache?
    private let cacheCapacity: Int
    private let session: URLSession
    private var unavailableUntil: [String: Date] = [:]
    private var lastFailure: [String: Date] = [:]
    private var sourceMessages: [String: String] = [:]
    private var openFreeMapTemplate: String?
    private var templateTask: Task<String, Error>?
    private struct DecodedTile {
        let fetched: Date
        let features: RailTileFeatures
        let cost: Int
        var used: Date
    }
    private var decoded: [String: DecodedTile] = [:]
    private var decodedCost = 0
    private static let backups: [(String, String, RailTileLayer)] = [
        ("VersaTiles", "https://tiles.versatiles.org", .shortbread),
        ("OpenFreeMap", "https://tiles.openfreemap.org", .openMapTiles)
    ]

    public init(directory: URL, session: URLSession? = nil, cacheCapacity: Int = RailCacheStats.capacity) {
        databaseURL = directory.appendingPathComponent("railways.railcache")
        self.cacheCapacity = cacheCapacity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        // A large overview tile may keep making progress for more than 30 s.
        // This is a per-request safety bound, never a viewport-wide deadline.
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = session ?? URLSession(configuration: configuration)
    }

    public static func normalizeSource(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw DataError.invalid("瓦片服务地址必须为 HTTPS，不含查询参数或登录信息")
        }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private func database() throws -> RailwayTileCache {
        if let cache { return cache }
        let new = try RailwayTileCache(url: databaseURL, capacity: cacheCapacity)
        cache = new
        return new
    }

    private var statsMemo: (value: RailCacheStats, at: Date)?
    /// The statistics query scans the whole tile table; viewport refreshes call
    /// this twice, so reuse a recent result instead of rescanning every time.
    public func stats() throws -> RailCacheStats {
        if let memo = statsMemo, Date().timeIntervalSince(memo.at) < 20 { return memo.value }
        let value = try database().stats()
        statsMemo = (value, .now)
        return value
    }

    /// Routing requires named main-line geometry. Generalized basemap tiles
    /// are useful for display but must not win the normal viewport fetch race.
    public func routingTile(_ key: RailTileKey) async throws -> RailTileResult {
        guard key.tile.isValid, key.layer == .tracks || key.layer == .stations else {
            throw DataError.invalid("径路只接受轨道与车站瓦片")
        }
        let source = Self.defaultSource, db = try database()
        let previous = try db.read(key, source: source)
        if let previous, previous.expires > .now {
            return RailTileResult(key: key, features: try decodedCache(previous, key: key, source: source), cached: true, stale: false)
        }
        do { return try await fetchAndSave(URL(string: "\(source)/\(key.path)")!, key: key, source: source) }
        catch {
            try Task.checkCancellation()
            if let previous {
                return RailTileResult(key: key, features: try decodedCache(previous, key: key, source: source), cached: true, stale: true)
            }
            throw error
        }
    }

    private func decodedCache(_ entry: CachedRailTile, key: RailTileKey, source: String) throws -> RailTileFeatures {
        let identity = source + "|" + key.path
        if var cached = decoded[identity], cached.fetched == entry.fetched {
            cached.used = .now; decoded[identity] = cached
            return cached.features
        }
        let features = try Self.decode(entry.data, key: key)
        let cost = features.lines.reduce(0) { $0 + $1.coordinates.count * 16 + 512 } + features.stations.count * 768
            + features.memberships.reduce(0) { $0 + 96 + $1.value.count * 128 }
        if let old = decoded.removeValue(forKey: identity) { decodedCost -= old.cost }
        decoded[identity] = DecodedTile(fetched: entry.fetched, features: features, cost: cost, used: .now)
        decodedCost += cost
        // Approximate decoded geometry budget; database capacity is independent.
        while decodedCost > 160 * 1024 * 1024 || decoded.count > 512 {
            guard let oldest = decoded.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = decoded.removeValue(forKey: oldest) else { break }
            decodedCost -= removed.cost
        }
        return features
    }

    public func cached(_ keys: [RailTileKey], source: String) throws -> [RailTileResult] {
        let db = try database()
        return try keys.compactMap { key in
            try Task.checkCancellation()
            if key.layer == .metroNetwork { return try cachedMetroNetwork(key, source: source) }
            if let entry = try? db.read(key, source: source),
               let features = try? decodedCache(entry, key: key, source: source) {
                return RailTileResult(key: key, features: features, cached: true, stale: entry.expires < .now)
            }
            guard Self.supportsBackup(key) else { return nil }
            for (name, url, layer) in Self.backups {
                let cacheKey = Self.backupKey(key, layer: layer)
                if let entry = try? db.read(cacheKey, source: url),
                   let features = try? decodedCache(entry, key: cacheKey, source: url) {
                    return RailTileResult(key: key, features: Self.subset(features, for: key), cached: true,
                                          stale: entry.expires < .now, provider: name, fallback: true)
                }
            }
            return nil
        }
    }

    /// Reuse coverage across Z8/Z9/Z10 without turning a partial city cache or
    /// bundled snapshot into proof that the whole regional cell is complete.
    private func cachedMetroNetwork(_ key: RailTileKey, source: String,
                                    ancestors: Bool = true) throws -> RailTileResult? {
        try Task.checkCancellation()
        guard key.tile.isValid else { return nil }
        let db = try database()
        var exact: RailTileResult?
        if let entry = try? db.read(key, source: source),
           let features = try? decodedCache(entry, key: key, source: source) {
            let result = RailTileResult(key: key, features: features, cached: true, stale: entry.expires < .now)
            if !result.stale { return result }
            exact = result
        }
        var ancestor: RailTileResult?
        if ancestors, ((MetroViewport.minimumZoom + 1)...MetroViewport.detailZoom).contains(key.tile.z) {
            for z in stride(from: key.tile.z - 1, through: MetroViewport.minimumZoom, by: -1) {
                let shift = key.tile.z - z
                let parent = RailTileKey(layer: .metroNetwork,
                    tile: RailTile(z: z, x: key.tile.x >> shift, y: key.tile.y >> shift))
                if let entry = try? db.read(parent, source: source),
                   let features = try? decodedCache(entry, key: parent, source: source) {
                    let result = RailTileResult(key: key, features: Self.metroSubset(features, for: key),
                                                cached: true, stale: entry.expires < .now,
                                                provider: "OSM 区域线路缓存")
                    if !result.stale { return result }
                    if ancestor == nil { ancestor = result }
                }
            }
        }
        var regional: RailTileResult?
        let children = MetroViewport.children(of: key.tile)
        if !children.isEmpty {
            let parts = try children.compactMap {
                try cachedMetroNetwork(RailTileKey(layer: .metroNetwork, tile: $0),
                                       source: source, ancestors: false)
            }
            func append(_ part: RailTileFeatures, to features: inout RailTileFeatures) {
                features.lines += part.lines
                features.stations += part.stations
                for (id, routes) in part.memberships {
                    // Adjacent cells often carry the same full relation
                    // membership. Do not multiply it at every regional level.
                    var seen = Set(features.memberships[id, default: []].map(\.id))
                    features.memberships[id, default: []].append(contentsOf: routes.filter {
                        seen.insert($0.id).inserted
                    })
                }
            }
            if !parts.isEmpty {
                var features = RailTileFeatures(), primary = RailTileFeatures()
                let snapshot = parts.contains(where: \.snapshot)
                for part in parts {
                    append(part.features, to: &features)
                    if snapshot {
                        if !part.snapshot { append(part.features, to: &primary) }
                        else if let real = part.primaryFeatures { append(real, to: &primary) }
                    }
                }
                let complete = parts.count == children.count && parts.allSatisfy(\.coverageComplete)
                let result = RailTileResult(key: key, features: features, cached: true,
                    stale: !complete || parts.contains(where: \.stale),
                    provider: snapshot ? "OSM 区域缓存与内置线路快照" : "OSM 区域线路缓存",
                    snapshot: snapshot, coverageComplete: complete, primaryFeatures: snapshot ? primary : nil)
                if complete && !result.stale { return result }
                regional = result
            }
        }
        // Expired exact/legacy entries must not hide complete fresh parent or
        // child coverage. They remain useful fallbacks when no such coverage exists.
        if let exact { return exact }
        let legacy = RailTileKey(layer: .metroColors, tile: key.tile)
        if let entry = try? db.read(legacy, source: source),
           let features = try? decodedCache(entry, key: legacy, source: source) {
            return RailTileResult(key: key, features: features, cached: true, stale: true,
                                  provider: "已缓存的线路关系", coverageComplete: false)
        }
        return ancestor ?? regional ?? Self.metroSnapshot(key, source: source)
    }

    private static func metroSubset(_ features: RailTileFeatures, for key: RailTileKey) -> RailTileFeatures {
        var result = RailTileFeatures()
        result.memberships = features.memberships
        let bounds = key.tile.bounds
        for line in features.lines {
            for (part, coordinates) in RailGeometryClip.segments(line.coordinates, inside: bounds).enumerated() {
                var clipped = line
                clipped.id = "metro-cache/\(key.tile.path)/\(line.id)/\(part)"
                clipped.coordinates = coordinates
                result.lines.append(clipped)
            }
        }
        result.stations = features.stations.filter { bounds.contains($0.coordinate) }
        return result
    }

    public func load(_ key: RailTileKey, source: String = defaultSource, refresh: Bool = false) async throws -> RailTileResult {
        try Task.checkCancellation()
        let source = try Self.normalizeSource(source)
        guard key.tile.isValid else { throw DataError.invalid("瓦片坐标无效") }
        let db = try database()
        let previous = try db.read(key, source: source)
        if !refresh, let previous, previous.expires > .now,
           let features = try? decodedCache(previous, key: key, source: source) {
            return RailTileResult(key: key, features: features, cached: true, stale: false)
        }
        if key.layer.isMetro {
            if !refresh, key.layer == .metroNetwork,
               let coverage = try cachedMetroNetwork(key, source: source),
               coverage.coverageComplete && !coverage.stale {
                return coverage
            }
            return try await loadMetro(key, source: source, previous: previous, refresh: refresh)
        }
        if Self.supportsBackup(key) {
            return try await loadFast(key, source: source, previous: previous, refresh: refresh)
        }
        var errors: [String] = []
        if refresh || unavailableUntil[source, default: .distantPast] < .now {
            let started = Date()
            do {
                let result = try await fetchAndSave(URL(string: "\(source)/\(key.path)")!, key: key, source: source)
                markAvailable(source, since: started, message: "可用 · 铁路属性")
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                markFailed(source, error: error)
                errors.append("OpenRailwayMap：\(error.localizedDescription)")
            }
        }
        if let previous, let features = try? Self.decode(previous.data, key: key) {
            return RailTileResult(key: key, features: features, cached: true, stale: true)
        }
        guard Self.supportsBackup(key) else {
            throw DataError.invalid(key.layer.isStations
                ? "车站主源暂不可用。备用源的车站需放大后显示；已有缓存仍可浏览。"
                : "全国铁路概览主源暂不可用。已保留缓存；可放大到城市使用备用源，或重试当前视野。")
        }
        // Independent tile hosts with different schemas, not aliases of the same server.
        for (name, url, layer) in Self.backups {
            do {
                let backup = try await loadBackup(key, name: name, source: url, layer: layer, refresh: refresh)
                return backup
            } catch {
                if Task.isCancelled { throw CancellationError() }
                errors.append("\(name)：\(error.localizedDescription)")
            }
        }
        throw DataError.invalid(errors.isEmpty ? "数据源暂不可用，已保留缓存" : errors.joined(separator: "；"))
    }

    public func cachedParents(_ keys: [RailTileKey], source: String) throws -> [RailTileResult] {
        var candidates = Set<RailTileKey>()
        for key in keys where !key.layer.isMetro {
            let minimum = key.layer.isStations ? 10 : 3
            guard key.tile.z > minimum else { continue }
            for z in stride(from: key.tile.z - 1, through: minimum, by: -1) {
                let shift = key.tile.z - z
                let tile = RailTile(z: z, x: key.tile.x >> shift, y: key.tile.y >> shift)
                let parent = RailTileKey(layer: key.layer.isStations ? .stations : z < 7 ? .overview : .tracks, tile: tile)
                if let _ = try database().read(parent, source: source) {
                    candidates.insert(parent)
                    break
                }
            }
        }
        return try cached(Array(candidates), source: source)
    }

    public static func decode(_ data: Data, key: RailTileKey) throws -> RailTileFeatures {
        if key.layer == .paletteColors {
            _ = try MetroPalette.decodeCache(data)
            return RailTileFeatures()
        }
        if key.layer == .wikiColors {
            _ = try WikiMetroColours.decodeCache(data)
            return RailTileFeatures()
        }
        return key.layer.isMetro ? try MetroRouteDecoder.decode(data, tile: key.layer == .metroStations ? nil : key.tile)
            : try VectorTileDecoder.decode(data, key: key)
    }

    public func paletteColours(for routes: [RailRoute], online: Bool) async throws -> [String: MetroPaletteRecord] {
        let key = RailTileKey(layer: .paletteColors, tile: RailTile(z: 0, x: 0, y: 0))
        let source = MetroPalette.hosts[0]
        let cached = try database().read(key, source: source).map { try MetroPalette.decodeCache($0.data) } ?? [:]
        guard online else { return cached }
        let records = await MetroPalette.fetch(routes: routes, cached: cached, session: session)
        try Task.checkCancellation()
        if !records.isEmpty {
            try database().save(key, source: source, entry: CachedRailTile(data: try JSONEncoder().encode(records),
                                                                         fetched: .now, expires: Date().addingTimeInterval(604800)))
        }
        return records
    }

    /// A slow primary must not hold every viewport tile hostage. Start the
    /// independent backups after a short head start and cancel losing transfers.
    private func loadFast(_ key: RailTileKey, source: String, previous: CachedRailTile?, refresh: Bool) async throws -> RailTileResult {
        let primaryEnabled = refresh || unavailableUntil[source, default: .distantPast] < .now
        return try await withThrowingTaskGroup(of: RailTileResult?.self) { group in
            if primaryEnabled {
                group.addTask {
                    let started = Date()
                    do {
                        let result = try await self.fetchAndSave(URL(string: "\(source)/\(key.path)")!, key: key, source: source)
                        await self.markAvailable(source, since: started, message: "可用 · 铁路属性")
                        return result
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        await self.markFailed(source, error: error)
                        return nil
                    }
                }
            }
            for (index, backup) in Self.backups.enumerated() {
                group.addTask {
                    do {
                        try await Task.sleep(for: .milliseconds((primaryEnabled ? 900 : 0) + index * 600))
                        let result = try await self.loadBackup(key, name: backup.0, source: backup.1, layer: backup.2, refresh: refresh)
                        // A generalized empty basemap is not evidence of no railways.
                        guard !result.features.lines.isEmpty || !result.features.stations.isEmpty else { return nil }
                        return result
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return nil
                    }
                }
            }
            while let result = try await group.next() {
                if let result {
                    if result.fallback, let previous,
                       let features = try? decodedCache(previous, key: key, source: source),
                       !RailTileContinuity.shouldReplace(existing: features, existingFallback: false,
                                                         incomingFallback: true) {
                        // The cached primary is already displayable. Let its
                        // refresh finish instead of letting an incomplete,
                        // fresh backup win the race and erase urban geometry.
                        continue
                    }
                    if result.fallback && primaryEnabled {
                        unavailableUntil[source] = max(unavailableUntil[source] ?? .distantPast, Date().addingTimeInterval(30))
                        sourceMessages[source] = "响应较慢 · 暂时优先备用源"
                    }
                    group.cancelAll()
                    return result
                }
            }
            if let previous, let features = try? Self.decode(previous.data, key: key) {
                return RailTileResult(key: key, features: features, cached: true, stale: true)
            }
            throw DataError.invalid("当前区域数据源暂不可用，已保留缓存；可重试当前视野")
        }
    }

    public func wikiColours(for routes: [RailRoute], online: Bool) async throws -> WikiMetroColourUpdate {
        let key = RailTileKey(layer: .wikiColors, tile: RailTile(z: 0, x: 0, y: 0))
        let source = "https://www.wikidata.org"
        let cached = try database().read(key, source: source).map { try WikiMetroColours.decodeCache($0.data) } ?? [:]
        guard online else { return WikiMetroColourUpdate(records: cached, message: "百科线路色 · 本地缓存") }
        if unavailableUntil["wiki", default: .distantPast] > .now {
            return WikiMetroColourUpdate(records: cached, message: "百科服务暂不可用 · 保留已有线路色")
        }
        let update = await WikiMetroColours.fetch(routes: routes, cached: cached, session: session)
        try Task.checkCancellation()
        if update.message.contains("暂不可用") { unavailableUntil["wiki"] = Date().addingTimeInterval(90) }
        var merged = try database().read(key, source: source).map { try WikiMetroColours.decodeCache($0.data) } ?? [:]
        for (id, record) in update.records where record.fetched >= (merged[id]?.fetched ?? .distantPast) { merged[id] = record }
        if merged.count > 5000 {
            merged = Dictionary(uniqueKeysWithValues: merged.sorted { $0.value.fetched > $1.value.fetched }.prefix(5000).map { ($0.key, $0.value) })
        }
        if !merged.isEmpty {
            try database().save(key, source: source, entry: CachedRailTile(
                data: try JSONEncoder().encode(merged), fetched: .now, expires: Date().addingTimeInterval(604800)))
        }
        return WikiMetroColourUpdate(records: merged, message: update.message)
    }

    private static func maxAge(_ control: String?) -> TimeInterval {
        for part in (control ?? "").split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("max-age="), let value = Double(p.dropFirst(8)) { return min(604800, max(0, value)) }
        }
        return 86400
    }

    private func fetchAndSave(_ url: URL, key: RailTileKey, source: String, healthSource: String? = nil) async throws -> RailTileResult {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = key.layer.isMetro ? 18 : key.layer == .overview ? 30 : 8
        request.setValue("RailwayAtlas/0.1.3 (native OSM railway viewer)", forHTTPHeaderField: "User-Agent")
        request.setValue("railwayatlas://map", forHTTPHeaderField: "Referer")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, [200, 204].contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let delay = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 120
                unavailableUntil[healthSource ?? source] = Date().addingTimeInterval(max(60, delay))
            }
            throw DataError.invalid("HTTP \(status)")
        }
        guard response.expectedContentLength <= VectorTileDecoder.maxBytes else { throw DataError.invalid("瓦片数据过大") }
        guard data.count <= VectorTileDecoder.maxBytes else { throw DataError.invalid("瓦片数据过大") }
        try Task.checkCancellation()
        let features = try Self.decode(data, key: key)
        if !(http.value(forHTTPHeaderField: "Cache-Control") ?? "").contains("no-store") {
            let entry = CachedRailTile(data: data, fetched: .now,
                                      expires: Date().addingTimeInterval(Self.maxAge(http.value(forHTTPHeaderField: "Cache-Control"))))
            try database().save(key, source: source, entry: entry)
        }
        return RailTileResult(key: key, features: features, cached: false, stale: false)
    }

    private func loadMetro(_ key: RailTileKey, source: String, previous: CachedRailTile?, refresh: Bool) async throws -> RailTileResult {
        let geometry = key.layer == .metroStations ? "" : """
        way(r.routes)(\(key.tile.bounds.overpassValue));
        out geom(\(key.tile.bounds.overpassValue));
        """
        let stationDetails = key.layer != .metroStations ? "" : """
        rel(bn.stops)["public_transport"="stop_area"]->.areas;
        .areas out body;
        rel(br.areas)["public_transport"="stop_area_group"]->.areaGroups;
        .areaGroups out body;
        (nwr(r.areas)["railway"~"^(station|halt|tram_stop)$"];
         nwr["railway"~"^(station|halt|tram_stop)$"](\(key.tile.bounds.overpassValue)););
        out center;
        """
        let query = """
        [out:json][timeout:20];
        (
        \(RailUrbanService.routeQuery(bounds: key.tile.bounds))
        )->.routes;
        (.routes; rel(br.routes)["type"="route_master"];);
        out body;
        \(geometry)
        node(r.routes)(\(key.tile.bounds.overpassValue))->.stops;
        .stops out body;
        \(stationDetails)
        """
        // The scheduler permits one metro job; two staggered Overpass queries
        // avoid a full timeout chain while keeping the public-service limit.
        if key.layer == .metroNetwork || key.layer == .metroStations {
            let endpoints = [DataEndpoint.vk, .community, .primary].filter {
                refresh || unavailableUntil[$0.rawValue, default: .distantPast] < .now
            }
            let result: RailTileResult? = await withTaskGroup(of: RailTileResult?.self) { group in
                for (index, endpoint) in endpoints.prefix(2).enumerated() {
                    group.addTask {
                        do {
                            if index > 0 { try await Task.sleep(for: .seconds(2)) }
                            return try await self.fetchMetro(query, endpoint: endpoint, key: key, source: source)
                        } catch { return nil }
                    }
                }
                while let result = await group.next() {
                    if let result { group.cancelAll(); return result }
                }
                return nil
            }
            try Task.checkCancellation()
            if let result { return result }
            // Third provider is used only after the two active requests finish.
            if let last = endpoints.dropFirst(2).first,
               let result = try? await fetchMetro(query, endpoint: last, key: key, source: source) { return result }
            try Task.checkCancellation()
            if key.layer == .metroNetwork, let coverage = try cachedMetroNetwork(key, source: source) {
                return coverage
            }
            if let previous, let features = try? Self.decode(previous.data, key: key) {
                return RailTileResult(key: key, features: features, cached: true, stale: true, provider: "OSM 整线缓存")
            }
            throw DataError.invalid("地铁整线关系暂不可用，已保留缓存；可重试补齐")
        }
        var errors: [String] = []
        for endpoint in [DataEndpoint.vk, .community, .primary] {
            try Task.checkCancellation()
            if !refresh, unavailableUntil[endpoint.rawValue, default: .distantPast] > .now { continue }
            var components = URLComponents(string: endpoint.rawValue)!
            components.queryItems = [URLQueryItem(name: "data", value: query)]
            let started = Date()
            do {
                // All route providers return the same OSM schema; cache the
                // data independently of which mirror answered.
                var result = try await fetchAndSave(components.url!, key: key, source: source, healthSource: endpoint.rawValue)
                result.provider = endpoint.title
                markAvailable(endpoint.rawValue, since: started, message: "可用 · 线路颜色")
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                markFailed(endpoint.rawValue, error: error)
                errors.append(endpoint.title)
            }
        }
        if let previous, let features = try? Self.decode(previous.data, key: key) {
            return RailTileResult(key: key, features: features, cached: true, stale: true, provider: "OSM 线路色缓存")
        }
        throw DataError.invalid("线路色服务暂不可用：\(errors.joined(separator: " / "))")
    }

    private static func metroSnapshot(_ key: RailTileKey, source: String) -> RailTileResult? {
        guard source == defaultSource, let features = BundledMetroSnapshots.features(for: key) else { return nil }
        return RailTileResult(key: key, features: features, cached: true, stale: true,
                              provider: "OSM 内置线路快照 · 2026-11-05", snapshot: true, coverageComplete: false)
    }

    private func fetchMetro(_ query: String, endpoint: DataEndpoint, key: RailTileKey, source: String) async throws -> RailTileResult {
        var components = URLComponents(string: endpoint.rawValue)!
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        let started = Date()
        do {
            var result = try await fetchAndSave(components.url!, key: key, source: source, healthSource: endpoint.rawValue)
            result.provider = endpoint.title
            markAvailable(endpoint.rawValue, since: started, message: "可用 · 整线配色与车站")
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            markFailed(endpoint.rawValue, error: error)
            throw error
        }
    }

    private static func backupKey(_ key: RailTileKey, layer: RailTileLayer) -> RailTileKey {
        let z = min(14, key.tile.z), shift = key.tile.z - z
        return RailTileKey(layer: layer, tile: RailTile(z: z, x: key.tile.x >> shift, y: key.tile.y >> shift))
    }

    private static func supportsBackup(_ key: RailTileKey) -> Bool {
        // General basemap schemas deliberately omit railways/stations at small
        // scales. An HTTP 200 there must not masquerade as railway coverage.
        !key.layer.isMetro && key.tile.z >= (key.layer.isStations ? 12 : 8)
    }

    private static func subset(_ features: RailTileFeatures, for key: RailTileKey) -> RailTileFeatures {
        var result = features
        if key.layer.isStations { result.lines = [] } else { result.stations = [] }
        return result
    }

    private func loadBackup(_ key: RailTileKey, name: String, source: String, layer: RailTileLayer, refresh: Bool) async throws -> RailTileResult {
        let cacheKey = Self.backupKey(key, layer: layer)
        let previous = try database().read(cacheKey, source: source)
        if !refresh, let entry = previous, entry.expires > .now,
           let features = try? Self.decode(entry.data, key: cacheKey) {
            return RailTileResult(key: key, features: Self.subset(features, for: key), cached: true,
                                  stale: false, provider: name, fallback: true)
        }
        let started = Date()
        do {
            if !refresh, unavailableUntil[source, default: .distantPast] > .now { throw DataError.invalid("暂时退避") }
            try Task.checkCancellation()
            let url: URL
            if layer == .openMapTiles {
                let template = try await openFreeMapURL()
                let tile = cacheKey.tile
                url = URL(string: template.replacingOccurrences(of: "{z}", with: "\(tile.z)")
                    .replacingOccurrences(of: "{x}", with: "\(tile.x)").replacingOccurrences(of: "{y}", with: "\(tile.y)"))!
            } else { url = URL(string: "\(source)/tiles/osm/\(cacheKey.tile.path)")! }
            // Stay in the viewport's structured task, so panning away cancels
            // the transfer instead of leaving detached fallback downloads.
            let result = try await fetchAndSave(url, key: cacheKey, source: source)
            markAvailable(source, since: started, message: "可用 · 基础轨道（无速度属性）")
            return RailTileResult(key: key, features: Self.subset(result.features, for: key),
                                  cached: result.cached, stale: result.stale, provider: name, fallback: true)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            markFailed(source, error: error)
            if let previous, let features = try? Self.decode(previous.data, key: cacheKey) {
                return RailTileResult(key: key, features: Self.subset(features, for: key),
                                      cached: true, stale: true, provider: name, fallback: true)
            }
            throw error
        }
    }

    private func openFreeMapURL() async throws -> String {
        if let openFreeMapTemplate { return openFreeMapTemplate }
        if let templateTask { return try await templateTask.value }
        let session = session
        let task = Task<String, Error> {
            var request = URLRequest(url: URL(string: "https://tiles.openfreemap.org/planet")!)
            request.timeoutInterval = 10
            request.setValue("RailwayAtlas/0.1.3", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let templates = object["tiles"] as? [String], let first = templates.first,
                  first.hasPrefix("https://tiles.openfreemap.org/") else { throw DataError.invalid("备用源 TileJSON 无效") }
            return first
        }
        templateTask = task
        defer { templateTask = nil }
        let template = try await task.value
        openFreeMapTemplate = template
        return template
    }

    private func markFailed(_ source: String, error: Error) {
        lastFailure[source] = .now
        unavailableUntil[source] = max(unavailableUntil[source] ?? .distantPast, Date().addingTimeInterval(90))
        sourceMessages[source] = "暂不可用 · \(error.localizedDescription)"
    }

    private func markAvailable(_ source: String, since started: Date, message: String) {
        guard lastFailure[source, default: .distantPast] < started else { return }
        sourceMessages[source] = message
        unavailableUntil[source] = nil
    }

    public func retrySources() { unavailableUntil = [:] }

    public func sourceStatus() -> [RailSourceStatus] {
        let sources = [("OpenRailwayMap", Self.defaultSource)] + Self.backups.map { ($0.0, $0.1) }
            + [DataEndpoint.vk, .community, .primary].map { ($0.title, $0.rawValue) }
        return sources.map { RailSourceStatus(id: $0.1, name: $0.0, status: sourceMessages[$0.1] ?? "备用就绪 · 尚未请求") }
    }

    public func exportCache(to url: URL) throws { try database().export(to: url) }
    public func importCache(from url: URL) throws -> Int { statsMemo = nil; return try database().merge(from: url) }
}
