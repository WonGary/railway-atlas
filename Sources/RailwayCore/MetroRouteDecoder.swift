import Foundation

/// Route geometry supplies metro colours even when the infrastructure tile has
/// no relation attributes. It is an optional, separately cached enhancement.
public enum MetroRouteDecoder {
    public static func decode(_ data: Data, tile: RailTile? = nil) throws -> RailTileFeatures {
        guard data.count <= VectorTileDecoder.maxBytes else { throw DataError.invalid("线路颜色数据过大") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.remark?.isEmpty != false else { throw DataError.invalid("线路颜色查询未完成，轨道地图仍可浏览") }
        var masters: [Int64: Relation] = [:]
        for master in document.elements.sorted(by: { $0.id < $1.id }) where master.tags?["type"] == "route_master" {
            for member in master.members ?? [] where member.type == "relation" && masters[member.ref] == nil {
                masters[member.ref] = master
            }
        }
        var lines: [String: RailLine] = [:]
        let elements = Dictionary(document.elements.map { ("\($0.type)/\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        var stations: [String: RailStation] = [:]
        var memberships: [String: [RailRoute]] = [:]
        let ways = Dictionary(document.elements.filter { $0.type == "way" }.map { ($0.id, $0.geometry ?? []) },
                              uniquingKeysWith: { first, _ in first })
        var vertices = 0
        for relation in document.elements where relation.type == "relation" {
            var tags = relation.tags ?? [:]
            var colourSource = "relation/\(relation.id)"
            if let master = masters[relation.id] {
                tags["atlas:routeMaster"] = "relation/\(master.id)"
                for field in ["ref", "network", "network:en", "operator", "wikidata", "wikipedia"]
                    + RailUrbanService.evidenceKeys where tags[field] == nil {
                    tags[field] = master.tags?[field]
                }
                if (tags["colour"] ?? tags["color"]).flatMap(RailColor.init) == nil,
                   let colour = master.tags?["colour"] ?? master.tags?["color"], RailColor(colour) != nil {
                    tags["colour"] = colour
                    colourSource = "relation/\(master.id)"
                }
            }
            guard RailUrbanService.supportsRoute(tags) else { continue }
            let route = RailRoute(id: "relation/\(relation.id)",
                                  name: tags["name:zh"] ?? tags["name"] ?? tags["ref"] ?? "城市轨道",
                                  tags: tags, colourSourceID: colourSource)
            for member in relation.members ?? [] where member.type == "way" && ["", "forward", "backward", "route", "inactive"].contains(member.role ?? "") {
                memberships["way/\(member.ref)", default: []].append(route)
                // Clipped Overpass geometry contains null nodes outside the
                // requested box. Split at those gaps, never join across them.
                var paths: [[Coordinate]] = [], path: [Coordinate] = []
                for point in member.geometry ?? ways[member.ref] ?? [] {
                    if let lat = point?.lat, let lon = point?.lon {
                        let coordinate = Coordinate(lat, lon)
                        guard coordinate.isValid else { throw DataError.invalid("线路颜色坐标无效") }
                        path.append(coordinate)
                    } else if !path.isEmpty { paths.append(path); path = [] }
                }
                if !path.isEmpty { paths.append(path) }
                for (part, coords) in paths.enumerated() where coords.count >= 2 {
                    let identity = "metro/\(tile?.path ?? "relation")/way/\(member.ref)/\(part)"
                    if var line = lines[identity] {
                        if !(line.routes ?? []).contains(where: { $0.id == route.id }) { line.routes?.append(route) }
                        lines[identity] = line
                        continue
                    }
                    vertices += coords.count
                    guard vertices <= 500_000, lines.count < 30_000 else { throw DataError.invalid("线路颜色区域过大") }
                    var lineTags = tags
                    // Service evidence belongs to the relation. In particular
                    // service=commuter/metro must not become a depot/service
                    // track category. Preserve the way's lifecycle and speed.
                    for field in RailUrbanService.evidenceKeys { lineTags.removeValue(forKey: field) }
                    for (key, value) in elements["way/\(member.ref)"]?.tags ?? [:] { lineTags[key] = value }
                    if RailCategory.lifecycleCategory(lineTags) == nil,
                       RailCategory.urbanTypes.contains(tags["route"] ?? "") {
                        // Keep the existing metro-network filter for operational
                        // metro overlays, even on railway=rail infrastructure.
                        lineTags["railway"] = tags["route"]
                    } else if lineTags["railway"] == nil {
                        lineTags["railway"] = tags["route"] == "train" ? "rail" : tags["route"]
                    }
                    lineTags["atlas:osm"] = "way/\(member.ref)"
                    lineTags["atlas:routeOverlay"] = "yes"
                    lineTags["atlas:source"] = "OpenStreetMap · 线路关系"
                    lines[identity] = RailLine(id: identity, name: route.name,
                                               coordinates: coords, tags: lineTags, routes: [route])
                }
            }
            for member in relation.members ?? [] where member.type == "node"
                && (member.role ?? "").hasPrefix("stop") {
                let id = "node/\(member.ref)"
                memberships[id, default: []].append(route)
                guard let node = elements[id], let lat = node.lat, let lon = node.lon else { continue }
                if var station = stations[id] {
                    if !(station.routes ?? []).contains(where: { $0.id == route.id }) { station.routes?.append(route) }
                    stations[id] = station
                } else {
                    var stationTags = node.tags ?? [:]
                    if stationTags["railway"] == nil || stationTags["railway"] == "stop" {
                        stationTags["railway"] = "station"
                    }
                    if stationTags["station"] == nil, tags["route"] != "train" { stationTags["station"] = tags["route"] }
                    stationTags["atlas:osm"] = id
                    stationTags["atlas:routeStop"] = "yes"
                    stations[id] = RailStation(id: id, name: stationTags["name:zh"] ?? stationTags["name"] ?? "未命名车站",
                                              coordinate: Coordinate(lat, lon), tags: stationTags, routes: [route])
                }
            }
        }
        // An explicitly tagged urban service track may not belong to a
        // passenger relation. Keep its own name/ref for the palette matcher;
        // neither proximity nor a generic railway name supplies an identity.
        let routeWays = Set(lines.values.compactMap { $0.tags["atlas:osm"] })
        for way in document.elements where way.type == "way"
            && RailCategory.urbanTypes.contains(way.tags?["railway"] ?? "")
            && !routeWays.contains("way/\(way.id)") {
            var parts: [[Coordinate]] = [], part: [Coordinate] = []
            for point in way.geometry ?? [] {
                if let lat = point?.lat, let lon = point?.lon {
                    let coordinate = Coordinate(lat, lon)
                    guard coordinate.isValid else { throw DataError.invalid("线路颜色坐标无效") }
                    part.append(coordinate)
                } else if !part.isEmpty { parts.append(part); part = [] }
            }
            if !part.isEmpty { parts.append(part) }
            for (index, coordinates) in parts.enumerated() where coordinates.count > 1 {
                vertices += coordinates.count
                guard vertices <= 500_000, lines.count < 30_000 else { throw DataError.invalid("线路颜色区域过大") }
                let id = "metro/\(tile?.path ?? "named")/way/\(way.id)/\(index)"
                var tags = way.tags ?? [:]
                tags["atlas:osm"] = "way/\(way.id)"
                tags["atlas:source"] = "OpenStreetMap · 城市轨道"
                tags["atlas:routeOverlay"] = "yes"
                lines[id] = RailLine(id: id, name: tags["name:zh"] ?? tags["name"] ?? "城市轨道",
                                     coordinates: coordinates, tags: tags, routes: nil)
            }
        }
        // Explicit stop_area membership, not distance clustering, supplies
        // transfer colours and rail/metro connections to each separate marker.
        var membership: [String: [RailRoute]] = [:]
        var connections = Set<String>(), representedStops = Set<String>()
        var stopAreaIDs: [String: Set<String>] = [:], stopAreaGroupIDs: [String: Set<String>] = [:]
        for area in document.elements where area.type == "relation" && area.tags?["public_transport"] == "stop_area" {
            let ids = (area.members ?? []).map { "\($0.type)/\($0.ref)" }
            let routes = ids.flatMap { stations[$0]?.routes ?? [] }
            let hasTrain = ids.contains { elements[$0]?.tags?["train"] == "yes" }
            let hasCanonical = ids.contains {
                let tag = elements[$0]?.tags
                return tag?["railway"] == "station" || tag?["railway"] == "halt"
            }
            for id in ids {
                stopAreaIDs[id, default: []].insert("relation/\(area.id)")
                membership[id, default: []].append(contentsOf: routes)
                if hasTrain && !routes.isEmpty { connections.insert(id) }
                if hasCanonical, stations[id]?.tags["atlas:routeStop"] == "yes" { representedStops.insert(id) }
            }
        }
        // Preserve explicit group membership for the inspector projection.
        // Do not spread group routes/colours across the physical station objects.
        // Only traverse supplied stop_area/group relations, never route members
        // or guessed missing children. The visited set also tolerates cycles.
        for group in document.elements where group.type == "relation" && group.tags?["public_transport"] == "stop_area_group" {
            let groupID = "relation/\(group.id)"
            var pending = group.members ?? [], visited: Set<String> = [groupID]
            while let member = pending.popLast() {
                let id = "\(member.type)/\(member.ref)"
                guard visited.insert(id).inserted else { continue }
                stopAreaGroupIDs[id, default: []].insert(groupID)
                if let child = elements[id], child.type == "relation",
                   ["stop_area", "stop_area_group"].contains(child.tags?["public_transport"] ?? "") {
                    pending.append(contentsOf: child.members ?? [])
                }
            }
        }
        for id in representedStops { stations.removeValue(forKey: id) }
        for element in document.elements where ["station", "halt", "tram_stop"].contains(element.tags?["railway"] ?? "") {
            guard let lat = element.lat ?? element.center?.lat,
                  let lon = element.lon ?? element.center?.lon,
                  Coordinate(lat, lon).isValid else { continue }
            let id = "\(element.type)/\(element.id)"
            var tags = element.tags ?? [:]
            tags["atlas:osm"] = id
            tags["atlas:rawStation"] = "yes"
            if connections.contains(id) { tags["atlas:railConnection"] = "yes" }
            let routes = (stations[id]?.routes ?? []) + (membership[id] ?? [])
            stations[id] = RailStation(id: id, name: tags["name:zh"] ?? tags["name"] ?? "未命名车站",
                                       coordinate: Coordinate(lat, lon), tags: tags, routes: routes.isEmpty ? nil : routes)
        }
        for id in Array(stations.keys) {
            guard var station = stations[id] else { continue }
            if let ids = stopAreaIDs[id], !ids.isEmpty {
                station.tags[StationInterchangeIndex.stopAreaTag] = ids.sorted().joined(separator: ";")
            }
            if let ids = stopAreaGroupIDs[id], !ids.isEmpty {
                station.tags[StationInterchangeIndex.stopAreaGroupTag] = ids.sorted().joined(separator: ";")
            }
            station.routes = (station.routes ?? []) + (membership[id] ?? [])
            var seen = Set<String>()
            station.routes = station.routes?.filter { seen.insert($0.id).inserted }
            stations[id] = station
        }
        var result = RailTileFeatures()
        result.lines = lines.values.sorted { $0.id < $1.id }
        result.stations = stations.values.sorted { $0.id < $1.id }
        result.memberships = memberships
        return result
    }

    private struct Document: Decodable { let elements: [Relation]; let remark: String? }
    private struct Relation: Decodable {
        let type: String
        let id: Int64
        let tags: [String: String]?
        let members: [Member]?
        let geometry: [Point?]?
        let lat: Double?
        let lon: Double?
        let center: Point?
    }
    private struct Member: Decodable {
        let type: String
        let ref: Int64
        let role: String?
        let geometry: [Point?]?
    }
    private struct Point: Decodable { let lat: Double?; let lon: Double? }
}
