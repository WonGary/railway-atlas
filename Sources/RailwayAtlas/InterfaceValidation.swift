#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

@MainActor
enum InterfaceValidation {
    static func run(directory: URL) async throws {
        var cases = 0
        for scale in [0.75, 1, 1.25, 1.6] {
            for width in [360.0, 440, 700, 1100] {
                for height in [500.0, 650, 820] {
                    let margin = 20 * scale
                    let size = CGSize(width: width, height: height)
                    let obstacles = [
                        CGRect(x: margin, y: margin, width: 125 * scale, height: 92 * scale),
                        CGRect(x: width - margin - 38 * scale, y: margin, width: 38 * scale, height: 178 * scale),
                        CGRect(x: margin, y: height - margin - 80 * scale, width: width - 2 * margin, height: 80 * scale)
                    ]
                    for cardHeight in [100.0, 700] {
                        for offset in [CGSize.zero, CGSize(width: -2000, height: -2000), CGSize(width: 2000, height: 2000),
                                       CGSize(width: -300, height: 100), CGSize(width: 0, height: 150)] {
                            let layout = MapStatusLayout(viewport: size, desired: CGSize(width: 260 * scale, height: cardHeight * scale),
                                                         scale: scale, offset: offset, obstacles: obstacles)
                            let rect = layout.frame
                            guard rect.height > 0, CGRect(origin: .zero, size: size).contains(rect),
                                  !obstacles.contains(where: { $0.intersects(rect.insetBy(dx: 0.1, dy: 0.1)) }) else {
                                throw DataError.invalid("Status card overlaps controls at \(width)×\(height), scale \(scale), offset \(offset)")
                            }
                            cases += 1
                        }
                    }
                }
            }
        }
        var report = ["PASS \(cases) status layouts: narrow/wide windows, 75–160% UI, short/long content and extreme drag positions avoid scale, navigation and attribution."]
        let map = RailwayMapStore(), assistant = AssistantStore()
        // This suite isolates the movable status card; panel collisions are
        // covered in PanelUIValidation's full workspace.
        map.panelVisible = false
        map.mapMode = .cached
        map.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                        span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        map.viewportWidth = 900; map.viewportHeight = 500
        let bounds = map.viewportBounds
        let lat = max(0.01, bounds.north), lon = max(0.01, bounds.east)
        func coordinate(_ point: Coordinate) -> [String: Double] { ["latitude": point.latitude, "longitude": point.longitude] }
        func line(_ id: String, points: [Coordinate], tags: [String: String]) throws -> RailLine {
            try JSONDecoder().decode(RailLine.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "name": id, "coordinates": points.map(coordinate), "tags": tags
            ]))
        }
        func station(_ id: String, point: Coordinate) throws -> RailStation {
            try JSONDecoder().decode(RailStation.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "name": id, "coordinate": coordinate(point), "tags": ["railway": "station"]
            ]))
        }
        map.onlineLines = [
            try line("crossing", points: [Coordinate(0, -lon * 2), Coordinate(0, lon * 2)],
                     tags: ["railway": "rail", "name": "Shared name", "operator": "A"]),
            try line("miss", points: [Coordinate(-lat * 2, lon * 5), Coordinate(lat * 5, -lon * 2)],
                     tags: ["railway": "rail", "name": "Shared name", "operator": "B"]),
            try line("distant", points: [Coordinate(30, 100), Coordinate(31, 101)], tags: ["railway": "rail"])
        ]
        map.onlineStations = [
            try station("inside", point: Coordinate(0, 0)),
            try station("outside", point: Coordinate(20, 20))
        ]
        map.rebuildIndex()
        assistant.scope = .region; assistant.prepare(map: map)
        let context = try JSONSerialization.jsonObject(with: Data(assistant.context.utf8)) as? [String: Any]
        guard context?["loaded_segment_count"] as? Int == 1,
              (context?["railways_sample"] as? [[String: Any]])?.first?["id"] as? String == "crossing",
              (context?["stations_sample"] as? [[String: Any]])?.count == 1,
              (context?["bounds"] as? [String: Double])?["north"] == bounds.north else {
            throw DataError.invalid("Region context omitted a crossing or included offscreen geometry")
        }
        guard map.assistantRoutes.count == 2, map.assistantRoutes.allSatisfy({ $0.lines.count == 1 }) else {
            throw DataError.invalid("Named routes belonging to different operators merged")
        }
        assistant.scope = .route; assistant.routeKey = map.assistantRoutes[0].id; assistant.prepare(map: map)
        guard assistant.context.contains("segments_sample") else { throw DataError.invalid("Prepared route context missing") }
        map.onlineLines = []
        map.rebuildIndex()
        guard map.assistantRoutes.isEmpty else { throw DataError.invalid("Prepared routes survived source replacement") }
        report.append("PASS GPT region context includes lines crossing the visible viewport with no interior vertex, excludes false-positive bounding boxes and distant stations, and uses projected viewport bounds.")
        report.append("PASS prepared route groups preserve operator identity and refresh when source data changes. No API request.")
        let base = try line("base", points: [Coordinate(0, 0), Coordinate(0, 2)],
                            tags: ["railway": "subway", "atlas:osm": "way/10"])
        let partial = try line("partial", points: [Coordinate(0, 0), Coordinate(0, 1)],
                               tags: ["railway": "subway", "atlas:osm": "way/10", "atlas:routeOverlay": "yes"])
        let partialPrepared = PreparedMapData(lines: [base, partial], stations: [])
        guard !partialPrepared.lines[0].suppressed else { throw DataError.invalid("Partial relation hid the rest of a long base way") }
        var complete = partial
        complete.coordinates = base.coordinates
        guard PreparedMapData(lines: [base, complete], stations: []).lines[0].suppressed else {
            throw DataError.invalid("Complete route overlay did not replace duplicate base geometry")
        }
        report.append("PASS partial route overlays retain uncovered base-way fragments; full overlays suppress only completely covered duplicates.")

        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.67, longitude: 117.06),
                                        span: MKCoordinateSpan(latitudeDelta: 0.36, longitudeDelta: 0.36))
        let keys = RailTile.covering(MapBounds(region: region), zoom: 10).map { RailTileKey(layer: .metroNetwork, tile: $0) }
        let tiles = Dictionary(keys.compactMap { key in BundledMetroSnapshots.features(for: key).map { (key, $0) } },
                               uniquingKeysWith: { a, _ in a })
        let assembly = await Task.detached {
            RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                           ledger: RailIdentityLedger(), preview: nil)
        }.value
        map.region = region
        map.onlineLines = assembly.features.lines; map.onlineStations = assembly.features.stations
        map.rebuildIndex()
        map.tileZoom = 12; map.failedTiles = 5; map.fallbackTiles = 3
        map.onlineStatus = "正在读取当前视野的本地缓存。部分在线来源暂时无法连接，已保留此前下载的铁路数据。"
        map.metroStatus = "线路关系读取较慢，当前使用随附线路快照。重新联网后会按区段更新，并保留已识别的线路颜色。"
        let connectivity = Connectivity()
        for (name, size, scale, offset) in [
            ("status-standard", CGSize(width: 920, height: 700), 1.0, CGSize.zero),
            ("status-narrow-160", CGSize(width: 440, height: 650), 1.6, CGSize.zero),
            ("status-dragged-160", CGSize(width: 440, height: 650), 1.6, CGSize(width: -2000, height: -2000))
        ] {
            map.uiScale = scale; map.statusOffset = offset
            map.viewportWidth = size.width; map.viewportHeight = size.height
            map.rebuildVisible()
            let view = NSHostingView(rootView: MapScreen().environmentObject(map).environmentObject(assistant)
                .environmentObject(connectivity).environment(\.atlasUIScale, scale))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(600))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  bitmap.pixelsWide >= Int(size.width) * 2 else { throw DataError.invalid("Status screenshot lacks Retina density") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            window.close()
        }
        report.append("PASS native status screenshots at 2× density captured with real Jinan geometry and simulated long loading messages; visual inspection required.")
        try Data(report.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("interface-qa.txt"))
    }
}
#endif
