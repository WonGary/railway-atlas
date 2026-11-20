import Foundation
import MapKit
import RailwayCore
import SwiftUI

@MainActor
final class RailwayMapStore: ObservableObject {
    lazy var journeyPlayer = RailMapPlayback(map: self)
    @Published var experienceLines: [ExperienceMapLine] = []
    @Published var experienceMarker: Coordinate?
    @Published var experienceGeometryRevision = 0
    @Published var historyMapActive = false
    var applyingConfiguration = false
    @Published var renderSettings = RailRenderSettings() { didSet { rebuildVisible() } }
    private var stationTrackCategories: [String: RailCategory] = [:]
    private var prepared = PreparedMapData(lines: [], stations: [])
    private var preparedStyles: [RailAppearance] = []
    private var styleSettings: RailRenderSettings?
    private var styleMetroColors = true
    private var renderBounds: MapBounds?
    private var renderBuffer: Double?
    private var candidateLines: [Int] = []
    private var candidateStations: [Int] = []
    private var linePaths: [String: CGPath] = [:]
    private var pathCoordinates: [String: [Coordinate]] = [:]
    private(set) var clippedGeometry: [String: [[Coordinate]]] = [:]
    private var groupedPaths: [RailAppearance: (ids: [String], path: CGPath, token: UUID)] = [:]
    private var previousVisibility: VisibilityState?
    private struct VisibilityState: Equatable {
        let level: Int
        let categories: Set<RailCategory>
        let networks: Set<RailNetwork>
        let forcedCategories: Set<RailCategory>
        let forcedNetworks: Set<RailNetwork>
        let hiddenRoutes: Set<String>
        let automatic: Bool
        let urbanTransitPriority: Bool
        let nationalMetroOverview: Bool
        let stations: Bool
        let metroColors: Bool
        let settings: RailRenderSettings
    }
    var viewportBounds: MapBounds {
        mapMode == .apple ? MapBounds(region: region) : RailProjection(
            region: region, size: CGSize(width: viewportWidth, height: viewportHeight)).visibleBounds
    }
    func stationAppearance(_ station: RailStation) -> StationAppearance {
        let width = stationTrackCategories[station.id].map {
            RailAppearance(category: $0, colors: []).lineWidth(zoom: displayZoom, settings: renderSettings)
        }
        return station.appearance(showMetroColors: showsMetroColors, lineWidth: width, zoom: displayZoom, settings: renderSettings)
    }
    func appearance(_ line: RailLine) -> RailAppearance {
        line.appearance(showMetroColors: showsMetroColors, depotBrightness: renderSettings.depotBrightness)
    }
    @Published var dataset: RailwayDataset?
    @Published var searchText = ""
    @Published var categories: Set<RailCategory> = Set(RailCategory.allCases) { didSet { rebuildVisible() } }
    @Published var showsStations = true { didSet { rebuildVisible() } }
    @Published var showsLabels = true { didSet { labelRevision += 1 } }
    @Published var basemapDarkness = 0.0 {
        didSet { persist(basemapDarkness, "railway.basemapDarkness") }
    }
    var dimsBasemap: Bool {
        get { basemapDarkness > 0 }
        set { basemapDarkness = newValue ? 0.42 : 0 }
    }
    @Published var basemapStyle: BasemapStyle = .standard {
        didSet { persist(basemapStyle.rawValue, "railway.basemapStyle") }
    }
    @Published var uiScale = 1.0 { didSet { persist(uiScale, "railway.uiScale") } }
    @Published var panelWidth = 320.0 { didSet { persist(panelWidth, "railway.panelWidth") } }
    @Published var panelVisible = true
    @Published var panelSize = MapPanelSize.medium
    @Published var panelLayout = MapPanelLayout.floating
    @Published var panelBackgroundOpacity = 1.0
    @Published var inspectorVisible = false
    @Published var inspectorWidth = 380.0
    @Published var inspectorPane = InspectorPane.feature
    @Published var inspectorLayout = MapPanelLayout.docked
    @Published var inspectorBackgroundOpacity = 1.0
    @Published var statusVisible = true { didSet { persist(statusVisible, "railway.statusVisible") } }
    @Published var statusOffset = CGSize.zero {
        didSet {
            persist(statusOffset.width, "railway.statusX")
            persist(statusOffset.height, "railway.statusY")
        }
    }
    @Published var showSettings = false
    /// iOS presents GPT as a sheet. macOS opens the named
    /// `railway-assistant` window from the view that owns the action, so this
    /// state must never repurpose the right feature inspector.
    @Published var showAssistant = false
    @Published var automaticDetail = true { didSet { persist(automaticDetail, "railway.automaticDetail"); rebuildVisible() } }
    @Published var prioritizesUrbanTransit = false {
        didSet {
            persist(prioritizesUrbanTransit, "railway.prioritizesUrbanTransit")
            rebuildVisible()
        }
    }
    /// The bundled relation-only nationwide network is useful at country scale,
    /// but it must not force a metro layer into ordinary railway browsing.
    /// Detailed tracks keep their independent filters and urban priority when
    /// this overview is disabled. Urban priority never starts an overview load.
    @Published var showsNationalMetroOverview = true {
        didSet {
            persist(showsNationalMetroOverview, "railway.showsNationalMetroOverview")
            if !showsNationalMetroOverview {
                nationalMetroWork?.cancel()
                nationalMetroWork = nil
                nationalMetroLoading = false
                nationalMetroStatus = "全国城市轨道概览 · 已关闭"
            } else if let snapshot = nationalMetroSnapshot {
                updateNationalMetroStatus(snapshot)
                if mapMode != .offline { publishTiles() }
            } else if mapMode != .offline {
                loadNationalMetroOverview()
            }
            rebuildVisible()
        }
    }
    @Published var forcedCategories = Set<RailCategory>()
    @Published var forcedNetworks = Set<RailNetwork>()
    var displayZoom: Double { RailDisplayPolicy.zoom(longitudeSpan: region.span.longitudeDelta, width: viewportWidth) }
    private var visibilityPolicy: RailVisibilityPolicy {
        var policy = RailVisibilityPolicy()
        policy.categories = categories
        policy.networks = networks
        policy.forcedCategories = forcedCategories
        policy.forcedNetworks = forcedNetworks
        policy.hiddenRoutes = hiddenRoutes
        policy.automaticDetail = automaticDetail
        policy.prioritizesUrbanTransit = prioritizesUrbanTransit
        policy.showsNationalMetroOverview = showsNationalMetroOverview
        policy.hasNationalMetroOverview = mapMode != .offline && nationalMetroSnapshot != nil
        policy.showsStations = showsStations
        policy.zoom = displayZoom
        return policy
    }
    func categoryVisible(_ category: RailCategory) -> Bool {
        visibilityPolicy.categoryVisible(category)
    }
    func networkVisible(_ network: RailNetwork) -> Bool {
        visibilityPolicy.networkVisible(network)
    }
    func setCategory(_ category: RailCategory, visible: Bool) {
        if visible { forcedCategories.insert(category); categories.insert(category) }
        else { forcedCategories.remove(category); categories.remove(category) }
    }
    func setNetwork(_ network: RailNetwork, visible: Bool) {
        if visible {
            forcedNetworks.insert(network)
            if [.metro, .lightRail, .tram].contains(network) { forcedCategories.insert(.urban); categories.insert(.urban) }
            networks.insert(network)
        } else { forcedNetworks.remove(network); networks.remove(network) }
    }
    @Published var alignment: MapAlignment = .mainlandGCJ {
        didSet {
            if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(alignment.rawValue, forKey: "railway.alignment") }
            renderRevision += 1
            cameraRevision += 1
        }
    }
    @Published var hiddenRoutes: Set<String> = [] {
        didSet {
            if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(Array(hiddenRoutes), forKey: "railway.hiddenRoutes") }
            rebuildVisible()
        }
    }
    @Published var networks: Set<RailNetwork> = Set(RailNetwork.allCases) { didSet { rebuildVisible() } }
    @Published var showsMetroColors = true { didSet { rebuildVisible() } }
    @Published var enrichWikiColours = true {
        didSet {
            wikiWork?.cancel()
            wikiWork = nil
            wikiAttempted = []
            publishTiles()
        }
    }
    @Published var wikiColourStatus = "浏览城市时自动补充百科线路色"
    @Published var wikiColourLoading = false
    @Published var visibleLines: [RailLine] = []
    @Published var visibleStations: [RailStation] = []
    @Published var renderGroups: [RailRenderGroup] = []
    @Published var categoryCounts: [RailCategory: Int] = [:]
    @Published var urbanRoutes: [RailRoute] = []
    @Published var urbanRouteTitles: [String: String] = [:]
    @Published var renderRevision = 0
    @Published var labelRevision = 0
    @Published var selection: RailwaySelection? {
        didSet {
            #if os(macOS)
            if selection != nil { inspectorPane = .feature; inspectorVisible = true }
            #endif
        }
    }
    @Published var mapMode: MapMode = .apple
    @Published var region = MapBounds.china.region
    @Published var cameraRevision = 0
    @Published var selectedTab = 0
    @Published var endpoint: DataEndpoint = .vk
    @Published var isLoading = false
    @Published var message: String?
    @Published var isError = false
    @Published var favoriteIDs: Set<String> = []
    @Published var showImporter = false
    @Published var showExporter = false
    @Published var exportFile: RailwayFile?
    @Published var showCacheImporter = false
    @Published var showCacheExporter = false
    @Published var cacheFile: RailwayCacheFile?
    @Published var cacheStats = RailCacheStats()
    @Published var onlineLines: [RailLine] = []
    @Published var onlineStations: [RailStation] = []
    @Published var onlineStatus = "全国铁路 · 随视野加载"
    @Published var onlineLoading = false
    @Published var metroLoading = false
    @Published var metroNeedsRetry = false
    @Published var metroStatus = "线路色 · 本地库就绪"
    @Published var nationalMetroStatus = "全国地铁概览 · 正在读取"
    @Published var nationalMetroLoading = false
    var nationalMetroSnapshot: NationalMetroSnapshot?
    let nationalMetroRepository: NationalMetroRepository
    var nationalMetroWork: Task<Void, Never>?
    @Published var tilesReady = 0
    @Published var tilesExpected = 0
    @Published var failedTiles = 0
    @Published var tileZoom = 4
    @Published var tileSource: String = RailwayTileRepository.defaultSource
    @Published var sourceDraft: String = RailwayTileRepository.defaultSource
    @Published var onlineError: String?
    @Published var fallbackTiles = 0
    @Published var sourceStates: [RailSourceStatus] = []
    @Published var activeProviders = ""
    @Published var placeResults: [RailwaySelection] = []
    @Published var isSearchingPlaces = false

    let tileRepository: RailwayTileRepository
    var viewportWork: Task<Void, Never>?
    var metroWork: Task<Void, Never>?
    var metroGeneration = UUID()
    var metroKeys: [RailTileKey] = []
    var metroCompleted = Set<RailTileKey>()
    var metroAttempts: [RailTileKey: Int] = [:]
    var metroRetryAfter: [RailTileKey: Date] = [:]
    let metroRetryDelays: [TimeInterval]
    var metroTaskSource = ""
    var viewportGeneration = UUID()
    var viewportWidth: Double = 920
    var viewportHeight: Double = 700
    var lastTileKeys: [RailTileKey] = []
    var tileFeatures: [RailTileKey: RailTileFeatures] = [:]
    var tileOrigins: [RailTileKey: String] = [:]
    var fallbackKeys = Set<RailTileKey>()
    var completeMetroKeys = Set<RailTileKey>()
    var wikiRecords: [String: WikiMetroColour] = [:]
    var wikiAttempted = Set<String>()
    var wikiWork: Task<Void, Never>?
    var paletteRecords: [String: MetroPaletteRecord] = [:]
    var paletteAttempted = Set<String>()
    var paletteWork: Task<Void, Never>?
    var localSearch: MKLocalSearch?
    var onlineStarted = false
    var metroPreview: RailwayDataset?
    var identityLedger = RailIdentityLedger()
    var assemblyTask: Task<Void, Never>?
    var assemblyID = UUID()
    var assemblyNeedsUpdate = false
    private(set) var assemblyPasses = 0
    func recordAssemblyPass() { assemblyPasses += 1 }
    var colourRequests: MetroColourRequests { prepared.colourRequests }
    @Published var showsMetroPreview = false

    private var indexedSearch: [(RailwaySelection, String)] = []
    private var searchIndexDirty = true
    private var normalizedNames: [String: String] = [:]
    private var work: Task<Void, Never>?
    private let repository: RailwayRepository

    init(tileSession: URLSession? = nil, metroRetryDelays: [TimeInterval] = [30, 90]) {
        self.metroRetryDelays = metroRetryDelays
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        repository = RailwayRepository(directory: support.appendingPathComponent("RailwayAtlas", isDirectory: true))
        let args = CommandLine.arguments
        let qaIndex = args.firstIndex(of: "--ui-smoke")
        let directory: URL
        if let qaIndex, args.count > qaIndex + 1 {
            directory = URL(fileURLWithPath: args[qaIndex + 1]).appendingPathComponent("cache", isDirectory: true)
        } else {
            directory = support.appendingPathComponent("RailwayAtlas/Online", isDirectory: true)
        }
        tileRepository = RailwayTileRepository(directory: directory, session: tileSession)
        nationalMetroRepository = NationalMetroRepository(
            directory: directory.appendingPathComponent("MetroOverview", isDirectory: true), session: tileSession)
        favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "railway.favorites") ?? [])
        if qaIndex == nil {
            hiddenRoutes = Set(UserDefaults.standard.stringArray(forKey: "railway.hiddenRoutes") ?? [])
            basemapDarkness = UserDefaults.standard.object(forKey: "railway.basemapDarkness") == nil
                ? (UserDefaults.standard.bool(forKey: "railway.dimBasemap") ? 0.42 : 0)
                : min(1, max(0, UserDefaults.standard.double(forKey: "railway.basemapDarkness")))
            basemapStyle = BasemapStyle(rawValue: UserDefaults.standard.string(forKey: "railway.basemapStyle") ?? "") ?? .standard
            uiScale = Self.preferenceNumber("railway.uiScale", default: 1, range: 0.75...1.6)
            panelWidth = Self.preferenceNumber("railway.panelWidth", default: 320, range: 250...560)
            statusVisible = UserDefaults.standard.object(forKey: "railway.statusVisible") as? Bool ?? true
            statusOffset = CGSize(
                width: Self.preferenceNumber("railway.statusX", default: 0, range: -2000...2000),
                height: Self.preferenceNumber("railway.statusY", default: 0, range: -2000...2000))
            automaticDetail = UserDefaults.standard.object(forKey: "railway.automaticDetail") as? Bool ?? true
            prioritizesUrbanTransit = UserDefaults.standard.object(forKey: "railway.prioritizesUrbanTransit") as? Bool ?? false
            showsNationalMetroOverview = UserDefaults.standard.object(
                forKey: "railway.showsNationalMetroOverview") as? Bool ?? true
            if !showsNationalMetroOverview {
                nationalMetroStatus = "全国城市轨道概览 · 已关闭"
            }
            alignment = MapAlignment(rawValue: UserDefaults.standard.string(forKey: "railway.alignment") ?? "") ?? .mainlandGCJ
        }
        if qaIndex == nil, let saved = UserDefaults.standard.string(forKey: "railway.tileSource"),
           let value = try? RailwayTileRepository.normalizeSource(saved) {
            tileSource = value
            sourceDraft = value
        }
    }

    private static func preferenceNumber(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let number = UserDefaults.standard.object(forKey: key) as? Double, number.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, number))
    }
    func persist(_ value: Any, _ key: String) {
        if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(value, forKey: key) }
    }

    func start() async {
        if CommandLine.arguments.contains("--retina-check") || CommandLine.arguments.contains("--loading-check")
            || CommandLine.arguments.contains("--settings-check") || CommandLine.arguments.contains("--viewport-check")
            || CommandLine.arguments.contains("--scale-check") || CommandLine.arguments.contains("--urban-lifecycle-check")
            || CommandLine.arguments.contains("--panels-check")
            || CommandLine.arguments.contains("--v020-check")
            || CommandLine.arguments.contains("--v020-discovery-check")
            || CommandLine.arguments.contains("--v020-panel-layout-check")
            || CommandLine.arguments.contains("--v020-assistant-check")
            || CommandLine.arguments.contains("--assistant-personalization-check")
            || CommandLine.arguments.contains("--v020-interchange-check")
            || CommandLine.arguments.contains("--v020-national-check")
            || CommandLine.arguments.contains("--experiences-check")
            || CommandLine.arguments.contains("--interface-check") || CommandLine.arguments.contains("--macao-check")
            || CommandLine.arguments.contains("--hongkong-check") || CommandLine.arguments.contains("--beijing-check") { mapMode = .offline }
        if CommandLine.arguments.contains("--render-performance") { mapMode = .offline }
        if !onlineStarted {
            onlineStarted = true
            Task.detached(priority: .utility) { _ = BundledMetroPalette.cityCount }
            if !CommandLine.arguments.contains("--ui-smoke"), showsNationalMetroOverview {
                loadNationalMetroOverview()
            }
            if !CommandLine.arguments.contains("--ui-smoke"),
               let url = Self.resourceURL("nanchang-preview", extension: "railmap") {
                metroPreview = try? RailwayCodec.decode(Data(contentsOf: url))
            }
            if !CommandLine.arguments.contains("--ui-smoke"), tileSource == RailwayTileRepository.defaultSource,
               let seed = Self.resourceURL("china-overview", extension: "railcache") {
                // Merge the tested national overview without replacing newer
                // cache entries. This is not an offline city-detail package.
                do {
                    _ = try await tileRepository.importCache(from: seed)
                    lastTileKeys = []
                }
                catch { showMessage("随附全国概览缓存未载入，将尝试联网。", error: true) }
            }
            refreshViewport()
        }
        guard dataset == nil else { return }
        do {
            if let saved = try await repository.load() {
                install(saved)
                return
            }
        } catch { showMessage("本地地图包无法读取，已尝试载入随附区域。", error: true) }
        let resource = Self.resourceURL("shanghai", extension: "railmap")
        if let resource {
            do {
                let url = resource
                let loaded = try await Task.detached { try RailwayCodec.decode(Data(contentsOf: url)) }.value
                install(loaded)
            } catch { showMessage("随附地图读取失败：\(error.localizedDescription)", error: true) }
        } else {
            showMessage("放大到感兴趣的区域，下载铁路数据；也可以导入本地地图包。")
            mapMode = .apple
        }
    }

    static func resourceURL(_ name: String, extension ext: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? Bundle.main.url(forResource: name, withExtension: ext) { return bundled }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
        #else
        return nil
        #endif
    }

    private func install(_ value: RailwayDataset) {
        dataset = value
        selection = nil
        rebuildIndex()
        rebuildVisible()
        if mapMode == .offline { fitDataset() }
    }

    var activeLines: [RailLine] { mapMode == .offline ? dataset?.lines ?? [] : onlineLines }
    var activeStations: [RailStation] { mapMode == .offline ? dataset?.stations ?? [] : onlineStations }
    var activeName: String { mapMode == .offline ? dataset?.name ?? "本地地图包" : "铁路地图" }
    var assistantRoutes: [AssistantRouteChoice] { prepared.assistantRoutes }

    func line(withID id: String) -> RailLine? {
        guard let index = prepared.lineByID[id], activeLines.indices.contains(index) else { return nil }
        return activeLines[index]
    }

    func station(withID id: String) -> RailStation? {
        guard let index = prepared.stationByID[id], activeStations.indices.contains(index) else { return nil }
        return activeStations[index]
    }

    func interchange(forStationID id: String) -> StationInterchangeGroup? {
        prepared.interchanges[id]
    }

    func assistantFeatures(in bounds: MapBounds) -> RailTileFeatures {
        let lines = activeLines, stations = activeStations
        var result = RailTileFeatures()
        result.lines = prepared.lineIndex.query(bounds).compactMap {
            let line = lines[$0]
            return RailGeometryClip.segments(line.coordinates, inside: bounds).isEmpty ? nil : line
        }
        result.stations = prepared.stationIndex.query(bounds).map { stations[$0] }
        return result
    }

    func rebuildIndex(precomputed: PreparedMapData? = nil) {
        prepared = precomputed ?? PreparedMapData(lines: activeLines, stations: activeStations)
        stationTrackCategories = prepared.stationCategories
        // A tile/colour response changes metadata much more often than
        // geometry. Keep paths and MapKit overlay tokens for unchanged lines.
        let source = activeLines
        let changed = Set(pathCoordinates.keys.filter { id in
            guard let i = prepared.lineByID[id] else { return true }
            return pathCoordinates[id] != source[i].coordinates
        })
        for id in changed {
            pathCoordinates.removeValue(forKey: id)
            linePaths.removeValue(forKey: id)
            clippedGeometry.removeValue(forKey: id)
        }
        groupedPaths = groupedPaths.filter { $0.value.ids.allSatisfy { !changed.contains($0) } }
        if let renderBounds {
            candidateLines = prepared.lineIndex.query(renderBounds)
            candidateStations = prepared.stationIndex.query(renderBounds)
        }
        previousVisibility = nil
        styleSettings = nil
        searchIndexDirty = true
        categoryCounts = prepared.counts
        urbanRoutes = prepared.routes
        urbanRouteTitles = prepared.routeTitles
        FavoriteStore.shared.reconcile(with: self)
    }

    private func prepareSearchIndex() {
        guard searchIndexDirty else { return }
        searchIndexDirty = false
        func normalized(_ value: String) -> String {
            if let cached = normalizedNames[value] { return cached }
            let result = RailwaySearch.normalized(value)
            normalizedNames[value] = result
            return result
        }
        indexedSearch = activeStations.map { station in
            let selection = Self.item(station)
            return (selection, normalized([station.name, station.tags["name:en"] ?? "", station.tags["ref"] ?? ""].joined(separator: " ")))
        } + activeLines.map { line in
            let selection = Self.item(line)
            let routeNames = (line.routes ?? []).flatMap { [$0.name, $0.tags["ref"] ?? ""] }
            return (selection, normalized(
                ([line.name, line.tags["name:en"] ?? "", line.tags["ref"] ?? ""] + routeNames).joined(separator: " ")))
        }
    }

    func rebuildVisible(in transientBounds: MapBounds? = nil) {
        guard !applyingConfiguration else { return }
        let view = transientBounds ?? viewportBounds
        let state = VisibilityState(level: Int(displayZoom), categories: categories, networks: networks,
            forcedCategories: forcedCategories, forcedNetworks: forcedNetworks, hiddenRoutes: hiddenRoutes,
            automatic: automaticDetail, urbanTransitPriority: prioritizesUrbanTransit,
            nationalMetroOverview: showsNationalMetroOverview,
            stations: showsStations, metroColors: showsMetroColors, settings: renderSettings)
        // Refresh when the camera reaches the buffer, or zooms far enough in
        // that the old buffer would retain excessive off-screen geometry.
        let reuseSpan = (1 + 2 * renderSettings.viewportBuffer) * 1.3
        let refresh = renderBounds == nil || !renderBounds!.contains(view)
            || renderBounds!.east - renderBounds!.west > (view.east - view.west) * reuseSpan
            || renderBounds!.north - renderBounds!.south > (view.north - view.south) * reuseSpan
            || renderBuffer != renderSettings.viewportBuffer
        guard refresh || previousVisibility != state else { return }
        if refresh {
            let buffered = view.expanded(by: renderSettings.viewportBuffer)
            renderBounds = buffered
            renderBuffer = renderSettings.viewportBuffer
            candidateLines = prepared.lineIndex.query(buffered)
            candidateStations = prepared.stationIndex.query(buffered)
            linePaths = [:]; pathCoordinates = [:]; clippedGeometry = [:]; groupedPaths = [:]
        }
        if previousVisibility?.level != state.level || previousVisibility?.automatic != state.automatic {
            // Both Canvas and MapKit consume these parts. A scale change must
            // invalidate their geometry tokens as well as the stroke style.
            linePaths = [:]; pathCoordinates = [:]; clippedGeometry = [:]; groupedPaths = [:]
        }
        previousVisibility = state
        if styleSettings?.depotBrightness != renderSettings.depotBrightness || styleMetroColors != showsMetroColors || styleSettings == nil {
            preparedStyles = prepared.lines.map { entry in
                entry.baseStyle.replacingColors(!showsMetroColors ? [] :
                    entry.depot ? entry.baseStyle.colors.map { $0.darkened(renderSettings.depotBrightness) } : entry.baseStyle.colors)
            }
            styleSettings = renderSettings; styleMetroColors = showsMetroColors
        }
        let policy = visibilityPolicy
        let sourceLines = activeLines, sourceStations = activeStations
        var visible: [RailLine] = [], grouped: [RailAppearance: [RailLine]] = [:]
        for i in candidateLines {
            let entry = prepared.lines[i]
            let original = sourceLines[i]
            guard let line = policy.visible(original, facts: entry.display, suppressed: entry.suppressed) else { continue }
            let style = hiddenRoutes.isEmpty || (line.routes ?? []).isEmpty ? preparedStyles[i] : appearance(line)
            if linePaths[line.id] == nil {
                let clipped = renderBounds!.contains(entry.bounds) ? [line.coordinates] :
                    RailGeometryClip.segments(line.coordinates, inside: renderBounds!)
                let segments = automaticDetail ? RailGeometryLOD.segments(clipped, zoom: displayZoom) : clipped
                guard !segments.isEmpty else { continue }
                clippedGeometry[line.id] = segments
                let path = CGMutablePath()
                for segment in segments {
                    for (index, point) in segment.enumerated() {
                        let p = point.mapPoint
                        if index == 0 { path.move(to: CGPoint(x: p.x, y: p.y)) }
                        else { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    }
                }
                linePaths[line.id] = path.copy()!
                pathCoordinates[line.id] = line.coordinates
            }
            visible.append(line)
            grouped[style, default: []].append(line)
        }
        visibleLines = visible
        visibleStations = showsStations ? candidateStations.compactMap { i in
            policy.visible(sourceStations[i], facts: prepared.stationDisplay[i])
        } : []
        renderGroups = grouped.map { style, lines in
            let ids = lines.map(\.id)
            if groupedPaths[style]?.ids != ids {
                let path = CGMutablePath()
                for id in ids { if let line = linePaths[id] { path.addPath(line) } }
                groupedPaths[style] = (ids, path.copy()!, UUID())
            }
            let cached = groupedPaths[style]!
            return RailRenderGroup(appearance: style, lines: lines, path: cached.path, geometryToken: cached.token)
        }.sorted {
            let left = RailCategory.allCases.firstIndex(of: $0.appearance.category)!
            let right = RailCategory.allCases.firstIndex(of: $1.appearance.category)!
            if left != right { return left > right }
            return $0.appearance.colors.map(\.hex).joined() < $1.appearance.colors.map(\.hex).joined()
        }
        renderRevision += 1
        labelRevision += 1
    }

    var displayRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: alignment.display(Coordinate(region.center.latitude, region.center.longitude)).location,
                           span: region.span)
    }

    var results: [RailwaySelection] {
        let query = RailwaySearch.normalized(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        prepareSearchIndex()
        return indexedSearch.lazy.filter { $0.1.contains(query) }.prefix(24).map(\.0)
    }

    var highlights: [RailwaySelection] {
        let stations = activeStations
        let sorted = stations.sorted {
            let left = favoriteIDs.contains($0.id) ? 0 : ($0.tags["train"] == "yes" && $0.tags["construction:railway"] == nil ? 1 : 2)
            let right = favoriteIDs.contains($1.id) ? 0 : ($1.tags["train"] == "yes" && $1.tags["construction:railway"] == nil ? 1 : 2)
            return left == right ? $0.name < $1.name : left < right
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.name).inserted }.prefix(12).map(Self.item)
    }

    func select(_ item: RailwaySelection) {
        selection = item
        if let line = activeLines.first(where: { $0.id == item.id }) {
            let latitudes = line.coordinates.map(\.latitude)
            let longitudes = line.coordinates.map(\.longitude)
            let lat = max(0.008, (latitudes.max()! - latitudes.min()!) * 1.5)
            let lon = max(0.008, (longitudes.max()! - longitudes.min()!) * 1.5)
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (latitudes.min()! + latitudes.max()!) / 2,
                                               longitude: (longitudes.min()! + longitudes.max()!) / 2),
                span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon))
            categories.insert(line.category)
            networks.insert(RailNetwork.classify(line.tags))
        } else {
            showsStations = true
            region = MKCoordinateRegion(center: item.coordinate.location,
                                        span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.018))
        }
        cameraRevision += 1
        rebuildVisible()
        if mapMode != .offline { refreshViewport() }
    }

    func fitDataset() {
        region = (mapMode == .offline ? dataset?.bounds ?? .shanghai : .china).region
        cameraRevision += 1
        rebuildVisible()
        if mapMode != .offline { refreshViewport() }
    }

    func zoom(_ factor: Double) {
        region.span.latitudeDelta = min(100, max(0.001, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = min(200, max(0.001, region.span.longitudeDelta * factor))
        cameraRevision += 1
        rebuildVisible()
        if mapMode != .offline { refreshViewport() }
    }

    func changeMode(_ mode: MapMode) {
        assemblyTask?.cancel()
        assemblyTask = nil
        assemblyID = UUID()
        assemblyNeedsUpdate = false
        viewportWork?.cancel()
        metroWork?.cancel()
        metroWork = nil
        metroGeneration = UUID()
        metroKeys = []
        metroCompleted = []
        metroLoading = false
        wikiWork?.cancel()
        paletteWork?.cancel()
        paletteWork = nil
        wikiWork = nil
        wikiColourLoading = false
        viewportGeneration = UUID()
        onlineLoading = false
        lastTileKeys = []
        mapMode = mode
        if mode != .apple {
            nationalMetroWork?.cancel()
            nationalMetroWork = nil
            nationalMetroLoading = false
        }
        persist(mode.rawValue, "railway.mode")
        selection = nil
        rebuildIndex()
        rebuildVisible()
        if mode == .offline { fitDataset() }
        else {
            if showsNationalMetroOverview, nationalMetroSnapshot == nil { loadNationalMetroOverview() }
            refreshViewport()
        }
    }

    func toggleFavorite(_ id: String) {
        FavoriteStore.shared.toggle(id, in: self)
    }

    func isFavorite(_ item: RailwaySelection) -> Bool {
        FavoriteStore.shared.contains(item, ids: favoriteIDs)
    }

    func downloadRegion() {
        guard !isLoading else { return }
        let bounds = MapBounds(region: region)
        guard bounds.canDownload else { showMessage("请放大地图，下载区域宽高各不超过 0.5°。", error: true); return }
        isLoading = true
        message = nil
        let service = repository
        let endpoint = endpoint
        work = Task {
            do {
                let value = try await service.fetch(bounds: bounds, endpoint: endpoint)
                try Task.checkCancellation()
                try await service.save(value)
                install(value)
                changeMode(.offline)
                showMessage("此区域已保存，离线铁路图可以直接使用。")
            } catch {
                if !Task.isCancelled { showMessage("更新失败：\(error.localizedDescription)。已有地图仍可使用。", error: true) }
            }
            isLoading = false
        }
    }

    func cancelDownload() { work?.cancel() }

    func importFile(_ url: URL) {
        guard !isLoading else { return }
        isLoading = true
        work = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                isLoading = false
            }
            do {
                let value = try await Task.detached {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= RailwayCodec.maxBytes else { throw DataError.invalid("文件不能超过 32 MB") }
                    return try RailwayCodec.decode(Data(contentsOf: url))
                }.value
                try await repository.save(value)
                install(value)
                changeMode(.offline)
                showMessage("地图包已导入并保存。")
            } catch { showMessage("导入失败：\(error.localizedDescription)", error: true) }
        }
    }

    func prepareExport() {
        guard let dataset else { return }
        do {
            exportFile = RailwayFile(data: try RailwayCodec.encode(dataset))
            showExporter = true
        } catch { showMessage(error.localizedDescription, error: true) }
    }

    func showMessage(_ text: String, error: Bool = false) {
        message = text
        isError = error
    }

    static func item(_ station: RailStation) -> RailwaySelection {
        RailwaySelection(id: station.id, name: station.name,
                         subtitle: station.tags["construction:railway"] != nil ? "在建车站" :
                            (station.tags["station"] == "subway" || station.tags["subway"] == "yes" ? "地铁车站" : "铁路车站"),
                         tags: station.tags, coordinate: station.coordinate)
    }

    static func item(_ line: RailLine) -> RailwaySelection {
        RailwaySelection(id: line.id, name: line.name, subtitle: line.category.title,
                         tags: line.tags, coordinate: line.coordinates[line.coordinates.count / 2])
    }
}
