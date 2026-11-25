import Foundation
import MapKit
import RailwayCore

private struct TileAttempt: Sendable {
    let key: RailTileKey
    let result: RailTileResult?
    let error: String?
}

extension RailwayMapStore {
    @discardableResult
    private func acceptTile(_ result: RailTileResult) -> Bool {
        // A cell evicted from memory must not regain historical completeness
        // merely because a later partial result reintroduces the same key.
        completeMetroKeys.formIntersection(tileFeatures.keys)
        guard let features = RailTileContinuity.accepting(result, existing: tileFeatures[result.key],
            existingFallback: fallbackKeys.contains(result.key)) else { return false }
        tileFeatures[result.key] = features
        // Expiry does not undo spatial completeness. Partial additions must
        // never revoke evidence already learned for this source and cell.
        if result.key.layer == .metroNetwork && result.coverageComplete && !result.snapshot && !result.fallback {
            completeMetroKeys.insert(result.key)
        }
        tileOrigins[result.key] = result.provider
        if result.fallback { fallbackKeys.insert(result.key) }
        else { fallbackKeys.remove(result.key) }
        return true
    }

    func viewportChanged(_ value: MKCoordinateRegion, width: Double? = nil, height: Double? = nil) {
        region = value
        if let width { viewportWidth = max(320, width) }
        if let height { viewportHeight = max(100, height) }
        rebuildVisible()
        refreshViewport()
    }

