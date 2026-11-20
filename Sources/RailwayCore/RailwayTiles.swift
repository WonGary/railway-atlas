import Foundation

/// XYZ tiles, always in Web Mercator / WGS84, independent of the map renderer.
public struct RailTile: Hashable, Codable, Sendable {
    public let z: Int
    public let x: Int
    public let y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    public var path: String { "\(z)/\(x)/\(y)" }
    public var isValid: Bool { (0...16).contains(z) && (0..<(1 << z)).contains(x) && (0..<(1 << z)).contains(y) }

    public var bounds: MapBounds {
        MapBounds(south: coordinate(0, 4096).latitude, west: coordinate(0, 0).longitude,
                  north: coordinate(4096, 0).latitude, east: coordinate(4096, 4096).longitude)
    }

    public func coordinate(_ px: Double, _ py: Double, extent: Double = 4096) -> Coordinate {
        let scale = Double(1 << z)
        return Coordinate(atan(sinh(.pi * (1 - 2 * (Double(y) + py / extent) / scale))) * 180 / .pi,
                          (Double(x) + px / extent) / scale * 360 - 180)
    }

    public static func covering(_ bounds: MapBounds, zoom: Int) -> [RailTile] {
        guard bounds.isValid, (0...16).contains(zoom) else { return [] }
        let scale = Double(1 << zoom)
        func tx(_ lon: Double) -> Int { min(Int(scale) - 1, max(0, Int(floor((lon + 180) / 360 * scale)))) }
        func ty(_ lat: Double) -> Int {
            let radians = min(85, max(-85, lat)) * .pi / 180
            return min(Int(scale) - 1, max(0, Int(floor((1 - asinh(tan(radians)) / .pi) / 2 * scale))))
        }
        let xs = tx(bounds.west)...tx(bounds.east)
        let ys = ty(bounds.north)...ty(bounds.south)
        guard xs.count * ys.count <= 64 else { return [] }
        let cx = Double(tx(bounds.center.longitude)), cy = Double(ty(bounds.center.latitude))
        return xs.flatMap { x in ys.map { RailTile(z: zoom, x: x, y: $0) } }
            .sorted { hypot(Double($0.x) - cx, Double($0.y) - cy) < hypot(Double($1.x) - cx, Double($1.y) - cy) }
    }
}

public enum RailTileLayer: String, CaseIterable, Codable, Sendable {
    case overview = "speed_railway_line_low"
    case tracks = "railway_line_high,railway_text_km"
    case stationsLow = "standard_railway_text_stations_low"
    case stationsMedium = "standard_railway_text_stations_med"
    case stations = "standard_railway_text_stations,standard_railway_grouped_stations,standard_railway_grouped_station_areas,standard_station_entrances,standard_railway_stop_positions,standard_interlocking,standard_interlocking_text"
    case metroColors = "atlas_metro_routes_v1"
    case metroNetwork = "atlas_metro_network_v2"
    case metroStations = "atlas_metro_stations_v2"
    case openMapTiles = "atlas_openmaptiles_v1"
    case shortbread = "atlas_shortbread_v1"
    case wikiColors = "atlas_wiki_colours_v1"
    case paletteColors = "atlas_palette_colours_v1"

    public var isStations: Bool { self == .stations || self == .stationsLow || self == .stationsMedium }
    public var isMetro: Bool { self == .metroColors || self == .metroNetwork || self == .metroStations }
    public static func at(zoom: Int, stations: Bool) -> [Self] {
        var layers: [Self] = [zoom < 7 ? .overview : .tracks]
        if stations && zoom >= 7 {
            layers.append(zoom < 7 ? .stationsLow : zoom < 8 ? .stationsMedium : .stations)
        }
        return layers
    }
}

public struct RailTileKey: Hashable, Codable, Sendable {
    public let layer: RailTileLayer
    public let tile: RailTile
    public init(layer: RailTileLayer, tile: RailTile) { self.layer = layer; self.tile = tile }
    public var path: String { "\(layer.rawValue)/\(tile.path)" }
}

public struct RailTilePlan: Sendable {
    public let zoom: Int
    public let keys: [RailTileKey]
    public init(bounds: MapBounds, width: Double, stations: Bool = true) {
        guard bounds.isValid, width.isFinite else { zoom = 0; keys = []; return }
        let ideal = log2(max(320, width) * 360 / (256 * max(0.001, bounds.east - bounds.west)))
        var z = min(15, max(3, Int(floor(ideal))))
        var tiles = RailTile.covering(bounds, zoom: z)
        while tiles.isEmpty && z > 0 { z -= 1; tiles = RailTile.covering(bounds, zoom: z) }
        zoom = z
        // One independent colour slot starts immediately beside track requests.
        var requested = RailTileLayer.at(zoom: z, stations: stations).flatMap { layer in tiles.map { RailTileKey(layer: layer, tile: $0) } }
        let metro = MetroViewport(bounds: bounds, zoom: z, stations: stations)
        requested.insert(contentsOf: metro.networkKeys, at: 0)
        requested += metro.stationKeys
        keys = requested
    }
}

public struct RailTileFeatures: Sendable {
    public var lines: [RailLine] = []
    public var stations: [RailStation] = []
    /// Complete relation membership survives even when geometry is clipped to
    /// a cell. OSM identity, not visible geometry, determines line membership.
    public var memberships: [String: [RailRoute]] = [:]
    public init() {}
}

/// Additional, independent visibility controls. An operator is never assumed
/// private merely because it is not the national railway company.
public enum RailNetwork: String, CaseIterable, Identifiable, Sendable {
    case railway, metro, lightRail, tram, industrial, narrowGauge, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .railway: "铁路 · 高铁 / 普铁 / 支线"
        case .metro: "地铁"
        case .lightRail: "轻轨与单轨"
        case .tram: "有轨电车"
        case .industrial: "工业与专用铁路"
        case .narrowGauge: "窄轨铁路"
        case .other: "其他轨道 · 缆索 / 观光"
        }
    }
    public static func classify(_ tags: [String: String]) -> Self {
        var type = tags["railway"] ?? ""
        for state in ["construction", "proposed", "disused", "abandoned", "razed"] {
            if let original = tags["\(state):railway"] { type = original }
        }
        switch type {
        case "subway": return .metro
        case "light_rail", "monorail": return .lightRail
        case "tram": return .tram
        case "narrow_gauge": return .narrowGauge
        case "funicular", "miniature": return .other
        default:
            if ["industrial", "military", "test"].contains(tags["usage"] ?? "") ||
                tags["service"] == "spur" || tags["ownership"] == "private" || tags["operator:type"] == "private" {
                return .industrial
            }
            return .railway
        }
    }
}

extension MapBounds {
    public static let china = MapBounds(south: 18, west: 73, north: 54, east: 135)
}
