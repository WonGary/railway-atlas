import Foundation

public enum RailCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case speed350, speed300, speed250, speed200, speed160, below160
    case unknown, urban, freight, branch, service, construction, disused, abandoned

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speed350: "350+ km/h"
        case .speed300: "300–349 km/h"
        case .speed250: "250–299 km/h"
        case .speed200: "200–249 km/h"
        case .speed160: "160–199 km/h"
        case .below160: "<160 km/h"
        case .unknown: "速度未知"
        case .urban: "地铁与城市轨道"
        case .freight: "货运专线"
        case .branch: "地方支线"
        case .service: "站场与联络轨道"
        case .construction: "在建与规划"
        case .disused: "停用线路"
        case .abandoned: "废弃与拆除线路"
        }
    }

    public static let speedCategories: [Self] = [.speed350, .speed300, .speed250, .speed200, .speed160, .below160, .unknown]
    public static let specialCategories: [Self] = [.freight, .branch, .service, .construction, .disused, .abandoned]
    public static let urbanTypes: Set<String> = ["subway", "light_rail", "tram", "monorail"]
    public static let trackTypes: Set<String> = urbanTypes.union([
        "rail", "narrow_gauge", "construction", "proposed", "disused", "abandoned", "razed"
    ])
    private static let lifecycleRailwayTypes = trackTypes.union(["station", "halt", "tram_stop"])
    private static let lifecycleRouteTypes = urbanTypes.union(["train"])

    public static func isTrack(_ tags: [String: String]) -> Bool {
        trackTypes.contains(tags["railway"] ?? "") ||
            ["abandoned", "razed", "disused", "construction", "proposed"].contains {
                trackTypes.contains(tags["\($0):railway"] ?? "")
            }
    }

    public static func lifecycleCategory(_ tags: [String: String]) -> Self? {
        let railway = tags["railway"] ?? ""
        func state(_ values: [String]) -> Bool {
            values.contains(railway) || values.contains {
                tags[$0] == "yes"
                    || lifecycleRailwayTypes.contains(tags["\($0):railway"] ?? "")
                    || lifecycleRouteTypes.contains(tags["\($0):route"] ?? "")
            }
        }
        if state(["abandoned", "razed"]) { return .abandoned }
        if state(["disused"]) { return .disused }
        if state(["construction", "proposed"]) { return .construction }
        return nil
    }

    /// Returns the physical urban-rail type carried by lifecycle tags.
    /// A lifecycle way may expose the type as `railway=subway` plus
    /// `construction=yes`, or as `railway=construction` plus
    /// `construction:railway=subway`.
    public static func urbanLifecycleType(_ tags: [String: String]) -> String? {
        guard lifecycleCategory(tags) == .construction else { return nil }
        let candidates = [
            tags["construction:railway"], tags["proposed:railway"],
            tags["railway:construction"], tags["railway:proposed"],
            tags["construction"], tags["proposed"], tags["railway"],
            tags["feature"]
        ].compactMap { $0?.lowercased() }
        return candidates.first(where: { urbanTypes.contains($0) })
    }

    public static func isUrbanLifecycle(_ tags: [String: String]) -> Bool {
        urbanLifecycleType(tags) != nil
    }

    public static func classify(_ tags: [String: String], hasUrbanRoute: Bool = false) -> Self {
        let railway = tags["railway"] ?? ""
        // Lifecycle and purpose must survive even when stale speed tags remain.
        if let lifecycle = lifecycleCategory(tags) { return lifecycle }
        if urbanTypes.contains(railway) || hasUrbanRoute { return .urban }
        if let service = tags["service"], !service.isEmpty, service != "no" { return .service }
        if tags["railway:traffic_mode"] == "freight" || ["freight", "industrial"].contains(tags["usage"] ?? "")
            || (tags["passenger"] == "no" && tags["freight"] == "yes") { return .freight }
        if tags["usage"] == "branch" { return .branch }
        guard let speed = RailSpeed.maximum(in: tags) else { return .unknown }
        switch speed {
        case 350...: return .speed350
        case 300..<350: return .speed300
        case 250..<300: return .speed250
        case 200..<250: return .speed200
        case 160..<200: return .speed160
        default: return .below160
        }
    }

    public var color: RailColor {
        let hex: String
        switch self {
        case .speed350: hex = "#D7303F"
        case .speed300: hex = "#E96825"
        case .speed250: hex = "#B58B00"
        case .speed200: hex = "#39864A"
        case .speed160: hex = "#007F99"
        case .below160: hex = "#3972C3"
        case .unknown: hex = "#76818C"
        case .urban: hex = "#526672"
        case .freight: hex = "#8B5AA6"
        case .branch: hex = "#93704C"
        case .service: hex = "#A8B0B6"
        case .construction: hex = "#BB8B3B"
        case .disused: hex = "#877D8D"
        case .abandoned: hex = "#827A73"
        }
        return RailColor(hex)!
    }

    public var lineWidth: Double {
        switch self {
        case .urban: 1.65
        case .service: 1.25
        case .speed350, .speed300: 2.6
        case .disused, .abandoned: 1.5
        default: 2.2
        }
    }

    public var dash: [Double] {
        switch self {
        case .construction: [7, 4]
        case .disused: [4, 5]
        case .abandoned: [1, 5]
        default: []
        }
    }
}

