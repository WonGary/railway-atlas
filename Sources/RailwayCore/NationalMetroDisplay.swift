import Foundation

/// Overview geometry never enters the detail identity ledger or pretends to be
/// a complete spatial tile. Replace only rectangles with complete detail data.
public enum NationalMetroDisplay {
    public static func merging(_ overview: NationalMetroSnapshot?, into detail: RailTileFeatures,
                               detailCoverage: [MapBounds], zoom: Double,
                               palette: [String: MetroPaletteRecord] = [:],
                               wiki: [String: WikiMetroColour] = [:],
                               enrichWiki: Bool = true) -> RailTileFeatures {
        guard let overview else { return detail }
        var result = detail
        let coverage = detailCoverage
        let detailGeometry = coverage.isEmpty ? nil : DetailGeometry(detail.lines)
        var decorated: [RailRoute: RailRoute] = [:]
        func decorate(_ route: RailRoute) -> RailRoute {
            if let value = decorated[route] { return value }
            var value = MetroPalette.applying(palette, to: route)
            if enrichWiki, let id = WikiMetroColours.identity(for: value), let colour = wiki[id] {
                value = colour.applying(to: value)
            }
            decorated[route] = value
            return value
        }
        for sourceLine in overview.lines {
            var original = sourceLine
            original.routes = original.routes?.map(decorate)
            let bounds = MapBounds(points: original.coordinates)
            // A complete *old* tile can still lack a new line or extension.
            // Replace only geometry actually represented by the same route.
            let overlaps = coverage.filter {
                $0.intersects(bounds) && detailGeometry?.covers(original, inside: $0) == true
            }
            if !overlaps.isEmpty {
                var country = original
                country.tags["atlas:overviewLOD"] = "country"
                result.lines.append(country)
            }
            var parts = [original.coordinates]
            for box in overlaps {
                parts = parts.flatMap { outside($0, bounds: box) }
            }
            for (index, coordinates) in parts.enumerated() {
                var line = original
                if !overlaps.isEmpty {
                    line.id += "/clip/\(index)"
                    line.tags["atlas:overviewLOD"] = "detail"
                }
                line.coordinates = coordinates
                result.lines.append(line)
            }
        }
        return result
    }

    private struct DetailGeometry {
        struct Segment {
            let a: Coordinate
            let b: Coordinate
            let keys: Set<String>
        }
        let segments: [Segment]
        let index: RailSpatialIndex
        // The overview has a 50m simplification tolerance. This margin permits
        // that approximation while requiring actual detail along the whole part.
        static let tolerance = 60.0

        init(_ lines: [RailLine]) {
            var segments: [Segment] = []
            for line in lines where line.tags["atlas:nationalOverview"] != "yes" {
                let keys = Set((line.routes ?? []).flatMap { [$0.id, $0.visibilityKey] })
                guard !keys.isEmpty else { continue }
                segments += zip(line.coordinates, line.coordinates.dropFirst()).map {
                    Segment(a: $0, b: $1, keys: keys)
                }
            }
            self.segments = segments
            index = RailSpatialIndex(bounds: segments.map { MapBounds(points: [$0.a, $0.b]) })
        }

        func covers(_ line: RailLine, inside box: MapBounds) -> Bool {
            let keys = Set((line.routes ?? []).flatMap { [$0.id, $0.visibilityKey] })
            guard !keys.isEmpty else { return false }
            let parts = RailGeometryClip.segments(line.coordinates, inside: box)
            guard !parts.isEmpty else { return false }
            for part in parts {
                for (a, b) in zip(part, part.dropFirst()) {
                    let metresPerLon = 111_320 * cos((a.latitude + b.latitude) * .pi / 360)
                    let distance = hypot((b.longitude - a.longitude) * metresPerLon, (b.latitude - a.latitude) * 111_320)
                    let steps = max(1, Int(ceil(distance / Self.tolerance)))
                    // Bound pathological/corrupt long parts; retaining overview
                    // is safer than spending unbounded time proving coverage.
                    guard steps <= 10_000 else { return false }
                    for step in 0...steps {
                        let t = Double(step) / Double(steps)
                        let point = Coordinate(a.latitude + (b.latitude - a.latitude) * t,
                                               a.longitude + (b.longitude - a.longitude) * t)
                        guard covered(point, keys: keys) else { return false }
                    }
                }
            }
            return true
        }

        private func covered(_ point: Coordinate, keys: Set<String>) -> Bool {
            let xScale = max(1, 111_320 * cos(point.latitude * .pi / 180))
            let dy = Self.tolerance / 111_320, dx = Self.tolerance / xScale
            let candidates = index.query(MapBounds(south: point.latitude - dy, west: point.longitude - dx,
                                                   north: point.latitude + dy, east: point.longitude + dx))
            for candidate in candidates {
                let segment = segments[candidate]
                guard !segment.keys.isDisjoint(with: keys) else { continue }
                let ax = (segment.a.longitude - point.longitude) * xScale
                let ay = (segment.a.latitude - point.latitude) * 111_320
                let bx = (segment.b.longitude - point.longitude) * xScale
                let by = (segment.b.latitude - point.latitude) * 111_320
                let vx = bx - ax, vy = by - ay, squared = vx * vx + vy * vy
                let t = squared == 0 ? 0 : min(1, max(0, -(ax * vx + ay * vy) / squared))
                if hypot(ax + t * vx, ay + t * vy) <= Self.tolerance { return true }
            }
            return false
        }
    }

    /// Complement of rectangle clipping. Preserve exit/re-entry gaps and the
    /// exact edge point shared with the detail tile; never bridge the removed area.
    static func outside(_ coordinates: [Coordinate], bounds: MapBounds) -> [[Coordinate]] {
        guard coordinates.count > 1 else { return [] }
        var output: [[Coordinate]] = [], part: [Coordinate] = []
        func finish() {
            if part.count > 1 { output.append(part) }
            part = []
        }
        func append(_ a: Coordinate, _ b: Coordinate) {
            guard a != b else { return }
            if part.last != a { finish(); part = [a] }
            part.append(b)
        }
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let clipped = RailGeometryClip.segments([a, b], inside: bounds)
            guard let inside = clipped.first, let entry = inside.first, let exit = inside.last else {
                append(a, b)
                continue
            }
            if a != entry { append(a, entry) }
            finish()
            if b != exit { append(exit, b) }
        }
        finish()
        return output
    }
}
