#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

@MainActor
enum ViewportValidation {
    static func urbanLifecycleCheck(store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        let fixture = try JSONDecoder().decode([RailLine].self, from: Data("""
        [
          {"id":"way/urban-construction","name":"规划地铁",
           "coordinates":[{"latitude":30.000,"longitude":106.000},{"latitude":30.010,"longitude":106.020}],
           "tags":{"railway":"construction","construction":"subway","service":"yard"},
           "routes":[{"id":"relation/9101","name":"一号线","tags":{"route":"subway","colour":"#FF0000"}},
                     {"id":"relation/9102","name":"二号线","tags":{"route":"subway","colour":"#0000FF"}}]},
          {"id":"way/urban-proposed","name":"规划轻轨",
           "coordinates":[{"latitude":30.002,"longitude":106.000},{"latitude":30.012,"longitude":106.020}],
           "tags":{"railway":"proposed","proposed":"light_rail"}},
          {"id":"way/rail-construction","name":"在建铁路",
           "coordinates":[{"latitude":29.998,"longitude":106.000},{"latitude":29.988,"longitude":106.020}],
           "tags":{"railway":"construction","construction":"rail"}}
        ]
        """.utf8))
        store.applyingConfiguration = true
        store.mapMode = .cached
        store.onlineLines = fixture
        store.onlineStations = []
        store.categories = Set(RailCategory.allCases)
        store.networks = Set(RailNetwork.allCases)
        store.forcedCategories = []
        store.forcedNetworks = []
        store.automaticDetail = false
        store.viewportWidth = 920
        store.viewportHeight = 700
        store.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 30.000, longitude: 106.010),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        store.rebuildIndex()
        store.applyingConfiguration = false
        store.rebuildVisible()

        let urban = store.renderGroups.filter(\.appearance.isUrbanLifecycle)
        let railway = store.renderGroups.filter {
            $0.appearance.category == .construction && !$0.appearance.isUrbanLifecycle
        }
        guard urban.count == 1, railway.count == 1,
              urban[0].lines.map(\.id).sorted() == ["way/urban-construction", "way/urban-proposed"],
              railway[0].lines.map(\.id) == ["way/rail-construction"] else {
            throw DataError.invalid("Map store lost the urban lifecycle marker while grouping construction lines")
        }
        let urbanStrokes = urban[0].appearance.strokes(zoom: store.displayZoom, settings: store.renderSettings)
        let railwayStrokes = railway[0].appearance.strokes(zoom: store.displayZoom, settings: store.renderSettings)
        guard urbanStrokes.map(\.color.hex) == ["#B7BEC5", "#F5F7F7"],
              railwayStrokes.first?.color.hex == "#BB8B3B" else {
            throw DataError.invalid("Prepared map styles did not keep grey-white urban dashes separate from yellow railway dashes")
        }