/// An independent service fact, not a replacement for speed, purpose or network.
/// Names, coordinates, ownership and operator names are deliberately not evidence.
public enum RailUrbanService {
    public static let evidenceKeys = ["usage", "service", "passenger", "train", "railway:traffic_mode"]
    private static let serviceValues: Set<String> = ["urban", "suburban", "commuter", "metro"]

    private static func values(_ raw: String?) -> Set<String> {
        Set((raw ?? "").lowercased().split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    public static func hasExplicitService(_ tags: [String: String]) -> Bool {
        evidenceKeys.contains { !values(tags[$0]).isDisjoint(with: serviceValues) }
    }

    /// Retain lifecycle metadata on supported relations; visibility decides if
    /// an operational priority can apply. Ordinary train relations are not urban.
    public static func supportsRoute(_ tags: [String: String]) -> Bool {
        RailCategory.urbanTypes.contains(tags["route"] ?? "")
            || (tags["route"] == "train" && hasExplicitService(tags))
    }

    private static func permitsPassengerService(_ tags: [String: String]) -> Bool {
        guard RailCategory.lifecycleCategory(tags) == nil, tags["passenger"] != "no" else { return false }
        let excluded: Set<String> = ["freight", "industrial", "military", "test", "tourism", "tourist", "heritage"]
        return ["usage", "service", "passenger", "railway:traffic_mode"].allSatisfy {
            values(tags[$0]).isDisjoint(with: excluded)
        }
    }

    public static func route(_ tags: [String: String]) -> Bool {
        permitsPassengerService(tags) && supportsRoute(tags)
    }

    public static func line(_ tags: [String: String], routes: [RailRoute]) -> Bool {
        guard permitsPassengerService(tags) else { return false }
        return RailCategory.urbanTypes.contains(tags["railway"] ?? "")
            || (["rail", "narrow_gauge"].contains(tags["railway"] ?? "") && hasExplicitService(tags))
            || routes.contains { route($0.tags) }
    }

    public static func station(_ tags: [String: String], routes: [RailRoute]) -> Bool {
        guard permitsPassengerService(tags) else { return false }
        return RailCategory.urbanTypes.contains(tags["station"] ?? "")
            || tags["railway"] == "tram_stop"
            || RailCategory.urbanTypes.contains { tags[$0] == "yes" }
            || hasExplicitService(tags) || routes.contains { route($0.tags) }
    }

    /// Keep bounded Overpass requests selective. Explicit suburban/commuter
    /// services use the existing relation pipeline, including offline packages.
    public static func routeQuery(bounds: MapBounds) -> String {
        let box = bounds.overpassValue
        return (["rel[\"type\"=\"route\"][\"route\"~\"^(subway|light_rail|tram|monorail)$\"](\(box));"]
            + evidenceKeys.map {
                "rel[\"type\"=\"route\"][\"route\"=\"train\"][\"\($0)\"~\"^(urban|suburban|commuter|metro)$\"](\(box));"
            }).joined(separator: "\n")
    }
}

public enum RailSpeed {
    public static let keys = ["maxspeed", "maxspeed:forward", "maxspeed:backward"]
    private static let expression = try! NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*(km/h|kmh|kph|mph)?$"#)

    /// km/h by default. Conditional, design and non-numeric limits are not guessed.
    public static func parse(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value),
              let number = Double(value[numberRange]), number > 0, number.isFinite else { return nil }
        let unit = Range(match.range(at: 2), in: value).map { String(value[$0]) }
        return number * (unit == "mph" ? 1.609344 : 1)
    }

    public static func maximum(in tags: [String: String]) -> Double? {
        keys.compactMap { tags[$0].flatMap(parse) }.max()
    }
}

public struct RailColor: Hashable, Sendable {
    public let hex: String
    public init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = [
            "red": "#ff0000", "green": "#008000", "blue": "#0000ff", "yellow": "#ffff00",
            "orange": "#ffa500", "purple": "#800080", "brown": "#a52a2a", "pink": "#ffc0cb",
            "black": "#000000", "white": "#ffffff", "gray": "#808080", "grey": "#808080",
            "cyan": "#00ffff", "aqua": "#00ffff", "magenta": "#ff00ff", "fuchsia": "#ff00ff",
            "teal": "#008080", "navy": "#000080", "lime": "#00ff00", "maroon": "#800000",
            "olive": "#808000", "silver": "#c0c0c0", "gold": "#ffd700"
        ]
        var digits = names[value] ?? value
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        guard [3, 6].contains(digits.count), digits.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        hex = "#" + digits.uppercased()
    }

