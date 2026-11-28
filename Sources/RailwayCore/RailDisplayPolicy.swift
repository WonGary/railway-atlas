import Foundation

/// Presentation changes with scale; the underlying tags and palette do not.
public enum RailDisplayPolicy {
    public static func minimumZoom(_ category: RailCategory) -> Int {
        switch category {
        case .freight, .branch: 8
        case .urban: MetroViewport.minimumZoom
        case .service: 15
        case .construction, .disused, .abandoned: 10
        default: 0
        }
    }
    public static func minimumZoom(_ network: RailNetwork) -> Int {
        switch network {
        case .metro, .lightRail, .tram: MetroViewport.minimumZoom
        case .industrial, .narrowGauge: 9
        default: 0
        }
    }
    public static func zoom(longitudeSpan: Double, width: Double) -> Double {
        min(20, max(2, log2(max(320, width) * 360 / (256 * max(0.001, longitudeSpan)))))
    }
    public static let detailHitZoom = 11.0
    /// Distance from the track centre, in logical screen points.
    public static func trackHitTolerance(zoom: Double, touch: Bool = false) -> Double {
        guard zoom >= detailHitZoom else { return 0 }
        return (zoom < 14 ? 3.5 : 4.5) + (touch ? 2 : 0)
    }
    /// Additional reach outside a station symbol, also in screen points.
    public static func stationHitPadding(zoom: Double, touch: Bool = false) -> Double {
        (zoom < detailHitZoom ? 1 : 2) + (touch ? 2 : 0)
    }
    public static func labelVisible(_ station: RailStation, zoom: Double) -> Bool {
        labelVisible(station.appearance().kind, zoom: zoom)
    }
    public static func labelVisible(_ kind: StationKind, zoom: Double) -> Bool {
        switch kind {
        case .major, .connection: zoom >= 9
        case .railway, .interchange: zoom >= 11
        default: zoom >= 13
        }
    }
}

/// Cached source facts shared by the UI store and headless visibility checks.
public struct RailLineDisplayFacts: Sendable {
    public let category: RailCategory
    public let network: RailNetwork
    public let urbanTransit: Bool
    public let branch: Bool
    public let overview: Bool
    public let overviewLOD: String?
    public let serviceTrack: Bool
    public let sourceZoom: Int?

    public init(_ line: RailLine) {
        category = line.category
        network = .classify(line.tags)
        urbanTransit = line.isUrbanTransit
        branch = line.tags["usage"] == "branch"
        overview = line.tags["atlas:nationalOverview"] == "yes"
        overviewLOD = line.tags["atlas:overviewLOD"]
        serviceTrack = line.tags["service"].map { !$0.isEmpty && $0 != "no" } == true
            || line.tags["depot"] == "yes"
        sourceZoom = line.tags["atlas:tileZoom"].flatMap(Int.init)
    }
}

public struct RailStationDisplayFacts: Sendable {
    public let network: RailNetwork
    public let kind: StationKind
    public let urbanTransit: Bool
    public let lifecycle: RailCategory?

    public init(_ station: RailStation) {
        network = station.network
        kind = station.appearance().kind
        urbanTransit = station.isUrbanTransit
        lifecycle = RailCategory.lifecycleCategory(station.tags)
    }
}

/// Urban priority is additive. Turning it off restores the stored class/network
/// choices; it never hides urban transit as a group or changes those choices.
public struct RailVisibilityPolicy: Sendable {
    public var categories = Set(RailCategory.allCases)
    public var networks = Set(RailNetwork.allCases)
    public var forcedCategories = Set<RailCategory>()
    public var forcedNetworks = Set<RailNetwork>()
    public var hiddenRoutes = Set<String>()
    public var automaticDetail = true
    public var prioritizesUrbanTransit = false
    public var showsNationalMetroOverview = true
    public var hasNationalMetroOverview = false
    public var showsStations = true
    public var zoom = 12.0
    public init() {}

