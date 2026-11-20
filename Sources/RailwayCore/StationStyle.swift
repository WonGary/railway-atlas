import Foundation

public enum StationKind: String, Sendable {
    case metro, tram, halt, railway, major, interchange, connection
}

public struct StationAppearance: Sendable, Equatable {
    public let kind: StationKind
    public let radius: Double
    public let filled: Bool
    public let colors: [RailColor]
    public var doubleRing: Bool { kind == .major || kind == .interchange || kind == .connection }
    public var ringWidth: Double { min(1.2, radius * 0.36) }
    public var title: String {
        switch kind {
        case .metro: "地铁站"
        case .tram: "轻轨 / 电车站"
        case .halt: "小型停靠站"
        case .railway: "铁路车站"
        case .major: "大型铁路车站"
        case .interchange: "城市轨道换乘站"
        case .connection: "铁路与城市轨道接驳站"
        }
    }
}

extension RailStation {
    public var isUrbanTransit: Bool { RailUrbanService.station(tags, routes: routes ?? []) }

    public var network: RailNetwork {
        var value = tags
        value["railway"] = tags["station"] ?? (tags["subway"] == "yes" ? "subway" :
            tags["tram"] == "yes" || tags["railway"] == "tram_stop" ? "tram" :
            tags["light_rail"] == "yes" ? "light_rail" : tags["monorail"] == "yes" ? "monorail" : "rail")
        return RailNetwork.classify(value)
    }

    public func appearance(showMetroColors: Bool = true, lineWidth: Double? = nil, zoom: Double = 12,
                           settings: RailRenderSettings = RailRenderSettings()) -> StationAppearance {
        let routes = routes ?? []
        let colors = showMetroColors ? Array(Set(routes.compactMap(\.color))).sorted { $0.hex < $1.hex } : []
        let urban = [.metro, .lightRail, .tram].contains(network) || !routes.isEmpty
        let count = Set(routes.map(\.visibilityKey)).count
        let explicitTransfer = tags["transfer"] == "yes" || tags["interchange"] == "yes"
        let connection = tags["train"] == "yes" && (urban || tags["subway"] == "yes")
            || tags["atlas:railConnection"] == "yes"
        let rank = tags["railway:station_category"] ?? tags["station:class"] ?? tags["railway:station_class"] ?? ""
        let major = ["特等站", "一等站", "特等", "一等", "1", "0"].contains(rank)
            || tags["highspeed"] == "yes" || tags["railway:station:importance"] == "major"
            || tags["station_size"] == "large"
        let kind: StationKind = connection ? .connection : urban && (count > 1 || explicitTransfer) ? .interchange :
            urban ? (network == .tram ? .tram : .metro) : major ? .major :
            tags["railway"] == "halt" ? .halt : .railway
        let category: RailCategory = urban ? .urban : .classify(tags)
        let width = lineWidth ?? RailAppearance(category: category, colors: []).lineWidth(zoom: zoom, settings: settings)
        let radius = width * settings.stationRadiusMultiplier
        return StationAppearance(kind: kind, radius: radius,
                                 filled: [.railway, .major, .connection].contains(kind),
                                 colors: colors.isEmpty ? [RailColor(urban ? "#657D8A" : "#346477")!] : colors)
    }
}

/// Associate size with the rendered track, without merging station objects or
/// inferring line colours. Route identity wins; geometry is only a sizing fallback.
public enum StationTrackSizing {
    public static func categories(lines: [RailLine], stations: [RailStation]) -> [String: RailCategory] {
        struct Cell: Hashable { let x: Int; let y: Int }
        struct Segment { let a: Coordinate; let b: Coordinate; let category: RailCategory }
        func cell(_ p: Coordinate) -> Cell { Cell(x: Int(floor(p.longitude / 0.02)), y: Int(floor(p.latitude / 0.02))) }
        var grid: [Cell: [Segment]] = [:]
        var routes: [String: RailCategory] = [:]
        for line in lines {
            for route in line.routes ?? [] { routes[route.visibilityKey] = line.category }
            for (a, b) in zip(line.coordinates, line.coordinates.dropFirst()) {
                let lo = cell(Coordinate(min(a.latitude, b.latitude), min(a.longitude, b.longitude)))
                let hi = cell(Coordinate(max(a.latitude, b.latitude), max(a.longitude, b.longitude)))
                guard hi.x - lo.x < 64, hi.y - lo.y < 64 else { continue }
                for x in lo.x...hi.x { for y in lo.y...hi.y {
                    grid[Cell(x: x, y: y), default: []].append(Segment(a: a, b: b, category: line.category))
                }}
            }
        }
        var result: [String: RailCategory] = [:]
        for station in stations {
            if let known = (station.routes ?? []).compactMap({ routes[$0.visibilityKey] }).max(by: { $0.lineWidth < $1.lineWidth }) {
                result[station.id] = known
                continue
            }
            let p = station.coordinate, c = cell(p), cosLat = max(0.02, cos(p.latitude * .pi / 180))
            let urban = [.metro, .lightRail, .tram].contains(station.network)
            var best = 300.0
            let longitudeCells = min(8, max(1, Int(ceil(300 / (2226 * cosLat)))))
            for x in (c.x - longitudeCells)...(c.x + longitudeCells) { for y in (c.y - 1)...(c.y + 1) {
                for segment in grid[Cell(x: x, y: y)] ?? [] where (segment.category == .urban) == urban {
                    let ax = (segment.a.longitude - p.longitude) * 111_320 * cosLat
                    let ay = (segment.a.latitude - p.latitude) * 111_320
                    let dx = (segment.b.longitude - segment.a.longitude) * 111_320 * cosLat
                    let dy = (segment.b.latitude - segment.a.latitude) * 111_320
                    let t = max(0, min(1, -(ax * dx + ay * dy) / max(1e-12, dx * dx + dy * dy)))
                    let distance = hypot(ax + t * dx, ay + t * dy)
                    if distance < best { best = distance; result[station.id] = segment.category }
                }
            }}
        }
        return result
    }
}
