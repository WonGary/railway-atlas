import Foundation

/// Labels never determine identity or visibility. Keep the original full
/// metadata for hover/details, and shorten only the presentation.
public enum MetroRouteTitle {
    /// Compute once for the caller's route scope when prepared map data changes,
    /// never for each View.body. Only confirmed cities trigger city prefixes.
    public static func labels(_ routes: [RailRoute]) -> [String: String] {
        let entries = routes.sorted {
            $0.id == $1.id ? $0.name < $1.name : $0.id < $1.id
        }.map { (route: $0, city: cityLabel($0), title: short($0)) }
        let multipleCities = Set(entries.compactMap { $0.city?.id }).count > 1
        return Dictionary(entries.map { entry in
            var title = entry.title
            if multipleCities, let city = entry.city, leadingPhrase(city.name, in: title) == nil {
                let separator = city.name.range(of: #"\p{Han}"#, options: .regularExpression) == nil ? " " : ""
                title = city.name + separator + title
            }
            return (entry.route.visibilityKey, title)
        }, uniquingKeysWith: { a, _ in a })
    }

    public static func short(_ route: RailRoute) -> String {
        if let ref = clean(route.tags["ref"]) {
            // Preserve combined refs, branch suffixes and named-line refs.
            return numericTitle(ref) ?? ref
        }
        if let name = ["short_name:zh", "short_name", "short_name:en"].compactMap({ clean(route.tags[$0]) }).first {
            return numericTitle(name) ?? name
        }
        let original = clean(route.name) ?? clean(route.tags["name"]) ?? "未命名线路"
        var name = withoutEndpoints(original)
        let networks = route.tags.filter { $0.key == "network" || $0.key.hasPrefix("network:") }
            .values.compactMap { clean($0) }
        let prefixes = Set(networks + modePrefixes).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        for _ in 0..<4 {
            guard let range = prefixes.compactMap({ leadingPhrase($0, in: name) }).first else { break }
            let remainder = String(name[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else { break }
            name = remainder
        }
        // Unlabelled Chinese networks may precede a numbered line. Do not
        // delete arbitrary text up to an internal occurrence of "地铁".
        name = name.replacingOccurrences(
            of: #"^[\p{Han}]{2,8}(?:轨道交通|軌道交通|地铁|地鐵)\s*(?=[A-Za-z]?[0-9])"#,
            with: "", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"^(?:인천|仁川)\s*(?=[12]\s*(?:호선|(?:号|號)?[线線綫])$)"#,
            with: "", options: .regularExpression)
        return numericTitle(name) ?? clean(name) ?? original
    }

    public static func full(_ route: RailRoute) -> String {
        let name = clean(route.name) ?? clean(route.tags["name"])
        var seen = Set<String>()
        let metadata = ["network", "operator"].compactMap { key in
            [key, key + ":zh", key + ":en"].compactMap { clean(route.tags[$0]) }.first
        }.filter { seen.insert(fold($0)).inserted }
        let distinct = metadata.filter { value in
            if let name, containsPhrase(value, in: name) { return false }
            return !metadata.contains { other in
                fold(other) != fold(value) && containsPhrase(value, in: other)
            }
        }
        let parts = [name].compactMap { $0 } + distinct
        return parts.isEmpty ? "未命名线路" : parts.joined(separator: " · ")
    }

    private struct CityLabel: Sendable {
        let id: String
        let name: String
        let namePrefixes: [String]
    }

    // Use the same offline catalogue as colour identity, loaded only once.
    // Missing translations retain a catalogue name; no inferred translations.
    private static let cityLabels: [String: CityLabel] = {
        struct City: Decodable {
            let id: String
            let name: [String: String]
        }
        struct Document: Decodable { let cities: [City] }
        guard let url = Bundle.main.url(forResource: "metro-palette", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "metro-palette", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [:] }
        let labels = document.cities.compactMap { city -> CityLabel? in
            let preferred = ["zh-Hans", "zh", "zh-Hant", "en"].compactMap { clean(city.name[$0]) }.first
            guard let name = preferred ?? city.name.sorted(by: { $0.key < $1.key }).compactMap({ clean($0.value) }).first else { return nil }
            // The catalogue groups Seoul/Tokyo's metropolitan areas together.
            let compact = name.replacingOccurrences(of: #"（首都圈）$"#, with: "", options: .regularExpression)
            let prefixes = city.name.values.compactMap {
                clean($0.components(separatedBy: CharacterSet(charactersIn: "(（")).first)
            }
            return CityLabel(id: city.id, name: compact, namePrefixes: Array(Set(prefixes)))
        }
        return Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    // A display-only distinction within the Seoul palette, never a route key.
    private static let incheonLabel = CityLabel(id: "seoul:incheon", name: "仁川", namePrefixes: [])

    private static func cityLabel(_ route: RailRoute) -> CityLabel? {
        // Seoul's catalogue includes Incheon, airport and regional services.
        // Use complete line IDs, never an "i..." prefix or an endpoint mention.
        if let identity = route.tags["atlas:paletteIdentity"] {
            let parts = identity.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0] == "metro", !parts[2].isEmpty {
                guard let city = cityLabels[parts[1]] else { return nil }
                return city.id == "seoul" && ["i1", "i2", "im"].contains(parts[2]) ? incheonLabel : city
            }
        }
        let city: CityLabel?
        if let id = clean(route.tags["atlas:paletteCity"]) {
            guard let known = cityLabels[id] else { return nil }
            city = known
        } else {
            // Prefer explicit network metadata. Operators and arbitrary city
            // mentions in route names do not establish location.
            var identifying = route
            identifying.name = ""
            identifying.tags = route.tags.filter { $0.key == "network" || $0.key.hasPrefix("network:") }
            city = BundledMetroPalette.city(for: identifying).flatMap { cityLabels[$0] } ?? namedCity(route)
        }
        guard city == nil || city?.id == "seoul" else { return city }
        let names = [route.name] + route.tags.filter { $0.key == "name" || $0.key.hasPrefix("name:") }.map(\.value)
        let incheonLine = names.contains { value in
            let name = fold(withoutEndpoints(value))
            return name.range(of: #"^(?:인천\s*(?:도시철도|지하철|메트로)?\s*[12]\s*호선|incheon\s+(?:(?:metro|subway)\s+)?line\s*[12]|仁川\s*(?:地[铁鐵]|都市[铁鐵]道)?\s*[12](?:号|號)?[线線綫])(?:$|\s|[:：（(])"#,
                              options: .regularExpression) != nil
        }
        let dedicatedIncheonNetworks: Set<String> = [
            "incheon metro", "incheon subway", "인천 도시철도", "인천 지하철", "인천도시철도", "인천지하철",
            "仁川地铁", "仁川地鐵", "仁川都市铁道", "仁川都市鐵道"
        ]
        let incheonNetwork = route.tags.contains {
            ($0.key == "network" || $0.key.hasPrefix("network:")) && dedicatedIncheonNetworks.contains(fold($0.value))
        }
        return incheonLine || incheonNetwork ? incheonLabel : city
    }

    private static func namedCity(_ route: RailRoute) -> CityLabel? {
        let names = ([route.name] + route.tags.filter {
            $0.key == "name" || $0.key.hasPrefix("name:")
        }.map(\.value)).map(withoutEndpoints)
        let matches = cityLabels.values.filter { city in
            city.namePrefixes.contains { prefix in
                names.contains { name in
                    guard let range = leadingPhrase(prefix, in: name),
                          let suffix = clean(String(name[range.upperBound...])) else { return false }
                    // Require an explicit line title after the city, rather
                    // than accepting endpoints such as "Beijing → Tianjin".
                    return numericTitle(suffix) != nil
                        || (modePrefixes + ["メトロ"]).contains { leadingPhrase($0, in: suffix) != nil }
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static let modePrefixes = [
        "東京メトロ", "都営地下鉄", "都営", "Tokyo Metro", "Toei Subway",
        "Seoul Metropolitan Subway", "Seoul Subway", "Seoul Metro",
        "Incheon Metro", "Incheon Subway", "서울 지하철", "서울도시철도", "수도권 전철",
        "인천 도시철도", "인천 지하철", "仁川地铁", "仁川地鐵",
        "香港港鐵", "香港港铁", "港鐵", "港铁", "MTR",
        "轨道交通", "軌道交通", "地铁", "地鐵", "地下鉄", "Subway", "Metro"
    ]

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.precomposedStringWithCanonicalMapping
    }

    private static func fold(_ value: String) -> String {
        (clean(value) ?? "").folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .precomposedStringWithCanonicalMapping
    }

    private static func numericTitle(_ value: String) -> String? {
        let value = clean(value) ?? ""
        for pattern in [
            #"(?i)^(?:line|route)\s+([A-Z]?[0-9]+[A-Z]?|[A-Z])$"#,
            #"^([A-Za-z]?[0-9]+[A-Za-z]?)\s*(?:(?:号|號)?[线線綫]|호선)$"#
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { continue }
            return String(value[range])
        }
        return nil
    }

    private static func withoutEndpoints(_ value: String) -> String {
        var value = clean(value) ?? ""
        // A colon without a direction annotation can identify a branch.
        if let colon = value.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let suffix = String(value[value.index(after: colon)...])
            if suffix.range(of: #"→|←|↔|->|=>|⇒"#, options: .regularExpression) != nil,
               let title = clean(String(value[..<colon])) { value = title }
        }
        value = value.replacingOccurrences(
            of: #"\s*[（(][^()（）]*(?:→|←|↔|->|=>|⇒)[^()（）]*[）)]\s*$"#,
            with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)\s*[（(](?:northbound|southbound|eastbound|westbound|inbound|outbound|上行|下行)[）)]\s*$"#,
            with: "", options: .regularExpression)
        return clean(value) ?? ""
    }

    private static func leadingPhrase(_ phrase: String, in value: String) -> Range<String.Index>? {
        guard let range = value.range(of: phrase, options: [.anchored, .caseInsensitive, .widthInsensitive]),
              isPhraseBoundary(phrase, range: range, in: value) else { return nil }
        return range
    }

    private static func containsPhrase(_ phrase: String, in value: String) -> Bool {
        let phrase = fold(phrase), value = fold(value)
        guard !phrase.isEmpty else { return false }
        var start = value.startIndex
        while let range = value.range(of: phrase, range: start..<value.endIndex) {
            if isPhraseBoundary(phrase, range: range, in: value) { return true }
            start = range.upperBound
        }
        return false
    }

    private static func isPhraseBoundary(_ phrase: String, range: Range<String.Index>, in value: String) -> Bool {
        func latinWord(_ character: Character?) -> Bool {
            character.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        }
        let before = range.lowerBound == value.startIndex ? nil : value[value.index(before: range.lowerBound)]
        let after = range.upperBound == value.endIndex ? nil : value[range.upperBound]
        return !(latinWord(phrase.first) && latinWord(before))
            && !(latinWord(phrase.last) && latinWord(after))
    }
}
