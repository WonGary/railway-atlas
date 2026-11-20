import Foundation

public struct WikiMetroColour: Codable, Sendable {
    public let identity: String
    public let hex: String?
    public let sourceName: String
    public let sourceURL: String
    public let fetched: Date

    public var fresh: Bool { Date().timeIntervalSince(fetched) < (hex == nil ? 86400 : 604800) }
    public func applying(to route: RailRoute) -> RailRoute {
        guard let hex, RailColor(hex) != nil else { return route }
        var result = route
        result.tags["atlas:wikiColour"] = hex
        result.tags["atlas:wikiSource"] = sourceName
        result.tags["atlas:wikiURL"] = sourceURL
        return result
    }
}

public struct WikiMetroColourUpdate: Sendable {
    public var records: [String: WikiMetroColour]
    public var message: String
}

/// Only explicit identifiers from OSM relations are queried. A route number
/// alone cannot distinguish, for example, Beijing Line 1 from Guangzhou Line 1.
public enum WikiMetroColours {
    public static func identity(for route: RailRoute) -> String? {
        if let id = route.tags["wikidata"], validEntity(id) { return id }
        if let page = route.tags["wikipedia"], wikipediaPage(page) != nil { return page }
        return nil
    }

    public static func validEntity(_ id: String) -> Bool {
        id.count > 1 && id.count < 20 && id.first == "Q" && id.dropFirst().allSatisfy(\.isNumber)
    }

