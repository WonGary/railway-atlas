#if os(macOS)
import AppKit
import Foundation
import MapKit
import RailwayCore
import ScreenCaptureKit
import SwiftUI

/// Explicit QA mode with an isolated cache. It never runs in a normal launch.
@MainActor
enum OnlineUIValidation {
    private static var started = false

    static func runIfRequested(store: RailwayMapStore, assistant: AssistantStore) async {
        let arguments = CommandLine.arguments
        guard !started, let index = arguments.firstIndex(of: "--ui-smoke"), arguments.count > index + 1 else { return }
        started = true
        // Keep the isolated stores available for interactive checks through the normal windows.
        if arguments.contains("--interactive-check") { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        var observations: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .seconds(1))
            let window = NSApp.windows.first { $0.contentView != nil && $0.isVisible }
            window?.setContentSize(NSSize(width: 1240, height: 820))
            window?.center()
            window?.title = "铁道图鉴 · 本地验证"
            if arguments.contains("--station-layout-check") {
                try await checkStationLayouts(store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--scale-check") {
                try await ViewportValidation.scaleCheck(store: store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--urban-lifecycle-check") {
                try await ViewportValidation.urbanLifecycleCheck(store: store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(ExperienceValidation.flag) {
                try await ExperienceValidation.run(directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(NationalMetroUIValidation.flag) {
                try await NationalMetroUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(InterchangeUIValidation.flag) {
                try await InterchangeUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(AssistantUIValidation.flag) {
                try await AssistantUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--assistant-personalization-check") {
                try await AssistantPersonalizationValidation.run(map: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains(PanelLayoutValidation.flag) {
                try await PanelLayoutValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v020-discovery-check") {
                try await SeriesUIValidation.discovery(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v020-check") {
                try await SeriesUIValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--panels-check") {
                try await PanelUIValidation.run(store: store, assistant: assistant, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--render-performance") {
                try await RenderPerformanceValidation.run(store: store, directory: directory)
                if arguments.contains("--expect-render-optimized") {
                    try await RenderPipelineValidation.run(store: store, directory: directory)
                }
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--beijing-check") {
                try await MetroCoverageValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--hongkong-check"), arguments.count > index + 1 {
                try await BorderUIValidation.inspectMacao(data: URL(fileURLWithPath: arguments[index + 1]), directory: directory,
                                                        hongKong: true, satellite: arguments.contains("--satellite-probe"))
                NSApp.terminate(nil)
                return
            }
            if let index = arguments.firstIndex(of: "--macao-check"), arguments.count > index + 1 {
                try await BorderUIValidation.inspectMacao(data: URL(fileURLWithPath: arguments[index + 1]), directory: directory,
                                                        satellite: arguments.contains("--satellite-probe"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--interface-check") {
                try await InterfaceValidation.run(directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--viewport-check") {
                try await ViewportValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--settings-check") {
                try await SettingsValidation.run(store: store, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--loading-check") {
                let notes = try await MetroLoadingValidation.run()
                try Data(notes.utf8).write(to: directory.appendingPathComponent("loading-qa.txt"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--retina-check") {
                try await RetinaUIValidation.run(store: store, window: window, directory: directory)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--border-check") {
                let notes = try await BorderUIValidation.run(repository: store.tileRepository, directory: directory)
                try Data(notes.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("border-ui.txt"))
                print(notes.joined(separator: "\n"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--v013-check") {
                try await renderingRevisionCheck(store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--metro-check") {
                store.changeMode(.cached)
                store.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.57, longitude: 127.01),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.24))
                store.cameraRevision += 1
                store.refreshViewport()
                try await settle(store, seconds: 30)
                try await waitAssembly(store)
                store.selectedTab = 1
                guard store.urbanRoutes.filter({ $0.color != nil }).count >= 10 else {
                    throw DataError.invalid("Seoul actual cached coloured routes missing")
                }
                try await capture("seoul-cache-colours", directory: directory, window: window)
                let rows = store.urbanRoutes.map { "\($0.visibilityKey): \($0.color?.hex ?? "unknown") · \($0.name)" }
                let note = "Seoul real cache, no network needed: \(store.urbanRoutes.count) line identities, \(store.onlineStations.count) independent station objects.\n" + rows.joined(separator: "\n")
                try Data(note.utf8).write(to: directory.appendingPathComponent("metro-qa.txt"))
                NSApp.terminate(nil)
                return
            }
            if arguments.contains("--revision-check") {
                try await revisionCheck(store, directory: directory, window: window)
                NSApp.terminate(nil)
                return
            }
            store.fitDataset()
            try await settle(store, seconds: 150)
            try await capture("01-national-online", directory: directory, window: window)
            guard store.onlineLines.count > 1000 else { throw DataError.invalid("Nationwide map did not load: \(store.onlineStatus)") }
            observations.append("National view: \(store.onlineLines.count) fragments; \(store.tilesReady)/\(store.tilesExpected) tiles; \(store.failedTiles) failures.")

            for name in ["北京", "广州"] {
                store.goTo(AtlasPlace.presets.first { $0.name == name }!)
                if store.mapMode != .apple { store.changeMode(.apple) }
                try await settle(store, seconds: 150)
                try await capture(name == "北京" ? "02-beijing-online" : "03-guangzhou-online", directory: directory, window: window)
                guard store.onlineLines.contains(where: { $0.category == .urban }) else {
                    throw DataError.invalid("\(name) urban tracks did not load")
                }
                guard store.urbanRoutes.count >= 2 else {
                    throw DataError.invalid("\(name) route colours did not load; a grey metro map is not a colour-test pass")
                }
                observations.append("\(name): \(store.onlineLines.count) fragments, \(store.onlineStations.count) stations, \(store.urbanRoutes.count) coloured routes; \(store.tilesReady)/\(store.tilesExpected) tiles.")
                store.selectedTab = 1
                store.changeMode(.cached)
                try await settle(store, seconds: 10)
                try await capture(name == "北京" ? "02b-beijing-cached-colours" : "03b-guangzhou-cached-colours",
                                  directory: directory, window: window)
                guard store.renderGroups.contains(where: { !$0.appearance.colors.isEmpty }) else {
                    throw DataError.invalid("Cached metro colours were lost")
                }
            }
            store.selectedTab = 1
            store.networks = [.metro]
            store.showsStations = false
            store.showsLabels = false
            guard !store.visibleLines.isEmpty, store.visibleLines.allSatisfy({ RailNetwork.classify($0.tags) == .metro }),
                  store.visibleStations.isEmpty else { throw DataError.invalid("Network/station filters failed") }
            try await Task.sleep(for: .seconds(1))
            try await capture("04-metro-filter", directory: directory, window: window)
            observations.append("Metro-only filter excludes railways and station markers.")
            store.showsMetroColors = false
            guard store.renderGroups.allSatisfy({ $0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("Metro colour toggle failed")
            }
            store.showsMetroColors = true
            guard store.renderGroups.contains(where: { !$0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("Metro colours were not restored")
            }
            observations.append("Beijing/Guangzhou coloured metro geometry survives cache reload and colour toggle.")

            store.networks = Set(RailNetwork.allCases)
            store.showsStations = true
            store.showsLabels = true
            store.selectedTab = 2
            store.changeMode(.cached)
            try await settle(store, seconds: 10)
            guard !store.onlineLines.isEmpty, !store.onlineLoading else { throw DataError.invalid("Offline cache reload failed") }
            try await capture("05-cached-offline", directory: directory, window: window)
            observations.append("Cached mode reloaded \(store.onlineLines.count) fragments.")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(500))
            try await capture("06-dark-cache", directory: directory, window: window)

            let database = directory.appendingPathComponent("Nationwide-and-cities.railcache")
            try await store.tileRepository.exportCache(to: database)
            let report = "UI smoke passed (network completeness recorded below):\n" + observations.joined(separator: "\n")
                + "\nScreenshots still require visual inspection. The cache covers these views and zooms, not every level of China.\n"
            try Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"), options: .atomic)
            print(report)
            NSApp.terminate(nil)
        } catch {
            let report = "UI smoke FAILED: \(error.localizedDescription)\n" + observations.joined(separator: "\n")
                + "\n" + store.sourceStates.map { "\($0.name): \($0.status)" }.joined(separator: "\n")
                + "\n" + (store.onlineError ?? "")
            try? Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"), options: .atomic)
            print(report)
            exit(1)
        }
    }

    private static func checkStationLayouts(_ store: RailwayMapStore, directory: URL) async throws {
        let western = Coordinate(39.8935,116.3151), metro = Coordinate(39.9403,116.3491)
        store.showsStationLayouts = true
        store.showsStations = true
        store.historyMapActive = false
        store.networks = Set(RailNetwork.allCases)
        store.categories = Set(RailCategory.allCases)
        let window = NSWindow(contentRect: CGRect(x: 100,y: 100,width: 1000,height: 690),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Use real Apple/Canvas renderers with the offline QA store to isolate the geometry from live track providers.
        store.mapMode = .offline
        store.viewportWidth = 1000
        store.viewportHeight = 690
        window.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        func findMap(_ v: NSView) -> MKMapView? {
            if let map = v as? MKMapView { return map }
            return v.subviews.lazy.compactMap(findMap).first
        }
        guard let map = window.contentView.flatMap(findMap), let coordinator = map.delegate as? AppleRailwayMap.Coordinator else {
            throw DataError.invalid("Missing native map")
        }
        func focus(_ p: Coordinate, _ z: Double) async throws {
            let width = store.viewportWidth * 360 / (256 * exp2(z+0.1))
            store.region = MKCoordinateRegion(center: p.location, span: .init(latitudeDelta: width*0.53, longitudeDelta: width))
            store.cameraRevision += 1
            store.rebuildVisible()
            try await Task.sleep(for: .milliseconds(120))
            map.setRegion(store.displayRegion, animated: false)
            try await Task.sleep(for: .milliseconds(900))
            guard abs(RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width) - z) < 0.6 else {
                throw DataError.invalid("MapKit camera did not settle at Z\(z)")
            }
        }
        func counts() -> [Int] { StationLayoutKind.allCases.map { coordinator.overlays(for: $0).count } }
        func require(_ ok: Bool, _ label: String) throws {
            if !ok { throw DataError.invalid("\(label) Z\(store.displayZoom): \(counts())") }
        }
        try await focus(western,13)
        try require(counts() == [0,0,0], "Z13")
        try await focus(western,16)
        try require(counts() == [1,0,0], "Beijing West outline")
        try await focus(western,17)
        let west = counts()
        try require(west == [1,10,0], "Beijing West platforms")
        try require(coordinator.overlays(for: .platform).allSatisfy { $0 is MKPolygon }, "Platform polygons")
        _ = try await capture("beijing-west-z17", directory: directory, window: window)
        try await focus(metro,18)
        let xizhimen = counts()
        try require(xizhimen.allSatisfy { $0 > 0 }, "Xizhimen passenger passages")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(320))
        _ = try await capture("xizhimen-z18-dark", directory: directory, window: window)
        store.showsStationLayouts = false
        try await Task.sleep(for: .milliseconds(150))
        try require(counts() == [0,0,0], "Hidden detail layer")
        store.showsStationLayouts = true
        store.showsStations = false
        try await Task.sleep(for: .milliseconds(150))
        try require(counts() == [0,0,0], "Hidden stations")
        store.showsStations = true
        window.contentView = NSHostingView(rootView: OfflineRailwayMap().environmentObject(store))
        try await Task.sleep(for: .milliseconds(400))
        _ = try await capture("xizhimen-z18-offline", directory: directory, window: window)
        try "Z13 0; Beijing West Z17 \(west); Xizhimen Z18 \(xizhimen); both visibility switches passed; Apple and offline renders captured."
            .write(to: directory.appendingPathComponent("station-layout-check.txt"), atomically: true, encoding: .utf8)
    }

    private static func renderingRevisionCheck(_ store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        var notes: [String] = []
        store.changeMode(.cached)
        store.goTo(AtlasPlace.presets.first { $0.name == "欧洲" }!)
        try await settle(store, seconds: 30)
        try await waitAssembly(store)
        guard store.visibleLines.count > 1000 else {
            throw DataError.invalid("European actual map data missing: \(store.visibleLines.count), \(store.onlineStatus), \(store.onlineError ?? ""), \(store.region)")
        }
        guard store.renderGroups.allSatisfy({ $0.appearance.strokes(zoom: store.displayZoom).allSatisfy { $0.width < 1.3 } }),
              !store.categoryVisible(.branch), !store.categoryVisible(.urban) else {
            throw DataError.invalid("European scale detail policy failed")
        }
        notes.append("Europe actual cached geometry: \(store.visibleLines.count) visible fragments, Z\(String(format: "%.1f", store.displayZoom)); narrow continent strokes, automatic secondary/metro suppression.")
        store.selectedTab = 1
        store.statusOffset = .zero
        store.basemapDarkness = 0.3
        try await capture("01-europe-light", directory: directory, window: window)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(400))
        try await capture("02-europe-dark", directory: directory, window: window)
        store.uiScale = 1.25
        store.panelWidth = 360
        store.statusOffset = CGSize(width: -180, height: 130)
        try await Task.sleep(for: .seconds(1))
        try await capture("03-europe-scaled-panel", directory: directory, window: window)
        store.panelVisible = false; store.statusVisible = false
        try await Task.sleep(for: .seconds(1))
        try await capture("04-europe-unobstructed", directory: directory, window: window)
        notes.append("UI at 125%, panel width 360, status moved and hidden, sidebar hidden; screenshots require visual review.")
        store.uiScale = 1; store.panelVisible = true; store.panelWidth = 320
        store.statusVisible = true; store.statusOffset = .zero
        NSApp.appearance = NSAppearance(named: .aqua)
        store.goTo(AtlasPlace.presets.first { $0.name == "南昌" }!)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        guard store.urbanRoutes.filter({ $0.color != nil }).count >= 4 else { throw DataError.invalid("Nanchang palette missing") }
        let before = Dictionary(store.urbanRoutes.map { ($0.visibilityKey, $0.color?.hex ?? "") }, uniquingKeysWith: { a, _ in a })
        store.zoom(0.65)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        let changed = store.urbanRoutes.filter { before[$0.visibilityKey] != nil && before[$0.visibilityKey] != $0.color?.hex }
        guard changed.isEmpty else { throw DataError.invalid("Line palette changed on zoom") }
        store.zoom(1 / 0.65)
        try await settle(store, seconds: 15)
        try await waitAssembly(store)
        try await capture("05-nanchang-consistent", directory: directory, window: window)
        notes.append("Nanchang known line colours unchanged across zoom-in/out; detail visibility independent from palette.")
        let assistant = AssistantStore()
        assistant.scope = .region; assistant.prepare(map: store)
        guard assistant.context.contains("bounds"), assistant.context.contains("loaded_segment_count") else { throw DataError.invalid("Region GPT context missing") }
        if let line = store.visibleLines.first {
            store.selection = RailwayMapStore.item(line)
            assistant.scope = .feature; assistant.prepare(map: store)
            let payload = try JSONSerialization.jsonObject(with: Data(assistant.context.utf8)) as? [String: Any]
            guard (payload?["feature"] as? [String: Any])?["id"] as? String == line.id else {
                throw DataError.invalid("Feature GPT context missing")
            }
        }
        guard let route = store.assistantRoutes.first else { throw DataError.invalid("Route GPT selection missing") }
        assistant.scope = .route; assistant.routeKey = route.id; assistant.prepare(map: store)
        guard assistant.context.contains("segments") else { throw DataError.invalid("Route GPT context missing") }
        notes.append("GPT context: selected feature, viewport, and named/related railway route verified without a paid API call.")
        let assistantWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 720, height: 820),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        let assistantView = NSHostingView(rootView: AtlasInterface(scale: store.uiScale) {
            AtlasAssistantView()
        }.environmentObject(store).environmentObject(assistant)
            .background(Color(nsColor: .windowBackgroundColor)))
        assistantWindow.contentView = assistantView
        assistantWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1))
        _ = try RetinaUIValidation.capture(assistantView, name: "06-gpt-context", directory: directory)
        guard assistantWindow.isVisible, store.inspectorPane == .feature else {
            throw DataError.invalid("GPT window opened without preserving the feature inspector")
        }
        assistantWindow.orderOut(nil)
        try await Task.sleep(for: .milliseconds(400))
        store.showSettings = true
        try await Task.sleep(for: .seconds(1))
        try await capture("07-settings", directory: directory, window: window)
        store.showSettings = false
        store.selection = nil
        store.basemapStyle = .satellite
        store.changeMode(.apple)
        // Test MapKit's actual satellite provider; no imagery is saved to the
        // RailwayAtlas SQLite database. This file is an explicit QA snapshot.
        let options = MKMapSnapshotter.Options()
        options.region = store.displayRegion
        options.mapType = .satellite
        options.size = CGSize(width: 1200, height: 800)
        let snapshotter = MKMapSnapshotter(options: options)
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(45))
            snapshotter.cancel()
        }
        defer { timeout.cancel() }
        do {
            let snapshot = try await snapshotter.start()
            if let tiff = snapshot.image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("08-satellite-provider.png"))
            }
            notes.append("MapKit satellite snapshot request succeeded; screenshot must be checked for actual imagery.")
        } catch { notes.append("Satellite provider snapshot unavailable: \(error.localizedDescription)") }
        store.changeMode(.cached)
        let report = notes.joined(separator: "\n")
        try Data(report.utf8).write(to: directory.appendingPathComponent("v013-ui.txt"))
        print(report)
    }

    private static func waitAssembly(_ store: RailwayMapStore) async throws {
        for _ in 0..<100 {
            if store.assemblyTask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.assemblyTask == nil else { throw DataError.invalid("Map assembly failed to settle") }
        try await Task.sleep(for: .milliseconds(600))
    }

    private static func revisionCheck(_ store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        let started = Date()
        store.goTo(AtlasPlace.presets.first { $0.name == "南昌" }!)
        if let index = CommandLine.arguments.firstIndex(of: "--saved-metro"),
           CommandLine.arguments.count > index + 1 {
            // Explicit, deterministic rendering QA with previously fetched
            // real OSM data; never reported as a live-network success.
            store.viewportWork?.cancel()
            store.viewportGeneration = UUID()
            store.mapMode = .offline
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            var saved = try RailwayCodec.decodeOverpass(data, bounds: MapBounds(south: 28.3, west: 115.5, north: 29.0, east: 116.3),
                                                       name: "南昌 · 实际 OSM 整线数据", sourceURL: DataEndpoint.vk.rawValue)
            saved.stations = try MetroRouteDecoder.decode(data).stations
            store.dataset = saved
            store.onlineLoading = false
            store.rebuildIndex()
            store.rebuildVisible()
        }
        var firstTrack: Double?, firstColour: Double?
        for _ in 0..<160 {
            try await Task.sleep(for: .milliseconds(500))
            if firstTrack == nil && store.activeLines.count > 100 { firstTrack = Date().timeIntervalSince(started) }
            if firstColour == nil && store.urbanRoutes.filter({ $0.color != nil }).count >= 4 {
                firstColour = Date().timeIntervalSince(started)
            }
            if !store.onlineLoading { break }
        }
        let isSaved = CommandLine.arguments.contains("--saved-metro")
        var notes = ["Nanchang \(isSaved ? "saved real geometry (not live)" : "live"): first tracks \(firstTrack.map { String(format: "%.1fs", $0) } ?? "unavailable"), first 4 coloured lines \(firstColour.map { String(format: "%.1fs", $0) } ?? "unavailable").",
                     "Viewport \(store.tilesReady)/\(store.tilesExpected), \(store.onlineStations.count) station objects, \(store.onlineError ?? "no error")."]
        let missing = store.activeLines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
        notes.append("Urban segments without a known colour: \(missing.count); names: \(Set(missing.map(\.name)).sorted().prefix(12).joined(separator: ", ")).")
        store.selectedTab = 1
        store.dimsBasemap = true
        try await Task.sleep(for: .seconds(1))
        try await capture("01-nanchang-apple-dimmed", directory: directory, window: window)
        guard firstColour != nil else { throw DataError.invalid(notes.joined(separator: "\n")) }
        let p = Coordinate(28.6266186, 115.7882702)
        guard MapAlignment.distance(p, store.alignment.display(p)) > 500 else {
            throw DataError.invalid("Bundled coordinate mask did not load")
        }
        if !isSaved {
            store.changeMode(.cached)
            try await settle(store, seconds: 10)
        }
        try await capture("02-nanchang-cache-colours", directory: directory, window: window)
        guard let route = store.urbanRoutes.first else { throw DataError.invalid("No cached routes") }
        let before = store.visibleLines.count
        store.hiddenRoutes.insert(route.visibilityKey)
        guard store.visibleLines.count < before,
              store.visibleLines.allSatisfy({ !($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } }) else {
            throw DataError.invalid("Per-route switch did not hide route geometry")
        }
        notes.append("Per-route switch removed \(before - store.visibleLines.count) fragments; no visible fragment retains hidden line.")
        try await capture("03-single-line-hidden", directory: directory, window: window)
        store.hiddenRoutes = []
        store.categories.remove(.speed350)
        guard !store.visibleLines.contains(where: { $0.category == .speed350 }) else { throw DataError.invalid("Speed switch failed") }
        store.categories = Set(RailCategory.allCases)
        store.showsMetroColors = false
        guard store.renderGroups.allSatisfy({ $0.appearance.colors.isEmpty }) else { throw DataError.invalid("Colour switch failed") }
        store.showsMetroColors = true
        if isSaved {
            store.region.span.latitudeDelta *= 0.3
            store.region.span.longitudeDelta *= 0.3
        } else {
            store.zoom(0.3)
            try await settle(store, seconds: 10)
        }
        try await capture("04-close-stations", directory: directory, window: window)
        if let line = store.visibleLines.first(where: { $0.tags["operator"] != nil }) {
            store.selection = RailwayMapStore.item(line)
            try await Task.sleep(for: .milliseconds(300))
            try await capture("05-metadata", directory: directory, window: window)
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(300))
        try await capture("06-dark", directory: directory, window: window)
        try await store.tileRepository.exportCache(to: directory.appendingPathComponent("Nanchang.railcache"))
        notes.append("Speed, colour, cached mode and bundled alignment checks passed. MapKit Metal capture requires permission; cached Canvas screenshots are available.")
        let report = notes.joined(separator: "\n")
        try Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"))
        print(report)
    }

    private static func settle(_ store: RailwayMapStore, seconds: Int) async throws {
        try await Task.sleep(for: .seconds(2))
        for _ in 0..<seconds {
            if !store.onlineLoading && !store.metroLoading { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DataError.invalid("Viewport loading exceeded QA deadline: \(store.onlineStatus)")
    }

    enum CaptureMethod: String {
        case compositor
        case viewSnapshot
    }

    @discardableResult
    static func capture(_ name: String, directory: URL, window: NSWindow?) async throws -> CaptureMethod {
        let window = window?.attachedSheet ?? window
        // Metal-backed MapKit cannot be captured by NSView.cacheDisplay.
        // Current-process capture is explicitly available without screen-recording
        // consent. It captures only this app, including live glass composition.
        if let window {
            let content: SCShareableContent?
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.currentProcess
            } else if CGPreflightScreenCaptureAccess() {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            } else {
                content = nil
            }
            if let target = content?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(target.frame.width * window.backingScaleFactor)
                configuration.height = Int(target.frame.height * window.backingScaleFactor)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("\(name).png"))
                    return .compositor
                }
            }
        }
        guard let view = window?.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DataError.invalid("No visible app window")
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw DataError.invalid("Window capture failed")
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return .viewSnapshot
    }
}
#endif