    func refreshViewport(force: Bool = false) {
        scheduleStationLayouts()
        loadViewportDirections()
        guard mapMode != .offline else { return }
        let plan = RailTilePlan(bounds: MapBounds(region: region), width: viewportWidth)
        guard force || lastTileKeys != plan.keys else { return }
        lastTileKeys = plan.keys
        viewportWork?.cancel()
        refreshMetro(keys: plan.keys.filter { $0.layer.isMetro }, force: force)
        wikiWork?.cancel()
        paletteWork?.cancel()
        paletteWork = nil
        paletteAttempted = []
        wikiWork = nil
        wikiAttempted = []
        wikiColourLoading = false
        let generation = UUID()
        viewportGeneration = generation
        let repository = tileRepository, source = tileSource
        let online = mapMode == .apple
        tileZoom = plan.zoom
        onlineLoading = true
        onlineStatus = online ? "读取缓存并更新视野…" : "读取视野内缓存…"
        onlineError = nil
        failedTiles = 0
        fallbackTiles = 0
        tilesExpected = plan.keys.filter { !$0.layer.isMetro }.count
        tilesReady = 0
        viewportWork = Task { [weak self] in
            do {
                if !force { try await Task.sleep(for: .milliseconds(220)) }
                let cached = try await repository.cached(plan.keys, source: source)
                guard !Task.isCancelled, let self, self.viewportGeneration == generation else { return }
                var received = Set(cached.map(\.key))
                var replacements = Set(cached.filter {
                    !$0.fallback && (!$0.key.layer.isMetro || (!$0.stale && !$0.snapshot))
                }.map(\.key))
                let bounds = MapBounds(region: self.region)
                let retained = RailTileContinuity.retainedKeys(existing: Set(self.tileFeatures.keys),
                    requested: plan.keys, ready: replacements, bounds: bounds)
                self.tileFeatures = self.tileFeatures.filter { retained.contains($0.key) }
                self.tileOrigins = self.tileOrigins.filter { retained.contains($0.key) }
                self.fallbackKeys.formIntersection(retained)
                for result in cached {
                    self.acceptTile(result)
                }
                let missingTracks = plan.keys.filter {
                    !$0.layer.isMetro && !replacements.contains($0)
                }
                if !missingTracks.isEmpty {
                    let parents = try await repository.cachedParents(missingTracks, source: source)
                    guard !Task.isCancelled, self.viewportGeneration == generation else { return }
                    for parent in parents where self.tileFeatures[parent.key] == nil {
                        self.tileFeatures[parent.key] = parent.features
                        self.tileOrigins[parent.key] = parent.provider
                    }
                }
                self.tilesReady = received.filter { !$0.layer.isMetro }.count
                self.publishTiles()
                self.cacheStats = try await repository.stats()
                guard online else {
                    self.onlineLoading = false
                    self.onlineStatus = "缓存覆盖 \(self.tilesReady)/\(self.tilesExpected) · Z\(plan.zoom)"
                    if self.tilesReady < self.tilesExpected {
                        self.onlineError = "当前缩放还有未缓存区域。可缩小查看概览，或切回“全国在线”补齐；空白不表示没有铁路。"
                    }
                    return
                }
                self.onlineStatus = "加载视野内铁路 \(self.tilesReady)/\(self.tilesExpected)"
                let fresh = Set(cached.filter { !$0.stale && !$0.fallback }.map(\.key))
                let pending = plan.keys.filter { !$0.layer.isMetro && (force || !fresh.contains($0)) }
                var remaining = pending
                var running = 0
                var lastPublished = Date.distantPast
                var staleCount = 0
                await withTaskGroup(of: TileAttempt.self) { group in
                    func fillSlots() {
                        while running < 6, !remaining.isEmpty {
                            let key = remaining.removeFirst()
                            running += 1
                            group.addTask {
                                do {
                                    return TileAttempt(key: key, result: try await repository.load(key, source: source, refresh: force), error: nil)
                                } catch {
                                    return TileAttempt(key: key, result: nil, error: error.localizedDescription)
                                }
                            }
                        }
                    }
                    fillSlots()
                    while let attempt = await group.next() {
                        guard !Task.isCancelled, self.viewportGeneration == generation else { group.cancelAll(); break }
                        running -= 1
                        if let result = attempt.result {
                            received.insert(result.key)
                            if !result.fallback { replacements.insert(result.key) }
                            let retained = RailTileContinuity.retainedKeys(existing: Set(self.tileFeatures.keys),
                                requested: plan.keys, ready: replacements, bounds: MapBounds(region: self.region))
                            self.tileFeatures = self.tileFeatures.filter { retained.contains($0.key) }
                            self.tileOrigins = self.tileOrigins.filter { retained.contains($0.key) }
                            self.fallbackKeys.formIntersection(retained)
                            self.acceptTile(result)
                            if result.stale { staleCount += 1 }
                        } else {
                            self.failedTiles += 1
                            self.onlineError = attempt.error
                        }
                        self.tilesReady = received.filter { !$0.layer.isMetro }.count
                        self.onlineStatus = self.tilesReady == self.tilesExpected ? "轨道已就绪" : "加载视野内铁路 \(self.tilesReady)/\(self.tilesExpected)"
                        if Date().timeIntervalSince(lastPublished) > 0.8 {
                            self.publishTiles()
                            self.sourceStates = await repository.sourceStatus()
                            lastPublished = .now
                        }
                        fillSlots()
                    }
                }
                guard !Task.isCancelled, self.viewportGeneration == generation else { return }
                self.publishTiles()
                self.onlineLoading = false
                self.cacheStats = try await repository.stats()
                self.sourceStates = await repository.sourceStatus()
                if self.failedTiles > 0 {
                    self.onlineStatus = "已加载 \(self.tilesReady)/\(self.tilesExpected) · \(self.failedTiles) 块待重试"
                } else if staleCount > 0 {
                    self.onlineStatus = "使用已有缓存 · 部分更新暂不可用"
                } else {
                    self.onlineStatus = self.fallbackTiles > 0 ? "视野已缓存 · \(self.fallbackTiles) 块使用备用源" : "视野已缓存 · Z\(plan.zoom)"
                }
            } catch {
                guard !Task.isCancelled, let self, self.viewportGeneration == generation else { return }
                self.onlineLoading = false
                self.onlineError = error.localizedDescription
                self.onlineStatus = "当前视野加载未完成"
            }
        }
    }