    public func categoryVisible(_ category: RailCategory) -> Bool {
        categories.contains(category) && (!automaticDetail || forcedCategories.contains(category)
            || (category == .urban && showsNationalMetroOverview && hasNationalMetroOverview)
            || zoom >= Double(RailDisplayPolicy.minimumZoom(category)))
    }

    public func networkVisible(_ network: RailNetwork) -> Bool {
        networks.contains(network) && (!automaticDetail || forcedNetworks.contains(network)
            || ([.metro, .lightRail, .tram].contains(network) && showsNationalMetroOverview && hasNationalMetroOverview)
            || zoom >= Double(RailDisplayPolicy.minimumZoom(network)))
    }

    public func visible(_ original: RailLine, facts supplied: RailLineDisplayFacts? = nil,
                        suppressed: Bool = false) -> RailLine? {
        guard !suppressed else { return nil }
        var facts = supplied ?? RailLineDisplayFacts(original)
        // The overview switch is a data/render gate, even for retained geometry
        // or an assembly response that arrives after it was disabled.
        guard !facts.overview || showsNationalMetroOverview else { return nil }
        if facts.overviewLOD == "country" && zoom >= Double(MetroViewport.minimumZoom) { return nil }
        if facts.overviewLOD == "detail" && zoom < Double(MetroViewport.minimumZoom) { return nil }
        guard let line = hiddenRoutes.isEmpty ? original : MetroIdentity.visible(original, hiding: hiddenRoutes) else { return nil }
        if line.routes?.count != original.routes?.count {
            // A hidden commuter route cannot promote a remaining intercity
            // service on the same physical track.
            facts = RailLineDisplayFacts(line)
        }
        let priority = prioritizesUrbanTransit && facts.urbanTransit
        guard priority || (categoryVisible(facts.category) && networkVisible(facts.network)) else { return nil }
        if automaticDetail {
            // Depot/siding facts also apply to urban tracks, whose category
            // remains urban so that their route colours and controls survive.
            if facts.serviceTrack && zoom < Double(RailDisplayPolicy.minimumZoom(.service)),
               !forcedCategories.contains(.service), !forcedCategories.contains(facts.category),
               !forcedNetworks.contains(facts.network) { return nil }
            // Source LOD is selected spatially by drawingTiles, which removes
            // old geometry only where a replacement has arrived. A zoom limit
            // here would hide the remaining coverage during a cache/network
            // wait, even though it is still the only railway we can draw.
            if facts.branch && !forcedCategories.contains(.branch) && zoom < 8 { return nil }
            // Priority overrides category/network selections, not scale rules,
            // lifecycle facts or overview/detail handoff.
            if !facts.overview {
                if !forcedCategories.contains(facts.category),
                   zoom < Double(RailDisplayPolicy.minimumZoom(facts.category)) { return nil }
                if !forcedNetworks.contains(facts.network),
                   zoom < Double(RailDisplayPolicy.minimumZoom(facts.network)) { return nil }
            }
        }
        return line
    }

    public func visible(_ original: RailStation, facts supplied: RailStationDisplayFacts? = nil) -> RailStation? {
        guard showsStations else { return nil }
        var station = original
        var facts = supplied ?? RailStationDisplayFacts(original)
        if let routes = station.routes, !routes.isEmpty, !hiddenRoutes.isEmpty {
            station.routes = routes.filter { !hiddenRoutes.contains($0.visibilityKey) }
            guard station.routes?.isEmpty == false else { return nil }
            if station.routes?.count != routes.count { facts = RailStationDisplayFacts(station) }
        }
        guard networkVisible(facts.network) || (prioritizesUrbanTransit && facts.urbanTransit),
              !automaticDetail || zoom >= 8,
              !automaticDetail || zoom >= 10 || [.major, .connection].contains(facts.kind) else { return nil }
        if let lifecycle = facts.lifecycle, !categoryVisible(lifecycle) { return nil }
        return station
    }
}

