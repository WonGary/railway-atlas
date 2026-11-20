import Foundation
import RailwayCore

enum StationInterchangeChecks {
    /// Reads the repository's real Beijing snapshot, never the user's cache.
    static func run(snapshotURL: URL? = nil) throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw DataError.invalid("StationInterchange: " + message) }
        }
        func route(_ id: Int, line: String, city: String = "beijing") throws -> RailRoute {
            try JSONDecoder().decode(RailRoute.self, from: JSONSerialization.data(withJSONObject: [
                "id": "relation/\(id)", "name": "Line \(line)", "tags": [
                    "route": "subway", "ref": line, "network": "共同网络",
                    "atlas:paletteIdentity": "metro:\(city):\(line)", "colour": id % 2 == 0 ? "#FF0000" : "#0000FF"
                ]
            ]))
        }
        func station(_ id: Int, _ name: String = "中心", latitude: Double = 39,
                     tags: [String: String] = [:], routes: [RailRoute] = []) throws -> RailStation {
            var station = try JSONDecoder().decode(RailStation.self, from: JSONSerialization.data(withJSONObject: [
                "id": "node/\(id)", "name": name,
                "coordinate": ["latitude": latitude, "longitude": 116.0], "tags": tags
            ]))
            station.routes = routes
            return station
        }
        let areaTag = StationInterchangeIndex.stopAreaTag
        let groupTag = StationInterchangeIndex.stopAreaGroupTag
        let line1 = try route(101, line: "1"), line2 = try route(102, line: "2"), line3 = try route(103, line: "3")

        // Documented membership can connect differently named/distant objects;
        // it never changes their original position, routes or selection IDs.
        let a = try station(1, "站台甲", tags: [areaTag: "relation/10"], routes: [line1])
        let b = try station(2, "站厅乙", latitude: 39.01,
                            tags: [areaTag: "relation/10", "wikidata": "Q1000"], routes: [line2])
        let c = try station(3, "站点丙", latitude: 39.02, tags: ["wikidata": "Q1000"], routes: [line3])
        let original = [a, b, c]
        let documented = StationInterchangeIndex(stations: original)
        try check(documented[a.id]?.confidence == .documented
                  && Set(documented[a.id]?.peers.map(\.id) ?? []) == [b.id, c.id]
                  && documented[a.id]?.routes.count == 3,
                  "explicit stop_area and station Wikidata form a documented complex")
        try check(Set(documented[a.id]?.evidence.map(\.kind) ?? []) == [.stopArea, .wikidata],
                  "documented chains retain their actual witnesses")
        try check(original == [a, b, c] && documented[a.id]?.peers.first(where: { $0.id == b.id })?.station == b,
                  "the projection preserves every original station, coordinate and individual route")
        try check(documented["node/unknown"] == nil, "unknown station IDs have no projection")

        let wikiA = try station(4, "旧名", tags: ["wikipedia": "en:Example_station"])
        let wikiB = try station(5, "新名", tags: ["wikipedia": "en:Example station"])
        try check(StationInterchangeIndex(stations: [wikiA, wikiB])[wikiA.id]?.evidence.first?.kind == .wikipedia,
                  "same station Wikipedia language/title is documented evidence")
        var otherLanguage = wikiB
        otherLanguage.tags["wikipedia"] = "fr:Example station"
        try check(StationInterchangeIndex(stations: [wikiA, otherLanguage])[wikiA.id] == nil,
                  "unverified article translations are not equated")
        let operatorA = try station(6, "甲", tags: ["operator:wikidata": "Q1000"], routes: [line1])
        let operatorB = try station(7, "乙", tags: ["network:wikidata": "Q1000"], routes: [line1])
        try check(StationInterchangeIndex(stations: [operatorA, operatorB])[operatorA.id] == nil,
                  "network/operator/route identities are not station entities")

        let candidateA = try station(20, routes: [line1])
        let candidateB = try station(21, latitude: 39.002, routes: [line2])
        let candidateC = try station(22, latitude: 39.004, routes: [line3])
        let candidates = StationInterchangeIndex(stations: [candidateA, candidateB, candidateC])
        try check(candidates[candidateA.id]?.confidence == .possible
                  && candidates[candidateA.id]?.peers.map(\.id) == [candidateB.id]
                  && candidates[candidateA.id]?.documentedRoutes.map(\.visibilityKey) == [line1.visibilityKey]
                  && candidates[candidateA.id]?.possibleRoutes.map(\.visibilityKey) == [line2.visibilityKey],
                  "same name/context, nearby and distinct lines creates only a possible interchange")
        try check(candidates[candidateB.id]?.peers.count == 2
                  && candidates[candidateC.id]?.peers.map(\.id) == [candidateB.id],
                  "possible links do not chain into distant station complexes")
        let otherCity = try station(23, latitude: 39.001, routes: [route(104, line: "2", city: "tianjin")])
        let otherName = try station(24, "另一站", latitude: 39.001, routes: [line2])
        let remote = try station(25, latitude: 40, routes: [line2])
        let reverse = try station(26, latitude: 39.001, routes: [route(105, line: "1")])
        let noRoutes = try station(27, latitude: 39.001)
        var noContext = try station(28, latitude: 39.001, routes: [line2])
        noContext.routes?[0].tags = ["ref": "2"]
        for item in [otherCity, otherName, remote, reverse, noRoutes, noContext] {
            try check(StationInterchangeIndex(stations: [candidateA, item])[candidateA.id] == nil,
                      "candidate requirements reject \(item.id): city/name/distance/different-line/context")
        }
        var unnamedA = candidateA, unnamedB = candidateB
        unnamedA.name = "未命名车站"; unnamedB.name = "未命名车站"
        try check(StationInterchangeIndex(stations: [unnamedA, unnamedB])[unnamedA.id] == nil,
                  "placeholder names do not establish an interchange")
        for key in ["interchange", "transfer", StationInterchangeIndex.interchangeProhibitedTag] {
            var prohibited = candidateB
            prohibited.tags[key] = "no"
            try check(StationInterchangeIndex(stations: [candidateA, prohibited])[candidateA.id] == nil,
                      "an explicit prohibition suppresses the candidate: \(key)")
            var documentedProhibition = b
            documentedProhibition.tags[key] = "no"
            try check(StationInterchangeIndex(stations: [a, documentedProhibition])[a.id] == nil,
                      "prohibitions also veto shared stop_area suggestions: \(key)")
        }

        // Exact-ID assembly can receive relation metadata only in a later tile.
        var firstTile = candidateA
        var laterTile = candidateA
        laterTile.tags = [areaTag: "relation/40", groupTag: "relation/50",
                          "wikidata": "Q2000", "wikipedia": "zh:中心站"]
        firstTile.tags = StationInterchangeIndex.mergedEvidenceTags(existing: firstTile, incoming: laterTile)
        var thirdTile = candidateA
        thirdTile.tags = [areaTag: "relation/41;relation/40", groupTag: "relation/51",
                          "wikidata": "Q9999", "wikipedia": "zh:其他站"]
        firstTile.tags = StationInterchangeIndex.mergedEvidenceTags(existing: firstTile, incoming: thirdTile)
        try check(firstTile.tags[areaTag] == "relation/40;relation/41"
                  && firstTile.tags[groupTag] == "relation/50;relation/51"
                  && firstTile.tags["wikidata"] == "Q2000" && firstTile.tags["wikipedia"] == "zh:中心站"
                  && firstTile.coordinate == candidateA.coordinate && firstTile.routes == candidateA.routes,
                  "later exact-ID tiles union relation evidence, fill missing entity tags and preserve conflicts")
        let tilePeer = try station(29, "不同站台名", tags: [groupTag: "relation/51"], routes: [line2])
        try check(StationInterchangeIndex(stations: [candidateA, tilePeer])[candidateA.id] == nil
                  && StationInterchangeIndex(stations: [firstTile, tilePeer])[firstTile.id]?.confidence == .documented,
                  "an initially incomplete tile can acquire documented evidence from a later tile")
        try check(StationInterchangeIndex.mergedEvidenceTags(existing: candidateB, incoming: laterTile) == candidateB.tags,
                  "the evidence merge helper refuses a different station ID")
        var prohibitedTile = candidateA
        prohibitedTile.tags["transfer"] = "no"
        firstTile.tags = StationInterchangeIndex.mergedEvidenceTags(existing: firstTile, incoming: prohibitedTile)
        try check(firstTile.tags["transfer"] == "no"
                  && StationInterchangeIndex(stations: [firstTile, tilePeer])[firstTile.id] == nil,
                  "a later exact-ID prohibition survives evidence merging and blocks suggestions")

        let relationData = Data("""
        {"elements":[
          {"type":"relation","id":101,"tags":{"route":"subway","ref":"1","network":"测试"},"members":[{"type":"node","ref":1,"role":"stop"}]},
          {"type":"relation","id":102,"tags":{"route":"subway","ref":"2","network":"测试"},"members":[{"type":"node","ref":2,"role":"stop"}]},
          {"type":"relation","id":103,"tags":{"route":"subway","ref":"3","network":"测试"},"members":[{"type":"node","ref":3,"role":"stop"}]},
          {"type":"relation","id":201,"tags":{"public_transport":"stop_area"},"members":[{"type":"node","ref":1}]},
          {"type":"relation","id":202,"tags":{"public_transport":"stop_area"},"members":[{"type":"node","ref":2}]},
          {"type":"relation","id":203,"tags":{"public_transport":"stop_area"},"members":[{"type":"node","ref":1}]},
          {"type":"relation","id":301,"tags":{"public_transport":"stop_area_group"},"members":[{"type":"relation","ref":201},{"type":"relation","ref":202},{"type":"relation","ref":302},{"type":"relation","ref":103}]},
          {"type":"relation","id":302,"tags":{"public_transport":"stop_area_group"},"members":[{"type":"relation","ref":301},{"type":"relation","ref":999}]},
          {"type":"node","id":1,"lat":39,"lon":116,"tags":{"railway":"station","name":"甲"}},
          {"type":"node","id":2,"lat":39.001,"lon":116,"tags":{"railway":"station","name":"乙"}},
          {"type":"node","id":3,"lat":39.001,"lon":116,"tags":{"railway":"station","name":"丙"}}
        ]}
        """.utf8)
        let decoded = try MetroRouteDecoder.decode(relationData).stations
        guard let first = decoded.first(where: { $0.id == "node/1" }),
              let second = decoded.first(where: { $0.id == "node/2" }),
              let unrelated = decoded.first(where: { $0.id == "node/3" }) else {
            throw DataError.invalid("StationInterchange: decoder lost physical station objects")
        }
        try check(decoded.count == 3 && first.tags[areaTag] == "relation/201;relation/203"
                  && second.tags[areaTag] == "relation/202"
                  && first.tags[groupTag] == "relation/301;relation/302"
                  && second.tags[groupTag] == first.tags[groupTag],
                  "decoder retains all explicit area/group IDs, including nested/cyclic groups")
        try check(first.routes?.count == 1 && second.routes?.count == 1
                  && unrelated.tags[groupTag] == nil,
                  "groups never propagate route colours or traverse a route relation as a stop_area")
        let groupIndex = StationInterchangeIndex(stations: decoded)
        try check(groupIndex[first.id]?.routes.count == 2
                  && groupIndex[first.id]?.evidence.contains(where: { $0.kind == .stopAreaGroup }) == true
                  && groupIndex[unrelated.id] == nil,
                  "group-based route union exists only in the inspector projection")

        // A small, exact slice of the actual bundled OSM snapshot, not invented
        // geometry or an external/cache fixture. Keep the source's route tags.
        let url = snapshotURL ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RailwayCore/Resources/metro-snapshot-beijing.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let ids: Set<Int64> = [245154338, 1306482810, 6617852357, 12433885695, 12433885696, 12435251104]
        let relations: Set<Int64> = [417951, 18444658, 1667375, 1667376, 18441518, 18441519, 1606927, 18444149]
        let elements = (document?["elements"] as? [[String: Any]] ?? []).compactMap { element -> [String: Any]? in
            guard let id = (element["id"] as? NSNumber)?.int64Value, let type = element["type"] as? String,
                  (type == "node" && ids.contains(id)) || (type == "relation" && relations.contains(id)) else { return nil }
            var element = element
            if type == "relation", let members = element["members"] as? [[String: Any]] {
                let isMaster = (element["tags"] as? [String: String])?["type"] == "route_master"
                element["members"] = members.filter {
                    let ref = ($0["ref"] as? NSNumber)?.int64Value ?? -1
                    return isMaster ? $0["type"] as? String == "relation" && relations.contains(ref)
                        : $0["type"] as? String == "node" && ids.contains(ref)
                }
            }
            return element
        }
        let guangximen = try MetroRouteDecoder.decode(JSONSerialization.data(withJSONObject: ["elements": elements])).stations
        guard let thirteen = guangximen.first(where: { $0.id == "node/6617852357" }),
              let twelve = guangximen.first(where: { $0.id == "node/12435251104" }) else {
            throw DataError.invalid("StationInterchange: actual Guangximen stations missing from snapshot")
        }
        try check(guangximen.count == 2 && thirteen.coordinate == Coordinate(39.9669843, 116.425641)
                  && twelve.coordinate == Coordinate(39.9680699, 116.4242608)
                  && thirteen.tags[areaTag] == "relation/1606927" && twelve.tags[areaTag] == "relation/18444149"
                  && thirteen.tags[groupTag] == nil && twelve.tags[groupTag] == nil
                  && thirteen.tags["wikidata"] == "Q5613705" && twelve.tags["wikidata"] == nil
                  && twelve.tags["wikipedia"] == nil,
                  "actual Guangximen nodes keep two positions and two separate stop_area memberships")
        let actual = StationInterchangeIndex(stations: guangximen)
        let route13 = Set((thirteen.routes ?? []).map(\.visibilityKey))
        let route12 = Set((twelve.routes ?? []).map(\.visibilityKey))
        try check(route13 == ["Q847744"] && route12 == ["Q26262009"]
                  && Set(actual[thirteen.id]?.routes.map(\.visibilityKey) ?? []) == route13.union(route12)
                  && Set(actual[thirteen.id]?.routes.compactMap { $0.tags["ref"] } ?? []) == ["12", "13"]
                  && Set((thirteen.routes ?? []).compactMap { $0.tags["atlas:routeMaster"] }) == ["relation/417951"]
                  && Set((twelve.routes ?? []).compactMap { $0.tags["atlas:routeMaster"] }) == ["relation/18444658"]
                  && actual[thirteen.id]?.peers.first?.station == twelve
                  && actual[twelve.id]?.peers.first?.station == thirteen,
                  "real 12/13 route identities appear together without merging or recolouring either station")
        let official = actual[thirteen.id]?.evidence.first { $0.kind == .official }
        try check(actual[thirteen.id]?.confidence == .documented
                  && actual[twelve.id]?.confidence == .documented
                  && actual[thirteen.id]?.documentedRoutes.count == 2
                  && actual[thirteen.id]?.possibleRoutes.isEmpty == true
                  && official?.sourceURL?.absoluteString == "https://www.bjsubway.com/station/siteinfo.html?loc=150998319"
                  && official?.supportingURLs.first?.absoluteString == "https://news.qq.com/rain/a/20250211A07WHU00"
                  && Set(official?.stationIDs ?? []) == [thirteen.id, twelve.id]
                  && actual[thirteen.id]?.passageNotice.contains("付费区内换乘") == true
                  && actual[thirteen.id]?.passageNotice.contains("未核实") == false
                  && guangximen == [twelve, thirteen].sorted(by: { $0.id < $1.id }),
                  "official exact-ID supplement documents Guangximen 12/13 and its paid-area passage without altering OSM")
        let withoutOfficial = StationInterchangeIndex(stations: guangximen, officialRecords: [])
        try check(withoutOfficial[thirteen.id]?.confidence == .possible
                  && withoutOfficial[thirteen.id]?.evidence.allSatisfy({ $0.kind == .nameContextNearby }) == true
                  && withoutOfficial[thirteen.id]?.passageNotice.contains("未核实") == true,
                  "without a sourced supplement the same OSM data remains a cautious candidate")
        var sameNameOtherID = twelve
        sameNameOtherID.id = "node/999999"
        let wrongID = StationInterchangeIndex(stations: [thirteen, sameNameOtherID])
        try check(wrongID[thirteen.id]?.confidence == .possible
                  && wrongID[thirteen.id]?.evidence.contains(where: { $0.kind == .official }) == false
                  && StationInterchangeIndex(stations: [thirteen])[thirteen.id] == nil,
                  "official records neither match by name/proximity nor create a missing physical station")
        sameNameOtherID.tags.removeValue(forKey: areaTag)
        let neighbouringCandidate = StationInterchangeIndex(stations: guangximen + [sameNameOtherID])
        try check(neighbouringCandidate[sameNameOtherID.id]?.confidence == .possible
                  && neighbouringCandidate[sameNameOtherID.id]?.passageNotice.contains("未核实") == true
                  && neighbouringCandidate[sameNameOtherID.id]?.passageNotice.contains("付费区内换乘") == false,
                  "official passage wording cannot leak to a neighbouring candidate")
        var prohibitedActual = twelve
        prohibitedActual.tags["transfer"] = "no"
        try check(StationInterchangeIndex(stations: [thirteen, prohibitedActual])[thirteen.id] == nil,
                  "an explicit prohibition still vetoes an official supplement")
        print("PASS station interchange projection: official Guangximen 12/13, cautious candidates, exact-ID tile union and no merging.")
    }
}
