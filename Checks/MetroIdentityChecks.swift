import Foundation
import RailwayCore

enum MetroIdentityChecks {
    static func run() throws {
        let relation = try MetroRouteDecoder.decode(Data("""
        {"elements":[
          {"type":"relation","id":9001,"tags":{"route":"tram","name":"Auto City T1 Line","ref":"T1","wikidata":"Q9001","colour":"#CC5923"},"members":[
            {"type":"way","ref":10,"geometry":[null,null]},
            {"type":"way","ref":11},
            {"type":"node","ref":20,"role":"stop"}]},
          {"type":"way","id":10,"tags":{"railway":"tram","name":"武汉有轨电车车都T1线"},"geometry":[
            {"lat":30.48,"lon":114.07},{"lat":30.49,"lon":114.08}]},
          {"type":"way","id":12,"tags":{"railway":"tram","name":"武漢有軌電車車都T1線"},"geometry":[
            {"lat":30.46,"lon":114.06},{"lat":30.48,"lon":114.07}]}]}
        """.utf8))
        let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 836, y: 420))
        let full = RailFeatureAssembler.assemble(tiles: [key: relation], palette: [:], wiki: [:],
            enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        guard full.features.lines.count == 2,
              full.features.lines.allSatisfy({ $0.appearance.colors.first?.hex == "#CC5923" }) else {
            throw DataError.invalid("Clipped relation or proven multilingual name lost line identity")
        }
        let partial = try MetroRouteDecoder.decode(Data("""
        {"elements":[{"type":"way","id":11,"tags":{"railway":"tram"},"geometry":[
          {"lat":30.45,"lon":114.06},{"lat":30.46,"lon":114.06}]},
          {"type":"node","id":20,"tags":{"railway":"tram_stop","name":"终点"},"lat":30.45,"lon":114.06}]}
        """.utf8))
        let later = RailFeatureAssembler.assemble(tiles: [key: partial], palette: [:], wiki: [:],
            enrichWiki: false, ledger: full.ledger, preview: nil).features
        guard later.lines.first?.appearance.colors.first?.hex == "#CC5923",
              later.stations.first?.appearance().colors.first?.hex == "#CC5923",
              MetroIdentity.visible(later.lines[0], hiding: ["Q9001"]) == nil else {
            throw DataError.invalid("Unseen way/stop membership must survive relation viewport eviction")
        }
        var remote = full.features.lines[1]
        remote.id = "other-city"; remote.tags = ["railway": "tram", "name": "武漢有軌電車車都T1線"]
        remote.routes = nil
        remote.coordinates = [Coordinate(40, 120), Coordinate(40.01, 120.01)]
        guard MetroIdentity.unify(lines: full.features.lines + [remote], stations: []).lines.last?.routes?.isEmpty != false else {
            throw DataError.invalid("A distant same-name track borrowed another city's route")
        }
        var wrongMode = remote
        wrongMode.id = "other-mode"; wrongMode.tags["railway"] = "subway"
        wrongMode.coordinates = full.features.lines[1].coordinates
        guard MetroIdentity.unify(lines: full.features.lines + [wrongMode], stations: []).lines.last?.routes?.isEmpty != false else {
            throw DataError.invalid("Tram and subway must not merge by a shared name")
        }
        var competing = full.features.lines[1]
        competing.id = "competing-service"
        competing.tags.removeValue(forKey: "atlas:osm")
        competing.routes![0].id = "relation/9002"
        competing.routes![0].tags["wikidata"] = "Q9002"
        var terminal = full.features.lines[1]
        terminal.id = "terminal"; terminal.tags.removeValue(forKey: "atlas:osm")
        terminal.routes = nil
        terminal.coordinates = [Coordinate(30.455, 114.06), Coordinate(30.46, 114.06)]
        let ambiguous = MetroIdentity.unify(lines: full.features.lines + [competing, terminal], stations: [])
        guard (ambiguous.lines.last?.routes ?? []).isEmpty else {
            throw DataError.invalid("Shared infrastructure name cannot choose between two connected service patterns")
        }
        competing.coordinates = [Coordinate(30.50, 114.1), Coordinate(30.51, 114.11)]
        let connected = MetroIdentity.unify(lines: full.features.lines + [competing, terminal], stations: [])
        guard connected.lines.last?.routes?.first?.visibilityKey == "Q9001" else {
            throw DataError.invalid("Same-name terminal should use its unique connected route")
        }
        print("PASS complete relation IDs survive clipped/missing geometry and viewport changes; proven translated names unify; same-name distant cities and different modes stay separate.")
    }

    static func cities(directory: URL) async throws {
        let repository = RailwayTileRepository(directory: directory)
        for (name, point) in [
            ("武汉", Coordinate(30.59, 114.3)), ("北京", Coordinate(39.96, 116.4)),
            ("东京", Coordinate(35.68, 139.76)), ("首尔", Coordinate(37.56, 126.98)),
            ("青岛", Coordinate(36.1, 120.35)), ("济南", Coordinate(36.67, 117.04))
        ] {
            let bounds = MapBounds(south: point.latitude - 0.4, west: point.longitude - 0.5,
                                   north: point.latitude + 0.4, east: point.longitude + 0.5)
            let keys = RailTile.covering(bounds, zoom: 11).flatMap {
                [RailTileKey(layer: .tracks, tile: $0), RailTileKey(layer: .stations, tile: $0),
                 RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: $0.x >> 1, y: $0.y >> 1))]
            }
            let values = try await repository.cached(Array(Set(keys)), source: RailwayTileRepository.defaultSource)
            guard !values.isEmpty else { throw DataError.invalid("Missing real city fixture: \(name)") }
            let ready = Set(values.filter { !$0.fallback }.map(\.key))
            let parents = try await repository.cachedParents(keys.filter { !ready.contains($0) }, source: RailwayTileRepository.defaultSource)
            let tiles = Dictionary((values + parents).map { ($0.key, $0.features) }, uniquingKeysWith: { a, _ in a })
            let start = Date()
            let full = RailFeatureAssembler.assemble(tiles: tiles, palette: [:], wiki: [:],
                enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
            let seconds = Date().timeIntervalSince(start)
            let known = full.features.lines.filter { !$0.appearance.colors.isEmpty }
            guard known.count > 10 else { throw DataError.invalid("No meaningful coloured city coverage: \(name)") }
            let palette = Dictionary(known.flatMap { $0.routes ?? [] }.map { ($0.visibilityKey, $0.color?.hex) },
                                     uniquingKeysWith: { a, _ in a })
            let viewport = tiles.filter { !$0.key.layer.isMetro }
            let after = RailFeatureAssembler.assemble(tiles: viewport, palette: [:], wiki: [:],
                enrichWiki: false, ledger: full.ledger, preview: nil)
            let prior = Dictionary(known.map { ($0.id, $0.appearance.colors) }, uniquingKeysWith: { a, _ in a })
            for line in after.features.lines {
                if let colors = prior[line.id], colors != line.appearance.colors {
                    throw DataError.invalid("\(name) lost colours after dropping relation tiles: \(line.id)")
                }
                for route in line.routes ?? [] {
                    if let expected = palette[route.visibilityKey], route.color?.hex != expected {
                        throw DataError.invalid("\(name) fragments disagree on a line colour")
                    }
                }
            }
            let unresolved = full.features.lines.filter { $0.category == .urban && $0.appearance.colors.isEmpty && $0.tags["service"] == nil }
            print(String(format: "PASS %@: %d coloured fragments, %d identities; %.3fs assembly; %d unresolved main urban fragments; identities survive partial viewport.",
                         name, known.count, palette.count, seconds, unresolved.count))
            let names = Dictionary(grouping: unresolved, by: { $0.tags["name"] ?? "(no name)" }).mapValues(\.count)
            print("  Remaining:", names.sorted { $0.value > $1.value }.prefix(5))
        }
    }
}