    public static func wikipediaPage(_ value: String) -> (language: String, title: String)? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, (2...12).contains(parts[0].count), parts[1].count <= 250,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == "-") }),
              !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    public static func decodeCache(_ data: Data) throws -> [String: WikiMetroColour] {
        let records = try JSONDecoder().decode([String: WikiMetroColour].self, from: data)
        guard records.count <= 5000 else { throw DataError.invalid("百科配色缓存过大") }
        for (id, value) in records {
            let host = URL(string: value.sourceURL)?.host ?? ""
            guard id == value.identity, validEntity(id) || wikipediaPage(id) != nil,
                  value.hex == nil || value.hex.flatMap(RailColor.init) != nil,
                  URL(string: value.sourceURL)?.scheme == "https",
                  host == "www.wikidata.org" || host.hasSuffix(".wikipedia.org"),
                  value.fetched.timeIntervalSince1970.isFinite else { throw DataError.invalid("百科配色缓存无效") }
        }
        return records
    }

    public static func entityColour(_ entity: [String: Any]) -> String? {
        guard let claims = entity["claims"] as? [String: Any],
              let values = claims["P465"] as? [[String: Any]] else { return nil }
        let usable = values.filter { $0["rank"] as? String != "deprecated" }
        let preferred = usable.filter { $0["rank"] as? String == "preferred" }
        let selected = preferred.isEmpty ? usable : preferred
        let colours = Set(selected.compactMap { claim -> String? in
            guard let snak = claim["mainsnak"] as? [String: Any], snak["snaktype"] as? String == "value",
                  let value = snak["datavalue"] as? [String: Any], let raw = value["value"] as? String else { return nil }
            return RailColor(raw.hasPrefix("#") ? raw : "#" + raw)?.hex
        })
        return colours.count == 1 ? colours.first : nil
    }

    public static func infoboxColour(_ text: String) -> String? {
        // Read explicit colour parameters only. Do not guess from unrelated
        // CSS, route numbers, page prose or unresolved wiki templates.
        let names = ["color", "colour", "颜色", "顏色", "标志色", "標誌色", "代表色", "线路色", "路線色"]
        var colours = Set<String>()
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("|"), let equals = value.firstIndex(of: "=") else { continue }
            let field = value[value.index(after: value.startIndex)..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard names.contains(field) else { continue }
            let raw = value[value.index(after: equals)...].components(separatedBy: "<!--")[0]
                .trimmingCharacters(in: .whitespaces)
            if let colour = RailColor(raw.hasPrefix("#") ? raw : "#" + raw) { colours.insert(colour.hex) }
        }
        return colours.count == 1 ? colours.first : nil
    }

    public static func fetch(routes: [RailRoute], cached: [String: WikiMetroColour],
                             session: URLSession) async -> WikiMetroColourUpdate {
        var records = cached
        var requested: [String: RailRoute] = [:]
        for route in routes {
            if let id = identity(for: route), records[id]?.fresh != true { requested[id] = route }
        }
        guard !requested.isEmpty else {
            return WikiMetroColourUpdate(records: records, message: "百科线路色 · 已使用缓存")
        }
        let identifiers = requested.keys.sorted().prefix(50)
        let entities = identifiers.filter(validEntity)
        var pages: [String: (String, String)] = [:]
        var failed = false
        if !entities.isEmpty {
            do {
                let object = try await request("https://www.wikidata.org/w/api.php", query: [
                    "action": "wbgetentities", "ids": entities.joined(separator: "|"),
                    "props": "claims|sitelinks", "format": "json"
                ], session: session)
                guard let items = object["entities"] as? [String: [String: Any]] else { throw DataError.invalid("Wikidata 响应无效") }
                for id in entities {
                    guard let entity = items[id] else { continue }
                    let colour = entityColour(entity)
                    if colour != nil {
                        records[id] = WikiMetroColour(identity: id, hex: colour, sourceName: "Wikidata · P465",
                                                       sourceURL: "https://www.wikidata.org/wiki/\(id)", fetched: .now)
                    } else {
                        let sites = entity["sitelinks"] as? [String: [String: Any]] ?? [:]
                        if let title = sites["zhwiki"]?["title"] as? String { pages[id] = ("zh", title) }
                        else if let title = sites["enwiki"]?["title"] as? String { pages[id] = ("en", title) }
                        else {
                            records[id] = WikiMetroColour(identity: id, hex: nil, sourceName: "Wikidata",
                                                           sourceURL: "https://www.wikidata.org/wiki/\(id)", fetched: .now)
                        }
                    }
                }
            } catch { failed = true }
        }
        for id in identifiers where records[id]?.fresh != true && pages[id] == nil {
            if let page = requested[id]?.tags["wikipedia"].flatMap(wikipediaPage) {
                pages[id] = (page.language, page.title)
            }
        }
        if !Task.isCancelled {
            // Batch page requests by language and cap each viewport's work.
            let limited = Array(pages.sorted { $0.key < $1.key }.prefix(30))
            for (language, entries) in Dictionary(grouping: limited, by: { $0.value.0 }).sorted(by: { $0.key < $1.key }) {
                do {
                    try Task.checkCancellation()
                    let object = try await request("https://\(language).wikipedia.org/w/api.php", query: [
                        "action": "query", "prop": "revisions", "titles": entries.map { $0.value.1 }.joined(separator: "|"),
                        "rvprop": "content", "rvslots": "main", "redirects": "1", "format": "json", "formatversion": "2"
                    ], session: session)
                    guard let query = object["query"] as? [String: Any], let result = query["pages"] as? [[String: Any]] else {
                        throw DataError.invalid("Wikipedia 响应无效")
                    }
                    var aliases: [String: String] = [:]
                    for field in ["normalized", "redirects"] {
                        for mapping in query[field] as? [[String: String]] ?? [] {
                            if let from = mapping["from"], let to = mapping["to"] { aliases[from] = to }
                        }
                    }
                    for (id, (_, originalTitle)) in entries {
                        var title = originalTitle
                        for _ in 0..<5 { if let next = aliases[title] { title = next } else { break } }
                        guard let page = result.first(where: { $0["title"] as? String == title }),
                              let revisions = page["revisions"] as? [[String: Any]],
                              let slots = revisions.first?["slots"] as? [String: [String: Any]],
                              let text = slots["main"]?["content"] as? String else { continue }
                        var link = URLComponents(string: "https://\(language).wikipedia.org/w/index.php")!
                        link.queryItems = [URLQueryItem(name: "title", value: title)]
                        records[id] = WikiMetroColour(identity: id, hex: infoboxColour(text),
                                                       sourceName: "Wikipedia · 线路信息框", sourceURL: link.url!.absoluteString, fetched: .now)
                    }
                } catch { failed = true }
            }
        }
        let count = identifiers.filter { records[$0]?.hex != nil }.count
        return WikiMetroColourUpdate(records: records, message: failed
            ? "百科服务暂不可用 · 保留已有线路色"
            : "百科线路色 · 本次补充 \(count) 条")
    }

    private static func request(_ endpoint: String, query: [String: String], session: URLSession) async throws -> [String: Any] {
        try Task.checkCancellation()
        var components = URLComponents(string: endpoint)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue("RailwayAtlas/0.1.3 (native OSM railway viewer; metro colour metadata)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
            throw DataError.invalid("百科线路色请求失败")
        }
        try Task.checkCancellation()
        return object
    }
}
