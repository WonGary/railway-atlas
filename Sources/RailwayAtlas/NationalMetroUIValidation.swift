#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

@MainActor
enum NationalMetroUIValidation {
    static let flag = "--v020-national-check"

    static func run(store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard let window, let view = window.contentView else { throw DataError.invalid("Nationwide QA window missing") }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw DataError.invalid("Nationwide QA: " + message) }
        }
        let began = Date()
        let snapshot = try await store.nationalMetroRepository.load()
        var notes = [String(format: "Local overview decode: %.3fs", Date().timeIntervalSince(began))]
        try check(snapshot.cityNames.count >= 68 && snapshot.routeCount >= 400, "bundled coverage unexpectedly small")
        store.applyingConfiguration = true
        store.mapMode = .cached
        store.tileFeatures = [:]; store.completeMetroKeys = []
        store.enrichWikiColours = false
        store.categories = Set(RailCategory.allCases); store.networks = Set(RailNetwork.allCases)
        store.forcedCategories = []; store.forcedNetworks = []
        store.hiddenRoutes = []; store.automaticDetail = true; store.showsMetroColors = true
        store.prioritizesUrbanTransit = false
        store.panelVisible = false; store.inspectorVisible = false; store.uiScale = 1
        store.region = MapBounds.china.region; store.cameraRevision += 1
        store.viewportWidth = 1100; store.viewportHeight = 820
        store.onlineLines = []; store.onlineStations = []
        store.rebuildIndex()
        store.applyingConfiguration = false
        window.setContentSize(CGSize(width: 1100, height: 820))
        store.acceptNationalMetro(snapshot)
        try await settle(store)
        store.rebuildVisible()
        let expected = Set(snapshot.lines.filter { $0.category == .urban &&
            !RailGeometryClip.segments($0.coordinates, inside: store.viewportBounds).isEmpty }
            .flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        let actual = Set(store.visibleLines.flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        _ = try RetinaUIValidation.capture(view, name: "national-metro-cached", directory: directory)
        try check(expected == actual && !actual.isEmpty,
                  "nationwide view omits \(expected.subtracting(actual).count) routes: \(expected.subtracting(actual).sorted())")
        try check(store.visibleStations.isEmpty, "overview should not instantiate station labels")
        try check(store.categoryVisible(.urban) && store.networkVisible(.metro), "toggles do not reflect overview visibility")
        try check(store.colourRequests.distinctRouteCount == 0, "overview triggered nationwide colour requests")
        let sourceColours = Dictionary(snapshot.lines.flatMap { $0.routes ?? [] }.map { ($0.visibilityKey, $0.color?.hex ?? "") },
                                       uniquingKeysWith: { a, _ in a })
        try check(store.visibleLines.flatMap { $0.routes ?? [] }.allSatisfy {
            sourceColours[$0.visibilityKey] == ($0.color?.hex ?? "")
        }, "nationwide rendering changed source colours")
        store.showsNationalMetroOverview = false
        try await settle(store)
        try check(store.visibleLines.allSatisfy { $0.tags["atlas:nationalOverview"] != "yes" },
                  "independent nationwide overview switch left overview geometry visible")
        try check(!store.categoryVisible(.urban) && !store.networkVisible(.metro),
                  "overview switch did not remove the low-zoom automatic urban exception")
        store.prioritizesUrbanTransit = true
        try await settle(store)
        try check(!store.showsNationalMetroOverview && store.nationalMetroWork == nil
                  && store.visibleLines.allSatisfy { $0.tags["atlas:nationalOverview"] != "yes" },
                  "urban priority restarted overview loading or drawing after its master switch was disabled")
        store.prioritizesUrbanTransit = false
        store.showsNationalMetroOverview = true
        try await settle(store)
        try check(expected.isSubset(of: Set(store.visibleLines.flatMap { ($0.routes ?? []).map(\.visibilityKey) })),
                  "re-enabling nationwide overview did not restore route geometry")
        notes.append("PASS \(snapshot.cityNames.count) city/network groups; \(snapshot.routeCount) unique route keys, \(snapshot.colouredRouteCount) coloured; \(snapshot.vertexCount) simplified vertices.")
        notes.append("PASS nationwide Z\(String(format: "%.2f", store.displayZoom)): \(actual.count)/\(expected.count) route keys visible; no station labels and no remote colour queue.")
        let stable = store.renderGroups.map(\.geometryToken)
        var pans: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            store.region.center.longitude += 0.00001
            store.rebuildVisible()
            pans.append(Date().timeIntervalSince(start))
        }
        try check(stable == store.renderGroups.map(\.geometryToken), "buffered panning rebuilt geometry")
        notes.append(String(format: "30 buffered nationwide pans avg %.6fs max %.6fs; geometry retained.",
                            pans.reduce(0, +) / 30, pans.max() ?? 0))
        store.setNetwork(.metro, visible: false)
        try check(!store.visibleLines.contains { RailNetwork.classify($0.tags) == .metro }, "metro switch did not hide overview")
        store.setNetwork(.metro, visible: true)
        if let route = snapshot.lines.flatMap({ $0.routes ?? [] }).first(where: { $0.tags["route"] == "subway" }) {
            store.hiddenRoutes = [route.visibilityKey]
            try check(!store.visibleLines.contains { ($0.routes ?? []).contains { $0.visibilityKey == route.visibilityKey } },
                      "per-line switch leaves overview fragments")
            store.hiddenRoutes = []
        }
        store.categories.remove(.urban)
        try check(!store.visibleLines.contains { $0.category == .urban }, "urban category did not hide overview")
        store.categories.insert(.urban)
        let abandoned = Set(snapshot.lines.filter { $0.category == .abandoned }
            .flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        if !abandoned.isEmpty {
            store.setCategory(.abandoned, visible: true)
            try check(abandoned.isSubset(of: Set(store.visibleLines.flatMap { ($0.routes ?? []).map(\.visibilityKey) })),
                      "explicit abandoned-lines switch did not reveal the preserved overview records")
            store.forcedCategories.remove(.abandoned)
            store.rebuildVisible()
        }
        notes.append("PASS nationwide network, category and per-line switches.")

        // Native vector overlay construction uses the same geometry as the
        // cache-only screenshot. No railway request is started in this fixture.
        let native = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 820),
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
        guard let map = native.contentView.flatMap(findMap) else { throw DataError.invalid("Nationwide native map missing") }
        let overlays = map.overlays.compactMap { $0 as? MKMultiPolyline }
        try check(!overlays.isEmpty, "native map has no metro overlays")
        let ids = overlays.map(ObjectIdentifier.init)
        store.rebuildVisible()
        try await Task.sleep(for: .milliseconds(120))
        try check(ids == map.overlays.compactMap { ($0 as? MKMultiPolyline).map(ObjectIdentifier.init) },
                  "unchanged native geometry was replaced")
        notes.append("PASS native vector overlays \(overlays.count), polylines \(overlays.reduce(0) { $0 + $1.polylines.count }); unchanged response retains overlay objects.")
        native.contentView = nil
        native.close()

        // Complete detail replaces just its rectangle, never the rest of a
        // relation stretching through neighbouring cells.
        let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 843, y: 387))
        guard let detail = BundledMetroSnapshots.features(for: key) else { throw DataError.invalid("Beijing detail missing") }
        store.tileFeatures = [key: detail]; store.completeMetroKeys = [key]
        store.region = key.tile.bounds.region; store.cameraRevision += 1
        store.publishTiles()
        try await settle(store)
        try check(!store.visibleLines.isEmpty, "zooming into detail produced a blank map")
        let outside = store.onlineLines.filter {
            $0.tags["atlas:nationalOverview"] == "yes" && !key.tile.bounds.intersects(MapBounds(points: $0.coordinates))
        }
        try check(!outside.isEmpty, "one detail cell erased nationwide overview")
        store.region = MapBounds.china.region; store.cameraRevision += 1
        store.rebuildVisible()
        let immediate = Set(store.visibleLines.filter { $0.tags["atlas:nationalOverview"] == "yes" }
            .flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        try check(expected.isSubset(of: immediate), "country zoom has a blank interval before async assembly")
        store.publishTiles()
        try await settle(store)
        let returned = Set(store.visibleLines.filter { $0.tags["atlas:nationalOverview"] == "yes" }
            .flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        try check(expected.isSubset(of: returned), "returning to nationwide lost route geometry")
        notes.append("PASS nationwide → Beijing detail → nationwide: complete national route set restored; detail never removes other cities.")
        try Data(notes.joined(separator: "\n").utf8)
            .write(to: directory.appendingPathComponent("national-metro-ui.txt"), options: .atomic)
    }

    private static func settle(_ store: RailwayMapStore) async throws {
        let end = Date().addingTimeInterval(60)
        while store.assemblyTask != nil {
            guard Date() < end else { throw DataError.invalid("Nationwide assembly timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
