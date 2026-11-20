import Foundation

/// ODbL OSM extracts provide real route membership when the query service is
/// slow. They are labelled snapshots, never presented as a successful update.
public enum BundledMetroSnapshots {
    private struct Pack: Sendable {
        let features: RailTileFeatures
        let bounds: MapBounds
        let lineIndex: RailSpatialIndex
        let stationIndex: RailSpatialIndex
    }
    private static let packs: [Pack] = ["qingdao", "jinan", "tokyo", "beijing", "hongkong", "macao"].compactMap { city in
        guard let url = Bundle.main.url(forResource: "metro-snapshot-\(city)", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "metro-snapshot-\(city)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = document["atlas"] as? [String: Any],
              let box = metadata["bounds"] as? [Double], box.count == 4,
              let source = metadata["source"] as? String,
              var features = try? MetroRouteDecoder.decode(data) else { return nil }
        let timestamp = metadata["latestObjectTimestamp"] as? String ?? ""
        func tags(_ sourceTags: [String: String]) -> [String: String] {
            var tags = sourceTags
            tags["atlas:source"] = "OpenStreetMap · 内置线路快照 · \(city)"
            tags["atlas:snapshotURL"] = source
            tags["atlas:snapshotDate"] = "2026-11-05"
            tags["atlas:latestObjectTimestamp"] = timestamp
            return tags
        }
        for i in features.lines.indices { features.lines[i].tags = tags(features.lines[i].tags) }
        for i in features.stations.indices { features.stations[i].tags = tags(features.stations[i].tags) }
        return Pack(features: features, bounds: MapBounds(south: box[0], west: box[1], north: box[2], east: box[3]),
                    lineIndex: RailSpatialIndex(bounds: features.lines.map { MapBounds(points: $0.coordinates) }),
                    stationIndex: RailSpatialIndex(bounds: features.stations.map { MapBounds(points: [$0.coordinate]) }))
    }

    public static func features(for key: RailTileKey) -> RailTileFeatures? {
        // Never masquerade as a complete station-detail tile: Tokyo's extract
        // has a smaller boundary than some Z10 cells.
        guard key.layer == .metroNetwork else { return nil }
        let bounds = key.tile.bounds
        var result = RailTileFeatures()
        for pack in packs where pack.bounds.intersects(bounds) {
            for (id, routes) in pack.features.memberships { result.memberships[id, default: []].append(contentsOf: routes) }
            for i in pack.lineIndex.query(bounds) {
                let original = pack.features.lines[i]
                for (part, coordinates) in RailGeometryClip.segments(original.coordinates, inside: bounds).enumerated() {
                    var line = original
                    line.id = "snapshot/\(key.tile.path)/\(original.id)/\(part)"
                    line.coordinates = coordinates
                    result.lines.append(line)
                }
            }
            result.stations += pack.stationIndex.query(bounds).map { pack.features.stations[$0] }
        }
        return result.lines.isEmpty && result.stations.isEmpty ? nil : result
    }
}
