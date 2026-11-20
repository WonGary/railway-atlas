#if os(macOS)
import AppKit
import MapKit
import RailwayCore

/// Full-window integration checks, only in the isolated --ui-smoke launch.
@MainActor
enum PanelUIValidation {
    static func run(store: RailwayMapStore, assistant: AssistantStore, window: NSWindow?, directory: URL) async throws {
        guard let window, let view = window.contentView,
              let line = store.dataset?.lines.first, let station = store.dataset?.stations.first else {
            throw DataError.invalid("Panel QA needs a window and bundled geometry")
        }
        var notes: [String] = []
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw DataError.invalid(message) }
            notes.append("PASS " + message)
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String) async throws {
            try await settle()
            let image = try RetinaUIValidation.capture(view, name: name, directory: directory)
            try check(abs(Double(image.pixelsWide) / view.bounds.width - window.backingScaleFactor) < 0.01,
                      "\(name): native \(window.backingScaleFactor)× backing density")
        }
        store.changeMode(.offline)
        store.uiScale = 1; store.panelWidth = 320; store.inspectorWidth = 380
        store.panelVisible = true; store.inspectorVisible = false; store.statusVisible = true
        store.panelSize = .medium; store.selectedTab = 0
        store.fitDataset()
        let lineItem = RailwayMapStore.item(line), stationItem = RailwayMapStore.item(station)
        store.selection = lineItem
        try check(store.inspectorVisible && store.inspectorPane == .feature, "line pick opens the right feature inspector")
        try await capture("01-feature-medium")
        try await OnlineUIValidation.capture("01-window-chrome", directory: directory, window: window)
        store.inspectorVisible = false
        store.selection = stationItem
        try check(store.inspectorVisible && store.inspectorPane == .feature && store.selection?.isStation == true,
                  "station pick reopens right inspector")
        store.inspectorVisible = false
        store.selection = stationItem
        try check(store.inspectorVisible, "reselecting the same station reopens hidden inspector")
        for size in MapPanelSize.allCases {
            store.panelSize = size
            try await capture("02-left-\(size.rawValue)")
        }
        assistant.focus(map: store, scope: .feature)
        assistant.question = "这座车站可以换乘哪些线路？"
        assistant.settings.model = "界面测试"
        assistant.settings.webSearch = true
        assistant.turns = [
            AssistantTurn(role: "user", text: "显示这座车站的资料"),
            AssistantTurn(role: "assistant", text: "## 车站资料\n这是界面验证用的模拟回答。\n\n- 查看右侧要素页可阅读运营方和原始字段。\n- 地图仍可在左侧拖动与缩放。\n\n**已保留会话**，收起侧栏后可以继续提问。")
        ]
        let context = assistant.context, turnIDs = assistant.turns.map(\.id), question = assistant.question
        // macOS GPT is a separate named window. The map window must keep only
        // the feature inspector; the assistant fixture is captured separately
        // by AssistantUIValidation.
        assistant.focus(map: store, scope: .feature)
        try await capture("03-feature-after-gpt-request")
        try check(store.inspectorPane == .feature && store.inspectorVisible,
                  "GPT request leaves the map window on the feature inspector")
        store.inspectorVisible = false
        store.panelVisible = false
        try await capture("04-both-hidden")
        try check(store.selection?.id == station.id, "hiding panels preserves selection")
        try await settle()
        try check(assistant.question == question && assistant.turns.map(\.id) == turnIDs && assistant.context == context,
                  "map panel changes preserve GPT draft, conversation and material snapshot")
        store.selection = lineItem
        try await settle()
        try check(store.inspectorPane == .feature && assistant.turns.map(\.id) == turnIDs,
                  "new map pick switches to metadata without clearing GPT")
        assistant.busy = true
        assistant.focus(map: store, scope: .region)
        try check(assistant.context == context && assistant.scope == .feature,
                  "switching panels during a pending answer preserves request context")
        assistant.busy = false
        store.panelVisible = true
        for (width, height, scale) in [(960.0, 650.0, 1.0), (960.0, 650.0, 1.6), (1240.0, 820.0, 0.75)] {
            window.setContentSize(CGSize(width: width, height: height))
            store.uiScale = scale; store.panelSize = .large
            try await capture("05-layout-\(Int(width))-\(Int(scale * 100))")
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(CGSize(width: 1240, height: 820))
        store.uiScale = 1; store.panelSize = .medium
        try await capture("06-dark-gpt")
        NSApp.appearance = NSAppearance(named: .aqua)

        // Panel changes must resize the existing native map, not recreate it.
        store.changeMode(.apple)
        try await settle()
        func mapIn(_ parent: NSView) -> MKMapView? {
            if let native = parent as? MKMapView { return native }
            return parent.subviews.lazy.compactMap { mapIn($0) }.first
        }
        guard let native = mapIn(view) else { throw DataError.invalid("Native map missing") }
        let identity = ObjectIdentifier(native)
        for index in 0..<9 {
            store.inspectorVisible = index.isMultiple(of: 2)
            store.panelVisible = index.isMultiple(of: 3)
            store.panelSize = MapPanelSize.allCases[index % 3]
            store.inspectorWidth = index.isMultiple(of: 2) ? 320 : 480
            store.uiScale = index.isMultiple(of: 2) ? 1.6 : 1
            try await settle()
            guard let current = mapIn(view), ObjectIdentifier(current) == identity,
                  abs(current.bounds.width - current.convert(current.bounds, to: nil).width) < 0.01 else {
                throw DataError.invalid("Panel change recreated or raster-scaled the map at \(index)")
            }
        }
        try check(true, "nine hide/resize/scale changes retain the same MKMapView at unit point scale")
        store.changeMode(.offline)

        // Use the real file watcher and a fresh model to test restart behavior.
        let map = RailwayMapStore(), gpt = AssistantStore()
        map.mapMode = .offline
        let url = directory.appendingPathComponent("panel-persistence.json")
        let configuration = ConfigurationStore(url: url)
        configuration.bind(map: map, assistant: gpt)
        map.panelSize = .small; map.panelVisible = false
        map.inspectorWidth = 460; map.inspectorVisible = true; map.inspectorPane = .feature
        try await Task.sleep(for: .milliseconds(600))
        var saved = try AtlasConfiguration.decode(Data(contentsOf: url))
        try check(saved.interface.panelSize == .small && !saved.interface.panelVisible
                  && saved.interface.inspectorWidth == 460 && saved.interface.inspectorVisible
                  && saved.interface.inspectorTab == "feature", "panel settings auto-save to config")
        saved.interface.panelSize = .large; saved.interface.inspectorTab = "feature"
        try saved.encoded().write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(600))
        try check(map.panelSize == .large && map.inspectorPane == .feature, "external atomic config edit updates panel state")
        let restored = RailwayMapStore(), restoredGPT = AssistantStore(), reload = ConfigurationStore(url: url)
        reload.bind(map: restored, assistant: restoredGPT)
        try check(restored.panelSize == .large && !restored.panelVisible && restored.inspectorVisible
                  && restored.inspectorWidth == 460 && restored.inspectorPane == .feature,
                  "fresh stores restore independent panel visibility, size, width and page")
        notes.append("Synthetic GPT conversation only; no GPT request. Window images require visual inspection.")
        try Data(notes.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("panels-qa.txt"))
    }
}
#endif
