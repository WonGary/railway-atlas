import Foundation
import RailwayCore

enum MetroPaletteChecks {
    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        func route(_ name: String, _ tags: [String: String]) throws -> RailRoute {
            try JSONDecoder().decode(RailRoute.self, from: JSONSerialization.data(withJSONObject:
                ["id": "relation/fixture", "name": name, "tags": tags]))
        }
        try check(BundledMetroPalette.cityCount == 229 && BundledMetroPalette.entryCount > 2700,
                  "global local palette is packaged and available without requests")
        for (network, ref, expected) in [
            ("长沙轨道交通", "1", "#E70014"), ("长沙轨道交通", "6", "#005BAC"),
            ("西安地铁", "14", "#00C1D4"), ("广州地铁", "9", "#71CC98"),
            ("广州地铁", "14", "#81312F"), ("港鐵", "TML", "#9C2E00"),
            ("青岛地铁", "3", "#006DBB"), ("Qingdao Metro", "11", "#304299"),
            ("济南轨道交通", "2", "#FFB620"), ("Jinan Metro", "R3", "#0073CE"),
            ("香港輕鐵", "614P", "#F3858D"), ("臺北捷運", "BL", "#0070BD"),
            ("수도권 전철", "2", "#00A84D")
        ] {
            let value = try route("", ["network": network, "ref": ref, "route": "subway"])
            try check(BundledMetroPalette.applying(to: value).color?.hex == expected,
                      "offline \(network) \(ref) colour")
        }
        for (name, network, ref, expected) in [
            ("東京メトロ銀座線", "東京メトロ", "", "#F9A328"),
            ("", "Tokyo Metro", "G", "#F9A328"),
            ("都営浅草線", "東京都交通局", "", "#DD4231"),
            ("都営地下鉄大江戸線", "都営地下鉄", "", "#CE1C64"),
            ("", "Toei Subway", "I", "#0068A5"),
            ("東京メトロ丸ノ内線", "Tokyo Metro", "Mb", "#D92C2F")
        ] {
            let value = try route(name, ["route": "subway", "network": network, "ref": ref])
            try check(BundledMetroPalette.match(value)?.hex == expected, "Tokyo name/ref alias \(name) \(ref)")
        }
        let tokyoLocated = try route("銀座線", ["route": "subway"])
        try check(BundledMetroPalette.match(tokyoLocated, near: Coordinate(35.67, 139.76))?.line == "g",
                  "Tokyo location disambiguates explicitly named track")
        for (name, expected) in [
            ("北京地铁十三号线", "bj13"), ("北京地铁17号线北段", "bj17"),
            ("北京地铁17号线中段", "bj17"), ("北京地铁昌平线南延", "bj27cp")
        ] {
            let value = try route(name, ["route": "subway"])
            try check(BundledMetroPalette.match(value, near: Coordinate(39.95, 116.4))?.line == expected,
                      "Beijing section and Chinese-number alias \(name)")
        }
        let remoteGinza = try route("銀座線", ["network": "Fictional network"])
        try check(BundledMetroPalette.match(remoteGinza, near: Coordinate(36.65, 117.04)) == nil,
                  "Tokyo named track is not assigned by a distant location")
        let englishNetwork = try route("3호선", ["network": "수도권 전철", "network:en": "Seoul Metropolitan Subway", "ref": "3"])
        try check(BundledMetroPalette.match(englishNetwork)?.line == "s3", "Korean and English network aliases resolve to one city")
        let incheon = try route("인천 도시철도 1호선", ["network": "수도권 전철", "ref": "1"])
        try check(BundledMetroPalette.match(incheon)?.line == "i1", "Incheon 1 is not confused with Seoul 1")
        let ui = try route("우이신설선", ["network": "수도권 전철", "ref": "W"])
        try check(BundledMetroPalette.match(ui)?.line == "ui", "OSM W does not use upstream's unrelated internal w ID")
        let macao = try route("氹仔線: 媽閣 → 氹仔碼頭", ["network": "澳門輕軌", "route": "light_rail"])
        try check(BundledMetroPalette.match(macao)?.hex == "#A4D65E", "Macao named line works without a numeric ref")
        let southIsland = try route("南港島綫（金鐘 → 海怡半島）", ["network": "港鐵 MTR", "ref": "SIL", "name:en": "South Island Line (Admiralty → South Horizons)"])
        try check(BundledMetroPalette.match(southIsland)?.line == "sile",
                  "South Island operating line is not made ambiguous by the planned West line")
        let westIsland = try route("South Island Line (West)", ["network": "MTR"])
        try check(BundledMetroPalette.match(westIsland)?.line == "silw",
                  "an explicit qualified line name retains its separate identity")
        let named = try route("长沙轨道交通2号线", ["route": "subway"])
        try check(BundledMetroPalette.match(named)?.hex == "#00B0EC", "explicit city and line name works without network or ref")
        let unknown = try route("1号线", ["route": "subway", "ref": "1"])
        for (name, expected) in [
            ("武漢地鐵16號線", "wh16"), ("武漢地鐵5號線二期", "wh5"), ("武漢地鐵19號線", "wh19")
        ] {
            let value = try route(name, ["route": "subway", "name": name])
            try check(BundledMetroPalette.match(value, near: Coordinate(30.23, 113.99))?.line == expected,
                      "explicit traditional Wuhan section name works beyond city-centre radius: \(name)")
        }
        try check(BundledMetroPalette.match(unknown) == nil, "bare route number does not match a global city")
        try check(BundledMetroPalette.match(unknown, near: Coordinate(23.06, 113.2)) == nil,
                  "overlapping Guangzhou/Foshan geography remains ambiguous")
        let xiangtan = try route("Xiangtan Metro", ["network": "Xiangtan Metro", "ref": "1"])
        try check(BundledMetroPalette.city(for: xiangtan) != "xian", "Latin city aliases use word boundaries")
        let ambiguous = try route("", ["network": "广州地铁", "ref": "1;2"])
        try check(BundledMetroPalette.match(ambiguous) == nil, "combined refs are not reduced to their first line")