/// Display-only generalization measured in screen points. Simplify each
/// already-clipped part separately; never alter source/routing coordinates.
public enum RailGeometryLOD {
    public static func segments(_ parts: [[Coordinate]], zoom: Double) -> [[Coordinate]] {
        guard zoom.isFinite else { return parts }
        let level = min(20, max(2, floor(zoom)))
        let tolerance = 0.75 / (256 * exp2(level))
        return parts.map { simplify($0, tolerance: tolerance) }
    }

    private static func simplify(_ coordinates: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }
        let points = coordinates.map { point -> (x: Double, y: Double) in
            let latitude = min(85, max(-85, point.latitude)) * .pi / 180
            return ((point.longitude + 180) / 360, (1 - asinh(tan(latitude)) / .pi) / 2)
        }
        var kept = Set([0, points.count - 1])
        var pending = [(0, points.count - 1)]
        while let (first, last) = pending.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            var maximum = tolerance * tolerance, farthest: Int?
            for index in (first + 1)..<last {
                let p = points[index]
                let t = length == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
                let distance = pow(p.x - a.x - t * dx, 2) + pow(p.y - a.y - t * dy, 2)
                if distance > maximum { maximum = distance; farthest = index }
            }
            if let farthest {
                kept.insert(farthest)
                pending.append((first, farthest)); pending.append((farthest, last))
            }
        }
        return kept.sorted().map { coordinates[$0] }
    }
}

/// Keep previously learned attributes when a less detailed source arrives.
/// Exact OSM identities only; no speed or ownership guessing.
public struct RailIdentityLedger: Sendable {
    private var ways: [String: RailLine] = [:]
    private var routes: [String: RailRoute] = [:]
    private var members: [String: Set<String>] = [:]
    public init() {}

    public mutating func apply(_ features: RailTileFeatures) -> RailTileFeatures {
        for route in features.lines.flatMap({ $0.routes ?? [] }) + features.stations.flatMap({ $0.routes ?? [] })
            + features.memberships.values.flatMap({ $0 }) {
            if let old = routes[route.id] {
                var merged = route
                merged.tags = old.tags.merging(route.tags) { old, new in new.isEmpty ? old : new }
                routes[route.id] = merged
            } else { routes[route.id] = route }
        }
        for (id, routes) in features.memberships {
            members[id, default: []].formUnion(routes.map(\.id))
        }
        var output = features
        for index in output.lines.indices {
            var line = output.lines[index]
            if let key = line.tags["atlas:osm"] {
                if (line.routes ?? []).isEmpty, let ids = members[key] {
                    line.routes = ids.sorted().compactMap { routes[$0] }
                    line.tags["atlas:routeMatch"] = "OSM 线路关系的完整成员 ID"
                }
                if let old = ways[key] {
                    for field in RailSpeed.keys + RailUrbanService.evidenceKeys
                        + ["operator", "network", "name", "colour"] {
                        if line.tags[field] == nil { line.tags[field] = old.tags[field] }
                    }
                    if (line.routes ?? []).isEmpty { line.routes = old.routes }
                }
                ways[key] = line
            }
            line.routes = line.routes?.map { routes[$0.id] ?? $0 }
            output.lines[index] = line
        }
        for index in output.stations.indices {
            let key = output.stations[index].tags["atlas:osm"] ?? output.stations[index].id
            if (output.stations[index].routes ?? []).isEmpty, let ids = members[key] {
                output.stations[index].routes = ids.sorted().compactMap { routes[$0] }
            }
            output.stations[index].routes = output.stations[index].routes?.map { routes[$0.id] ?? $0 }
        }
        if ways.count > 50_000 { ways = Dictionary(ways.sorted { $0.key < $1.key }.suffix(30_000), uniquingKeysWith: { a, _ in a }) }
        if members.count > 100_000 { members = [:] }
        if routes.count > 5_000 { routes = [:]; members = [:] }
        return output
    }
}
