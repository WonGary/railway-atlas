import Foundation

/// Learn names from already identified infrastructure, including translated
/// way names absent from the route relation. A name is a candidate, never an
/// identity by itself: mode, network, geographical scope and ambiguity gate it.
struct MetroNameIndex {
    private var names: [String: Set<String>] = [:]
    private var routes: [String: RailRoute] = [:]
    private var bounds: [String: MapBounds] = [:]
    private var networks: [String: Set<String>] = [:]
    private var normalized: [String: String] = [:]
    private struct Cell: Hashable { let x: Int; let y: Int }
    private struct Endpoint { let point: Coordinate; let route: String }
    private var endpoints: [Cell: [Endpoint]] = [:]

    init(lines: [RailLine]) {
        for line in lines where !(line.routes ?? []).isEmpty {
            let box = MapBounds(points: line.coordinates)
            for route in line.routes ?? [] {
                let key = route.visibilityKey
                if routes[key] == nil || route.id < routes[key]!.id { routes[key] = route }
                bounds[key] = bounds[key].map { $0.union(box) } ?? box
                let knownNetworks = networkNames(line.tags) + networkNames(route.tags)
                networks[key, default: []].formUnion(knownNetworks)
                let mode = route.tags["route"] ?? line.tags["railway"] ?? ""
                let labels = tagNames(line.tags) + tagNames(route.tags) + [route.name]
                for label in labels {
                    let name = normalize(label)
                    guard name.count >= 2, !["未命名城市轨道", "城市轨道", "地铁与城市轨道"].contains(name) else { continue }
                    names[mode + "|" + name, default: []].insert(key)
                }
                recordEndpoints(line, route: route)
            }
        }
    }

    mutating func match(_ line: RailLine) -> RailRoute? {
        let mode = line.tags["railway"] ?? ""
        guard RailCategory.urbanTypes.contains(mode) else { return nil }
        let labels = tagNames(line.tags)
        var candidates = Set<String>()
        for label in labels { candidates.formUnion(names[mode + "|" + normalize(label)] ?? []) }
        let box = MapBounds(points: line.coordinates)
        let suppliedNetworks = Set(networkNames(line.tags))
        candidates = candidates.filter { key in
            guard let known = bounds[key] else { return false }
            // Only disambiguates a matching name. It never assigns a name or
            // route by proximity, and it never merges station objects.
            let scope = MapBounds(south: known.south - 0.12, west: known.west - 0.15,
                                  north: known.north + 0.12, east: known.east + 0.15)
            guard scope.intersects(box) else { return false }
            let knownNetworks = networks[key, default: []]
            return suppliedNetworks.isEmpty || knownNetworks.isEmpty
                || !knownNetworks.isDisjoint(with: suppliedNetworks)
        }
        if candidates.count > 1 {
            // Infrastructure names may cover several service patterns. Only
            // a uniquely connected candidate can extend beyond a terminus.
            // This gate requires a proven matching name first, not proximity.
            var connected = Set<String>()
            for point in [line.coordinates.first, line.coordinates.last].compactMap({ $0 }) {
                let cell = Self.cell(point)
                let reach = Int(ceil(8 / (22.239 * max(0.05, cos(point.latitude * .pi / 180))))) + 1
                for x in (cell.x - reach)...(cell.x + reach) {
                    for y in (cell.y - 1)...(cell.y + 1) {
                        for edge in endpoints[Cell(x: x, y: y), default: []]
                            where candidates.contains(edge.route) && MapAlignment.distance(point, edge.point) <= 8 {
                            connected.insert(edge.route)
                        }
                    }
                }
            }
            candidates = connected
        }
        guard candidates.count == 1, let key = candidates.first else { return nil }
        return routes[key]
    }

    mutating func recordEndpoints(_ line: RailLine, route: RailRoute) {
        for point in [line.coordinates.first, line.coordinates.last].compactMap({ $0 }) {
            endpoints[Self.cell(point), default: []].append(Endpoint(point: point, route: route.visibilityKey))
        }
    }
    private static func cell(_ point: Coordinate) -> Cell {
        Cell(x: Int(floor(point.longitude * 5_000)), y: Int(floor(point.latitude * 5_000)))
    }
    private func tagNames(_ tags: [String: String]) -> [String] {
        tags.filter { $0.key == "name" || $0.key.hasPrefix("name:")
            || $0.key == "official_name" || $0.key == "alt_name" || $0.key == "localized_name" }
            .flatMap { $0.value.components(separatedBy: ";") }
    }
    private mutating func networkNames(_ tags: [String: String]) -> [String] {
        tags.filter { $0.key == "network" || $0.key.hasPrefix("network:") }
            .values.map { normalize($0) }.filter { !$0.isEmpty }
    }
    private mutating func normalize(_ raw: String) -> String {
        if let value = normalized[raw] { return value }
        var text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
        text = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        text = text.replacingOccurrences(of: "綫", with: "线")
        // Keep branch names and arbitrary qualifiers. Only these explicit
        // extension/phase suffixes are known to retain the physical line.
        text = text.replacingOccurrences(of: #"(?<=线)(?:[（(]?(?:[东西南北中](?:段|延(?:伸)?(?:线|段)?)|第?[一二三四五六七八九十0-9]+期(?:工程)?)[）)]?)$"#,
                                         with: "", options: .regularExpression)
        let value = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .precomposedStringWithCanonicalMapping
        normalized[raw] = value
        return value
    }
}
