import Foundation

/// Retain visible geometry until the replacement tiles covering it arrive.
/// Network failure is not evidence that a previously visible railway vanished.
public enum RailTileContinuity {
    /// Keep fallback data in memory, but draw each area at only one tile LOD.
    /// An arrived cell replaces the corresponding part of an old parent
    /// immediately, without waiting for the parent's other children.
    public static func drawingTiles(_ tiles: [RailTileKey: RailTileFeatures],
                                    requested: [RailTileKey],
                                    fallbackKeys: Set<RailTileKey> = []) -> [RailTileKey: RailTileFeatures] {
        let tracks = tiles.keys.filter { $0.layer == .tracks || $0.layer == .overview }
        let wanted = Set(requested)
        guard let zoom = requested.first(where: { $0.layer == .tracks || $0.layer == .overview })?.tile.z else {
            return tiles
        }
        func rank(_ key: RailTileKey) -> Int {
            // A detailed backup is more useful than a deeply overzoomed
            // overview. Otherwise primary geometry keeps its precedence.
            if key.tile.z + 2 < zoom { return 3 }
            if fallbackKeys.contains(key) { return 2 }
            return wanted.contains(key) ? 0 : 1
        }
        let ordered = tracks.sorted {
            let left = rank($0), right = rank($1)
            if left != right { return left < right }
            let ld = abs($0.tile.z - zoom), rd = abs($1.tile.z - zoom)
            if ld != rd { return ld < rd }
            if $0.tile.z != $1.tile.z { return $0.tile.z > $1.tile.z }
            return $0.path < $1.path
        }
        var result = tiles, covered: [MapBounds] = []
        for key in ordered {
            guard var features = tiles[key], !Task.isCancelled else { break }
            let bounds = key.tile.bounds
            let overlaps = covered.filter { $0.intersects(bounds) }
            features.lines = features.lines.flatMap { original -> [RailLine] in
                // MVT buffers can extend beyond a tile. Trim those too so
                // adjacent tiles cannot reintroduce a second shifted stroke.
                var parts = RailGeometryClip.segments(original.coordinates, inside: bounds)
                for overlap in overlaps {
                    parts = parts.flatMap { NationalMetroDisplay.outside($0, bounds: overlap) }
                    if parts.isEmpty { break }
                }
                return parts.enumerated().map { index, coordinates in
                    var line = original
                    // A backup Z14 tile may serve four requested Z15 cells
                    // with identical source IDs. Each clipped cell is distinct.
                    line.id += "/display/\(key.tile.path)/\(index)"
                    line.coordinates = coordinates
                    line.tags["atlas:tileZoom"] = String(key.tile.z)
                    return line
                }
            }
            result[key] = features
            // Even an empty complete primary tile replaces old content.
            // A fallback cell is never evidence that a railway is absent.
            if !fallbackKeys.contains(key) || !features.lines.isEmpty { covered.append(bounds) }
        }
        return result
    }

    /// Freshness is not completeness: a generalized basemap may omit every
    /// subway in a cell. Keep arrived primary geometry until primary data
    /// replaces it; backups still fill empty cells and update other backups.
    public static func shouldReplace(existing: RailTileFeatures?, existingFallback: Bool,
                                     incomingFallback: Bool, incomingSnapshot: Bool = false,
                                     incomingComplete: Bool = true) -> Bool {
        guard let existing, !existing.lines.isEmpty || !existing.stations.isEmpty
                || !existing.memberships.isEmpty else { return true }
        if incomingSnapshot || !incomingComplete { return false }
        return !incomingFallback || existingFallback
    }

    /// A partial read is not evidence that any arrived fragment disappeared.
    /// Add only primary identities, retaining existing geometry/attributes on
    /// conflicts. A complete primary result can subsequently replace the cell,
    /// including an empty result. Repeated partial reads cannot multiply IDs.
    public static func accepting(_ incoming: RailTileResult, existing: RailTileFeatures?,
                                 existingFallback: Bool) -> RailTileFeatures? {
        if shouldReplace(existing: existing, existingFallback: existingFallback,
                         incomingFallback: incoming.fallback, incomingSnapshot: incoming.snapshot,
                         incomingComplete: incoming.coverageComplete) {
            return incoming.features
        }
        guard !incoming.fallback, var features = existing,
              let additions = incoming.snapshot ? incoming.primaryFeatures : incoming.features,
              !additions.lines.isEmpty || !additions.stations.isEmpty || !additions.memberships.isEmpty else {
            return nil
        }
        func addingRoutes(_ old: [RailRoute]?, _ new: [RailRoute]?) -> [RailRoute]? {
            guard let new, !new.isEmpty else { return old }
            var ids = Set((old ?? []).map(\.id))
            return (old ?? []) + new.filter { ids.insert($0.id).inserted }
        }
        var lineIndices = Dictionary(features.lines.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
        for line in additions.lines {
            if let index = lineIndices[line.id] {
                features.lines[index].routes = addingRoutes(features.lines[index].routes, line.routes)
            } else {
                lineIndices[line.id] = features.lines.count
                features.lines.append(line)
            }
        }
        var stationIndices = Dictionary(features.stations.enumerated().map { ($0.element.id, $0.offset) },
                                        uniquingKeysWith: { first, _ in first })
        for station in additions.stations {
            if let index = stationIndices[station.id] {
                features.stations[index].routes = addingRoutes(features.stations[index].routes, station.routes)
            } else {
                stationIndices[station.id] = features.stations.count
                features.stations.append(station)
            }
        }
        for (id, routes) in additions.memberships {
            var routeIDs = Set(features.memberships[id, default: []].map(\.id))
            features.memberships[id, default: []].append(contentsOf: routes.filter { routeIDs.insert($0.id).inserted })
        }
        return features
    }

    public static func retainedKeys(existing: Set<RailTileKey>, requested: [RailTileKey],
                                    ready: Set<RailTileKey>, bounds: MapBounds) -> Set<RailTileKey> {
        let wanted = Set(requested)
        let tracks = requested.filter { !$0.layer.isMetro && !$0.layer.isStations }
        let stations = requested.filter { $0.layer.isStations }
        let metro = requested.filter { $0.layer == .metroNetwork }
        let metroStations = requested.filter { $0.layer == .metroStations }
        let buffered = bounds.expanded(by: MetroViewport.bufferFraction)
        return Set(existing.filter { key in
            guard let visible = intersection(key.tile.bounds, key.layer.isMetro ? buffered : bounds) else { return false }
            if wanted.contains(key) { return true }
            let candidates = key.layer.isMetro
                ? (key.layer == .metroStations ? metroStations : metro)
                : (key.layer.isStations ? stations : tracks)
            let replacements = candidates.filter {
                intersection($0.tile.bounds, visible) != nil
            }
            return replacements.isEmpty || !replacements.allSatisfy(ready.contains)
        })
    }

    private static func intersection(_ a: MapBounds, _ b: MapBounds) -> MapBounds? {
        let south = max(a.south, b.south), west = max(a.west, b.west)
        let north = min(a.north, b.north), east = min(a.east, b.east)
        guard north - south > 1e-10, east - west > 1e-10 else { return nil }
        return MapBounds(south: south, west: west, north: north, east: east)
    }
}