        let qaWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 720, height: 520),
                                styleMask: [.titled], backing: .buffered, defer: false)
        qaWindow.isReleasedWhenClosed = false
        qaWindow.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        qaWindow.makeKeyAndOrderFront(nil)
        defer { qaWindow.close() }
        try await Task.sleep(for: .milliseconds(600))
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(findMap).first
        }
        guard let map = qaWindow.contentView.flatMap(findMap) else {
            throw DataError.invalid("Native MapKit lifecycle check could not find its map view")
        }
        let overlays = map.overlays.compactMap { $0 as? MKMultiPolyline }
        let renderers = overlays.compactMap { map.renderer(for: $0) as? MKMultiPolylineRenderer }
        func hex(_ color: NSColor?) -> String? {
            guard let color = color?.usingColorSpace(.sRGB) else { return nil }
            return String(format: "#%02X%02X%02X",
                          Int((color.redComponent * 255).rounded()),
                          Int((color.greenComponent * 255).rounded()),
                          Int((color.blueComponent * 255).rounded()))
        }
        let rendererColors = renderers.compactMap { hex($0.strokeColor) }
        guard rendererColors.contains("#B7BEC5"), rendererColors.contains("#F5F7F7"),
              rendererColors.contains("#BB8B3B") else {
            throw DataError.invalid("MapKit renderer still did not receive grey-white urban and yellow railway construction colours")
        }
        var report = [
            "PASS source classifications: construction/subway and proposed/light_rail are urban lifecycle; construction/rail remains railway construction.",
            "PASS prepared styles: urban \(urbanStrokes.map(\.color.hex).joined(separator: " + ")) dashed; railway \(railwayStrokes.map(\.color.hex).joined(separator: " + ")) dashed.",
            "PASS MapKit renderer colours: \(rendererColors.joined(separator: ", "))."
        ]
        for (label, colors, brightness, hidden) in [
            ("colours off", false, 0.5, Set<String>()),
            ("depot brightness", true, 0.2, Set<String>()),
            ("hidden route direct appearance", false, 1.0, Set(["relation/9101"])),
            ("restore", true, 0.5, Set<String>())
        ] {
            store.showsMetroColors = colors
            store.renderSettings.depotBrightness = brightness
            store.hiddenRoutes = hidden
            try await Task.sleep(for: .milliseconds(250))
            guard store.visibleLines.count == fixture.count,
                  store.renderGroups.filter(\.appearance.isUrbanLifecycle).flatMap(\.lines).count == 2 else {
                throw DataError.invalid("Urban lifecycle grouping lost at \(label)")
            }
            let current = map.overlays.compactMap { $0 as? MKMultiPolyline }
                .compactMap { map.renderer(for: $0) as? MKMultiPolylineRenderer }
            guard current.compactMap({ hex($0.strokeColor) }).sorted() == ["#B7BEC5", "#BB8B3B", "#F5F7F7"],
                  current.allSatisfy({ $0.lineDashPattern?.map(\.doubleValue) == [7, 4] }) else {
                throw DataError.invalid("Native grey-white/yellow dashed distinction lost at \(label)")
            }
            report.append("PASS \(label): both urban dashes remain grey-white and railway dash remains yellow.")
        }
        if let host = qaWindow.contentView {
            _ = try RetinaUIValidation.capture(host, name: "urban-lifecycle-mapkit", directory: directory)
        }
        report.append("Isolated synthetic tracks; no user map files or railway/model API requests. MapKit's basemap can use system network/cache.")
        try Data((report.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("urban-lifecycle.txt"))
    }

    static func scaleCheck(store: RailwayMapStore, directory: URL, window: NSWindow?) async throws {
        let fixture = Data("""
        [
          {"id":"scale/main","name":"Main","tags":{"railway":"rail","maxspeed":"120"},
           "coordinates":[{"latitude":30,"longitude":106},{"latitude":30.00016,"longitude":106.002},{"latitude":30,"longitude":106.004}]},
          {"id":"scale/yard","name":"Siding","tags":{"railway":"rail","service":"siding"},
           "coordinates":[{"latitude":30.001,"longitude":106},{"latitude":30.001,"longitude":106.004}]}
        ]
        """.utf8)
        let lines = try JSONDecoder().decode([RailLine].self, from: fixture)
        store.applyingConfiguration = true
        store.mapMode = .cached
        store.onlineLines = lines; store.onlineStations = []
        store.categories = Set(RailCategory.allCases); store.networks = Set(RailNetwork.allCases)
        store.forcedCategories = []; store.forcedNetworks = []
        store.automaticDetail = true; store.selection = nil
        store.viewportWidth = 920; store.viewportHeight = 700
        store.rebuildIndex()
        store.applyingConfiguration = false
        func show(_ zoom: Double) {
            let span = 920 * 360 / (256 * exp2(zoom))
            store.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30, longitude: 106.002),
                span: MKCoordinateSpan(latitudeDelta: span * 0.75, longitudeDelta: span))
            store.rebuildVisible()
        }
        show(12.95)
        let initial = store.renderGroups.map(\.geometryToken)
        guard store.visibleLines.count == 1, store.clippedGeometry["scale/main"]?.first?.count == 2 else {
            throw DataError.invalid("Far view did not generalize the main line and hide the siding")
        }
        show(13.05) // This small zoom stays within the existing viewport buffer.
        guard store.renderGroups.map(\.geometryToken) != initial,
              store.clippedGeometry["scale/main"]?.first == lines[0].coordinates else {
            throw DataError.invalid("LOD threshold reused a stale Canvas/MapKit path")
        }
        let tokens = store.renderGroups.map(\.geometryToken)
        store.region.center.longitude += 0.0001; store.rebuildVisible()
        guard store.renderGroups.map(\.geometryToken) == tokens else {
            throw DataError.invalid("A small pan needlessly rebuilt generalized geometry")
        }
        show(16)
        guard store.visibleLines.count == 2 else { throw DataError.invalid("Near view did not restore the siding") }
        show(12.95)
        store.automaticDetail = false
        guard store.visibleLines.count == 2,
              store.clippedGeometry["scale/main"]?.first == lines[0].coordinates,
              store.activeLines[0].coordinates == lines[0].coordinates else {
            throw DataError.invalid("Manual detail or source geometry was lost")
        }
        try await checkNativeReuse(lines: lines, region: store.region)
        var report = [
            "PASS Z12.95 → Z13.05 rebuilds geometry inside the same buffer.",
            "PASS small pan preserves geometry tokens; Z16 restores sidings; manual detail restores source points.",
            "PASS native MapKit overlays reuse their objects across width changes and small pans."
        ]
        store.changeMode(.offline)
        guard var sample = store.dataset else { throw DataError.invalid("Missing local fixture container") }
        for name in ["jingkou-mixed", "jingkou-selected"] {
            let file = directory.appendingPathComponent("\(name).json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let lines = try JSONDecoder().decode([RailLine].self, from: Data(contentsOf: file))
            store.applyingConfiguration = true
            sample.lines = lines; sample.stations = []
            sample.name = "井口 · 比例尺回归"
            sample.bounds = MapBounds(south: 29.615, west: 106.425, north: 29.66, east: 106.475)
            store.dataset = sample
            store.automaticDetail = name == "jingkou-selected"
            store.panelVisible = false; store.inspectorVisible = false; store.statusVisible = false
            store.region = MapBounds(south: 29.615, west: 106.425, north: 29.66, east: 106.475).region
            store.rebuildIndex()
            store.applyingConfiguration = false
            store.rebuildVisible()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(400))
            guard !store.visibleLines.isEmpty else { throw DataError.invalid("Cache sample was not rendered") }
            try await OnlineUIValidation.capture(name, directory: directory, window: window)
            report.append("\(name): \(store.visibleLines.count) drawn parts; screenshot is an offline cache reconstruction.")
        }
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("scale-ui.txt"))
    }

    static func run(store: RailwayMapStore, directory: URL) async throws {
        let fixtureRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 50.5, longitude: 15),
                                              span: MKCoordinateSpan(latitudeDelta: 34, longitudeDelta: 55))
        let keys = RailTilePlan(bounds: MapBounds(region: fixtureRegion), width: 920).keys
        let cached = try await store.tileRepository.cached(keys, source: RailwayTileRepository.defaultSource)
        guard !cached.isEmpty else { throw DataError.invalid("Viewport benchmark requires Europe cache") }
        let tiles = Dictionary(cached.map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
        let (assembly, prepared, indexTime) = await Task.detached {
            let result = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                          ledger: RailIdentityLedger(), preview: nil)
            let start = Date()
            let prepared = PreparedMapData(lines: result.features.lines, stations: result.features.stations)
            return (result, prepared, Date().timeIntervalSince(start))
        }.value
        store.applyingConfiguration = true
        store.mapMode = .cached
        store.onlineLines = assembly.features.lines; store.onlineStations = assembly.features.stations
        store.renderSettings = RailRenderSettings()
        store.automaticDetail = true
        store.rebuildIndex(precomputed: prepared)
        store.applyingConfiguration = false
        var report = ["Loaded \(store.onlineLines.count) real European fragments; background index \(String(format: "%.3f", indexTime))s."]
        for (name, region) in [
            ("europe", fixtureRegion),
            ("paris", MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.35),
                                        span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.25)))
        ] {
            store.region = region
            var samples: [Double] = []
            var vertices = 0
            for _ in 0..<8 {
                let start = Date()
                store.rebuildVisible()
                samples.append(Date().timeIntervalSince(start))
            }
            let projection = RailProjection(region: region, size: CGSize(width: 920, height: 700))
            var path = Path()
            let start = Date()
            for line in store.visibleLines {
                if let first = line.coordinates.first { path.move(to: projection.screen(first)) }
                for point in line.coordinates.dropFirst() { path.addLine(to: projection.screen(point)) }
                vertices += line.coordinates.count
            }
            let drawing = Date().timeIntervalSince(start)
            let cachedStart = Date()
            let paths = store.renderGroups.map { Path($0.path).applying(projection.transform) }
            let cachedTime = Date().timeIntervalSince(cachedStart)
            guard !paths.isEmpty else { throw DataError.invalid("Cached paths are empty") }
            report.append(String(format: "%@: visible %d/%d fragments, %d vertices; visibility first %.4fs steady avg %.6fs; old per-frame path %.4fs cached path %.6fs.",
                                 name, store.visibleLines.count, store.activeLines.count, vertices,
                                 samples[0], samples.dropFirst().reduce(0,+) / 7, drawing, cachedTime))
            if name == "paris" {
                guard store.visibleLines.count < store.activeLines.count / 10 else { throw DataError.invalid("City view retained distant tracks") }
                let tokens = store.renderGroups.map(\.geometryToken), revision = store.renderRevision
                store.region.center.longitude += 0.01
                store.rebuildVisible()
                guard tokens == store.renderGroups.map(\.geometryToken), revision == store.renderRevision else {
                    throw DataError.invalid("Small pan rebuilt geometry inside the buffer")
                }
                store.region.center.longitude += 0.3
                let start = Date()
                store.rebuildVisible()
                guard revision < store.renderRevision, tokens != store.renderGroups.map(\.geometryToken) else {
                    throw DataError.invalid("Crossing the buffer did not replenish geometry")
                }
                report.append(String(format: "PASS buffer reuse and crossing: rebuild %.4fs.", Date().timeIntervalSince(start)))
                store.region = region
                store.renderSettings.viewportBuffer = 0
                let box = store.viewportBounds
                guard store.clippedGeometry.values.joined().joined().allSatisfy({
                    $0.longitude >= box.west - 1e-8 && $0.longitude <= box.east + 1e-8
                        && $0.latitude >= box.south - 1e-8 && $0.latitude <= box.north + 1e-8
                }) else { throw DataError.invalid("Geometry escaped a zero-buffer viewport") }
                store.renderSettings.viewportBuffer = 0.5
                let enlargedTokens = store.renderGroups.map(\.geometryToken)
                store.rebuildVisible()
                guard store.renderGroups.map(\.geometryToken) == enlargedTokens else {
                    throw DataError.invalid("50 percent buffer rebuilt stationary geometry")
                }
                store.renderSettings.viewportBuffer = 0.2
                report.append("PASS configurable buffer clips drawing geometry and retains original source metadata.")
            }
        }
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("viewport-performance.txt"))
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        try await OnlineUIValidation.capture("paris-viewport", directory: directory, window: window)
        var cities: [String] = []
        for (name, point, span) in [
            ("qingdao", Coordinate(36.10, 120.38), 0.28),
            ("jinan", Coordinate(36.67, 117.06), 0.36),
            ("tokyo", Coordinate(35.68, 139.77), 0.19)
        ] {
            let region = MKCoordinateRegion(center: point.location, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
            let keys = RailTile.covering(MapBounds(region: region), zoom: 10).map { RailTileKey(layer: .metroNetwork, tile: $0) }
            let tiles = Dictionary(keys.compactMap { key in BundledMetroSnapshots.features(for: key).map { (key, $0) } },
                                   uniquingKeysWith: { a, _ in a })
            let (assembly, prepared) = await Task.detached {
                let assembly = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                                             ledger: RailIdentityLedger(), preview: nil)
                return (assembly, PreparedMapData(lines: assembly.features.lines, stations: assembly.features.stations))
            }.value
            store.applyingConfiguration = true
            store.onlineLines = assembly.features.lines; store.onlineStations = assembly.features.stations
            store.region = region
            store.rebuildIndex(precomputed: prepared)
            store.applyingConfiguration = false
            store.rebuildVisible()
            guard store.urbanRoutes.contains(where: { $0.color != nil }) else { throw DataError.invalid("\(name) lacks real coloured routes") }
            let uncoloured = store.visibleLines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
            cities.append("\(name): \(store.visibleLines.count) visible ways; \(uncoloured.count) without known colour; \(store.visibleStations.count) stations.")
            cities += store.urbanRoutes.map { "\($0.visibilityKey) \($0.color?.hex ?? "?") \($0.name)" }
            store.selectedTab = 1
            try await OnlineUIValidation.capture("\(name)-snapshot", directory: directory, window: window)
            if let route = store.urbanRoutes.first(where: { $0.color != nil }) {
                store.hiddenRoutes.insert(route.visibilityKey)
                guard !store.visibleLines.contains(where: { ($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } }),
                      !store.visibleStations.contains(where: { ($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } }) else {
                    throw DataError.invalid("\(name) line switch failed")
                }
                store.hiddenRoutes = []
            }
        }
        try await checkNativeReuse(lines: store.onlineLines, region: store.region)
        cities.append("PASS native MapKit keeps the same overlay objects when width changes and while panning inside the buffer.")
        try Data(cities.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("city-snapshots.txt"))
    }

    private static func checkNativeReuse(lines: [RailLine], region: MKCoordinateRegion) async throws {
        let store = RailwayMapStore()
        store.mapMode = .cached // No live railway requests in this native-view check.
        store.region = region
        store.onlineLines = lines
        store.rebuildIndex(); store.rebuildVisible()
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(findMap).first
        }
        guard let map = window.contentView.flatMap(findMap) else { throw DataError.invalid("Native MapKit view missing") }
        func overlays() -> [ObjectIdentifier] { map.overlays.compactMap { ($0 as? MKMultiPolyline).map(ObjectIdentifier.init) } }
        let original = overlays()
        guard !original.isEmpty else { throw DataError.invalid("Native railway overlays missing") }
        store.renderSettings.metroWidthScale = 1.15
        try await Task.sleep(for: .milliseconds(100))
        guard overlays() == original else { throw DataError.invalid("Width change rebuilt native geometry") }
        store.region.center.longitude += 0.001
        store.rebuildVisible()
        store.cameraRevision += 1
        try await Task.sleep(for: .milliseconds(100))
        guard overlays() == original else { throw DataError.invalid("Buffered pan rebuilt native geometry") }
        var minimumVisible = Int.max
        for span in [0.18, 0.06, 0.22, 0.035, 0.14] {
            store.region.span = MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.35)
            store.rebuildVisible()
            store.cameraRevision += 1
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(12))
                minimumVisible = min(minimumVisible, overlays().count)
            }
            let expected = store.renderGroups.reduce(0) {
                $0 + $1.appearance.strokes(zoom: store.displayZoom, settings: store.renderSettings).count
            }
            try await Task.sleep(for: .milliseconds(180))
            guard overlays().count == expected else {
                throw DataError.invalid("Native handoff left \(overlays().count) overlays; expected \(expected)")
            }
        }
        guard minimumVisible > 0 else {
            throw DataError.invalid("Native handoff had a frame with no railway overlay")
        }
        print("PASS native scale handoff keeps at least \(minimumVisible) railway overlay(s) during every zoom transition and settles to one current generation.")
    }
}
#endif
