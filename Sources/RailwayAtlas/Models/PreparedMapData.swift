import Foundation
import RailwayCore

/// All source-dependent decisions happen once, outside camera movement.
struct PreparedMapData: Sendable {
    struct Line: Sendable {
        let display: RailLineDisplayFacts
        var category: RailCategory { display.category }
        let bounds: MapBounds
        let baseStyle: RailAppearance
        let depot: Bool
        let suppressed: Bool
    }
    let lines: [Line]
    let lineIndex: RailSpatialIndex
    let stationIndex: RailSpatialIndex
    let stationDisplay: [RailStationDisplayFacts]
    let stationCategories: [String: RailCategory]
    let counts: [RailCategory: Int]
    let routes: [RailRoute]
    let routeTitles: [String: String]
    let assistantRoutes: [AssistantRouteChoice]
    let lineByID: [String: Int]
    let stationByID: [String: Int]
    let interchanges: StationInterchangeIndex
    let colourRequests: MetroColourRequests
    init(lines source: [RailLine], stations: [RailStation]) {
        var overlayBounds: [String: [MapBounds]] = [:]
        for line in source where line.tags["atlas:routeOverlay"] == "yes" {
            if let way = line.tags["atlas:osm"] {
                overlayBounds[way, default: []].append(MapBounds(points: line.coordinates))
            }
        }
        var counts: [RailCategory: Int] = [:], routes: [String: RailRoute] = [:]
        var routeLines: [String: [RailLine]] = [:], namedLines: [String: [RailLine]] = [:]
        self.lines = source.map { line in
            let category = line.category
            let bounds = MapBounds(points: line.coordinates)
            if line.tags["atlas:routeOverlay"] != "yes" { counts[category, default: 0] += 1 }
            for route in line.routes ?? [] {
                let key = route.visibilityKey
                if let old = routes[key], old.id <= route.id { continue }
                routes[key] = route
            }
            for key in Set((line.routes ?? []).map(\.visibilityKey)) { routeLines[key, default: []].append(line) }
            if (line.routes ?? []).isEmpty && (line.tags["name"] != nil || line.tags["ref"] != nil) {
                let key = "named|\(line.tags["network"] ?? "")|\(line.tags["operator"] ?? "")|\(line.tags["name"] ?? "")|\(line.tags["ref"] ?? "")"
                namedLines[key, default: []].append(line)
            }
            return Line(display: RailLineDisplayFacts(line),
                        bounds: bounds, baseStyle: line.appearance(showMetroColors: true, depotBrightness: 1),
                        depot: line.tags["service"] != nil || line.tags["depot"] == "yes",
                        // A relation response may contain only one clipped
                        // part of a long OSM way. Keep its other base fragments.
                        suppressed: line.tags["atlas:routeOverlay"] != "yes"
                            && overlayBounds[line.tags["atlas:osm"] ?? "", default: []].contains { $0.contains(bounds) })
        }
        lineIndex = RailSpatialIndex(bounds: self.lines.map(\.bounds))
        stationIndex = RailSpatialIndex(bounds: stations.map { MapBounds(points: [$0.coordinate]) })
        stationDisplay = stations.map(RailStationDisplayFacts.init)
        stationCategories = stations.isEmpty ? [:] : StationTrackSizing.categories(lines: source, stations: stations)
        self.counts = counts
        let sortedRoutes = routes.values.sorted {
            ($0.tags["ref"] ?? $0.name).localizedStandardCompare($1.tags["ref"] ?? $1.name) == .orderedAscending
        }
        self.routes = sortedRoutes
        routeTitles = MetroRouteTitle.labels(sortedRoutes)
        assistantRoutes = (
            routes.map { AssistantRouteChoice(id: $0.key, name: $0.value.name, route: $0.value, lines: routeLines[$0.key] ?? []) }
            + namedLines.map { AssistantRouteChoice(id: $0.key, name: $0.value[0].name, route: nil, lines: $0.value) }
        ).sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        lineByID = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        stationByID = Dictionary(stations.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        interchanges = StationInterchangeIndex(stations: stations)
        colourRequests = MetroColourRequests(
            lines: source.filter { $0.tags["atlas:nationalOverview"] != "yes" }, stations: stations)
    }
}
