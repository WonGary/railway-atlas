#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

/// Regression against the user's actual, partially-coloured Beijing cache.
@MainActor
enum MetroCoverageValidation {
    static func run(store: RailwayMapStore, directory: URL) async throws {
        let keys = (1684...1688).flatMap { x in (774...777).flatMap { y in
            [RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: x, y: y)),
             RailTileKey(layer: .stations, tile: RailTile(z: 11, x: x, y: y))]
        } }
        let base = try await store.tileRepository.cached(keys, source: RailwayTileRepository.defaultSource)
        guard base.count > 10 else { throw DataError.invalid("Beijing regression requires actual mixed-source tile cache") }
        var tiles = Dictionary(base.map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
        let before = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                                   ledger: RailIdentityLedger(), preview: nil)
        let bounds = MapBounds(south: 39.4, west: 115.6, north: 40.5, east: 117.3)
        for tile in RailTile.covering(bounds, zoom: 10) {
            let key = RailTileKey(layer: .metroNetwork, tile: tile)
            if let features = BundledMetroSnapshots.features(for: key) { tiles[key] = features }
        }
        let assembly = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                                     ledger: before.ledger, preview: nil)
        let targetIDs = ["bj4", "bj8", "bj13", "bj14", "bj15"].map { "metro:beijing:\($0)" }
        var report = ["Actual Beijing Z11 mixed-source cache: \(base.count) tiles; explicit OSM relation snapshots added without network."]
        for identity in targetIDs {
            let source = tiles.values.flatMap(\.lines).filter { line in
                (line.routes ?? []).contains { BundledMetroPalette.applying(to: $0).visibilityKey == identity }
            }
            let ways = Set(source.compactMap { $0.tags["atlas:osm"] })
            let fragments = assembly.features.lines.filter { ways.contains($0.tags["atlas:osm"] ?? "") }
            guard !ways.isEmpty, !fragments.isEmpty, fragments.allSatisfy({ !$0.appearance.colors.isEmpty }),
                  Set(fragments.compactMap { $0.tags["atlas:osm"] }) == ways else {
                throw DataError.invalid("\(identity) lost a member or colour in mixed cache")
            }
            report.append("PASS \(identity): \(ways.count) member ways, \(fragments.count) mixed-source fragments all coloured.")
        }
        store.applyingConfiguration = true
        store.mapMode = .cached; store.automaticDetail = false
        store.onlineLines = assembly.features.lines; store.onlineStations = assembly.features.stations
        store.renderSettings = RailRenderSettings()
        store.rebuildIndex()
        store.applyingConfiguration = false
        let colors = Dictionary(store.urbanRoutes.map { ($0.visibilityKey, $0.color?.hex ?? "") }, uniquingKeysWith: { a, _ in a })
        for (name, point, span) in [
            ("beijing-city", Coordinate(39.96, 116.4), 0.65),
            ("beijing-north", Coordinate(40.02, 116.38), 0.20),
            ("beijing-centre", Coordinate(39.94, 116.37), 0.055),
            ("beijing-return", Coordinate(39.96, 116.4), 0.65)
        ] {
            store.region = MKCoordinateRegion(center: point.location, span: .init(latitudeDelta: span, longitudeDelta: span * 1.3))
            store.rebuildVisible()
            guard store.visibleLines.contains(where: { !$0.appearance.colors.isEmpty }) else {
                throw DataError.invalid("\(name) contains no coloured routes")
            }
            for route in store.visibleLines.flatMap({ $0.routes ?? [] }) where colors[route.visibilityKey] != nil {
                guard colors[route.visibilityKey] == (route.color?.hex ?? "") else { throw DataError.invalid("Zoom changed \(route.visibilityKey) colour") }
            }
            let unresolved = store.visibleLines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
            report.append("\(name): \(store.visibleLines.count) rendered fragments; \(unresolved.count) unresolved urban fragments (includes yards/unknown membership); known route colours stable.")
            store.cameraRevision += 1
            try await OnlineUIValidation.capture(name, directory: directory,
                                                window: NSApp.windows.first { $0.isVisible && $0.contentView != nil })
        }
        let hidden = "metro:beijing:bj14"
        store.hiddenRoutes = [hidden]
        guard !store.visibleLines.contains(where: { ($0.routes ?? []).contains { $0.visibilityKey == hidden } }) else {
            throw DataError.invalid("Beijing line 14 toggle left coloured fragments")
        }
        store.hiddenRoutes = []
        try await checkOverlayOrder()
        report.append("PASS line 14 switch hides its known fragments; native MapKit retains coloured geometry above a re-enabled neutral layer.")
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("beijing-coverage.txt"))
    }

    private static func checkOverlayOrder() async throws {
        let store = RailwayMapStore()
        store.mapMode = .cached
        let features = try MetroRouteDecoder.decode(Data("""
        {"elements":[
          {"type":"relation","id":21,"tags":{"route":"subway","network":"北京地铁","ref":"4"},"members":[
            {"type":"way","ref":10,"geometry":[{"lat":39.95,"lon":116.30},{"lat":39.95,"lon":116.50}]}]},
          {"type":"way","id":11,"tags":{"railway":"tram"},"geometry":[{"lat":39.95,"lon":116.30},{"lat":39.95,"lon":116.50}]}
        ]}
        """.utf8))
        let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 843, y: 387))
        let assembled = RailFeatureAssembler.assemble(tiles: [key: features], palette: [:], wiki: [:], enrichWiki: false,
                                                       ledger: RailIdentityLedger(), preview: nil)
        store.onlineLines = assembled.features.lines
        store.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.95, longitude: 116.4),
                                           span: .init(latitudeDelta: 0.2, longitudeDelta: 0.3))
        store.automaticDetail = false
        store.rebuildIndex(); store.rebuildVisible()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppleRailwayMap(store: store))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap(findMap).first
        }
        guard let map = window.contentView.flatMap(findMap),
              let coordinator = map.delegate as? AppleRailwayMap.Coordinator else { throw DataError.invalid("Native map missing") }
        func expected() -> [ObjectIdentifier] {
            store.renderGroups.flatMap {
                coordinator.groups[.init(token: $0.geometryToken, alignment: store.alignment), default: []].map(ObjectIdentifier.init)
            }
        }
        func actual() -> [ObjectIdentifier] { map.overlays.compactMap { ($0 as? MKMultiPolyline).map(ObjectIdentifier.init) } }
        guard expected().count >= 2, actual() == expected() else { throw DataError.invalid("Initial overlay order incorrect") }
        store.networks = [.metro]
        try await Task.sleep(for: .milliseconds(150))
        let retained = actual()
        store.networks = Set(RailNetwork.allCases)
        try await Task.sleep(for: .milliseconds(150))
        guard !retained.isEmpty, actual().count > retained.count,
              retained.allSatisfy(actual().contains), actual() == expected() else {
            throw DataError.invalid("Re-enabled neutral layer: retained \(retained.count), current \(actual().count), preserved \(retained.allSatisfy(actual().contains)), ordered \(actual() == expected())")
        }
    }
}
#endif
