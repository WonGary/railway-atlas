import Foundation

/// Small offline colour catalogue. It does not supply geometry, prove that a
/// proposed line is open, or identify a route from a number without a city.
public enum BundledMetroPalette {
    public struct Match: Sendable {
        public let city: String
        public let line: String
        public let hex: String
        public let url: String
        public var identity: String { "metro:\(city):\(line)" }
    }
    private struct Entry: Decodable, Sendable {
        let id: String
        let colour: String
        let name: [String: String]
    }
    private struct City: Decodable, Sendable {
        let id: String
        let name: [String: String]
        let latitude: Double?
        let longitude: Double?
        let aliases: [String]
        let lineAliases: [String: [String]]
        let url: String
        let lines: [Entry]
    }
    private struct Document: Decodable { let cities: [City] }
    private struct Index: Sendable {
        let city: City
        let aliases: [String]
        let names: [String]
        let lines: [String: Set<String>]
        let exactLines: [String: Set<String>]
        let entries: [String: Entry]
    }
    private static let indices: [Index] = {
        guard let url = Bundle.main.url(forResource: "metro-palette", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "metro-palette", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return document.cities.map { city in
            let names = Array(Set(city.name.values.map { baseName($0) } + [city.id])).map(fold)
            let aliases = Array(Set(names + city.aliases.map(fold))).filter { $0.count >= 2 }
            var lines: [String: Set<String>] = [:], exactLines: [String: Set<String>] = [:]
            for entry in city.lines where !entry.id.isEmpty && RailColor(entry.colour) != nil {
                // RMG's internal IDs are not OSM refs (Seoul's "w", for
                // example, means a different line). Only names/explicit aliases.
                for name in Array(entry.name.values) + (city.lineAliases[entry.id] ?? []) {
                    for part in name.components(separatedBy: "/") {
                        exactLines[compact(fold(part)), default: []].insert(entry.id)
                        for key in keys(part) { lines[key, default: []].insert(entry.id) }
                    }
                }
            }
            // "South Island Line (West)" must not make the unqualified
            // operating "South Island Line" ambiguous. Keep full qualifiers,
            // and prefer an exact catalogue name to a shortened annotation.
            for (key, ids) in exactLines where ids.count == 1 { lines[key] = ids }
            return Index(city: city, aliases: aliases, names: names, lines: lines, exactLines: exactLines,
                         entries: Dictionary(city.lines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        }
    }()
    public static var cityCount: Int { indices.count }
    public static var entryCount: Int { indices.reduce(0) { $0 + $1.city.lines.count } }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "綫", with: "线").replacingOccurrences(of: "線", with: "线")
            .replacingOccurrences(of: "號", with: "号").replacingOccurrences(of: "臺", with: "台")
            .replacingOccurrences(of: "凼", with: "氹")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
    private static func compact(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func baseName(_ value: String) -> String {
        value.components(separatedBy: CharacterSet(charactersIn: ":：（(")).first ?? value
    }
    private static func keys(_ value: String) -> Set<String> {
        var value = fold(baseName(value))
        // Explicit section suffixes do not change a route's identity.
        value = value.replacingOccurrences(of: #"(?<=线)(?:[东西南北中](?:段|延(?:伸)?(?:线|段)?)|第?[一二三四五六七八九十0-9]+期(?:工程)?)$"#,
                                            with: "", options: .regularExpression)
        if let match = value.range(of: #"[一二三四五六七八九十]{1,3}(?=号线$)"#, options: .regularExpression) {
            let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
            let number = String(value[match]), parts = number.split(separator: "十", omittingEmptySubsequences: false)
            let parsed: Int?
            if parts.count == 2, parts.allSatisfy({ $0.count <= 1 }) {
                parsed = (parts[0].first.flatMap { digits[$0] } ?? 1) * 10 + (parts[1].first.flatMap { digits[$0] } ?? 0)
            } else { parsed = number.count == 1 ? number.first.flatMap { digits[$0] } : nil }
            if let parsed { value.replaceSubrange(match, with: String(parsed)) }
        }
        guard !value.isEmpty else { return [] }
        var result: Set<String> = [compact(value)]
        for pattern in numberPatterns {
            if let regex = expressions[pattern], let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let range = Range(match.range(at: 1), in: value) { result.insert(String(value[range])) }
        }
        return result
    }
    private static let numberPatterns = [
        #"^(?:line|route)\s+([a-z]?\d+[a-z]?|[a-z])$"#,
        #"^([a-z]?\d+[a-z]?)\s*(?:号?线|호선)$"#
    ]
    private static let expressions = Dictionary(uniqueKeysWithValues: numberPatterns.map { ($0, try! NSRegularExpression(pattern: $0)) })

    private static func aliasRanges(_ text: String, _ alias: String) -> [Range<String.Index>] {
        // Match Latin city names as words: "Xian" must not match "Xiangtan".
        let latin = alias.unicodeScalars.allSatisfy { $0.isASCII }
        var result: [Range<String.Index>] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: alias, options: .literal, range: search) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !latin || (!(before?.isASCII == true && before?.isLetter == true)
                && !(after?.isASCII == true && after?.isLetter == true)) { result.append(range) }
            search = range.upperBound..<text.endIndex
        }
        return result
    }
    private static func candidateCities(tags: [String: String], name: String, near point: Coordinate?) -> [Index] {
        if let city = tags["atlas:paletteCity"], let index = indices.first(where: { $0.city.id == city }) { return [index] }
        // A route name is more specific than the operator (e.g. Guangzhou
        // Metro operates other cities' lines). Prefer explicit network fields.
        for fields in [
            tags.filter { $0.key == "network" || $0.key.hasPrefix("network:") }.map(\.value),
            [name] + tags.filter { $0.key == "name" || $0.key.hasPrefix("name:") }.map(\.value),
            tags.filter { $0.key == "operator" || $0.key.hasPrefix("operator:") }.map(\.value)
        ] {
            let texts = Set(fields.map(fold))
            var cityIDs = Set<String>()
            for text in texts {
                let matches = indices.flatMap { index in index.aliases.flatMap { alias in
                    aliasRanges(text, alias).map { (city: index.city.id, range: $0) }
                } }
                // 京都 is a substring of 東京都交通局, but is not the network's
                // city. Prefer the enclosing explicit alias only at that same
                // occurrence; genuinely separate city names stay ambiguous.
                for match in matches where !matches.contains(where: {
                    $0.city != match.city && $0.range != match.range
                        && $0.range.lowerBound <= match.range.lowerBound && $0.range.upperBound >= match.range.upperBound
                }) { cityIDs.insert(match.city) }
            }
            let found = indices.filter { cityIDs.contains($0.city.id) }
            if !found.isEmpty { return found }
        }
        guard let point, point.isValid else { return [] }
        // Location is only a city disambiguator for a named urban track.
        // Overlapping urban areas deliberately remain ambiguous.
        return indices.filter { index in
            guard let lat = index.city.latitude, let lon = index.city.longitude,
                  abs(lat - point.latitude) < 0.35, abs(lon - point.longitude) < 0.5 else { return false }
            return MapAlignment.distance(point, Coordinate(lat, lon)) < 35_000
        }
    }
    private static let modePrefixes = [
        "metropolitan subway", "metropolitan area", "metro", "subway", "mtr",
        "地铁", "地鐵", "軌道交通", "轨道交通", "捷運", "捷运", "轻轨", "輕軌",
        "東京メトロ", "都営地下鉄", "都営", "地下鉄", "メトロ", "toei subway",
        "수도권 전철", "서울 지하철", "서울도시철도", "경전철", "지하철", "도시철도", "전철"
    ].sorted { $0.count > $1.count }

    private static func line(in index: Index, tags: [String: String], name: String) -> Entry? {
        let names = [name] + tags.filter { $0.key == "name" || $0.key.hasPrefix("name:") }.map(\.value)
        var matches = Set<String>()
        for name in names {
            matches.formUnion(index.exactLines[compact(fold(name))] ?? [])
        }
        if matches.count > 1 { return nil }
        if let id = matches.first { return index.entries[id] }
        // Full names distinguish Incheon Line 1 from Seoul Line 1 before
        // consulting the common ref "1".
        for name in names {
            for key in keys(name) where key.count > 2 {
                matches.formUnion(index.lines[key] ?? [])
            }
        }
        if matches.count > 1 { return nil }
        if let id = matches.first { return index.entries[id] }
        for field in ["ref", "official_ref", "ref:en"] {
            if let ref = tags[field], !ref.contains(";") {
                for key in keys(ref) { matches.formUnion(index.lines[key] ?? []) }
            }
        }
        if matches.count > 1 { return nil }
        if let id = matches.first { return index.entries[id] }
        for name in names {
            var value = fold(baseName(name))
            // Remove only a leading city/mode prefix, never arbitrary words
            // inside a named route or its terminus.
            for _ in 0..<4 {
                let prefixes = (index.names + modePrefixes).sorted { $0.count > $1.count }
                guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { break }
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            for key in keys(value) { matches.formUnion(index.lines[key] ?? []) }
        }
        guard matches.count == 1, let id = matches.first else { return nil }
        return index.entries[id]
    }

    public static func match(_ route: RailRoute, near point: Coordinate? = nil) -> Match? {
        if let identity = route.tags["atlas:paletteIdentity"] {
            let parts = identity.split(separator: ":").map(String.init)
            if parts.count == 3, parts[0] == "metro",
               let index = indices.first(where: { $0.city.id == parts[1] }),
               let entry = index.entries[parts[2]], let color = RailColor(entry.colour) {
                return Match(city: parts[1], line: parts[2], hex: color.hex, url: index.city.url)
            }
        }
        let cities = candidateCities(tags: route.tags, name: route.name, near: point)
        guard cities.count == 1, let index = cities.first,
              let entry = line(in: index, tags: route.tags, name: route.name),
              let color = RailColor(entry.colour) else { return nil }
        return Match(city: index.city.id, line: entry.id, hex: color.hex, url: index.city.url)
    }
    public static func city(for route: RailRoute) -> String? {
        if let city = route.tags["atlas:paletteCity"] { return city }
        let cities = candidateCities(tags: route.tags, name: route.name, near: nil)
        return cities.count == 1 ? cities.first?.city.id : nil
    }
    public static func applying(to route: RailRoute, near point: Coordinate? = nil) -> RailRoute {
        if route.tags["atlas:bundledColour"] != nil, route.tags["atlas:paletteIdentity"] != nil { return route }
        guard let match = match(route, near: point) else { return route }
        var route = route
        route.tags["atlas:paletteCity"] = match.city
        route.tags["atlas:paletteIdentity"] = match.identity
        route.tags["atlas:bundledColour"] = match.hex
        route.tags["atlas:paletteURL"] = match.url
        return route
    }
    public static func identify(_ features: RailTileFeatures) -> RailTileFeatures {
        var result = features
        // Decode/normalise each distinct route once per assembly, not once for
        // every vertex or every one of its thousands of track fragments.
        struct LocatedRoute: Hashable {
            let route: RailRoute
            let cell: String
        }
        // A long suburban route may start well outside its city centre. Resolve
        // the relation using all occupied cells once, then apply that identity
        // to every fragment (including fragments visited before the match).
        var locations: [RailRoute: [String: Coordinate]] = [:]
        for line in features.lines {
            guard let point = line.coordinates.first else { continue }
            for route in line.routes ?? [] where route.id.hasPrefix("relation/") {
                let cell = "\(Int(floor(point.latitude * 4))),\(Int(floor(point.longitude * 4)))"
                locations[route, default: [:]][cell] = point
            }
        }
        var routeCache: [LocatedRoute: RailRoute] = [:]
        for (route, points) in locations {
            let direct = applying(to: route)
            let value: RailRoute
            if direct.tags["atlas:paletteIdentity"] != nil { value = direct }
            else {
                let matches = points.values.compactMap { point -> RailRoute? in
                    let candidate = applying(to: route, near: point)
                    return candidate.tags["atlas:paletteIdentity"] == nil ? nil : candidate
                }
                value = Set(matches.compactMap { $0.tags["atlas:paletteIdentity"] }).count == 1 ? matches[0] : route
            }
            routeCache[LocatedRoute(route: route, cell: "")] = value
        }
        func apply(_ route: RailRoute, near point: Coordinate?) -> RailRoute {
            let cell = route.id.hasPrefix("relation/") ? "" :
                point.map { "\(Int(floor($0.latitude * 4))),\(Int(floor($0.longitude * 4)))" } ?? ""
            let key = LocatedRoute(route: route, cell: cell)
            if let cached = routeCache[key] { return cached }
            let value = applying(to: route, near: point)
            routeCache[key] = value
            return value
        }
        for i in result.lines.indices {
            var line = result.lines[i]
            let point = line.coordinates.first
            if let routes = line.routes, !routes.isEmpty {
                line.routes = routes.map { apply($0, near: point) }
            } else if RailCategory.urbanTypes.contains(line.tags["railway"] ?? ""),
                      line.tags["ref"] != nil || line.tags.keys.contains(where: {
                          $0 == "name" || $0.hasPrefix("name:") || $0 == "localized_name"
                      }) {
                var tags = line.tags
                tags["route"] = tags["railway"]
                let inferred = apply(RailRoute(id: "named/\(line.name)", name: line.tags["name"] ?? line.name, tags: tags), near: point)
                if let identity = inferred.tags["atlas:paletteIdentity"] {
                    var route = inferred
                    route.id = identity
                    line.routes = [route]
                    line.tags["atlas:routeMatch"] = "本地配色库 · 城市与明确线路名称/编号"
                }
            }
            result.lines[i] = line
        }
        for i in result.stations.indices {
            let point = result.stations[i].coordinate
            result.stations[i].routes = result.stations[i].routes?.map { apply($0, near: point) }
        }
        return result
    }
}
