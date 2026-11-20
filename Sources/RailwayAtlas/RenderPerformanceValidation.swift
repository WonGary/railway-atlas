#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

/// Replays the same real Tokyo data in both builds. No public railway service,
/// user cache, API key or paid request is involved.
@MainActor
enum RenderPerformanceValidation {
    static func run(store: RailwayMapStore, directory: URL) async throws {
        let verify = CommandLine.arguments.contains("--expect-render-optimized")
        let centre = Coordinate(35.68, 139.77)
        let bounds = MapBounds(south: 35.3, west: 139.2, north: 36.05, east: 140.2)
        let (tiles, result, prepared, elapsed) = await Task.detached {
            let tiles = Dictionary(RailTile.covering(bounds, zoom: 10).compactMap { tile -> (RailTileKey, RailTileFeatures)? in
                let key = RailTileKey(layer: .metroNetwork, tile: tile)
                return BundledMetroSnapshots.features(for: key).map { (key, $0) }
            }, uniquingKeysWith: { a, _ in a })
            let start = Date()
            let result = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                                       ledger: RailIdentityLedger(), preview: nil)
            let prepared = PreparedMapData(lines: result.features.lines, stations: result.features.stations)
            return (tiles, result, prepared, Date().timeIntervalSince(start))
        }.value
        guard result.features.lines.count > 1000 else { throw DataError.invalid("Tokyo fixture incomplete") }
        store.enrichWikiColours = false
        store.applyingConfiguration = true
        store.mapMode = .cached
        store.tileFeatures = tiles
        store.onlineLines = result.features.lines
        store.onlineStations = result.features.stations
        store.region = MKCoordinateRegion(center: centre.location, span: .init(latitudeDelta: 0.16, longitudeDelta: 0.22))
        store.rebuildIndex(precomputed: prepared)
        store.applyingConfiguration = false
        let start = Date()
        store.rebuildVisible()
        var report = [String(format: "Tokyo: %d fragments, %d station objects; background assemble/index %.3fs; visible build %.4fs.",
                             result.features.lines.count, result.features.stations.count, elapsed, Date().timeIntervalSince(start))]

        // This was synchronous UI-thread work in build 7, even if no route
        // could be matched. Measure the actual public store entry point.
        let paletteStart = Date()
        store.loadPaletteIfNeeded()
        report.append(String(format: "Main-thread palette scheduling: %.6fs.", Date().timeIntervalSince(paletteStart)))
        try await settle(store)
        let tokens = store.renderGroups.map(\.geometryToken)
        let rebuildStart = Date()
        store.onlineLines = result.features.lines
        store.onlineStations = result.features.stations
        store.rebuildIndex(precomputed: prepared)
        store.rebuildVisible()
        let retained = Set(tokens).intersection(store.renderGroups.map(\.geometryToken)).count
        report.append(String(format: "Identical data refresh: %.6fs; retained geometry groups %d/%d.",
                             Date().timeIntervalSince(rebuildStart), retained, tokens.count))
        if verify, retained != tokens.count { throw DataError.invalid("Unchanged data replaced geometry") }