    /// The active attempt has no retry deadline until its result arrives.
    /// Derive it from the existing scheduler state, without adding map-store
    /// properties that would require a separate integration hook.
    private var activeMetroKey: RailTileKey? {
        metroKeys.first {
            metroAttempts[$0, default: 0] > 0
                && !metroCompleted.contains($0) && metroRetryAfter[$0] == nil
        }
    }

    /// Keep one relation job across track-tile changes. Newly exposed spatial
    /// cells join the queue; a request that left the buffered view is cancelled.
    func refreshMetro(keys: [RailTileKey], force: Bool) {
        let wanted = Set(keys)
        let sourceChanged = metroTaskSource != tileSource
        let reset = force || sourceChanged || mapMode != .apple
        let obsolete = activeMetroKey.map { !wanted.contains($0) } ?? false
        var draining: Task<Void, Never>?
        if reset || obsolete || keys.isEmpty {
            draining = metroWork
            draining?.cancel()
            metroWork = nil
            metroGeneration = UUID()
        }
        if reset {
            metroCompleted = []
            metroAttempts = [:]
            metroRetryAfter = [:]
            metroNeedsRetry = false
        }
        metroKeys = keys
        metroCompleted.formIntersection(wanted)
        metroAttempts = metroAttempts.filter { wanted.contains($0.key) }
        metroRetryAfter = metroRetryAfter.filter { wanted.contains($0.key) }
        metroTaskSource = tileSource
        guard mapMode == .apple, !keys.isEmpty else { metroLoading = false; return }
        guard metroWork == nil else { return }
        guard keys.contains(where: { !metroCompleted.contains($0) }) else { metroLoading = false; return }
        let id = metroGeneration, repository = tileRepository, source = tileSource
        let previousWork = draining
        metroLoading = true
        metroStatus = "补充线路归属 · 已知线路先用本地配色"
        metroWork = Task { [weak self] in
            // Do not overlap a cancelled job's two Overpass transfers with
            // the replacement job while URLSession is draining cancellation.
            await previousWork?.value
            try? await Task.sleep(for: .milliseconds(220))
            var failures = Set<RailTileKey>(), snapshots = Set<RailTileKey>(), replacements = Set<RailTileKey>()
            while let self, !Task.isCancelled, self.metroGeneration == id {
                let current = Set(self.metroKeys)
                failures.formIntersection(current)
                snapshots.formIntersection(current)
                replacements.formIntersection(current)
                let pending = self.metroKeys.filter { !self.metroCompleted.contains($0) }
                guard !pending.isEmpty else { break }
                guard let key = pending.first(where: { self.metroRetryAfter[$0, default: .distantPast] <= .now }) else {
                    self.metroLoading = false
                    self.metroStatus = "部分线路归属待补齐 · 稍后自动重试"
                    // A short cancellable wait also lets newly exposed cells
                    // join immediately when the camera moves within this city.
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                self.metroLoading = true
                self.metroRetryAfter.removeValue(forKey: key)
                self.metroAttempts[key, default: 0] += 1
                var needsRetry = false
                do {
                    let result = try await repository.load(key, source: source, refresh: force)
                    guard !Task.isCancelled, self.metroGeneration == id else { return }
                    needsRetry = result.stale
                    if result.snapshot { snapshots.insert(key) } else { snapshots.remove(key) }
                    if result.stale { failures.insert(key) } else { failures.remove(key) }
                    if self.metroKeys.contains(key) {
                        self.acceptTile(result)
                        if !result.stale && !result.snapshot { replacements.insert(key) }
                        let retained = RailTileContinuity.retainedKeys(existing: Set(self.tileFeatures.keys),
                            requested: self.lastTileKeys, ready: replacements, bounds: MapBounds(region: self.region))
                        self.tileFeatures = self.tileFeatures.filter { retained.contains($0.key) }
                        self.tileOrigins = self.tileOrigins.filter { retained.contains($0.key) }
                        self.fallbackKeys.formIntersection(retained)
                        self.publishTiles()
                    }
                } catch {
                    guard !Task.isCancelled, self.metroGeneration == id else { return }
                    failures.insert(key)
                    needsRetry = true
                }
                let attempt = self.metroAttempts[key, default: 1]
                self.metroNeedsRetry = !failures.isEmpty
                if needsRetry, attempt <= self.metroRetryDelays.count {
                    self.metroRetryAfter[key] = Date().addingTimeInterval(self.metroRetryDelays[attempt - 1])
                } else {
                    self.metroCompleted.insert(key)
                    self.metroRetryAfter.removeValue(forKey: key)
                }
            }
            guard let self, !Task.isCancelled, self.metroGeneration == id else { return }
            self.metroWork = nil
            self.metroLoading = false
            self.metroStatus = !snapshots.isEmpty ? "使用内置 OSM 线路快照 · 在线更新暂不可用，可重试" :
                !failures.isEmpty ? "部分线路归属待补齐 · 已保留现有配色，可重试" : "线路归属已缓存 · 本地配色可离线使用"
            self.sourceStates = await repository.sourceStatus()
            self.cacheStats = (try? await repository.stats()) ?? self.cacheStats
        }
    }

    func publishTiles() {
        assemblyNeedsUpdate = true
        // At most one CPU worker. Incoming tiles coalesce into its next pass;
        // cancelling a detached task does not stop synchronous Swift work.
        guard assemblyTask == nil, mapMode != .offline else { return }
        let id = UUID()
        assemblyID = id
        assemblyTask = Task { [weak self] in
          while let self, !Task.isCancelled, self.assemblyID == id, self.mapMode != .offline {
            // Coalesce bursts without delaying the first render behind network
            // completion.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, self.assemblyID == id else { return }
            self.assemblyNeedsUpdate = false
            let generation = self.viewportGeneration, source = self.tileSource
            let tiles = self.tileFeatures, palette = self.paletteRecords, wiki = self.wikiRecords
            let requested = self.lastTileKeys, fallback = self.fallbackKeys
            let enrich = self.enrichWikiColours, ledger = self.identityLedger
            let preview = self.tileZoom >= 10 && (28.3...29.0).contains(self.region.center.latitude)
                && (115.5...116.3).contains(self.region.center.longitude) ? self.metroPreview : nil
            let overview = self.showsNationalMetroOverview ? self.nationalMetroSnapshot : nil
            self.recordAssemblyPass()
            let worker = Task.detached(priority: .userInitiated) {
                let result = RailFeatureAssembler.assemble(tiles: tiles, palette: palette, wiki: wiki,
                                               enrichWiki: enrich, ledger: ledger, preview: preview,
                                               requested: requested, fallbackKeys: fallback)
                let features = NationalMetroDisplay.merging(overview, into: result.features,
                    palette: palette, wiki: wiki, enrichWiki: enrich)
                guard !Task.isCancelled else { return nil as (RailAssembly, RailTileFeatures, PreparedMapData)? }
                return (result, features, PreparedMapData(lines: features.lines, stations: features.stations))
            }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, self.assemblyID == id, self.mapMode != .offline else { return }
            // A previous viewport/source cannot replace the one now on screen.
            guard generation == self.viewportGeneration, source == self.tileSource, let (result, features, prepared) = value else {
                if self.assemblyNeedsUpdate { continue }
                self.assemblyTask = nil
                return
            }
            self.applyingConfiguration = true
            self.identityLedger = result.ledger
            self.onlineLines = features.lines
            self.onlineStations = features.stations
            if !self.hiddenRoutes.isEmpty {
                var hidden = self.hiddenRoutes
                for route in self.onlineLines.flatMap({ $0.routes ?? [] }) where route.visibilityKey != route.sourceVisibilityKey {
                    if hidden.remove(route.sourceVisibilityKey) != nil { hidden.insert(route.visibilityKey) }
                }
                if hidden != self.hiddenRoutes { self.hiddenRoutes = hidden }
            }
            self.showsMetroPreview = result.usesPreview
            self.fallbackTiles = self.fallbackKeys.count
            self.activeProviders = Set(self.tileOrigins.values).sorted().joined(separator: " · ")
            self.rebuildIndex(precomputed: prepared)
            self.applyingConfiguration = false
            self.rebuildVisible()
            self.loadPaletteIfNeeded()
            self.loadWikiColoursIfNeeded()
            if !self.assemblyNeedsUpdate {
                self.assemblyTask = nil
                return
            }
          }
        }
    }

    func loadPaletteIfNeeded() {
        guard mapMode != .offline, paletteWork == nil else { return }
        let needed = colourRequests.palette.filter { !paletteAttempted.contains($0.key) }
        let routes = needed.sorted { $0.key < $1.key }.map(\.value)
        guard !routes.isEmpty else { return }
        paletteAttempted.formUnion(needed.keys)
        let generation = viewportGeneration, repository = tileRepository, online = mapMode == .apple
        paletteWork = Task { [weak self] in
            let records = try? await repository.paletteColours(for: routes, online: online)
            guard let self, !Task.isCancelled, self.viewportGeneration == generation else { return }
            let changed = records?.contains { key, record in
                self.paletteRecords[key]?.hex != record.hex || self.paletteRecords[key]?.url != record.url
            } ?? false
            if let records { self.paletteRecords.merge(records) { _, new in new } }
            self.paletteWork = nil
            if changed { self.publishTiles() }
            else { self.loadPaletteIfNeeded() }
        }
    }

    func loadWikiColoursIfNeeded() {
        guard mapMode != .offline, enrichWikiColours, wikiWork == nil else { return }
        let needed = colourRequests.wiki.filter { !wikiAttempted.contains($0.key) }
            .sorted { $0.key < $1.key }.prefix(50)
        let routes = needed.map(\.value)
        guard !routes.isEmpty else { return }
        wikiAttempted.formUnion(needed.map(\.key))
        let generation = viewportGeneration, repository = tileRepository
        let online = mapMode == .apple
        wikiColourLoading = online
        wikiColourStatus = online ? "正在补充百科线路色…" : "读取百科配色缓存…"
        wikiWork = Task { [weak self] in
            do {
                let update = try await repository.wikiColours(for: routes, online: online)
                guard let self, !Task.isCancelled, self.viewportGeneration == generation else { return }
                let changed = update.records.contains { key, record in
                    self.wikiRecords[key]?.hex != record.hex
                        || (record.hex != nil && (self.wikiRecords[key]?.sourceURL != record.sourceURL
                            || self.wikiRecords[key]?.sourceName != record.sourceName))
                }
                self.wikiRecords.merge(update.records) { _, new in new }
                self.wikiColourStatus = update.message
                self.wikiColourLoading = false
                self.wikiWork = nil
                if changed { self.publishTiles() }
                else { self.loadWikiColoursIfNeeded() }
            } catch {
                guard let self, !Task.isCancelled, self.viewportGeneration == generation else { return }
                self.wikiColourStatus = "百科服务暂不可用 · 保留已有线路色"
                self.wikiColourLoading = false
                self.wikiWork = nil
            }
        }
    }

    func applySource() {
        do {
            let source = try RailwayTileRepository.normalizeSource(sourceDraft)
            tileSource = source
            UserDefaults.standard.set(source, forKey: "railway.tileSource")
            tileFeatures = [:]
            tileOrigins = [:]
            fallbackKeys = []
            completeMetroKeys = []
            identityLedger = RailIdentityLedger()
            publishTiles()
            refreshViewport(force: true)
        } catch { showMessage(error.localizedDescription, error: true) }
    }

    func retryViewport() {
        Task {
            await tileRepository.retrySources()
            // Cancel/drain the active job and reset attempts/deadlines together;
            // clearing only completed keys makes old attempts look active.
            refreshViewport(force: true)
        }
    }

    func importCache(_ url: URL) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; isLoading = false }
            do {
                let count = try await tileRepository.importCache(from: url)
                cacheStats = try await tileRepository.stats()
                showMessage("已合并 \(count) 块铁路缓存，可在“仅使用缓存”模式浏览。")
                lastTileKeys = []
                if mapMode == .offline { changeMode(.cached) }
                else { refreshViewport() }
            } catch { showMessage("缓存导入失败：\(error.localizedDescription)", error: true) }
        }
    }

    func prepareCacheExport() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("RailwayAtlas-\(UUID().uuidString).railcache")
                try await tileRepository.exportCache(to: file)
                if let previous = cacheFile?.file { try? FileManager.default.removeItem(at: previous) }
                cacheFile = RailwayCacheFile(file: file)
                showCacheExporter = true
            } catch { showMessage("缓存导出失败：\(error.localizedDescription)", error: true) }
        }
    }

    func goTo(_ place: AtlasPlace) {
        selection = nil
        searchText = ""
        if mapMode == .offline { changeMode(.apple) }
        region = MKCoordinateRegion(center: place.coordinate.location, span: MKCoordinateSpan(latitudeDelta: place.span, longitudeDelta: place.span * 1.4))
        cameraRevision += 1
        rebuildVisible()
        refreshViewport()
    }

    var matchingPlaces: [AtlasPlace] {
        let query = RailwaySearch.normalized(searchText)
        return AtlasPlace.presets.filter { RailwaySearch.normalized($0.name).contains(query) }
    }

    func searchPlaces() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, mapMode == .apple else { return }
        localSearch?.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let service = MKLocalSearch(request: request)
        localSearch = service
        isSearchingPlaces = true
        Task {
            do {
                let response = try await service.start()
                guard self.localSearch === service else { return }
                placeResults = response.mapItems.prefix(10).enumerated().map { index, item in
                    RailwaySelection(id: "place/\(index)", name: item.name ?? query, subtitle: "地点 · 在线搜索",
                                     tags: [:], coordinate: alignment.original(Coordinate(item.placemark.coordinate.latitude, item.placemark.coordinate.longitude)))
                }
            } catch {
                guard self.localSearch === service else { return }
                showMessage("地点搜索暂不可用：\(error.localizedDescription)", error: true)
            }
            if self.localSearch === service { isSearchingPlaces = false }
        }
    }
}

