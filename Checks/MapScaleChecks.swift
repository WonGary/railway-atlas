import Foundation
import CSQLite
import RailwayCore

enum MapScaleChecks {
    static func run() throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw DataError.invalid(message) }
        }
        let parent = RailTileKey(layer: .tracks, tile: RailTile(z: 12, x: 3259, y: 1694))
        let child = RailTileKey(layer: .tracks, tile: RailTile(z: 13, x: 6518, y: 3388))
        let sibling = RailTileKey(layer: .tracks, tile: RailTile(z: 13, x: 6519, y: 3388))
        let p = parent.tile.bounds, c = child.tile.bounds
        let y = c.center.latitude
        let main = try line("parent", [Coordinate(y, p.west), Coordinate(y, p.east)])
        let detail = try line("child", [Coordinate(y, c.west), Coordinate(y, c.east)])
        var old = RailTileFeatures(), new = RailTileFeatures()
        old.lines = [main]; new.lines = [detail]
        let tiles = [parent: old, child: new]
        let zoomIn = RailTileContinuity.drawingTiles(tiles, requested: [child, sibling])
        try require(zoomIn[child]?.lines.first?.coordinates == detail.coordinates, "Detailed tile changed")
        try require(zoomIn[parent]?.lines.count == 1
                    && abs(zoomIn[parent]!.lines[0].coordinates.first!.longitude - c.east) < 1e-9,
                    "Partial arrival still draws its parent across the completed child")
        try require(zoomIn[parent]!.lines[0].coordinates.last == main.coordinates.last,
                    "Missing sibling lost its fallback railway")
        let zoomOut = RailTileContinuity.drawingTiles(tiles, requested: [parent])
        try require(zoomOut[child]?.lines.isEmpty == true && zoomOut[parent]?.lines.count == 1,
                    "Zoom out duplicated high-detail tracks")
        let zoomBack = RailTileContinuity.drawingTiles(tiles, requested: [child, sibling])
        try require(zoomBack[child]?.lines.first?.coordinates == detail.coordinates,
                    "Zooming back did not recover the original detailed geometry")
        try require(tiles[parent]?.lines.first?.coordinates == main.coordinates
                    && tiles[child]?.lines.first?.coordinates == detail.coordinates,
                    "Presentation changed retained source data")
        let empty = RailTileContinuity.drawingTiles([parent: old, child: RailTileFeatures()], requested: [child, sibling])
        try require(empty[parent]?.lines == nil || empty[parent]!.lines.allSatisfy {
            $0.coordinates.allSatisfy { $0.longitude >= c.east - 1e-9 }
        }, "An empty complete tile did not replace old geometry")
        let fallback = RailTileContinuity.drawingTiles(tiles, requested: [child, sibling], fallbackKeys: [child])
        try require(fallback[parent]?.lines.first?.coordinates == main.coordinates,
                    "An incomplete backup erased arrived primary geometry")
        let sharedBackup = RailFeatureAssembler.assemble(tiles: [child: old, sibling: old],
            palette: [:], wiki: [:], enrichWiki: false, ledger: RailIdentityLedger(), preview: nil,
            requested: [child, sibling], fallbackKeys: [child, sibling]).features.lines
        try require(sharedBackup.count == 2 && Set(sharedBackup.map(\.id)).count == 2,
                    "Shared backup IDs erased a sibling cell")
        let backupTransition = RailTileContinuity.drawingTiles(tiles,
            requested: [child, sibling], fallbackKeys: [parent, child])
        try require(backupTransition[parent]?.lines.first?.coordinates.first?.longitude == c.east,
                    "Backup-to-backup transition retained duplicate geometry")

        // Leave and re-enter the completed cell: the old line must be split,
        // never reconnected across the area that was removed.
        old.lines = [try line("loop", [
            Coordinate(y, p.east), Coordinate(y, c.center.longitude),
            Coordinate(c.north - 0.001, c.center.longitude), Coordinate(c.north - 0.001, p.east)
        ])]
        let split = RailTileContinuity.drawingTiles([parent: old, child: new], requested: [child, sibling])
        try require(split[parent]?.lines.count == 2
                    && Set(split[parent]!.lines.map(\.id)).count == 2,
                    "Clipping bridged an excluded cell or reused an ID")

        var policy = RailVisibilityPolicy()
        for railway in ["rail", "subway"] {
            let siding = try line("yard", detail.coordinates, tags: ["railway": railway, "service": "siding"])
            policy.zoom = 13
            try require(policy.visible(siding) == nil, "Regional view exposes \(railway) siding detail")
            policy.zoom = 16
            try require(policy.visible(siding) != nil, "Close-up failed to restore \(railway) siding")
            policy.zoom = 13; policy.forcedCategories = [.service]
            try require(policy.visible(siding) != nil, "Explicit service-track override was ignored")
            policy.forcedCategories = []
        }
        var coarse = main
        coarse.tags["atlas:tileZoom"] = "8"
        policy.zoom = 13
        try require(policy.visible(coarse) != nil, "Zoom hid the only available railway before its replacement arrived")
        policy.automaticDetail = false
        try require(policy.visible(coarse) != nil, "Manual full-detail control no longer works")
        policy.automaticDetail = true; policy.zoom = 20
        coarse.tags["atlas:tileZoom"] = "15"
        try require(policy.visible(coarse) != nil, "Maximum-source-zoom tracks disappeared in close-up")

        let points = [Coordinate(30, 106), Coordinate(30.00005, 106.005), Coordinate(30, 106.01)]
        let near = RailGeometryLOD.segments([points], zoom: 17)[0]
        let far = RailGeometryLOD.segments([points], zoom: 12)[0]
        try require(far.count == 2 && near == points && far.first == points.first && far.last == points.last,
                    "Screen-space detail does not recover with zoom or moved endpoints")
        let bend = [Coordinate(30, 106), Coordinate(30.002, 106.005), Coordinate(30, 106.01)]
        try require(RailGeometryLOD.segments([bend], zoom: 12)[0] == bend, "Generalization erased a visible bend")
        let pieces = [points, [Coordinate(30.1, 106.1), Coordinate(30.1, 106.2)]]
        let simplified = RailGeometryLOD.segments(pieces, zoom: 12)
        try require(simplified.count == 2 && simplified[1] == pieces[1],
                    "Display generalization bridged disjoint pieces")
        print("PASS scale regression: partial-cell handoff, zoom out/back, empty primary/backup precedence, split gaps, source preservation, rail/metro sidings, pending overzoom continuity, screen-space bends and endpoints.")
    }

    private static func line(_ id: String, _ coordinates: [Coordinate],
                             tags: [String: String] = ["railway": "rail", "maxspeed": "120"]) throws -> RailLine {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "name": id, "tags": tags,
            "coordinates": coordinates.map { ["latitude": $0.latitude, "longitude": $0.longitude] }
        ])
        return try JSONDecoder().decode(RailLine.self, from: data)
    }

    /// Bounded, read-only cache sample from the user's screenshot area. No
    /// migration, network requests, refresh or eviction of the original cache.
    static func cache(_ path: String, output: String) throws {
        let bounds = MapBounds(south: 29.615, west: 106.425, north: 29.66, east: 106.475)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw DataError.invalid("Cannot open cache read-only")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT data FROM tiles WHERE source IN ('https://openrailwaymap.app','https://tiles.versatiles.org','https://tiles.openfreemap.org') AND layer=? AND z=? AND x=? AND y=?",
            -1, &query, nil) == SQLITE_OK, let query else { throw DataError.invalid("Cannot read cache") }
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var tiles: [RailTileKey: RailTileFeatures] = [:], fallback = Set<RailTileKey>(), bytes = 0
        // Check the same primary/backup ordering as the viewport repository.
        // Z14 backup data can serve several requested Z15 child cells.
        for zoom in 3...15 {
            for tile in RailTile.covering(bounds, zoom: zoom) {
                let key = RailTileKey(layer: zoom < 7 ? .overview : .tracks, tile: tile)
                for layer in [key.layer, .shortbread, .openMapTiles] {
                    if zoom < 8 && layer != key.layer { continue }
                    let backup = layer != key.layer
                    let z = backup ? min(14, zoom) : zoom
                    let sourceTile = RailTile(z: z, x: tile.x >> (zoom - z), y: tile.y >> (zoom - z))
                    sqlite3_reset(query)
                    sqlite3_bind_text(query, 1, layer.rawValue, -1, transient)
                    sqlite3_bind_int(query, 2, Int32(z))
                    sqlite3_bind_int(query, 3, Int32(sourceTile.x))
                    sqlite3_bind_int(query, 4, Int32(sourceTile.y))
                    let status = sqlite3_step(query)
                    guard status == SQLITE_ROW || status == SQLITE_DONE else { throw DataError.invalid("Cache query failed") }
                    if status == SQLITE_ROW, let blob = sqlite3_column_blob(query, 0) {
                        let count = Int(sqlite3_column_bytes(query, 0)); bytes += count
                        guard bytes <= 32_000_000 else { throw DataError.invalid("Cache fixture exceeds 32MB") }
                        tiles[key] = try RailwayTileRepository.decode(Data(bytes: blob, count: count),
                            key: RailTileKey(layer: layer, tile: sourceTile))
                        if backup { fallback.insert(key) }
                        break
                    }
                }
            }
        }
        guard !tiles.isEmpty else { throw DataError.invalid("No cached tracks near Jingkou") }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requested = RailTile.covering(bounds, zoom: 15).map { RailTileKey(layer: .tracks, tile: $0) }
        let raw = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                               ledger: RailIdentityLedger(), preview: nil).features.lines
        let selected = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
            ledger: RailIdentityLedger(), preview: nil, requested: requested, fallbackKeys: fallback).features.lines
        var policy = RailVisibilityPolicy(); policy.zoom = 15
        let visible = selected.compactMap { policy.visible($0) }
        for (name, lines) in [("jingkou-mixed", raw), ("jingkou-selected", visible)] {
            var clipped: [RailLine] = []
            for original in lines {
                let parts = RailGeometryClip.segments(original.coordinates, inside: bounds)
                let display = name == "jingkou-mixed" ? parts : RailGeometryLOD.segments(parts, zoom: 15)
                for (index, coordinates) in display.enumerated() {
                    var line = original
                    line.id += "/sample/\(index)"; line.coordinates = coordinates
                    clipped.append(line)
                }
            }
            try JSONEncoder().encode(clipped).write(to: directory.appendingPathComponent("\(name).json"))
            print("\(name): \(clipped.count) fragments, \(clipped.reduce(0) { $0 + $1.coordinates.count }) vertices")
        }
        print("Read-only Jingkou sample: \(tiles.count) cached tiles, \(bytes) encoded bytes; source cache untouched. Mixed-LOD reconstruction, not an exact replay of the screenshot.")
    }
}
