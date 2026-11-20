import Foundation
import RailwayCore

enum UrbanTransitChecks {
    static func run() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw DataError.invalid("Urban transit: " + message) }
            count += 1
        }
        func line(_ tags: [String: String], routes: [RailRoute] = []) throws -> RailLine {
            var result = try JSONDecoder().decode(RailLine.self, from: JSONSerialization.data(withJSONObject: [
                "id": "way/1", "name": "城市内的轨道",
                "coordinates": [["latitude": 31.2, "longitude": 121.3], ["latitude": 31.21, "longitude": 121.31]],
                "tags": tags
            ]))
            result.routes = routes.isEmpty ? nil : routes
            return result
        }
        func route(_ id: Int, _ tags: [String: String]) throws -> RailRoute {
            try JSONDecoder().decode(RailRoute.self, from: JSONSerialization.data(withJSONObject: [
                "id": "relation/\(id)", "name": "都市圈铁路", "tags": tags
            ]))
        }
        func station(_ tags: [String: String], routes: [RailRoute] = []) throws -> RailStation {
            var result = try JSONDecoder().decode(RailStation.self, from: JSONSerialization.data(withJSONObject: [
                "id": "node/1", "name": "同城车站",
                "coordinate": ["latitude": 31.2, "longitude": 121.3], "tags": tags
            ]))
            result.routes = routes.isEmpty ? nil : routes
            return result
        }
        let commuter = try route(10, ["route": "train", "passenger": "suburban"])
        let metro = try route(11, ["route": "subway"])
        let intercity = try route(12, ["route": "train", "service": "high_speed", "passenger": "national"])
        let natives = try ["subway", "light_rail", "monorail", "tram"].map { try line(["railway": $0]) }
        let commuterTrack = try line(["railway": "rail", "maxspeed": "160", "ownership": "private"], routes: [commuter])
        try check(natives.allSatisfy(\.isUrbanTransit), "four operational urban modes must qualify")
        try check(commuterTrack.isUrbanTransit && commuterTrack.category == .speed160
                  && RailNetwork.classify(commuterTrack.tags) == .industrial,
                  "explicit commuter service is independent of speed and private-ownership network")
        for field in RailUrbanService.evidenceKeys {
            try check(try line(["railway": "rail", field: "suburban"]).isUrbanTransit,
                      "explicit service evidence: \(field)")
        }
        for tags in [
            ["railway": "rail", "operator": "JR East", "network": "Tokyo", "usage": "main"],
            ["railway": "rail", "ownership": "private", "operator:type": "private"],
            ["railway": "rail", "passenger": "yes", "usage": "main"],
            ["railway": "rail", "service": "regional", "passenger": "regional"],
            ["railway": "rail", "railway:traffic_mode": "freight", "passenger": "suburban"],
            ["railway": "rail", "usage": "industrial", "passenger": "urban"],
            ["railway": "rail", "passenger": "no", "service": "commuter"],
            ["railway": "tram", "usage": "tourism"]
        ] {
            try check(try !line(tags).isUrbanTransit, "city/operator/general passenger/freight/tourism is not urban evidence: \(tags)")
        }
        try check(try !line(["railway": "rail"], routes: [intercity]).isUrbanTransit,
                  "a train relation alone does not qualify")

        var policy = RailVisibilityPolicy()
        policy.zoom = 12
        policy.categories = []
        policy.networks = []
        let operational = natives + [commuterTrack, try line(["railway": "rail"], routes: [metro])]
        for candidate in operational {
            try check(policy.visible(candidate) == nil, "priority off respects disabled filters")
            policy.prioritizesUrbanTransit = true
            try check(policy.visible(candidate) != nil, "priority on bypasses both disabled filters")
            try check(policy.visible(candidate, suppressed: true) == nil, "priority does not duplicate a suppressed base way")
            policy.prioritizesUrbanTransit = false
        }
        policy.categories = Set(RailCategory.allCases)
        policy.networks = Set(RailNetwork.allCases)
        try check(operational.allSatisfy { policy.visible($0) != nil }, "off must not mean hide all urban transit")

        // Exercise the exact policy consumed by the map against legacy AND
        // semantics, then prove the priority switch leaves stored sets intact.
        for candidate in operational {
            for categoryOn in [false, true] { for networkOn in [false, true] {
                policy.categories = categoryOn ? [candidate.category] : []
                policy.networks = networkOn ? [.classify(candidate.tags)] : []
                let categories = policy.categories, networks = policy.networks
                try check((policy.visible(candidate) != nil) == (categoryOn && networkOn), "legacy filter truth table")
                policy.prioritizesUrbanTransit = true
                try check(policy.visible(candidate) != nil, "additive priority truth table")
                policy.prioritizesUrbanTransit = false
                try check(policy.categories == categories && policy.networks == networks
                          && (policy.visible(candidate) != nil) == (categoryOn && networkOn), "turning off restores previous preferences")
            }}
        }
        policy.categories = []
        policy.networks = []
        policy.prioritizesUrbanTransit = true
        for state in ["construction", "proposed", "disused", "abandoned", "razed"] {
            for tags in [
                ["railway": state, state: "subway"],
                ["railway": "subway", "\(state):railway": "subway"],
                ["railway": "rail", state: "yes", "passenger": "suburban"]
            ] {
                let inactive = try line(tags, routes: [commuter])
                try check(!inactive.isUrbanTransit && policy.visible(inactive) == nil, "lifecycle beats urban priority: \(state)")
                var ordinary = policy
                ordinary.categories = [inactive.category]
                ordinary.networks = [.classify(inactive.tags)]
                try check(ordinary.visible(inactive) != nil, "explicit lifecycle and network controls still work: \(state)")
            }
        }
        policy.hiddenRoutes = [commuter.visibilityKey]
        try check(policy.visible(commuterTrack) == nil, "whole-line hide beats priority")
        let shared = try line(["railway": "rail", "maxspeed": "160"], routes: [commuter, intercity])
        try check(policy.visible(shared) == nil, "hidden commuter route cannot promote the remaining intercity service")
        policy.categories = [.speed160]; policy.networks = [.railway]
        try check(policy.visible(shared)?.routes == [intercity], "other visible service on shared infrastructure remains")
        policy.hiddenRoutes = []

        var overview = natives[0]
        overview.tags["atlas:nationalOverview"] = "yes"
        policy.categories = []; policy.networks = []
        policy.hasNationalMetroOverview = true
        policy.zoom = 4
        try check(policy.visible(overview) != nil, "priority can bypass filters for enabled overview")
        policy.showsNationalMetroOverview = false
        policy.automaticDetail = false
        try check(policy.visible(overview) == nil && policy.visible(natives[0]) != nil,
                  "overview data gate wins even with priority, cached geometry and automatic detail off")
        policy.showsNationalMetroOverview = true
        policy.automaticDetail = true
        try check(policy.visible(natives[0]) == nil, "detailed geometry keeps low-zoom protection")
        policy.forcedCategories = [.urban]; policy.forcedNetworks = [.metro]
        try check(policy.visible(natives[0]) != nil, "existing manual zoom overrides remain effective")
        policy.forcedCategories = []; policy.forcedNetworks = []
        overview.tags["atlas:overviewLOD"] = "country"
        policy.zoom = 8
        try check(policy.visible(overview) == nil, "priority preserves country/detail handoff")
        overview.tags["atlas:overviewLOD"] = "detail"
        policy.zoom = 7
        try check(policy.visible(overview) == nil, "detail remainder is not drawn at country scale")
        policy.zoom = 12

        let urbanStation = try station(["railway": "station"], routes: [commuter])
        try check(policy.visible(urbanStation) != nil, "explicit commuter station can bypass its network switch")
        policy.showsStations = false
        try check(policy.visible(urbanStation) == nil, "station master switch wins")
        policy.showsStations = true
        policy.hiddenRoutes = [commuter.visibilityKey]
        try check(policy.visible(urbanStation) == nil, "station's hidden route wins")
        policy.hiddenRoutes = []
        try check(try policy.visible(station(["railway": "station", "train": "yes", "operator:type": "private"])) == nil,
                  "nearby ordinary/private railway station is not promoted")
        try check(try policy.visible(station(["railway": "station", "station": "subway", "construction:railway": "station"])) == nil,
                  "urban priority cannot revive an unfinished station")
        policy.zoom = 9
        try check(policy.visible(urbanStation) == nil, "ordinary station detail zoom retained")
        policy.zoom = 7
        let connection = try station(["railway": "station", "train": "yes"], routes: [metro])
        try check(policy.visible(connection) == nil, "connection stations retain the minimum station zoom")

        try decoderChecks(check)
        try realDataChecks(check)
        print("PASS \(count) urban transit classification, priority, lifecycle, station, decoder and real-data checks.")
    }

    private static func decoderChecks(_ check: (Bool, String) throws -> Void) throws {
        let source = Data("""
        {"elements":[
          {"type":"relation","id":100,"tags":{"type":"route_master","route_master":"train","passenger":"suburban"},
           "members":[{"type":"relation","ref":10}]},
          {"type":"relation","id":10,"tags":{"type":"route","route":"train","service":"commuter"},
           "members":[{"type":"way","ref":1},{"type":"node","ref":20,"role":"stop"}]},
          {"type":"relation","id":11,"tags":{"type":"route","route":"subway"},
           "members":[{"type":"way","ref":2},{"type":"way","ref":3}]},
          {"type":"relation","id":12,"tags":{"type":"route","route":"train","service":"regional"},
           "members":[{"type":"way","ref":4}]},
          {"type":"way","id":1,"tags":{"railway":"rail","maxspeed":"160","ownership":"private"},
           "geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]},
          {"type":"way","id":2,"tags":{"railway":"construction","construction":"subway"},
           "geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]},
          {"type":"way","id":3,"tags":{"railway":"abandoned"},
           "geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]},
          {"type":"way","id":4,"tags":{"railway":"rail"},
           "geometry":[{"lat":31.2,"lon":121.3},{"lat":31.21,"lon":121.31}]},
          {"type":"node","id":20,"tags":{"railway":"station","train":"yes"},"lat":31.2,"lon":121.3}
        ]}
        """.utf8)
        let decoded = try MetroRouteDecoder.decode(source)
        let train = decoded.lines.first { $0.tags["atlas:osm"] == "way/1" }!
        try check(train.isUrbanTransit && train.category == .speed160 && train.tags["service"] == nil
                  && train.routes?.first?.tags["passenger"] == "suburban",
                  "Overpass preserves commuter membership and master evidence without treating route service as a siding")
        try check(decoded.lines.first { $0.tags["atlas:osm"] == "way/2" }?.category == .construction
                  && decoded.lines.first { $0.tags["atlas:osm"] == "way/3" }?.category == .abandoned,
                  "relation decoder preserves real way lifecycle instead of replacing it with subway")
        try check(!decoded.lines.contains { $0.tags["atlas:osm"] == "way/4" },
                  "regional train with no urban evidence is excluded from the urban relation overlay")
        try check(decoded.stations.first?.isUrbanTransit == true, "commuter stop membership reaches stations")
        let package = try RailwayCodec.decodeOverpass(source, bounds: .shanghai, name: "test", sourceURL: "https://example.test")
        let restored = try RailwayCodec.decode(RailwayCodec.encode(package))
        try check(restored.lines.first { $0.id == "way/1" }?.isUrbanTransit == true
                  && restored.stations.first?.isUrbanTransit == true,
                  "offline package preserves train relation evidence on ways and stops")
        var ledger = RailIdentityLedger()
        _ = ledger.apply(decoded)
        var partial = decoded
        partial.lines[0].routes = nil
        partial.stations[0].routes = nil
        try check(ledger.apply(partial).stations.first?.isUrbanTransit == true,
                  "identity ledger retains explicit commuter stop evidence across partial source responses")
        let key = RailTileKey(layer: .tracks, tile: RailTile(z: 11, x: 1686, y: 775))
        let railwayTile = OnlineChecks.tileFixture(tags: [
            ("feature", "rail"), ("maxspeed", "160"),
            ("line_routes", #"[{"route_id":10,"route":"train","passenger":"suburban"},{"route_id":12,"route":"train","service":"regional"}]"#)
        ])
        let railway = try VectorTileDecoder.decode(railwayTile, key: key).lines[0]
        try check(railway.isUrbanTransit && railway.category == .speed160
                  && railway.routes?.map(\.id) == ["relation/10"],
                  "MVT railway relation evidence survives without promoting ordinary regional services")
        let withoutEvidence = OnlineChecks.tileFixture(tags: [
            ("feature", "rail"), ("line_routes", #"[{"route_id":12,"route":"train","service":"regional"}]"#)
        ])
        try check(try !VectorTileDecoder.decode(withoutEvidence, key: key).lines[0].isUrbanTransit,
                  "MVT train-only membership does not invent urban service")
        let nativeOnRail = Data(String(decoding: source, as: UTF8.self).replacingOccurrences(
            of: #""railway":"construction","construction":"subway""#, with: #""railway":"rail""#).utf8)
        let native = try MetroRouteDecoder.decode(nativeOnRail).lines.first { $0.tags["atlas:osm"] == "way/2" }!
        try check(RailNetwork.classify(native.tags) == .metro, "operational metro relation keeps its previous network switch")
    }

    private static func realDataChecks(_ check: (Bool, String) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shanghai = try RailwayCodec.decode(Data(contentsOf: root.appendingPathComponent("Sources/RailwayAtlas/Resources/shanghai.railmap")))
        let mainline = shanghai.lines.first { $0.id == "way/24943912" }!
        let yard = shanghai.lines.first { $0.id == "way/39181401" }!
        let subway = shanghai.lines.first { $0.tags["railway"] == "subway" && $0.category == .urban }!
        var policy = RailVisibilityPolicy()
        policy.categories = []; policy.networks = []
        policy.prioritizesUrbanTransit = true; policy.zoom = 14
        try check(!mainline.isUrbanTransit && policy.visible(mainline) == nil,
                  "real Shanghai Hukun mainline in the city is not automatically urban")
        try check(!yard.isUrbanTransit && policy.visible(yard) == nil, "real Shanghai industrial yard is not promoted")
        try check(policy.visible(subway) != nil, "real Shanghai subway survives disabled category/network filters")
        let inactive = shanghai.lines.filter { [.construction, .disused, .abandoned].contains($0.category) }
        try check(!inactive.isEmpty && inactive.allSatisfy { !$0.isUrbanTransit && policy.visible($0) == nil },
                  "all real Shanghai construction/disused records remain outside priority")
        for city in ["hongkong", "tokyo", "macao"] {
            let features = try MetroRouteDecoder.decode(Data(contentsOf: root.appendingPathComponent(
                "Sources/RailwayCore/Resources/metro-snapshot-\(city).json")))
            let operational = features.lines.filter(\.isUrbanTransit)
            try check(!operational.isEmpty && operational.allSatisfy {
                (policy.visible($0) != nil) == !RailLineDisplayFacts($0).serviceTrack
            }, "real \(city) urban priority preserves service-track scale limits")
            policy.zoom = 16
            try check(operational.allSatisfy { policy.visible($0) != nil },
                      "real \(city) urban priority restores service tracks in close-up")
            policy.zoom = 14
            let lifecycle = features.lines.filter { RailCategory.lifecycleCategory($0.tags) != nil }
            try check(lifecycle.allSatisfy { policy.visible($0) == nil }, "real \(city) lifecycle boundary retained")
        }
        let national = try NationalMetroSnapshot.decode(Data(contentsOf: root.appendingPathComponent(
            "Sources/RailwayCore/Resources/china-metro-overview.json")))
        policy.hasNationalMetroOverview = true; policy.zoom = 4
        let visible = national.lines.compactMap { policy.visible($0) }
        try check(Set(visible.flatMap { ($0.routes ?? []).map(\.visibilityKey) }).count > 300,
                  "real national overview can bypass network/category filters with explicit priority")
        policy.showsNationalMetroOverview = false
        try check(national.lines.allSatisfy { policy.visible($0) == nil },
                  "all real national overview fragments obey the independent master gate")
    }
}