struct AtlasPlace: Identifiable {
    let name: String
    let coordinate: Coordinate
    var span: Double = 0.23
    var id: String { name }
    static let presets: [Self] = [
        .init(name: "欧洲", coordinate: Coordinate(54, 15), span: 37),
        .init(name: "伦敦", coordinate: Coordinate(51.51, -0.13)),
        .init(name: "巴黎", coordinate: Coordinate(48.86, 2.35)),
        .init(name: "柏林", coordinate: Coordinate(52.52, 13.40)),
        .init(name: "北京", coordinate: Coordinate(39.91, 116.40)),
        .init(name: "上海", coordinate: Coordinate(31.23, 121.47)),
        .init(name: "广州", coordinate: Coordinate(23.13, 113.27)),
        .init(name: "深圳", coordinate: Coordinate(22.55, 114.06)),
        .init(name: "成都", coordinate: Coordinate(30.66, 104.06)),
        .init(name: "重庆", coordinate: Coordinate(29.56, 106.55)),
        .init(name: "武汉", coordinate: Coordinate(30.59, 114.30)),
        .init(name: "西安", coordinate: Coordinate(34.26, 108.95)),
        .init(name: "杭州", coordinate: Coordinate(30.27, 120.15)),
        .init(name: "南京", coordinate: Coordinate(32.06, 118.80)),
        .init(name: "南昌", coordinate: Coordinate(28.68, 115.89)),
        .init(name: "哈尔滨", coordinate: Coordinate(45.76, 126.64)),
        .init(name: "乌鲁木齐", coordinate: Coordinate(43.82, 87.62)),
        .init(name: "拉萨", coordinate: Coordinate(29.65, 91.11)),
        .init(name: "香港", coordinate: Coordinate(22.32, 114.17)),
        .init(name: "台北", coordinate: Coordinate(25.04, 121.54)),
        .init(name: "澳门", coordinate: Coordinate(22.17, 113.55), span: 0.12)
    ]
}