        let native = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        native.makeKeyAndOrderFront(nil)
        defer { native.close() }
        try await Task.sleep(for: .seconds(1))
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(findMap).first
        }
        guard let map = native.contentView.flatMap(findMap),
              let coordinator = map.delegate as? AppleRailwayMap.Coordinator else {
            throw DataError.invalid("Native map unavailable")
        }
        func overlays() -> [ObjectIdentifier] {
            map.overlays.compactMap { ($0 as? MKMultiPolyline).map(ObjectIdentifier.init) }
        }
        let nativeIDs = overlays()
        store.rebuildIndex(precomputed: prepared)
        store.rebuildVisible()
        try await Task.sleep(for: .milliseconds(150))
        report.append("Native overlay retention on identical response: \(Set(nativeIDs).intersection(overlays()).count)/\(nativeIDs.count).")
        if verify, nativeIDs != overlays() { throw DataError.invalid("Identical response replaced native overlays") }

        var pan: [Double] = [], labels: [Double] = []
        let stableTokens = store.renderGroups.map(\.geometryToken)
        for _ in 0..<30 {
            let before = Date()
            store.region.center.longitude += 0.00001
            store.rebuildVisible()
            pan.append(Date().timeIntervalSince(before))
            let labelStart = Date()
            coordinator.updateStationLabels(map)
            labels.append(Date().timeIntervalSince(labelStart))
        }
        guard store.renderGroups.map(\.geometryToken) == stableTokens else { throw DataError.invalid("Buffered pan replaced geometry") }
        report.append(String(format: "30 buffered pans: avg %.6fs max %.6fs; stationary labels avg %.6fs max %.6fs.",
                             pan.reduce(0,+) / 30, pan.max()!, labels.reduce(0,+) / 30, labels.max()!))
        let colours = Dictionary(store.urbanRoutes.map { ($0.visibilityKey, $0.color?.hex ?? "") }, uniquingKeysWith: { a, _ in a })
        for span in [0.035, 0.4, 0.16] {
            store.region.span = .init(latitudeDelta: span, longitudeDelta: span * 1.375)
            store.rebuildVisible()
            guard !store.visibleLines.isEmpty, store.visibleLines.flatMap({ $0.routes ?? [] }).allSatisfy({
                colours[$0.visibilityKey] == ($0.color?.hex ?? "")
            }) else { throw DataError.invalid("Zoom changed route colours") }
        }
        store.renderSettings.metroWidthScale = 1.12
        let widthTokens = store.renderGroups.map(\.geometryToken)
        store.renderSettings.metroWidthScale = 1.0
        guard widthTokens == store.renderGroups.map(\.geometryToken) else { throw DataError.invalid("Width change replaced geometry") }
        if let route = store.urbanRoutes.first {
            store.hiddenRoutes = [route.visibilityKey]
            guard !store.visibleLines.contains(where: { ($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } }) else {
                throw DataError.invalid("Route toggle failed")
            }
            store.hiddenRoutes = []
        }
        // An actual edit under a stable ID must invalidate its cached path.
        if verify, let line = store.visibleLines.first, let index = store.onlineLines.firstIndex(where: { $0.id == line.id }) {
            let old = store.clippedGeometry[line.id]
            store.onlineLines[index].coordinates = line.coordinates.map { Coordinate($0.latitude + 0.001, $0.longitude) }
            let lines = store.onlineLines, stations = store.onlineStations
            let changed = await Task.detached { PreparedMapData(lines: lines, stations: stations) }.value
            store.rebuildIndex(precomputed: changed); store.rebuildVisible()
            guard store.clippedGeometry[line.id] != old else { throw DataError.invalid("Changed coordinates reused stale geometry") }
        }
        // Cached colour misses must settle without a second assembly. Measure
        // responsiveness while replaying a burst of arrivals.
        store.tileFeatures = tiles
        store.paletteAttempted = []
        let revision = store.renderRevision
        store.loadPaletteIfNeeded()
        try await settle(store)
        report.append("Empty palette response render revisions: \(store.renderRevision - revision).")
        if verify, store.renderRevision != revision { throw DataError.invalid("Empty palette response redrew map") }
        var heartbeat: [Double] = []
        let pulse = Task { @MainActor in
            var previous = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                let now = Date()
                heartbeat.append(now.timeIntervalSince(previous))
                previous = now
            }
        }
        for _ in 0..<8 { store.publishTiles() }
        try await settle(store)
        pulse.cancel()
        _ = await pulse.value
        heartbeat.sort()
        report.append(String(format: "Burst of 8 data notifications: main-run-loop interval p95 %.4fs max %.4fs (%d samples; target 16ms).",
                             heartbeat[Int(Double(heartbeat.count - 1) * 0.95)], heartbeat.max()!, heartbeat.count))
        report.append("PASS buffered pans, zoom colours, widths and route switches. Geometry/empty-result assertions apply only with --expect-render-optimized. Timing is this machine/scenario, not a frame-rate guarantee.")
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("render-performance.txt"))
        try await OnlineUIValidation.capture("tokyo-native", directory: directory, window: native)
    }

    private static func settle(_ store: RailwayMapStore) async throws {
        let deadline = Date().addingTimeInterval(90)
        while store.assemblyTask != nil || store.paletteWork != nil {
            guard Date() < deadline else { throw DataError.invalid("Render pipeline did not settle") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
#endif
