#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

/// v0.2 development checks share one entry point and isolated QA directory.
@MainActor
enum SeriesUIValidation {
    static func discovery(store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        let report = try DiscoveryValidation.run()
        guard let window, let view = window.contentView,
              let station = store.activeStations.first,
              let line = store.activeLines.first(where: { !$0.coordinates.isEmpty }) else {
            throw DataError.invalid("Discovery QA requires bundled map and native window")
        }
        store.favoriteIDs = []
        store.selection = RailwayMapStore.item(station)
        store.toggleFavorite(station.id)
        store.selection = RailwayMapStore.item(line)
        store.toggleFavorite(line.id)
        store.selection = nil
        store.inspectorVisible = false
        store.panelVisible = true
        store.panelSize = .large
        store.panelWidth = 320
        store.uiScale = 1
        store.selectedTab = 0
        guard store.isFavorite(RailwayMapStore.item(station)),
              store.isFavorite(RailwayMapStore.item(line)),
              FavoriteStore.shared.entries.count == 2 else {
            throw DataError.invalid("Live discovery favorite hooks failed")
        }
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        _ = try RetinaUIValidation.capture(view, name: "discovery-favorites", directory: directory)
        store.selectedTab = 1
        try await Task.sleep(for: .milliseconds(250))
        _ = try RetinaUIValidation.capture(view, name: "layers-compact", directory: directory)
        try Data((report + "\nPASS live map favorite hooks; native discovery and layers captured.").utf8)
            .write(to: directory.appendingPathComponent("discovery-qa.txt"))
    }

    static func run(store: RailwayMapStore, assistant: AssistantStore, window: NSWindow?, directory: URL) async throws {
        guard let window, let view = window.contentView, var dataset = store.dataset else {
            throw DataError.invalid("Series QA needs the application window")
        }
        let keys = (1671...1677).flatMap { x in (839...844).flatMap { y in
            [RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: x, y: y)),
             RailTileKey(layer: .stations, tile: RailTile(z: 11, x: x, y: y)),
             RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: x >> 1, y: y >> 1))]
        } }
        let values = try await store.tileRepository.cached(Array(Set(keys)), source: RailwayTileRepository.defaultSource)
        guard values.count > 30 else { throw DataError.invalid("Wuhan cache fixture is missing") }
        let ready = Set(values.filter { !$0.fallback }.map(\.key))
        let parents = try await store.tileRepository.cachedParents(keys.filter { !ready.contains($0) },
                                                                   source: RailwayTileRepository.defaultSource)
        let result = await Task.detached {
            RailFeatureAssembler.assemble(tiles: Dictionary((values + parents).map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a }),
                palette: [:], wiki: [:], enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        }.value
        dataset.name = "武汉"; dataset.lines = result.features.lines; dataset.stations = result.features.stations
        dataset.bounds = MapBounds(south: 30.20, west: 113.85, north: 31.02, east: 114.72)
        store.changeMode(.offline)
        store.dataset = dataset; store.rebuildIndex()
        store.automaticDetail = false; store.uiScale = 1
        store.panelLayout = .floating; store.inspectorLayout = .docked
        store.panelBackgroundOpacity = 1; store.inspectorBackgroundOpacity = 1
        store.panelVisible = false; store.inspectorVisible = false; store.statusVisible = false
        store.fitDataset()
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
            let bitmap = try RetinaUIValidation.capture(view, name: name, directory: directory)
            guard abs(Double(bitmap.pixelsWide) / view.bounds.width - window.backingScaleFactor) < 0.01 else {
                throw DataError.invalid("Series QA lost native pixel density")
            }
        }
        try await capture("wuhan-overview")
        if let endpoint = result.features.lines
            .filter({ $0.tags["name"] == "武汉有轨电车车都T1线" })
            .flatMap(\.coordinates).min(by: { $0.latitude < $1.latitude }) {
            store.region = MKCoordinateRegion(center: endpoint.location,
                span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.09))
            store.cameraRevision += 1; store.rebuildVisible()
            let t1 = store.visibleLines.filter { $0.tags["name"] == "武汉有轨电车车都T1线" }
            guard !t1.isEmpty, t1.allSatisfy({ !$0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("Wuhan Auto City T1 endpoint still uncoloured")
            }
            try await capture("wuhan-tram-t1-endpoint")
        }
        for (name, center, span) in [
            ("wuhan-southwest", Coordinate(30.29, 114.025), 0.20),
            ("wuhan-southwest-close", Coordinate(30.282, 114.045), 0.05),
            ("wuhan-return", Coordinate(30.60, 114.30), 0.90)
        ] {
            store.region = MKCoordinateRegion(center: center.location,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.3))
            store.cameraRevision += 1; store.rebuildVisible()
            let extensions = store.visibleLines.filter { ($0.routes ?? []).contains { $0.visibilityKey == "metro:wuhan:wh16" } }
            guard !extensions.isEmpty, extensions.allSatisfy({ !$0.appearance.colors.isEmpty }),
                  extensions.allSatisfy({ !(store.clippedGeometry[$0.id] ?? []).isEmpty }) else {
                throw DataError.invalid("Wuhan line 16 lost colour or visible path at " + name)
            }
            try await capture(name)
        }
        guard let station = result.features.stations.first(where: {
            $0.network == .metro && $0.coordinate.latitude < 30.30 && $0.coordinate.longitude < 114.13
        }) else { throw DataError.invalid("Wuhan endpoint station missing") }
        store.selection = RailwayMapStore.item(station)
        store.inspectorWidth = 200
        window.setContentSize(CGSize(width: 960, height: 650))
        try await capture("inspector-200")
        assistant.focus(map: store, scope: .feature)
        assistant.settings.model = "界面验证"
        assistant.turns = [AssistantTurn(role: "assistant", text: "## 武汉 16 号线\n已加载区段使用统一线路色。\n\n这是用于检查窄侧栏布局的本地模拟回答。")]
        assistant.question = "这座车站与市中心如何连接？"
        let assistantWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 720, height: 820),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        let assistantView = NSHostingView(rootView: AtlasAssistantView()
            .environmentObject(store).environmentObject(assistant)
            .background(Color(nsColor: .windowBackgroundColor)))
        assistantWindow.contentView = assistantView
        assistantWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        try await capture("gpt-window-720")
        guard assistantWindow.isVisible, window.attachedSheet == nil,
              store.inspectorPane == .feature else {
            throw DataError.invalid("GPT should use a separate window while the map keeps the feature inspector")
        }
        assistantWindow.orderOut(nil)
        try Data("""
        PASS actual Wuhan cached geometry: southwest line 16 retains colour and clipped paths through three zoom positions.
        PASS separate endpoint stations carry line 16 identity.
        PASS feature inspector stays in the map window and GPT renders in a separate 720 pt window; native backing density.
        Synthetic assistant reply only, no paid API call.
        """.utf8).write(to: directory.appendingPathComponent("series-ui.txt"))
    }
}
#endif