    public var rgb: (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16)!
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    public func darkened(_ factor: Double) -> RailColor {
        RailColor(String(format: "#%02X%02X%02X", Int(rgb.red * 255 * factor),
                         Int(rgb.green * 255 * factor), Int(rgb.blue * 255 * factor)))!
    }
}

public struct RailRoute: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tags: [String: String]
    /// Relation supplying the colour tag, including inherited route_master colours.
    public var colourSourceID: String?
    public var isUrbanTransit: Bool { RailUrbanService.route(tags) }

    /// Directions and tiles of a physical line share one switch and colour.
    /// Never identify a line by its number alone.
    public var visibilityKey: String {
        if let line = tags["atlas:paletteIdentity"], !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }
        return sourceVisibilityKey
    }
    /// Previous versions persisted this key. Keep it available for migrating
    /// the user's hidden-line switches when a canonical palette ID is learned.
    public var sourceVisibilityKey: String {
        if let q = tags["wikidata"], q.first == "Q" { return q }
        if let master = tags["atlas:routeMaster"], !master.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return master }
        if let network = tags["network"], !network.isEmpty,
           let ref = tags["ref"], !ref.isEmpty { return "\(network)|\(ref)" }
        return id
    }

    public var color: RailColor? {
        OfficialMetroPalette.color(for: tags) ?? tags["atlas:wikiColour"].flatMap(RailColor.init)
            ?? tags["atlas:paletteColour"].flatMap(RailColor.init)
            ?? tags["atlas:bundledColour"].flatMap(RailColor.init)
            ?? (tags["colour"] ?? tags["color"]).flatMap(RailColor.init)
    }
    public var colorSourceName: String {
        if OfficialMetroPalette.color(for: tags) != nil { return "上海地铁官方线路图" }
        if tags["atlas:wikiColour"].flatMap(RailColor.init) != nil { return tags["atlas:wikiSource"] ?? "百科线路色" }
        if tags["atlas:paletteColour"] != nil { return "RMG 社区线路色" }
        if tags["atlas:bundledColour"] != nil { return "本地线路色库 · RMG 社区数据" }
        if id.hasPrefix("tile-route/") { return "OSM 线路色 · OpenMapTiles" }
        return "OSM 线路关系 colour"
    }
    public var colorSourceURL: URL {
        if OfficialMetroPalette.color(for: tags) != nil {
            return URL(string: "https://service.shmetro.com/shMetro2/metro.jsp")!
        }
        if tags["atlas:wikiColour"].flatMap(RailColor.init) != nil, let value = tags["atlas:wikiURL"],
           let url = URL(string: value), url.scheme == "https" { return url }
        if let value = tags["atlas:paletteURL"], let url = URL(string: value),
           MetroPalette.hosts.contains(where: { value.hasPrefix($0 + "/") }) { return url }
        if id.hasPrefix("tile-route/") { return URL(string: "https://openfreemap.org")! }
        return URL(string: "https://www.openstreetmap.org/\(colourSourceID ?? id)")!
    }
}

public enum OfficialMetroPalette {
    /// Shanghai Metro's published line colours, recorded from its official line
    /// marker SVGs. OSM relation colours remain the fallback for other networks.
    private static let shanghai: [String: RailColor] = [
        "1": "#E6002A", "2": "#8CC220", "3": "#FCD600", "4": "#461D84",
        "5": "#944D9A", "6": "#D40068", "7": "#ED6F00", "8": "#0095D9",
        "9": "#87CAED", "10": "#C6AFD4", "11": "#871C2B", "12": "#007A60",
        "13": "#E999C0", "14": "#616020", "15": "#C8B38E", "16": "#98D1C0",
        "17": "#B7766C", "18": "#C09453"
    ].compactMapValues(RailColor.init)

