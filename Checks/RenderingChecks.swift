import Foundation
import RailwayCore

enum RenderingChecks {
    static func run() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw DataError.invalid("FAIL: \(label)") }
            count += 1
            print("PASS \(label)")
        }
        let original = Coordinate(39.908823, 116.397470)
        let converted = MapAlignment.mainlandGCJ.display(original)
        try check(abs(converted.latitude - 39.910226498) < 0.000001
                  && abs(converted.longitude - 116.403713582) < 0.000001, "WGS84 to GCJ agrees with Beijing reference")
        for p in [original, Coordinate(28.68, 115.89), Coordinate(31.23, 121.47), Coordinate(43.82, 87.62),
                  Coordinate(22.32, 114.17), Coordinate(22.19, 113.54)] {
            let display = MapAlignment.mainlandGCJ.display(p)
            try check(MapAlignment.distance(p, display) > 100
                      && MapAlignment.distance(p, MapAlignment.mainlandGCJ.original(display)) < 0.01,
                      "China basemap projection round trip under one centimetre \(p.latitude)")
        }
        for p in [Coordinate(25.03, 121.56),
                  Coordinate(21.03, 105.85), Coordinate(37.56, 126.98), Coordinate(35.68, 139.76)] {
            try check(MapAlignment.mainlandGCJ.display(p) == p, "Taiwan and foreign points stay WGS84 \(p.longitude)")
        }
        let nanchangStop = Coordinate(28.6266186, 115.7882702)
        let appleStation = Coordinate(28.622886, 115.792938)
        let before = MapAlignment.distance(nanchangStop, appleStation)
        let after = MapAlignment.distance(MapAlignment.mainlandGCJ.display(nanchangStop), appleStation)
        try check(before > 500 && after < 80, "Nanchang West measured POI residual falls from >500 m to <80 m")
        print(String(format: "ALIGNMENT Nanchang West: %.1f m before, %.1f m after (metro platform vs station POI)", before, after))

        let data = Data("""
        {"elements":[
          {"type":"relation","id":100,"tags":{"type":"route","route":"subway","network":"测试地铁","ref":"1","wikidata":"Q100","colour":"#E60039"},"members":[{"type":"way","ref":10,"role":""},{"type":"node","ref":30,"role":"stop"}]},
          {"type":"relation","id":101,"tags":{"type":"route","route":"subway","network":"测试地铁","ref":"1","wikidata":"Q100"},"members":[{"type":"way","ref":11,"role":""}]},
          {"type":"relation","id":102,"tags":{"type":"route","route":"subway","network":"测试地铁","ref":"2","wikidata":"Q200","colour":"#0079C3"},"members":[{"type":"way","ref":10,"role":""},{"type":"node","ref":31,"role":"stop"}]},
          {"type":"relation","id":200,"tags":{"public_transport":"stop_area"},"members":[{"type":"node","ref":30,"role":"stop"},{"type":"node","ref":31,"role":"stop"},{"type":"node","ref":32,"role":""}]},
          {"type":"way","id":10,"tags":{"railway":"subway"},"geometry":[{"lat":28.68,"lon":115.89},{"lat":28.681,"lon":115.90}]},
          {"type":"way","id":11,"tags":{"railway":"subway","service":"yard"},"geometry":[{"lat":28.68,"lon":115.89},{"lat":28.679,"lon":115.891}]},
          {"type":"node","id":30,"lat":28.68,"lon":115.89,"tags":{"name":"中心","railway":"stop"}},
          {"type":"node","id":31,"lat":28.6801,"lon":115.89,"tags":{"name":"中心","railway":"stop"}},
          {"type":"node","id":32,"lat":28.68005,"lon":115.89,"tags":{"name":"中心","railway":"station","station":"subway"}},
          {"type":"node","id":33,"lat":28.68006,"lon":115.89,"tags":{"name":"独立车站","railway":"station","station":"subway"}},
          {"type":"node","id":34,"lat":28.685,"lon":115.90,"tags":{"name":"一等站","railway":"station","railway:station_class":"一等站"}}
        ]}
        """.utf8)
        let features = try MetroRouteDecoder.decode(data)
        let unified = MetroIdentity.unify(lines: features.lines, stations: features.stations)
        try check(unified.lines.count == 2 && unified.lines.allSatisfy { !($0.routes ?? []).isEmpty },
                  "full route geometry retains every way")
        let depot = unified.lines.first { $0.tags["service"] == "yard" }!
        try check(depot.routes?.first?.color?.hex == "#E60039"
                  && depot.appearance.colors.first?.hex == "#73001C", "uncoloured direction inherits line colour; depot darkens 50 percent")
        let shared = unified.lines.first { $0.tags["atlas:osm"] == "way/10" }!
        let firstKey = depot.routes!.first!.visibilityKey
        let filtered = MetroIdentity.visible(shared, hiding: [firstKey])!
        try check(filtered.routes?.count == 1 && filtered.appearance.colors.first?.hex == "#0079C3",
                  "per-line toggle preserves the other line on shared track")
        try check(MetroIdentity.visible(depot, hiding: [firstKey]) == nil, "per-line toggle hides every fragment of its line")
        let interchange = unified.stations.first { $0.id == "node/32" }!
        try check(interchange.appearance().colors.count == 2 && interchange.appearance().doubleRing,
                  "explicit stop_area gives transfer station all line colours")
        try check(unified.stations.contains { $0.id == "node/33" && ($0.routes ?? []).isEmpty },
                  "nearby independent station is neither clustered nor assigned neighbour colours")
        var sameStation = unified.stations.first { $0.id == "node/33" }!
        sameStation.id = "node/35"
        sameStation.name = "中心"
        let named = MetroIdentity.unify(lines: unified.lines, stations: unified.stations + [sameStation])
        try check(named.stations.count == unified.stations.count + 1
                  && named.stations.last?.appearance().colors.count == 2,
                  "station-centre colours match named platform stops without merging positions")
        var namedDepot = depot
        namedDepot.id = "way/99"
        namedDepot.routes = nil
        namedDepot.tags = ["railway": "subway", "service": "yard", "name": "测试地铁1号线"]
        let depotMatch = MetroIdentity.unify(lines: unified.lines + [namedDepot], stations: [])
        try check(depotMatch.lines.last?.appearance.colors.first?.hex == "#73001C",
                  "explicit city line name colours a depot even outside passenger relations")
        var extensionLine = namedDepot
        extensionLine.tags = ["railway": "subway", "name": "地铁1号线（东延）"]
        extensionLine.coordinates = [Coordinate(28.68, 116.1), Coordinate(28.68, 115.90)]
        let extensionMatch = MetroIdentity.unify(lines: unified.lines + [extensionLine], stations: [])
        try check(extensionMatch.lines.last?.appearance.colors.first?.hex == "#E60039",
                  "named extension inherits whole-line colour when either end reaches the known route")
        extensionLine.tags["atlas:osm"] = "way/123"
        var farFragment = extensionLine
        farFragment.id = "tile/far-fragment"
        farFragment.coordinates = [Coordinate(28.68, 116.1), Coordinate(28.68, 116.11)]
        let splitExtension = MetroIdentity.unify(lines: unified.lines + [extensionLine, farFragment], stations: [])
        try check(splitExtension.lines.last?.appearance.colors.first?.hex == "#E60039",
                  "extension colour propagates across tile boundaries by exact OSM way")
        var extensionStation = sameStation
        extensionStation.name = "延伸站"
        extensionStation.coordinate = Coordinate(28.6801, 116.105)
        let onExtension = MetroIdentity.unify(lines: splitExtension.lines, stations: [extensionStation])
        try check(onExtension.stations.first?.appearance().colors.first?.hex == "#E60039"
                  && onExtension.stations.first?.tags["atlas:routeMatch"]?.contains("推定") == true,
                  "station on a unique known line gets matching colour with inferred provenance")
        var crossing = farFragment
        crossing.id = "way/crossing"
        crossing.routes = [shared.routes!.first { $0.tags["ref"] == "2" }!]
        crossing.coordinates = [Coordinate(28.679, 116.105), Coordinate(28.682, 116.105)]
        let ambiguousStation = MetroIdentity.unify(lines: splitExtension.lines + [crossing], stations: [extensionStation])
        try check((ambiguousStation.stations.first?.routes ?? []).isEmpty,
                  "geometry never invents a transfer at ambiguous crossing lines")
        extensionStation.coordinate = Coordinate(28.69, 116.105)
        let distantStation = MetroIdentity.unify(lines: splitExtension.lines, stations: [extensionStation])
        try check((distantStation.stations.first?.routes ?? []).isEmpty, "distant station never borrows a line colour")
        extensionLine.tags["name"] = "11号线北延"
        let otherNumber = MetroIdentity.unify(lines: unified.lines + [extensionLine], stations: [])
        try check((otherNumber.lines.last?.routes ?? []).isEmpty, "extension name never matches a partial line number")
        extensionLine.tags = ["railway": "subway", "name": "地铁1号线(东延)", "network": "另一城市地铁"]
        let otherCity = MetroIdentity.unify(lines: unified.lines + [extensionLine], stations: [])
        try check((otherCity.lines.last?.routes ?? []).isEmpty, "explicit different network rejects same-number extension match")
        let major = unified.stations.first { $0.id == "node/34" }!
        try check(major.appearance().filled && major.appearance().kind == .major, "explicit major-station class retains icon identity and fill")
        for zoom in [4.0, 8, 12, 17] {
            var settings = RailRenderSettings()
            settings.metroWidthScale = 0.7; settings.railwayWidthScale = 1.4
            for category in [RailCategory.urban, .speed350, .below160] {
                let width = RailAppearance(category: category, colors: []).strokes(zoom: zoom, settings: settings)[0].width
                let symbol = major.appearance(lineWidth: width, zoom: zoom, settings: settings)
                try check(abs(symbol.radius / width - 1.25) < 1e-10 && symbol.ringWidth < symbol.radius,
                          "station outer radius is 1.25 × rendered \(category.rawValue) width at Z\(zoom)")
            }
        }
        var fastLine = shared
        fastLine.tags = ["railway": "rail", "maxspeed": "350"]; fastLine.routes = nil
        var railStop = major
        railStop.coordinate = fastLine.coordinates[0]
        let sizing = StationTrackSizing.categories(lines: [fastLine], stations: [railStop])
        try check(sizing[railStop.id] == .speed350, "rail station without a speed tag sizes against its nearby rendered high-speed track")
        try check(RailCategory.urban.lineWidth < RailCategory.speed350.lineWidth,
                  "metro is thinner than mainline railway")
        let railway = RailAppearance(category: .speed350, colors: [])
        try check(railway.strokes.count == 2 && railway.strokes[1].width < railway.strokes[0].width
                  && !railway.strokes[1].dash.isEmpty, "railways use inset hollow dashes, never wide sleepers")
        try check(railway.strokes(zoom: 4).count == 1 && railway.strokes(zoom: 4)[0].width <= 1.2
                  && railway.strokes(zoom: 4)[0].color == railway.strokes[0].color,
                  "continent symbols simplify width without changing speed colour")
        let metroConstructionTags = ["railway": "construction", "construction": "subway"]
        let metroConstruction = RailAppearance(category: .construction, colors: [],
                                                isUrbanLifecycle: RailCategory.isUrbanLifecycle(metroConstructionTags))
        let railwayConstruction = RailAppearance(category: .construction, colors: [])
        try check(RailCategory.isUrbanLifecycle(metroConstructionTags)
                  && !RailCategory.isUrbanLifecycle(["railway": "construction", "construction": "rail"]),
                  "urban lifecycle tags are separated from ordinary railway construction")
        try check(metroConstruction.strokes[0].color == RailColor("#B7BEC5")!
                  && metroConstruction.strokes[1].color == RailColor("#F5F7F7")!
                  && !metroConstruction.strokes[0].dash.isEmpty
                  && metroConstruction.strokes[0].color != railwayConstruction.strokes[0].color,
                  "planned urban rail uses grey-white dashes while railway construction stays yellow")
        let recolouredUrbanConstruction = metroConstruction.replacingColors([RailColor("#E60039")!])
        try check(recolouredUrbanConstruction.strokes[0].color == RailColor("#B7BEC5")!
                  && recolouredUrbanConstruction.strokes[1].color == RailColor("#F5F7F7")!,
                  "colour adjustment preserves grey-white urban construction styling")
        try check(RailCacheStats.capacity == 8_589_934_592, "cache ceiling is eight GiB, not 32-bit overflow")
        try check(RailDisplayPolicy.minimumZoom(.urban) == 8 && RailDisplayPolicy.minimumZoom(.freight) == 8
                  && RailDisplayPolicy.minimumZoom(.speed350) == 0, "automatic LOD supports regional urban networks while retaining national main lines")
        var ledger = RailIdentityLedger()
        _ = ledger.apply(unified)
        var partial = RailTileFeatures()
        var fragment = depot
        fragment.id = "new-tile/way/11"
        fragment.routes = nil
        partial.lines = [fragment]
        let restored = ledger.apply(partial)
        try check(restored.lines.first?.routes?.first?.color == depot.routes?.first?.color,
                  "known route membership survives lower-detail tile replacement")
        var knownSpeed = shared
        knownSpeed.tags = ["railway": "rail", "atlas:osm": "way/123456", "maxspeed": "300", "operator": "Fixture"]
        knownSpeed.routes = nil
        partial.lines = [knownSpeed]
        _ = ledger.apply(partial)
        knownSpeed.tags.removeValue(forKey: "maxspeed")
        knownSpeed.tags.removeValue(forKey: "operator")
        partial.lines = [knownSpeed]
        let retained = ledger.apply(partial).lines[0]
        try check(retained.category == .speed300 && retained.tags["operator"] == "Fixture",
                  "backup tile with exact OSM identity cannot erase learned speed and operator")
        print("\(count) alignment, colour and station checks passed.")
    }
}
