import Foundation
import RailwayCore

enum MetroSnapshotChecks {
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-snapshot-check-\(UUID())")
        let repository = RailwayTileRepository(directory: directory)
        for (city, bounds, expected) in [
            ("qingdao", MapBounds(south: 35.55, west: 119.60, north: 36.75, east: 121.05),
             ["qd1", "qd2", "qd3", "qd4", "qd6", "qd8", "qd11", "qd13"]),
            ("jinan", MapBounds(south: 36.25, west: 116.6, north: 37.1, east: 117.65),
             ["jnr01", "jnr02", "jnr03", "jnr04", "jnr06", "jnr08"]),
            ("tokyo", MapBounds(south: 35.5591, west: 139.6165, north: 35.7836, east: 139.9478),
             ["g", "m", "h", "t", "c", "y", "z", "n", "f", "a", "i", "s", "e"]),
            ("beijing", MapBounds(south: 39.4, west: 115.6, north: 40.5, east: 117.3),
             ["bj4", "bj8", "bj13", "bj14", "bj15"]),
            ("hongkong", MapBounds(south: 22.12, west: 113.8, north: 22.6, east: 114.45),
             ["ktl", "twl", "isl", "tkl", "tcl", "ael", "eal", "mol", "drl", "sile"]),
            ("macao", MapBounds(south: 22.1, west: 113.5, north: 22.23, east: 113.65),
             ["taipa", "seacpaivan", "hengqin"])
        ] {
            let keys = RailTile.covering(bounds, zoom: 10).map { RailTileKey(layer: .metroNetwork, tile: $0) }
            let started = Date()
            let cached = try await repository.cached(keys, source: RailwayTileRepository.defaultSource)
            try check(!cached.isEmpty && cached.allSatisfy { $0.snapshot && $0.stale },
                      "\(city) fresh install reads labelled snapshots without networking")
            try check(cached.allSatisfy { tile in
                tile.features.lines.flatMap(\.coordinates).allSatisfy { point in
                    let bounds = tile.key.tile.bounds.expanded(by: 0.000001)
                    return bounds.contains(point)
                }
            }, "\(city) snapshot fragments stay in their cell so live updates replace only that cell")
            let tiles = Dictionary(cached.map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
            let assembly = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:], enrichWiki: false,
                                                         ledger: RailIdentityLedger(), preview: nil).features
            let routes = assembly.lines.flatMap { $0.routes ?? [] }
            for id in expected {
                let key = "metro:\(city):\(id)"
                let line = routes.filter { $0.visibilityKey == key }
                try check(!line.isEmpty && line.allSatisfy { $0.color != nil }
                          && Set(line.compactMap { $0.color?.hex }).count == 1,
                          "\(city) real OSM \(id) is coloured consistently across directions")
            }
            if city == "beijing" {
                for ref in ["4", "8", "13", "14", "15"] {
                    let members = cached.flatMap(\.features.lines).filter { ($0.routes ?? []).contains { $0.tags["ref"] == ref } }
                    let ways = Set(members.compactMap { $0.tags["atlas:osm"] })
                    let fragments = assembly.lines.filter { ways.contains($0.tags["atlas:osm"] ?? "") }
                    try check(!ways.isEmpty && Set(fragments.compactMap { $0.tags["atlas:osm"] }) == ways
                              && fragments.allSatisfy { !$0.appearance.colors.isEmpty },
                              "Beijing line \(ref): every OSM member way across city cells has a colour (\(ways.count) ways, \(fragments.count) fragments)")
                }
            }
            try check(assembly.stations.contains { ($0.routes ?? []).contains { $0.color != nil } },
                      "\(city) real OSM stations inherit route colours")
            let unknown = assembly.lines.filter { $0.category == .urban && $0.appearance.colors.isEmpty }
            print("\(city) snapshot: \(assembly.lines.count) ways, \(assembly.stations.count) stations; " +
                  "\(unknown.count) unresolved urban ways, \(unknown.filter { $0.tags["service"] == nil }.count) without service tag; " +
                  String(format: "%.3fs to read and assemble", Date().timeIntervalSince(started)))
        }
        let outside = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 516, y: 351))
        try check(BundledMetroSnapshots.features(for: outside) == nil, "city snapshot never claims coverage in Europe")
        var adjacent: [RailTileKey: RailTileFeatures] = [:]
        for (x, west, east) in [(512, 0.25, 0.3515625), (513, 0.3515625, 0.45)] {
            let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: x, y: 512))
            let data = Data("""
            {"elements":[{"type":"relation","id":1,"tags":{"route":"subway","colour":"#123456"},"members":[
              {"type":"way","ref":2,"geometry":[{"lat":-0.1,"lon":\(west)},{"lat":-0.1,"lon":\(east)}]}]}]}
            """.utf8)
            adjacent[key] = try RailwayTileRepository.decode(data, key: key)
        }
        let joined = RailFeatureAssembler.assemble(tiles: adjacent, palette: [:], wiki: [:], enrichWiki: false,
                                                   ledger: RailIdentityLedger(), preview: nil).features
        try check(joined.lines.count == 2 && Set(joined.lines.map(\.id)).count == 2
                  && joined.lines.allSatisfy { $0.tags["atlas:osm"] == "way/2" && $0.appearance.colors.first?.hex == "#123456" },
                  "a live route crossing two city cells retains both fragments and a consistent colour")
        print("\(count) actual OSM snapshot checks passed.")
    }
}
