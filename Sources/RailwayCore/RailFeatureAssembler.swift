import Foundation

public struct RailAssembly: Sendable {
    public let features: RailTileFeatures
    public let ledger: RailIdentityLedger
    public let usesPreview: Bool
}

public enum RailFeatureAssembler {
    public static func assemble(
        tiles: [RailTileKey: RailTileFeatures], palette: [String: MetroPaletteRecord],
        wiki: [String: WikiMetroColour], enrichWiki: Bool, ledger: RailIdentityLedger,
        preview: RailwayDataset?, requested: [RailTileKey] = [],
        fallbackKeys: Set<RailTileKey> = []
    ) -> RailAssembly {
        let tiles = RailTileContinuity.drawingTiles(tiles, requested: requested, fallbackKeys: fallbackKeys)
        var lines: [RailLine] = [], stations: [RailStation] = []
        var lineIDs = Set<String>(), stationIndices: [String: Int] = [:]
        var memberships: [String: [RailRoute]] = [:]
        let rawBounds = tiles.keys.filter { $0.layer == .metroStations }.map { $0.tile.bounds }
        var decorated: [RailRoute: RailRoute] = [:]
        func decorate(_ route: RailRoute) -> RailRoute {
            if let result = decorated[route] { return result }
            var result = MetroPalette.applying(palette, to: route)
            if enrichWiki, let id = WikiMetroColours.identity(for: result), let record = wiki[id] {
                result = record.applying(to: result)
            }
            decorated[route] = result
            return result
        }
        for key in tiles.keys.sorted(by: { $0.path < $1.path }) {
            guard let features = tiles[key], !Task.isCancelled else { continue }
            for (id, routes) in features.memberships { memberships[id, default: []].append(contentsOf: routes) }
            for line in features.lines where lineIDs.insert(line.id).inserted {
                lines.append(line)
            }
            for station in features.stations {
                if key.layer != .metroStations && (!key.layer.isMetro || station.tags["atlas:routeStop"] == "yes")
                    && rawBounds.contains(where: { $0.contains(station.coordinate) }) { continue }
                if let index = stationIndices[station.id] {
                    stations[index].tags = StationInterchangeIndex.mergedEvidenceTags(
                        existing: stations[index], incoming: station)
                    stations[index].routes = (stations[index].routes ?? []) + (station.routes ?? [])
                } else {
                    stationIndices[station.id] = stations.count
                    stations.append(station)
                }
            }
        }
        var usesPreview = false
        if let preview {
            let live = Set(lines.flatMap { ($0.routes ?? []).map(\.visibilityKey) })
            let missing = preview.lines.filter { ($0.routes ?? []).allSatisfy { !live.contains($0.visibilityKey) } }
            usesPreview = !missing.isEmpty
            lines += missing
            stations += preview.stations.filter {
                stationIndices[$0.id] == nil && ($0.routes ?? []).allSatisfy { !live.contains($0.visibilityKey) }
            }
        }
        var raw = RailTileFeatures()
        raw.lines = lines; raw.stations = stations
        raw.memberships = memberships
        var ledger = ledger
        func cancelled() -> RailAssembly {
            RailAssembly(features: RailTileFeatures(), ledger: ledger, usesPreview: false)
        }
        guard !Task.isCancelled else { return cancelled() }
        raw = ledger.apply(raw)
        guard !Task.isCancelled else { return cancelled() }
        raw = BundledMetroPalette.identify(raw)
        guard !Task.isCancelled else { return cancelled() }
        var unified = MetroIdentity.unify(lines: raw.lines, stations: raw.stations)
        guard !Task.isCancelled else { return cancelled() }
        // Record inferred route membership so it survives a later partial tile.
        _ = ledger.apply(unified)
        guard !Task.isCancelled else { return cancelled() }
        // The ledger stores source identities, never optional enrichment. This
        // lets turning Wikipedia off restore the source colour immediately.
        for index in unified.lines.indices { unified.lines[index].routes = unified.lines[index].routes?.map(decorate) }
        for index in unified.stations.indices { unified.stations[index].routes = unified.stations[index].routes?.map(decorate) }
        return RailAssembly(features: MetroIdentity.unifyColours(unified), ledger: ledger, usesPreview: usesPreview)
    }
}

extension MapBounds {
    public func contains(_ point: Coordinate) -> Bool {
        point.latitude >= south && point.latitude <= north && point.longitude >= west && point.longitude <= east
    }
    public func intersects(_ other: MapBounds) -> Bool {
        south <= other.north && north >= other.south && west <= other.east && east >= other.west
    }
}
