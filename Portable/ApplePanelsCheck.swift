import AppKit
import MapKit
import RailwayCore
import SwiftUI
@testable import RailwayAtlas

@main @MainActor private enum ApplePanelsCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let check = PanelCheck(root: root)
            do { try await check.run(); check.note("PASS") }
            catch { check.note("FAIL \(error.localizedDescription)") }
            app.terminate(nil)
        }
        app.run()
    }
}

@MainActor private final class PanelCheck {
    let root: URL
    let map = RailwayMapStore()
    let assistant = AssistantStore()
    let configuration: ConfigurationStore
    let connectivity = Connectivity()
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: CGRect(x: 70, y: 70, width: 1200, height: 800),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    var lines: [String] = []
    var frames: [String: CGRect] = [:]
    init(root: URL) {
        self.root = root
        configuration = ConfigurationStore(url: root.appendingPathComponent("config.json"))
    }
    func note(_ message: String) {
        lines.append(message)
        try? (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("results.txt"),
                                                          atomically: true, encoding: .utf8)
    }
    func require(_ test: Bool, _ message: String) throws {
        if !test { throw DataError.invalid(message) }
    }
    func settle(_ milliseconds: Int = 180) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func mount(_ content: some View, width: CGFloat = 1200, height: CGFloat = 800) async {
        host.rootView = AnyView(content.environmentObject(map).environmentObject(assistant)
            .environmentObject(configuration).environmentObject(connectivity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.measureMapActions, true).coordinateSpace(name: "measured-map-controls")
            .onPreferenceChange(MapActionFrames.self) { [weak self] in self?.frames = $0 })
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(.init(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()
    }

    func run() async throws {
        try ConfigurationChecks.run()
        let template = URL(fileURLWithPath: CommandLine.arguments.last!)
        let defaults = try AtlasConfiguration.decode(Data(contentsOf: template))
        try require(defaults.interface.offlineLegendOpacity == 0, "offline legend default")
        let seeded = Data(#"{"map":{"mode":"offline"},"interface":{"cornerControlsOpacity":0.45,"topControlsOpacity":0.2}}"#.utf8)
        try seeded.write(to: configuration.url)
        configuration.bind(map: map, assistant: assistant)
        try require(!configuration.hasError && configuration.interfaceSettings.scaleOpacity == 0.45 &&
                    configuration.interfaceSettings.lineFocusOpacity == 0.2, "live config migration")
        for (index, control) in MapControl.allCases.enumerated() {
            configuration.interfaceSettings[keyPath: control.opacity] = Double(index + 1) / 20
        }
        map.panelBackgroundOpacity = 0.13
        map.inspectorBackgroundOpacity = 0.71
        configuration.saveNow()
        let saved = try AtlasConfiguration.decode(Data(contentsOf: configuration.url))
        for (index, control) in MapControl.allCases.enumerated() {
            try require(saved.interface[keyPath: control.opacity] == Double(index + 1) / 20,
                        "config file lost \(control.rawValue)")
        }
        try require(saved.interface.panelBackgroundOpacity == 0.13 && saved.interface.inspectorBackgroundOpacity == 0.71,
                    "two sidebar opacities")
        note("PASS configuration store migrated old values and saved \(MapControl.allCases.count) independent controls plus both panels.")
        try await surfaces()
        try await buttons()
    }

    func surfaces() async throws {
        // The reference has identical foreground content but no card, rim or inner fill.
        let foreground = Text("沪").font(.system(size: 26)).foregroundStyle(.black)
            .frame(width: 90, height: 55)
        func sample(_ view: some View) async throws -> Data {
            await mount(view.frame(width: 190, height: 110).background(Color.cyan), width: 190, height: 110)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DataError.invalid("bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DataError.invalid("PNG") }
            return data
        }
        let bare = try await sample(foreground)
        let withInnerFill = foreground.atlasPanelDecoration(.red, in: RoundedRectangle(cornerRadius: 8),
                                                           border: .secondary.opacity(0.3))
        for (mode, alpha) in [(AtlasSurfaceMode.textOnly, 1.0), (.glass, 0), (.translucent, 0)] {
            let actual = try await sample(withInnerFill.modifier(DesktopFloatingPanelSurface(opacity: alpha, surfaceMode: mode)))
            try require(actual == bare, "\(mode) \(alpha): extra panel/row paint or lost foreground")
        }
        let filled = try await sample(withInnerFill.modifier(DesktopFloatingPanelSurface(opacity: 1, surfaceMode: .translucent)))
        try require(filled != bare, "positive fill control vanished")
        for mode in [AtlasSurfaceMode.glass, .translucent, .textOnly] {
            await mount(withInnerFill.atlasMapSurface(mode: mode, opacity: 0.6, cornerRadius: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.teal), width: 390, height: 180)
            let capture = try await OnlineUIValidation.capture("surface-\(mode.rawValue)", directory: root, window: window)
            note("PASS mounted \(mode.rawValue) at 60%; capture \(capture.rawValue)")
        }
        note("PASS text-only, zero glass and zero material are pixel-identical to bare foreground; positive fill differs.")
    }

    func buttons() async throws {
        var openCount = 0
        await mount(MobileMapLauncher(title: "广元") { openCount += 1 }, width: 390, height: 110)
        try await press("collapse-map-launcher")
        try require(frames["map-open-sidebar"] == nil, "launcher did not collapse")
        try await press("restore-map-launcher")
        try await press("map-open-sidebar")
        try require(openCount == 1, "restored launcher action")
        note("PASS production iOS launcher at 390 pt: collapse, restore, open.")

        map.panelVisible = true; map.inspectorVisible = true
        map.panelLayout = .floating; map.inspectorLayout = .docked
        map.statusVisible = false
        map.selection = NationalDirectoryPins.byName["广元"].map(RailwayMapStore.item)
        map.focusDirectoryLine("陇海线", names: ["郑州", "洛阳"], fit: false)
        let focus = map.lineFocus?.revision, selected = map.selection?.id
        try require(focus != nil && selected != nil, "line and selection fixture")
        await mount(DesktopMapWorkspace())
        try await press("toggle-right-panel")
        try require(frames["right-panel-layout"] == nil && map.inspectorVisible &&
                    map.lineFocus?.revision == focus && map.selection?.id == selected, "closing right panel cleared line")
        try await press("toggle-right-panel")
        try require(frames["right-panel-layout"] != nil && map.lineFocus?.revision == focus, "restore right panel")
        try await press("collapse-left-panel")
        try require(frames["left-panel-layout"] == nil && map.panelVisible, "closing left panel changed preference")
        try await press("toggle-left-panel")
        try require(frames["left-panel-layout"] != nil, "restore left panel")
        for (collapse, restore, startupKey) in [
            ("collapse-map-top", "restore-map-top", \AtlasConfiguration.InterfaceSettings.topControlsVisible),
            ("collapse-map-footer", "restore-map-footer", \.bottomControlsVisible)
        ] {
            try await press(collapse)
            try require(frames[collapse] == nil && frames[restore] != nil && configuration.snapshot().interface[keyPath: startupKey],
                        "folding \(collapse) changed the startup preference or left the control open")
            try await press(restore)
            try require(frames[collapse] != nil && frames[restore] == nil, "failed to restore \(collapse)")
        }
        note("PASS actual desktop buttons: floating left, docked right, top and bottom restore with selection and focus intact.")

        let train = try RailExperienceCatalog.timetables()[0]
        let track = try RailTrackJourney.bundled().first { $0.train == train.train && $0.serviceDate == train.serviceDate }
        guard let track else { throw DataError.invalid("no bundled train track") }
        try map.journeyPlayer.start(train, route: track)
        await settle()
        try await press("collapse-map-player")
        let before = map.journeyPlayer.seconds
        await settle(400)
        try require(map.journeyPlayer.playing && map.journeyPlayer.seconds > before && frames["collapse-map-player"] == nil &&
                    configuration.snapshot().interface.experienceControlsVisible,
                    "folded train failed to advance")
        try await press("restore-map-player")
        try require(frames["collapse-map-player"] != nil && map.journeyPlayer.timetable?.train == train.train,
                    "restored different train")
        map.journeyPlayer.stop()
        guard var region = try RailHistoricalGeometry.bundled().first(where: { $0.id == "hongkong" }) else {
            throw DataError.invalid("no bundled Hong Kong history")
        }
        // The panel needs a few clock ticks. Keep the full region available for integration runs.
        if !CommandLine.arguments.contains("--full-history") {
            var dates = Set<String>()
            var sample: [RailDatedSegment] = []
            for segment in region.segments {
                guard let opened = segment.opened, dates.insert(RailDatedSegment.upperBound(opened)).inserted else { continue }
                sample.append(segment)
                if sample.count == 4 { break }
            }
            region.segments = sample
        }
        try require(region.dates.count >= 3, "not enough dates to exercise folded playback")
        map.journeyPlayer.start(region); map.journeyPlayer.play()
        await settle()
        try await press("collapse-map-player")
        let foldedIndex = map.journeyPlayer.historyIndex
        let foldedDate = map.journeyPlayer.date
        try require(frames["collapse-map-player"] == nil && frames["restore-map-player"] != nil &&
                    map.journeyPlayer.playing, "history player did not fold while playing")
        for _ in 0..<40 where map.journeyPlayer.historyIndex == foldedIndex { await settle(100) }
        let advancedIndex = map.journeyPlayer.historyIndex
        let advancedDate = map.journeyPlayer.date
        try require(advancedIndex > foldedIndex && advancedDate > foldedDate, "folded history failed to advance")
        try await press("restore-map-player")
        try require(frames["collapse-map-player"] != nil && frames["restore-map-player"] == nil &&
                    map.journeyPlayer.region?.id == region.id && map.journeyPlayer.historyIndex >= advancedIndex,
                    "restoring the history player lost its date or region")
        map.journeyPlayer.stop()
        configuration.saveNow()
        let persisted = try AtlasConfiguration.decode(Data(contentsOf: configuration.url)).interface
        try require(persisted.topControlsVisible && persisted.bottomControlsVisible && persisted.experienceControlsVisible,
                    "temporary collapse leaked into startup preferences")
        note("PASS \(train.train) clock advanced while folded. \(region.title) (\(region.segments.count) sections) advanced from \(foldedDate) to \(advancedDate) while folded. Both players restored.")
    }

    func press(_ name: String) async throws {
        for _ in 0..<6 {
            if let frame = frames[name], !frame.isEmpty {
                let p = CGPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
                let location = host.convert(p, to: nil)
                note("Click \(name) frame \(frame) at \(location) in \(host.bounds.size)")
                for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    window.sendEvent(event)
                    await settle(20)
                }
                await settle()
                return
            }
            await settle(100)
        }
        throw DataError.invalid("missing actionable control \(name)")
    }
}
