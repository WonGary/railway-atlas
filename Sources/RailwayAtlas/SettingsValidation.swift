#if os(macOS)
import AppKit
import RailwayCore
import SwiftUI

@MainActor
enum SettingsValidation {
    static func run(store original: RailwayMapStore, directory: URL) async throws {
        let map = RailwayMapStore(), assistant = AssistantStore()
        map.mapMode = .offline
        map.dataset = original.dataset
        map.region = original.region
        map.rebuildIndex(); map.rebuildVisible()
        // Verify the actual store invalidates its cached visibility state, not
        // just the core predicate, when the additive priority changes.
        map.automaticDetail = false
        map.categories = []; map.networks = []
        guard map.visibleLines.isEmpty else { throw DataError.invalid("Disabled class filters still show lines") }
        map.prioritizesUrbanTransit = true
        guard !map.visibleLines.isEmpty, map.visibleLines.allSatisfy(\.isUrbanTransit),
              map.categories.isEmpty, map.networks.isEmpty else {
            throw DataError.invalid("Urban priority did not update the actual map independently of saved filters")
        }
        map.prioritizesUrbanTransit = false
        guard map.visibleLines.isEmpty else { throw DataError.invalid("Turning priority off did not restore individual filters") }
        map.automaticDetail = true
        map.categories = Set(RailCategory.allCases); map.networks = Set(RailNetwork.allCases)
        let url = directory.appendingPathComponent("settings-fixture.json")
        let config = ConfigurationStore(url: url)
        config.bind(map: map, assistant: assistant)
        map.renderSettings.stationRadiusMultiplier = 1.5
        map.categories = [.speed350, .speed300]
        map.showsNationalMetroOverview = false
        map.prioritizesUrbanTransit = true
        map.hiddenRoutes = ["metro:seoul:2"]
        assistant.settings.webSearch = true
        try await Task.sleep(for: .milliseconds(650))
        let saved = try AtlasConfiguration.decode(Data(contentsOf: url))
        guard saved.rendering.stationRadiusMultiplier == 1.5, saved.assistant.webSearch,
              saved.layers.categories.count == 2, saved.layers.hiddenRoutes == ["metro:seoul:2"],
              !saved.layers.showsNationalMetroOverview, saved.layers.prioritizesUrbanTransit else {
            throw DataError.invalid("Settings did not auto-save UI state")
        }
        var external = saved
        external.rendering.stationRadiusMultiplier = 1.25
        external.rendering.metroWidthScale = 0.8
        external.layers.categories = RailCategory.allCases.map(\.rawValue)
        external.layers.hiddenRoutes = []
        external.layers.showsNationalMetroOverview = true
        external.layers.prioritizesUrbanTransit = false
        external.assistant.webSearch = false
        try external.encoded().write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(650))
        guard map.renderSettings.stationRadiusMultiplier == 1.25, map.renderSettings.metroWidthScale == 0.8,
              map.categories.count == RailCategory.allCases.count, map.showsNationalMetroOverview,
              !map.prioritizesUrbanTransit, !assistant.settings.webSearch else {
            throw DataError.invalid("External atomic save did not apply via file watcher")
        }
        let invalid = Data(#"{"rendering":{"stationRadiusMultiplier":-1}}"#.utf8)
        try invalid.write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        map.showsLabels = false
        try await Task.sleep(for: .milliseconds(500))
        guard config.hasError, map.renderSettings.stationRadiusMultiplier == 1.25,
              try Data(contentsOf: url) == invalid else {
            throw DataError.invalid("Invalid configuration was applied or overwritten")
        }
        try external.encoded().write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        guard !config.hasError, map.showsLabels else { throw DataError.invalid("Configuration did not recover after repair") }
        let restored = RailwayMapStore(), restoredAssistant = AssistantStore(), reload = ConfigurationStore(url: url)
        reload.bind(map: restored, assistant: restoredAssistant)
        guard restored.renderSettings == map.renderSettings, restored.categories == map.categories,
              restored.showsNationalMetroOverview == map.showsNationalMetroOverview,
              restored.prioritizesUrbanTransit == map.prioritizesUrbanTransit,
              restoredAssistant.settings.webSearch == assistant.settings.webSearch else {
            throw DataError.invalid("Config launch restore failed")
        }
        map.uiScale = 1
        for page in AtlasSettingsView.Page.allCases {
            let content = NSHostingView(rootView: AtlasSettingsView(initialPage: page)
                .environmentObject(map).environmentObject(assistant).environmentObject(config)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 620, height: 680),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw DataError.invalid("Settings snapshot failed") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-\(page.rawValue).png"))
            window.orderOut(nil)
        }
        let reply = try AtlasAssistantClient.reply(Data("""
        {"output":[{"type":"web_search_call","status":"completed"},
         {"type":"message","content":[{"type":"output_text","text":"## 铁路资料\\n这是用于界面验证的模拟回答。\\n\\n- 地图字段来自 OSM。\\n- 联网引用单独列在下方。",
         "annotations":[{"type":"url_citation","url":"https://www.openstreetmap.org","title":"OpenStreetMap · 测试来源"}]}]}]}
        """.utf8), apiProtocol: .responses)
        assistant.settings.model = "界面测试"
        assistant.settings.webSearch = true
        assistant.turns = [AssistantTurn(role: "assistant", text: reply.text, citations: reply.citations, searchRequested: true, searched: reply.searched)]
        let answerView = NSHostingView(rootView: AtlasAssistantView().environmentObject(map)
            .environmentObject(assistant).background(Color(nsColor: .windowBackgroundColor)))
        let answerWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 650, height: 650),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        answerWindow.contentView = answerView
        answerWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        if let bitmap = answerView.bitmapImageRepForCachingDisplay(in: answerView.bounds) {
            answerView.cacheDisplay(in: answerView.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("gpt-search-citations.png"))
        }
        answerWindow.orderOut(nil)
        // Capture the expanded network section as part of the real controls,
        // including its position after speed/purpose and before individual modes.
        map.prioritizesUrbanTransit = true
        map.urbanRoutes = []
        let layersView = NSHostingView(rootView: AtlasInterface(scale: 1) {
            LayerControlsContent(compactLabels: true)
                .padding(16).frame(width: 380, alignment: .topLeading)
        }.environmentObject(map).environment(\.colorScheme, .light).tint(.railwayAccent).background(Color.white))
        let layersWindow = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 380, height: 2300),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        layersWindow.isReleasedWhenClosed = false
        layersWindow.contentView = layersView
        layersWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        layersView.layoutSubtreeIfNeeded()
        _ = try RetinaUIValidation.capture(layersView, name: "urban-priority-controls", directory: directory)
        layersWindow.close()
        let report = """
        Actual map store: urban priority changes cached visibility without mutating individual filters; off restores them.
        UI settings persist to JSON, including drawing ratio, category filters, hidden line and web search.
        Atomic external edits apply automatically; invalid config keeps runtime state and is never overwritten.
        Fixing the file restores automatic sync. New stores restore the saved configuration.
        Five native settings pages captured at the screen's backing resolution; visual review required.
        GPT search switch, completed-search indicator and source link captured with a synthetic API response.
        No paid API request; user config/cache untouched.
        """
        try Data(report.utf8).write(to: directory.appendingPathComponent("settings-qa.txt"))
    }
}
#endif
