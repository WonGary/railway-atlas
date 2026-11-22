import Combine
import Darwin
import Foundation
import RailwayCore
import SwiftUI

@MainActor
final class ConfigurationStore: ObservableObject {
    @Published var notice = ""
    @Published var hasError = false
    let url: URL
    private weak var map: RailwayMapStore?
    private weak var assistant: AssistantStore?
    private var subscriptions = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var applying = false
    private var lastWritten: Data?

    init(url: URL? = nil) {
        if let url { self.url = url }
        else if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke"), CommandLine.arguments.count > index + 1 {
            self.url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("config.json")
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RailwayAtlas/config.json")
        }
    }

    func bind(map: RailwayMapStore, assistant: AssistantStore) {
        self.map = map; self.assistant = assistant
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) { reload() }
            else { saveNow() } // One-time migration from existing preferences.
        } catch { fail(error) }
        map.objectWillChange.sink { [weak self] _ in self?.scheduleSave() }.store(in: &subscriptions)
        assistant.$settings.dropFirst().sink { [weak self] _ in self?.scheduleSave() }.store(in: &subscriptions)
        #if os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.saveNow() }.store(in: &subscriptions)
        #else
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.saveNow() }.store(in: &subscriptions)
        #endif
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        // Watch the directory so atomic editor saves (rename) are detected too.
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        watcher.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.setCancelHandler { close(fd) }
        self.watcher = watcher
        watcher.resume()
    }

    private func scheduleSave() {
        guard !applying, !hasError else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.saveNow()
        }
    }

    func snapshot() -> AtlasConfiguration {
        var value = AtlasConfiguration()
        guard let map, let assistant else { return value }
        value.rendering = map.renderSettings
        value.assistant = assistant.settings
        value.map.mode = map.mapMode.rawValue
        value.map.basemapStyle = map.basemapStyle.rawValue
        value.map.basemapDarkness = map.basemapDarkness
        value.map.alignment = map.alignment.rawValue
        value.map.tileSource = map.tileSource
        value.layers.categories = map.categories.map(\.rawValue).sorted()
        value.layers.networks = map.networks.map(\.rawValue).sorted()
        value.layers.forcedCategories = map.forcedCategories.map(\.rawValue).sorted()
        value.layers.forcedNetworks = map.forcedNetworks.map(\.rawValue).sorted()
        value.layers.hiddenRoutes = map.hiddenRoutes.sorted()
        value.layers.automaticDetail = map.automaticDetail
        value.layers.prioritizesUrbanTransit = map.prioritizesUrbanTransit
        value.layers.showsNationalMetroOverview = map.showsNationalMetroOverview
        value.layers.showsStations = map.showsStations
        value.layers.showsStationLayouts = map.showsStationLayouts
        value.layers.showsStationOutlines = map.showsStationOutlines
        value.layers.showsPlatforms = map.showsPlatforms
        value.layers.showsPassengerPassages = map.showsPassengerPassages
        value.layers.showsPlatformNumbers = map.showsPlatformNumbers
        value.layers.showsLabels = map.showsLabels
        value.layers.showsMetroColors = map.showsMetroColors
        value.layers.enrichWikiColours = map.enrichWikiColours
        value.interface.uiScale = map.uiScale
        value.interface.panelWidth = map.panelWidth
        value.interface.panelVisible = map.panelVisible
        value.interface.panelSize = map.panelSize
        value.interface.panelLayout = map.panelLayout
        value.interface.panelBackgroundOpacity = map.panelBackgroundOpacity
        value.interface.inspectorVisible = map.inspectorVisible
        value.interface.inspectorWidth = map.inspectorWidth
        value.interface.inspectorTab = assistant.settings.presentation == .window ? "feature" : map.inspectorPane.rawValue
        value.interface.inspectorLayout = map.inspectorLayout
        value.interface.inspectorBackgroundOpacity = map.inspectorBackgroundOpacity
        value.interface.statusVisible = map.statusVisible
        value.interface.statusX = map.statusOffset.width
        value.interface.statusY = map.statusOffset.height
        return value
    }

    func saveNow() {
        guard !applying, !hasError else { return }
        do {
            let value = snapshot()
            try value.validate()
            let data = try value.encoded()
            guard data != lastWritten else { return }
            // Do not overwrite an external edit that arrived before our debounce.
            if let lastWritten, let disk = try? Data(contentsOf: url), disk != lastWritten {
                reload(); return
            }
            try data.write(to: url, options: .atomic)
            lastWritten = data
            notice = "配置已保存；外部修改会自动载入。"
        } catch { fail(error) }
    }

    func reload() {
        do {
            let data = try Data(contentsOf: url)
            guard data != lastWritten || hasError else { return }
            let value = try AtlasConfiguration.decode(data)
            pending?.cancel()
            applying = true
            apply(value)
            applying = false
            lastWritten = data
            hasError = false
            notice = "已载入配置。"
        } catch { fail(error) }
    }

    private func apply(_ value: AtlasConfiguration) {
        guard let map, let assistant else { return }
        // Batch visibility changes; build the geometry index just once.
        map.applyingConfiguration = true
        map.renderSettings = value.rendering
        assistant.settings = value.assistant
        map.basemapStyle = BasemapStyle(rawValue: value.map.basemapStyle)!
        map.basemapDarkness = value.map.basemapDarkness
        map.alignment = MapAlignment(rawValue: value.map.alignment)!
        map.categories = Set(value.layers.categories.compactMap(RailCategory.init(rawValue:)))
        map.networks = Set(value.layers.networks.compactMap(RailNetwork.init(rawValue:)))
        map.forcedCategories = Set(value.layers.forcedCategories.compactMap(RailCategory.init(rawValue:)))
        map.forcedNetworks = Set(value.layers.forcedNetworks.compactMap(RailNetwork.init(rawValue:)))
        map.hiddenRoutes = Set(value.layers.hiddenRoutes)
        map.automaticDetail = value.layers.automaticDetail
        map.prioritizesUrbanTransit = value.layers.prioritizesUrbanTransit
        map.showsNationalMetroOverview = value.layers.showsNationalMetroOverview
        map.showsStations = value.layers.showsStations
        map.showsStationLayouts = value.layers.showsStationLayouts ?? true
        map.showsStationOutlines = value.layers.showsStationOutlines
        map.showsPlatforms = value.layers.showsPlatforms
        map.showsPassengerPassages = value.layers.showsPassengerPassages
        map.showsPlatformNumbers = value.layers.showsPlatformNumbers
        map.showsLabels = value.layers.showsLabels
        map.showsMetroColors = value.layers.showsMetroColors
        if map.enrichWikiColours != value.layers.enrichWikiColours { map.enrichWikiColours = value.layers.enrichWikiColours }
        map.uiScale = value.interface.uiScale
        map.panelWidth = value.interface.panelWidth
        map.panelVisible = value.interface.panelVisible
        map.panelSize = value.interface.panelSize
        map.panelLayout = value.interface.panelLayout
        map.panelBackgroundOpacity = value.interface.panelBackgroundOpacity
        map.inspectorVisible = value.interface.inspectorVisible
        map.inspectorWidth = value.interface.inspectorWidth
        map.inspectorPane = value.assistant.presentation == .window ? .feature :
            (InspectorPane(rawValue: value.interface.inspectorTab) ?? .feature)
        map.inspectorLayout = value.interface.inspectorLayout
        map.inspectorBackgroundOpacity = value.interface.inspectorBackgroundOpacity
        map.statusVisible = value.interface.statusVisible
        map.statusOffset = CGSize(width: value.interface.statusX, height: value.interface.statusY)
        let source = (try? RailwayTileRepository.normalizeSource(value.map.tileSource)) ?? value.map.tileSource
        let sourceChanged = map.tileSource != source
        map.tileSource = source; map.sourceDraft = source
        map.applyingConfiguration = false
        map.rebuildVisible()
        let mode = MapMode(rawValue: value.map.mode)!
        if map.mapMode != mode { map.changeMode(mode) }
        else if sourceChanged, map.onlineStarted { map.refreshViewport(force: true) }
    }

    private func fail(_ error: Error) {
        hasError = true
        pending?.cancel()
        notice = "配置未应用，保留当前设置并暂停写入：\(error.localizedDescription) 修正文件后重新载入。"
    }
}
