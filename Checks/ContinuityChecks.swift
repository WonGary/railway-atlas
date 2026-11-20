import Foundation
import RailwayCore

enum ContinuityChecks {
    static func run() throws {
        let parent = RailTileKey(layer: .tracks, tile: RailTile(z: 10, x: 836, y: 421))
        let children = (1672...1673).flatMap { x in (842...843).map {
            RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: x, y: $0))
        } }
        let metro = RailTileKey(layer: .metroNetwork, tile: parent.tile)
        let far = RailTileKey(layer: .tracks, tile: RailTile(z: 10, x: 700, y: 300))
        let existing: Set<RailTileKey> = [parent, metro, far]
        for count in 0...children.count {
            let kept = RailTileContinuity.retainedKeys(existing: existing, requested: children,
                ready: Set(children.prefix(count)), bounds: parent.tile.bounds)
            guard kept.contains(parent) == (count < children.count), kept.contains(metro), !kept.contains(far) else {
                throw DataError.invalid("Tile transition removed geometry before its coverage was ready")
            }
        }
        for ready in [Set<RailTileKey>(), [parent]] {
            let kept = RailTileContinuity.retainedKeys(existing: Set(children), requested: [parent],
                                                      ready: ready, bounds: parent.tile.bounds)
            guard kept.count == (ready.isEmpty ? 4 : 0) else {
                throw DataError.invalid("Zoom out dropped detailed tracks before parent arrived")
            }
        }
        let narrow = children[0].tile.bounds
        let kept = RailTileContinuity.retainedKeys(existing: [parent], requested: [children[0]],
            ready: [children[0]], bounds: narrow)
        guard kept.isEmpty else { throw DataError.invalid("Completed viewport retained obsolete geometry") }
        print("PASS tile transitions preserve old geometry through partial/failed loads, keep metro identities, evict offscreen tiles, and release fully replaced coverage.")
    }

    static func wuhan(directory: URL) async throws {
        let repository = RailwayTileRepository(directory: directory)
        let keys = (1671...1677).flatMap { x in (839...844).flatMap { y in
            [RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: x, y: y)),
             RailTileKey(layer: .stations, tile: RailTile(z: 11, x: x, y: y)),
             RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: x >> 1, y: y >> 1))]
        } }
        let values = try await repository.cached(Array(Set(keys)), source: RailwayTileRepository.defaultSource)
        guard values.count > 30 else { throw DataError.invalid("Wuhan regression needs the real mixed cache") }
        let ready = Set(values.filter { !$0.fallback }.map(\.key))
        let parents = try await repository.cachedParents(keys.filter { !ready.contains($0) }, source: RailwayTileRepository.defaultSource)
        let tiles = Dictionary((values + parents).map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
        let assembly = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:],
            enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        for (name, identity) in [("武漢地鐵16號線", "wh16"), ("武漢地鐵5號線二期", "wh5"), ("武漢地鐵19號線", "wh19")] {
            let matching = assembly.features.lines.filter { $0.tags["name"] == name }
            guard !matching.isEmpty, matching.allSatisfy({ line in
                (line.routes ?? []).contains { $0.visibilityKey == "metro:wuhan:\(identity)" && $0.color != nil }
            }) else { throw DataError.invalid("Wuhan real section still uncoloured: " + name) }
            print("PASS \(name): \(matching.count) actual cache fragments use \(identity)")
        }
        let fringe = assembly.features.stations.filter {
            $0.network == .metro && $0.coordinate.latitude < 30.30 && $0.coordinate.longitude < 114.13
        }
        guard !fringe.isEmpty, fringe.allSatisfy({ ($0.routes ?? []).contains { $0.visibilityKey == "metro:wuhan:wh16" } }) else {
            let details = fringe.map { "\($0.name) \($0.coordinate) \($0.routes?.map { $0.visibilityKey } ?? [])" }
            throw DataError.invalid("Wuhan southwest end stations lost Line 16 membership: \(details)")
        }
        print("PASS Wuhan southwest: \(fringe.count) separate station markers inherit line 16 colour")
        let endTracks = assembly.features.lines.filter { $0.coordinates.contains { $0.latitude < 30.285 && $0.longitude < 114.07 }
            && ($0.routes ?? []).contains { $0.visibilityKey == "metro:wuhan:wh16" } }
        guard !endTracks.isEmpty else { throw DataError.invalid("Wuhan southern end geometry lost in fallback tiles") }
        print("PASS Wuhan main-source parents restore \(endTracks.count) coloured southern fragments despite incomplete backup tiles")
        let keysAtEdge = tiles.filter { $0.key.tile.bounds.center.latitude < 30.5 }
        let partial = RailFeatureAssembler.assemble(tiles: keysAtEdge, palette: [:], wiki: [:],
            enrichWiki: false, ledger: assembly.ledger, preview: nil)
        let line16 = partial.features.lines.filter { $0.tags["name"] == "武漢地鐵16號線" }
        guard !line16.isEmpty, line16.allSatisfy({ !$0.appearance.colors.isEmpty }) else {
            throw DataError.invalid("Line 16 colour vanished after a partial viewport replacement")
        }
        print("PASS Wuhan subset viewport preserves learned line 16 colour")
        for name in ["武汉有轨电车车都T1线", "光谷现代有轨电车T1线", "光谷现代有轨电车T2线"] {
            let tracks = assembly.features.lines.filter { $0.tags["name"] == name && $0.tags["service"] == nil }
            guard !tracks.isEmpty, tracks.allSatisfy({ !$0.appearance.colors.isEmpty }) else {
                let missing = tracks.filter { $0.appearance.colors.isEmpty }.map { "\($0.tags["atlas:osm"] ?? $0.id) \($0.coordinates.first!)" }
                throw DataError.invalid("Wuhan tram \(name): \(missing)")
            }
            print("PASS \(name): all \(tracks.count) real main-track fragments coloured")
        }
    }
}
