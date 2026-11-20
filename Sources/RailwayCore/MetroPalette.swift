import Foundation

public struct MetroPaletteRecord: Codable, Sendable {
    public let hex: String
    public let url: String
    public let fetched: Date
}

/// Community palette, separate from verified operator standards and Wikimedia.
/// Exact city/network + line labels only; never match a bare route number.
public enum MetroPalette {
    public static let hosts = ["https://railmapgen.org", "https://railmapgen.github.io"]
    public static func city(for route: RailRoute) -> String? {
        BundledMetroPalette.city(for: route)
    }
    public static func key(for route: RailRoute) -> String? {
        if let identity = route.tags["atlas:paletteIdentity"], identity.hasPrefix("metro:") {
            return identity.dropFirst(6).replacingOccurrences(of: ":", with: "|")
        }
        if let match = BundledMetroPalette.match(route) { return match.city + "|" + match.line }
        guard let city = city(for: route), let ref = route.tags["ref"], !ref.isEmpty else { return nil }
        return city + "|" + normalized(ref)
    }
    private static func normalized(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: "line ", with: "")
            .replacingOccurrences(of: "号线", with: "").trimmingCharacters(in: .whitespaces)
    }
    private struct Entry: Decodable { let id: String?; let colour: String; let name: [String: String] }
    public static func decode(_ data: Data) throws -> [String: String] {
        guard data.count < 256_000 else { throw DataError.invalid("调色板过大") }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard entries.count <= 300 else { throw DataError.invalid("调色板条目过多") }
        var result: [String: String] = [:], conflicts = Set<String>()
        for entry in entries {
            guard let color = RailColor(entry.colour) else { continue }
            for name in Array(entry.name.values) + [entry.id].compactMap({ $0 }) {
                let key = normalized(name)
                if let previous = result[key], previous != color.hex { conflicts.insert(key) }
                result[key] = color.hex
            }
        }
        for key in conflicts { result.removeValue(forKey: key) }
        return result
    }
    public static func decodeCache(_ data: Data) throws -> [String: MetroPaletteRecord] {
        let records = try JSONDecoder().decode([String: MetroPaletteRecord].self, from: data)
        guard records.count < 5000, records.values.allSatisfy({ record in
            RailColor(record.hex) != nil && hosts.contains { host in record.url.hasPrefix(host + "/rmg-palette/resources/palettes/") }
        }) else { throw DataError.invalid("线路色缓存无效") }
        return records
    }
    public static func applying(_ records: [String: MetroPaletteRecord], to route: RailRoute) -> RailRoute {
        var route = BundledMetroPalette.applying(to: route)
        guard !records.isEmpty else { return route }
        guard let key = key(for: route) else { return route }
        // Keep reading pre-bundle caches keyed by city + OSM ref.
        let legacy = key.components(separatedBy: "|")[0] + "|" + normalized(route.tags["ref"] ?? "")
        guard let record = records[key] ?? records[legacy] else { return route }
        route.tags["atlas:paletteColour"] = record.hex
        route.tags["atlas:paletteURL"] = record.url
        return route
    }
    public static func fetch(routes: [RailRoute], cached: [String: MetroPaletteRecord], session: URLSession) async -> [String: MetroPaletteRecord] {
        var records = cached
        let needed = routes.filter {
            guard let key = key(for: $0) else { return false }
            return Date().timeIntervalSince(records[key]?.fetched ?? .distantPast) >= 604800
        }
        for city in Set(needed.compactMap { Self.city(for: $0) }).sorted().prefix(3) {
            for host in hosts {
                if Task.isCancelled { return records }
                let url = "\(host)/rmg-palette/resources/palettes/\(city).json"
                var request = URLRequest(url: URL(string: url)!)
                request.timeoutInterval = 5
                request.setValue("RailwayAtlas/0.1.3", forHTTPHeaderField: "User-Agent")
                do {
                    let (data, response) = try await session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let palette = try decode(data)
                    for route in needed where Self.city(for: route) == city {
                        guard let key = key(for: route),
                              let hex = BundledMetroPalette.match(route).flatMap({ palette[$0.line] })
                                ?? route.tags["ref"].flatMap({ palette[normalized($0)] }) else { continue }
                        records[key] = MetroPaletteRecord(hex: hex, url: url, fetched: .now)
                    }
                    break
                } catch { continue }
            }
        }
        return records
    }
}
