import Foundation

/// Relation coverage follows the whole viewport, including neighbouring cities.
/// These are spatial cells, not city identities or a nearest-city selection.
public struct MetroViewport: Sendable {
    public static let minimumZoom = 8
    public static let detailZoom = 10
    public static let bufferFraction = 0.2
    public static let maximumCells = 64

    public let bounds: MapBounds
    public let networkKeys: [RailTileKey]
    public let stationKeys: [RailTileKey]

    public init(bounds visible: MapBounds, zoom: Int, stations: Bool = true) {
        bounds = visible.isValid ? visible.expanded(by: Self.bufferFraction) : visible
        guard visible.isValid, zoom >= Self.minimumZoom else {
            networkKeys = []; stationKeys = []
            return
        }
        // Regional queries use Z8/Z9 cells, not hundreds of Z10 requests.
        // Never enlarge the query to a country-wide cell to satisfy the cap.
        var level = min(Self.detailZoom, zoom)
        var cells = RailTile.covering(bounds, zoom: level)
        while cells.isEmpty && level > Self.minimumZoom {
            level -= 1
            cells = RailTile.covering(bounds, zoom: level)
        }
        let center = visible.center
        cells.sort {
            let aVisible = $0.bounds.intersects(visible), bVisible = $1.bounds.intersects(visible)
            if aVisible != bVisible { return aVisible }
            let a = $0.bounds.center, b = $1.bounds.center
            let da = hypot(a.latitude - center.latitude, a.longitude - center.longitude)
            let db = hypot(b.latitude - center.latitude, b.longitude - center.longitude)
            return da == db ? $0.path < $1.path : da < db
        }
        guard cells.count <= Self.maximumCells else {
            networkKeys = []; stationKeys = []
            return
        }
        networkKeys = cells.map { RailTileKey(layer: .metroNetwork, tile: $0) }
        // Regional line coverage does not require city-detail station queries.
        stationKeys = stations && zoom >= Self.detailZoom && level == Self.detailZoom
            ? cells.map { RailTileKey(layer: .metroStations, tile: $0) } : []
    }

    /// Bounded subdivision also reuses old Z10 caches at regional scales.
    static func children(of tile: RailTile) -> [RailTile] {
        guard tile.isValid, (minimumZoom..<detailZoom).contains(tile.z) else { return [] }
        return (0...1).flatMap { dx in (0...1).map { dy in
            RailTile(z: tile.z + 1, x: tile.x * 2 + dx, y: tile.y * 2 + dy)
        } }
    }
}
