import Foundation

/// Prepared alongside the spatial index, off the UI thread. Unknown routes
/// are deduplicated too: failing to match a city must not cost one catalogue
/// scan per track fragment on every network response.
public struct MetroColourRequests: Sendable {
    public let palette: [String: RailRoute]
    public let wiki: [String: RailRoute]
    public let distinctRouteCount: Int

    public init(lines: [RailLine], stations: [RailStation]) {
        var unique = Set<RailRoute>()
        for line in lines { unique.formUnion(line.routes ?? []) }
        for station in stations { unique.formUnion(station.routes ?? []) }
        distinctRouteCount = unique.count
        var palette: [String: RailRoute] = [:], wiki: [String: RailRoute] = [:]
        for route in unique.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { break }
            if let key = MetroPalette.key(for: route), palette[key] == nil { palette[key] = route }
            if let key = WikiMetroColours.identity(for: route), wiki[key] == nil { wiki[key] = route }
        }
        self.palette = palette
        self.wiki = wiki
    }
}