    public static func color(for tags: [String: String]) -> RailColor? {
        let network = tags["network"] ?? tags["operator"] ?? ""
        guard network.localizedCaseInsensitiveContains("上海地铁") else { return nil }
        let reference = (tags["ref"] ?? "").replacingOccurrences(of: "号线", with: "")
            .trimmingCharacters(in: .whitespaces)
        return shanghai[reference]
    }
}

/// Shared by Canvas, MapKit and the legend. Same-track routes alternate colours.
public struct RailAppearance: Hashable, Sendable {
    public let category: RailCategory
    public let colors: [RailColor]
    /// Construction / proposed urban rail is intentionally independent from
    /// the yellow railway construction symbol.
    public let isUrbanLifecycle: Bool
    public init(category: RailCategory, colors: [RailColor], isUrbanLifecycle: Bool = false) {
        self.category = category
        self.colors = colors
        self.isUrbanLifecycle = isUrbanLifecycle
    }
    /// Rebuild a colour-adjusted appearance without losing lifecycle-specific
    /// rendering facts such as the grey-white urban construction dash.
    public func replacingColors(_ colors: [RailColor]) -> Self {
        Self(category: category, colors: colors, isUrbanLifecycle: isUrbanLifecycle)
    }

    public var strokes: [RailStroke] { strokes(zoom: 12) }

    public func lineWidth(zoom: Double, settings: RailRenderSettings = RailRenderSettings()) -> Double {
        let width = zoom < 6 ? (category == .speed350 || category == .speed300 ? 1.15 : 0.65) :
            zoom < 9 ? category.lineWidth * 0.65 : category.lineWidth
        return width * (category == .urban ? settings.metroWidthScale : settings.railwayWidthScale)
    }

    public func strokes(zoom: Double, settings: RailRenderSettings = RailRenderSettings()) -> [RailStroke] {
        // At continental scale, keep the colour, simplify only the symbol.
        let width = lineWidth(zoom: zoom, settings: settings)
        if category == .construction && isUrbanLifecycle {
            let casing = RailStroke(color: RailColor("#B7BEC5")!, width: width, dash: [7, 4])
            let highlight = RailStroke(color: RailColor("#F5F7F7")!,
                                        width: max(0.55, width * 0.52), dash: [7, 4])
            return [casing, highlight]
        }
        guard category == .urban else {
            let rail = RailStroke(color: category.color, width: width, dash: category.dash)
            guard settings.railwayPattern, zoom >= 7, category.dash.isEmpty else { return [rail] }
            // Colour casing with an inset light dash: solid / hollow rectangles,
            // never perpendicular sleepers. Both strokes have the same envelope.
            return [rail, RailStroke(color: RailColor("#F4F5F3")!, width: max(0.5, width * 0.48),
                                    dash: [7, 7])]
        }
        guard !colors.isEmpty else { return [RailStroke(color: category.color, width: width)] }
        var strokes: [RailStroke] = []
        for (index, color) in colors.enumerated() {
            strokes.append(RailStroke(
                color: color, width: width,
                dash: colors.count > 1 ? [9, Double(colors.count - 1) * 9] : [],
                phase: -Double(index) * 9
            ))
        }
        return strokes
    }
}

public struct RailStroke: Hashable, Sendable {
    public let color: RailColor
    public let width: Double
    public var dash: [Double] = []
    public var phase: Double = 0
}

extension RailLine {
    public var appearance: RailAppearance { appearance(showMetroColors: true) }

    public func appearance(showMetroColors: Bool, depotBrightness: Double = 0.5) -> RailAppearance {
        let urbanLifecycle = category == .construction && RailCategory.isUrbanLifecycle(tags)
        guard showMetroColors else {
            return RailAppearance(category: category, colors: [], isUrbanLifecycle: urbanLifecycle)
        }
        var colors = Array(Set((routes ?? []).compactMap(\.color)))
        if colors.isEmpty, let color = (tags["colour"] ?? tags["color"]).flatMap(RailColor.init) {
            colors = [color]
        }
        let depot = tags["service"] != nil || tags["depot"] == "yes"
        return RailAppearance(category: category, colors: category == .urban
            ? colors.map { depot ? $0.darkened(depotBrightness) : $0 }.sorted { $0.hex < $1.hex } : [],
            isUrbanLifecycle: urbanLifecycle)
    }
}