        let features = try MetroRouteDecoder.decode(Data("""
        {"elements":[
          {"type":"relation","id":21,"tags":{"route":"subway","network":"长沙轨道交通","ref":"2","wikidata":"Q111"},"members":[
            {"type":"way","ref":10,"geometry":[{"lat":28.23,"lon":112.94},{"lat":28.24,"lon":112.95}]},
            {"type":"node","ref":100,"role":"stop"}]},
          {"type":"relation","id":22,"tags":{"route":"subway","network:en":"Changsha Metro","ref":"2","wikidata":"Q222"},"members":[
            {"type":"way","ref":11,"geometry":[{"lat":28.25,"lon":112.95},{"lat":28.26,"lon":112.96}]}]},
          {"type":"node","id":100,"lat":28.23,"lon":112.94,"tags":{"name":"测试站","railway":"station","station":"subway"}}
        ]}
        """.utf8))
        let key = RailTileKey(layer: .metroNetwork, tile: RailTile(z: 10, x: 833, y: 428))
        let assembly = RailFeatureAssembler.assemble(tiles: [key: features], palette: [:], wiki: [:],
                                                     enrichWiki: false, ledger: RailIdentityLedger(), preview: nil)
        try check(assembly.features.lines.allSatisfy { $0.appearance.colors.first?.hex == "#00B0EC" },
                  "all directions receive the local line colour in the first assembly")
        let identities = Set(assembly.features.lines.flatMap { ($0.routes ?? []).map(\.visibilityKey) })
        try check(identities.count == 1, "different relation/wikidata direction IDs share a physical line colour and switch")
        try check(Set(assembly.features.lines.flatMap { ($0.routes ?? []).map(\.sourceVisibilityKey) }) == ["Q111", "Q222"],
                  "original line switch identities remain available for saved-setting migration")
        try check(assembly.features.stations.first?.routes?.first?.color?.hex == "#00B0EC",
                  "station inherits its line colour in the same assembly")
        let wiki = try JSONDecoder().decode(WikiMetroColour.self, from: Data("""
        {"identity":"Q111","hex":"#112233","sourceName":"Wikidata · P465",
         "sourceURL":"https://www.wikidata.org/wiki/Q111","fetched":0}
        """.utf8))
        let enriched = RailFeatureAssembler.assemble(tiles: [key: features], palette: [:], wiki: ["Q111": wiki],
                                                     enrichWiki: true, ledger: assembly.ledger, preview: nil)
        try check(enriched.features.lines.allSatisfy { $0.appearance.colors.first?.hex == "#112233" }
                  && enriched.features.stations.first?.routes?.first?.color?.hex == "#112233",
                  "one wiki enrichment updates the entire physical line and its station together")
        let reverted = RailFeatureAssembler.assemble(tiles: [key: features], palette: [:], wiki: ["Q111": wiki],
                                                     enrichWiki: false, ledger: enriched.ledger, preview: nil)
        try check(reverted.features.lines.allSatisfy { $0.appearance.colors.first?.hex == "#00B0EC" },
                  "disabling wiki restores local palette without sticky ledger enrichment")
        let requests = MetroColourRequests(lines: Array(repeating: assembly.features.lines, count: 1000).flatMap { $0 },
                                            stations: assembly.features.stations)
        try check(requests.palette.count == 1 && requests.wiki.count == 2,
                  "thousands of fragments request a physical palette once and preserve both wiki IDs")
        var unresolved = assembly.features.lines[0]
        unresolved.routes = [unknown]
        let misses = MetroColourRequests(lines: Array(repeating: unresolved, count: 3000), stations: [])
        try check(misses.distinctRouteCount == 1 && misses.palette.isEmpty && misses.wiki.isEmpty,
                  "unmatched repeated routes are deduplicated without inventing a city")
        let stationRequests = MetroColourRequests(lines: [], stations: assembly.features.stations)
        try check(stationRequests.palette.count == 1 && !stationRequests.wiki.isEmpty,
                  "station-only memberships can still request colours")
        let decomposed = try route("3호선", ["network": "수도권 전철".decomposedStringWithCanonicalMapping, "ref": "3"])
        try check(BundledMetroPalette.match(decomposed)?.line == "s3",
                  "literal city lookup preserves canonical Korean Unicode equivalence")
        print("\(count) local metro palette checks passed.")
    }
}
