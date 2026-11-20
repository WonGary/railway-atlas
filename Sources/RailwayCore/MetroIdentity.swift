import Foundation

/// One colour decision for every fragment and station of the same line.
/// Exact memberships take priority; bounded geometry fallback is marked as inferred.
public enum MetroIdentity {
    public static func unify(lines: [RailLine], stations: [RailStation]) -> RailTileFeatures {
        let all = lines.flatMap { $0.routes ?? [] } + stations.flatMap { $0.routes ?? [] }
        let groups = Dictionary(grouping: all, by: \.visibilityKey)
        var palette: [String: RailRoute] = [:]
        for (key, routes) in groups {
            let ordered = routes.sorted {
                func rank(_ r: RailRoute) -> Int {
                    OfficialMetroPalette.color(for: r.tags) != nil ? 0 :
                        r.tags["atlas:wikiColour"] != nil ? 1 : r.tags["atlas:paletteColour"] != nil ? 2 :
                        r.tags["atlas:bundledColour"] != nil ? 3 : r.color != nil ? 4 : 5
                }
                return rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1)
            }
            palette[key] = ordered.first
        }
        func normalized(_ routes: [RailRoute]?) -> [RailRoute]? {
            var seen = Set<String>()
            return routes?.filter { seen.insert($0.id).inserted }.map { route in
                guard let canonical = palette[route.visibilityKey], let color = canonical.color else { return route }
                var result = route
                if let old = route.tags["colour"], old != color.hex { result.tags["atlas:originalColour"] = old }
                result.tags["colour"] = color.hex
                result.colourSourceID = canonical.colourSourceID
                for field in ["atlas:wikiColour", "atlas:wikiSource", "atlas:wikiURL", "atlas:paletteColour",
                              "atlas:paletteURL", "atlas:bundledColour"] {
                    result.tags[field] = canonical.tags[field]
                }
                return result
            }
        }
        // Exact OSM-way identities propagate memberships to infrastructure
        // fragments as well as route overlays.
        let byWay = Dictionary(grouping: lines.filter { !($0.routes ?? []).isEmpty },
                               by: { $0.tags["atlas:osm"] ?? $0.id })
        let identified = lines.map { line in
            var line = line
            if (line.routes ?? []).isEmpty, let matches = byWay[line.tags["atlas:osm"] ?? line.id] {
                line.routes = matches.flatMap { $0.routes ?? [] }
            }
            return line
        }
        var nameIndex = MetroNameIndex(lines: identified)
        let routeBounds = Dictionary(grouping: lines.filter { !($0.routes ?? []).isEmpty }
            .flatMap { line in (line.routes ?? []).map { ($0.visibilityKey, line.coordinates) } }, by: { $0.0 })
            .mapValues { entries -> MapBounds in
                let points = entries.flatMap { $0.1 }
                return MapBounds(south: (points.map(\.latitude).min() ?? 0) - 0.03,
                                 west: (points.map(\.longitude).min() ?? 0) - 0.03,
                                 north: (points.map(\.latitude).max() ?? 0) + 0.03,
                                 east: (points.map(\.longitude).max() ?? 0) + 0.03)
            }
        var result = RailTileFeatures()
        result.lines = identified.map { line in
            var line = line
            if (line.routes ?? []).isEmpty, let route = nameIndex.match(line) {
                line.routes = [route]
                line.tags["atlas:routeMatch"] = "已确认的同名区段 · 类型 / 网络 / 地区筛选；歧义时要求唯一端点连接（8m）"
                nameIndex.recordEndpoints(line, route: route)
            }
            // A service track can explicitly name its line even when omitted
            // from passenger route relations. Do not use proximity alone.
            if (line.routes ?? []).isEmpty, RailCategory.urbanTypes.contains(line.tags["railway"] ?? "") {
                let matches = palette.values.filter { route in
                    guard let bounds = routeBounds[route.visibilityKey],
                          line.coordinates.contains(where: {
                              $0.latitude >= bounds.south && $0.latitude <= bounds.north
                                  && $0.longitude >= bounds.west && $0.longitude <= bounds.east
                          }) else { return false }
                    if let network = line.tags["network"], let routeNetwork = route.tags["network"],
                       !network.isEmpty, network != routeNetwork { return false }
                    if let network = line.tags["network"], let ref = line.tags["ref"],
                       network == route.tags["network"], ref == route.tags["ref"] { return true }
                    let name = (line.tags["name"] ?? "")
                        .replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
                    let routeName = route.name.components(separatedBy: CharacterSet(charactersIn: ":：")).first ?? ""
                    if name.count >= 4 && name == routeName { return true }
                    if let ref = route.tags["ref"], ref.allSatisfy(\.isNumber), !ref.isEmpty {
                        let number = ref + "号线"
                        for prefix in Set(["", "地铁", route.tags["network"] ?? ""]) {
                            let base = prefix + number
                            guard name.hasPrefix(base) else { continue }
                            let suffix = String(name.dropFirst(base.count))
                            if suffix.isEmpty { return true }
                            // Explicit extension names identify the same line;
                            // arbitrary suffixes and other line numbers do not.
                            let pattern = #"^\(?[东西南北]延(?:伸)?(?:线|段)?\)?$"#
                            if suffix.range(of: pattern, options: .regularExpression) != nil { return true }
                        }
                    }
                    return false
                }
                if matches.count == 1 {
                    line.routes = Array(matches)
                    line.tags["atlas:routeMatch"] = "明确线路名称 / 编号 · 与已知线路范围相交"
                }
            }
            line.routes = normalized(line.routes)
            return line
        }
        // Resolve short same-name terminal chains in bounded passes. A
        // crossing, different name or ambiguous junction cannot propagate.
        var pending = result.lines.indices.filter { (result.lines[$0].routes ?? []).isEmpty }
        for _ in 0..<4 where !pending.isEmpty {
            var remaining: [Int] = []
            for i in pending {
                if let route = nameIndex.match(result.lines[i]) {
                    result.lines[i].routes = normalized([route])
                    result.lines[i].tags["atlas:routeMatch"] = "已确认同名线路 · 唯一端点连接 / 地区与网络匹配"
                    nameIndex.recordEndpoints(result.lines[i], route: route)
                } else { remaining.append(i) }
            }
            if remaining.count == pending.count { break }
            pending = remaining
        }
        // A tile boundary can split an explicitly named extension. Once one
        // fragment is identified, every fragment of that exact OSM way follows.
        let identifiedWays = Dictionary(grouping: result.lines.filter { !($0.routes ?? []).isEmpty },
                                       by: { $0.tags["atlas:osm"] ?? $0.id })
        for index in result.lines.indices where (result.lines[index].routes ?? []).isEmpty {
            let key = result.lines[index].tags["atlas:osm"] ?? result.lines[index].id
            if let fragments = identifiedWays[key] {
                result.lines[index].routes = normalized(fragments.flatMap { $0.routes ?? [] })
                result.lines[index].tags["atlas:routeMatch"] = "同一 OSM way 的已识别区段"
            }
        }
        let stationTracks = result.lines.filter {
            !($0.routes ?? []).isEmpty && $0.tags["service"] == nil
        }.map { line in
            (line, MapBounds(south: line.coordinates.map(\.latitude).min() ?? 0,
                             west: line.coordinates.map(\.longitude).min() ?? 0,
                             north: line.coordinates.map(\.latitude).max() ?? 0,
                             east: line.coordinates.map(\.longitude).max() ?? 0))
        }
        let stationTrackIndex = RailSpatialIndex(bounds: stationTracks.map { $0.1 })
        let byStation = Dictionary(grouping: stations.filter { !($0.routes ?? []).isEmpty },
                                   by: { $0.tags["atlas:osm"] ?? $0.id })
        func stationName(_ name: String) -> String {
            name.count > 2 && name.hasSuffix("站") ? String(name.dropLast()) : name
        }
        func names(_ station: RailStation) -> Set<String> {
            Set(([station.name] + ["name", "name:ja", "name:zh", "name:en"].compactMap { station.tags[$0] })
                .map(stationName).filter { !$0.isEmpty && $0 != "未命名车站" })
        }
        var byName: [String: [RailStation]] = [:]
        for station in stations where !(station.routes ?? []).isEmpty {
            for name in names(station) { byName[name, default: []].append(station) }
        }
        result.stations = stations.map { station in
            var station = station
            if (station.routes ?? []).isEmpty {
                station.routes = byStation[station.tags["atlas:osm"] ?? station.id]?.flatMap { $0.routes ?? [] }
            }
            if (station.routes ?? []).isEmpty, [.metro, .lightRail, .tram].contains(station.network),
               !station.name.isEmpty, station.name != "未命名车站" {
                // The infrastructure tile may use a station-centre ID instead
                // of its platform-stop IDs. Exact name + urban mode + bounded
                // same-station location associates colours without moving,
                // deleting or clustering either marker.
                let matches = names(station).flatMap { byName[$0] ?? [] }.filter {
                    MapAlignment.distance(station.coordinate, $0.coordinate) <= 180
                }
                if !matches.isEmpty {
                    station.routes = matches.flatMap { $0.routes ?? [] }
                    station.tags["atlas:routeMatch"] = "同名城市轨道站点（含原文名称）· 180m 内，保留独立位置"
                }
            }
            if (station.routes ?? []).isEmpty, [.metro, .lightRail, .tram].contains(station.network) {
                // A centre from a base tile may have no stop relation at all.
                // Infer only a unique same-mode line within 60 m, never infer a
                // transfer from nearby lines, and retain the original marker.
                var candidates: [String: RailRoute] = [:]
                let point = station.coordinate
                let margin = 60 / 111_195.0
                let lonMargin = margin / max(0.1, cos(point.latitude * .pi / 180))
                let nearby = MapBounds(south: point.latitude - margin, west: point.longitude - lonMargin,
                                       north: point.latitude + margin, east: point.longitude + lonMargin)
                for index in stationTrackIndex.query(nearby) {
                    let (track, bounds) = stationTracks[index]
                    guard RailNetwork.classify(track.tags) == station.network,
                          point.latitude >= bounds.south - margin, point.latitude <= bounds.north + margin,
                          point.longitude >= bounds.west - lonMargin, point.longitude <= bounds.east + lonMargin,
                          zip(track.coordinates, track.coordinates.dropFirst()).contains(where: {
                              distance(point, from: $0.0, to: $0.1) <= 60
                          }) else { continue }
                    for route in track.routes ?? [] { candidates[route.visibilityKey] = route }
                }
                if candidates.count == 1 {
                    station.routes = Array(candidates.values)
                    station.tags["atlas:routeMatch"] = "几何关联（推定）· 60m 内唯一已知同类型线路；保留独立位置"
                }
            }
            station.routes = normalized(station.routes)
            return station
        }
        return result
    }

    private static func distance(_ point: Coordinate, from a: Coordinate, to b: Coordinate) -> Double {
        let scale = 111_195.0, longitudeScale = scale * cos(point.latitude * .pi / 180)
        let ax = (a.longitude - point.longitude) * longitudeScale, ay = (a.latitude - point.latitude) * scale
        let bx = (b.longitude - point.longitude) * longitudeScale, by = (b.latitude - point.latitude) * scale
        let dx = bx - ax, dy = by - ay
        let squared = dx * dx + dy * dy
        let t = squared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / squared)) : 0
        return hypot(ax + t * dx, ay + t * dy)
    }

    public static func visible(_ line: RailLine, hiding hidden: Set<String>) -> RailLine? {
        guard let routes = line.routes, !routes.isEmpty else { return line }
        var copy = line
        copy.routes = routes.filter { !hidden.contains($0.visibilityKey) }
        return copy.routes!.isEmpty ? nil : copy
    }

    /// After optional enrichment, propagate the selected colour to every
    /// direction and station without repeating the geometry association pass.
    public static func unifyColours(_ features: RailTileFeatures) -> RailTileFeatures {
        var selected: [String: RailRoute] = [:]
        func rank(_ route: RailRoute) -> Int {
            OfficialMetroPalette.color(for: route.tags) != nil ? 0 :
                route.tags["atlas:wikiColour"] != nil ? 1 : route.tags["atlas:paletteColour"] != nil ? 2 :
                route.tags["atlas:bundledColour"] != nil ? 3 : route.color != nil ? 4 : 5
        }
        for route in features.lines.flatMap({ $0.routes ?? [] }) + features.stations.flatMap({ $0.routes ?? [] }) {
            if let old = selected[route.visibilityKey],
               rank(old) < rank(route) || (rank(old) == rank(route) && old.id <= route.id) { continue }
            selected[route.visibilityKey] = route
        }
        func apply(_ route: RailRoute) -> RailRoute {
            guard let canonical = selected[route.visibilityKey], let color = canonical.color else { return route }
            var result = route
            result.tags["colour"] = color.hex
            result.colourSourceID = canonical.colourSourceID
            for key in ["atlas:wikiColour", "atlas:wikiSource", "atlas:wikiURL", "atlas:paletteColour",
                        "atlas:paletteURL", "atlas:bundledColour"] { result.tags[key] = canonical.tags[key] }
            return result
        }
        var output = features
        for i in output.lines.indices { output.lines[i].routes = output.lines[i].routes?.map(apply) }
        for i in output.stations.indices { output.stations[i].routes = output.stations[i].routes?.map(apply) }
        return output
    }
}
