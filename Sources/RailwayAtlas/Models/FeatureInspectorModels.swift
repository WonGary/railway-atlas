import Foundation
import RailwayCore

/// A projection of the selected feature, never of similarly named map features.
struct FeatureInspectorModel {
    let item: RailwaySelection
    let name: String
    let subtitle: String
    let tags: [String: String]
    let routes: [RailRoute]
    let isStation: Bool
    let interchange: StationInterchangeGroup?

    init(item: RailwaySelection, line: RailLine?, station: RailStation?,
         interchange: StationInterchangeGroup? = nil) {
        self.item = item
        self.interchange = interchange
        name = Self.nonempty(line?.name ?? station?.name ?? item.name) ?? "未命名要素"
        subtitle = line?.category.title ?? item.subtitle
        // Live metadata can acquire colours/memberships after selection. Use the
        // selection snapshot only when its exact feature is no longer loaded.
        tags = line?.tags ?? station?.tags ?? item.tags
        isStation = station != nil || item.isStation
        var seen = Set<RailRoute>()
        // Remove only identical records. Neither names, visibilityKey nor colour
        // alone identify a relation: shared tracks must retain every identity.
        routes = (line?.routes ?? station?.routes ?? []).filter { seen.insert($0).inserted }
    }

    var speed: Double? { RailSpeed.maximum(in: tags) }
    var speedFields: [String: String] {
        tags.filter { RailSpeed.keys.contains($0.key) && Self.nonempty($0.value) != nil }
    }
    var speedText: String {
        speed.map { $0.formatted(.number.precision(.fractionLength(0...1))) }
            ?? (speedFields.isEmpty ? "未标注" : "无明确数值")
    }

    private static let operatorKeys = ["operator:zh", "operator", "operator:en"]
    private var ownOperator: String? { Self.firstValue(Self.operatorKeys, in: tags) }
    var usesRouteOperators: Bool { ownOperator == nil && !operators.isEmpty }
    var operators: [String] {
        if let ownOperator { return [ownOperator] }
        var seen = Set<String>()
        return routes.compactMap { Self.firstValue(Self.operatorKeys, in: $0.tags) }
            .filter { seen.insert($0).inserted }
    }
    var operatorMark: String? {
        // These are actual textual marks, not initials synthesized into a logo.
        let mark = Self.firstValue(["operator:short_name", "operator:short", "operator:abbr", "operator:ref"], in: tags)
        return mark == ownOperator ? nil : mark
    }

    var countries: [FeatureInspectorCountry] {
        [
            ("country", "国家 / 地区"),
            ("addr:country", "地址国家 / 地区"),
            ("operator:country", "运营方所属国家"),
            ("ISO3166-1:alpha2", "国家代码"),
            ("ISO3166-1", "国家代码")
        ].compactMap { key, title in
            guard let value = Self.nonempty(tags[key]) else { return nil }
            return FeatureInspectorCountry(key: key, title: title, value: value)
        }
    }

    /// An element's own colour is not evidence of route membership.
    var featureColor: RailColor? {
        guard routes.isEmpty else { return nil }
        return ["colour", "color"].compactMap { tags[$0].flatMap(RailColor.init) }.first
    }

    var associationExplanation: String {
        if let recorded = Self.nonempty(tags["atlas:routeMatch"]) { return recorded }
        if routes.isEmpty { return "当前已载入的要素没有线路关联记录，不能据此判定它不属于任何线路。" }
        if tags["atlas:routeStop"] == "yes" {
            return "该站点作为 stop 成员载入 OSM 线路关系。"
        }
        return "来自当前选中要素所携带的线路记录；数据没有记录更具体的关联方式。"
    }

    var osmURL: URL? {
        [tags["atlas:osm"], item.osmReference, item.id]
            .compactMap { $0.flatMap(Self.osmURL(reference:)) }.first
    }

    var sourceName: String {
        Self.nonempty(tags["atlas:source"]) ?? (osmURL != nil ? "OpenStreetMap" : "未提供要素来源")
    }

    static func nonempty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func firstValue(_ keys: [String], in tags: [String: String]) -> String? {
        keys.compactMap { nonempty(tags[$0]) }.first
    }

    static func osmURL(reference: String) -> URL? {
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["node", "way", "relation"].contains(String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(parts[1]), number > 0 else { return nil }
        return URL(string: "https://www.openstreetmap.org/\(parts[0])/\(number)")
    }

    static func webURL(_ value: String?) -> URL? {
        guard let value = nonempty(value), let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func osmTags(_ tags: [String: String]) -> [String: String] {
        tags.filter { !$0.key.hasPrefix("atlas:") }
    }

    static func applicationTags(_ tags: [String: String]) -> [String: String] {
        tags.filter { $0.key.hasPrefix("atlas:") }
    }

    static func tagJSON(_ tags: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tags, options: [.prettyPrinted, .sortedKeys]) else {
            return tags.keys.sorted().map { "\($0)=\(tags[$0] ?? "")" }.joined(separator: "\n")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct FeatureInspectorCountry: Identifiable {
    let key: String
    let title: String
    let value: String
    var id: String { key }

    private static let regionCodes = Set(Locale.Region.isoRegions.map(\.identifier))

    var displayValue: String {
        value.components(separatedBy: ";").map { raw in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            // Only explicit ISO alpha-2 values receive flags. Unrecognised
            // country names/codes remain verbatim; location/operator names
            // never supply a country.
            guard code.unicodeScalars.count == 2,
                  code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
                  Self.regionCodes.contains(code) else { return raw }
            let flag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
                UnicodeScalar(127397 + $0.value)
            }))
            return "\(flag) \(Locale.current.localizedString(forRegionCode: code) ?? code) · \(code)"
        }.joined(separator: "；")
    }
}
