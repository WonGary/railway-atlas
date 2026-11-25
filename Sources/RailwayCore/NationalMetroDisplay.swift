import Foundation

/// The national view keeps its original geometry. At detail zoom each displayed
/// urban track replaces only the stretch of overview it actually represents.
public enum NationalMetroDisplay {
    public static func merging(_ overview: NationalMetroSnapshot?, into detail: RailTileFeatures,
                               palette: [String: MetroPaletteRecord] = [:],
                               wiki: [String: WikiMetroColour] = [:],
                               enrichWiki: Bool = true) -> RailTileFeatures {
        guard let overview else { return detail }
        var result = detail
        let detailGeometry = DetailGeometry(detail.lines)
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
            guard let parts = detailGeometry.uncovered(original) else {
                result.lines.append(original)
                continue
            }
            var country = original
            country.tags["atlas:overviewLOD"] = "country"
            result.lines.append(country)
            for (index, coordinates) in parts.enumerated() {
                var line = original
                line.id += "/clip/\(index)"
                line.tags["atlas:overviewLOD"] = "detail"
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
            let network: RailNetwork
            let category: RailCategory
        }
        let segments: [Segment]
        let index: RailSpatialIndex
        // The source overview was simplified to 50 m.
        static let tolerance = 60.0

        init(_ lines: [RailLine]) {
            var segments: [Segment] = []
            for line in lines where line.tags["atlas:nationalOverview"] != "yes" {
                let facts = RailLineDisplayFacts(line)
                guard facts.urbanTransit, !facts.serviceTrack,
                      (facts.sourceZoom ?? MetroViewport.minimumZoom) >= MetroViewport.minimumZoom else { continue }
                let keys = Set((line.routes ?? []).map(\.id))
                segments += zip(line.coordinates, line.coordinates.dropFirst()).map {
                    Segment(a: $0, b: $1, keys: keys, network: facts.network, category: facts.category)
                }
            }
            self.segments = segments
            index = RailSpatialIndex(bounds: segments.map { MapBounds(points: [$0.a, $0.b]) })
        }

        func expanded(_ box: MapBounds) -> MapBounds {
            let dy = Self.tolerance / 111_320
            let dx = dy / max(0.08, cos(max(abs(box.south), abs(box.north)) * .pi / 180))
            return MapBounds(south: box.south-dy, west: box.west-dx, north: box.north+dy, east: box.east+dx)
        }

        // Project detail onto the overview chord. The perpendicular strip admits
        // simplified bends, but the projected endpoints bound the handoff.
        func uncovered(_ line: RailLine) -> [[Coordinate]]? {
            guard !segments.isEmpty, !index.query(expanded(MapBounds(points: line.coordinates))).isEmpty else { return nil }
            let keys = Set((line.routes ?? []).map(\.id))
            let network = RailNetwork.classify(line.tags), category = line.category
            var changed = false, output: [[Coordinate]] = [], part: [Coordinate] = []
            func finish() { if part.count > 1 { output.append(part) }; part = [] }
            for (a,b) in zip(line.coordinates, line.coordinates.dropFirst()) {
                let scale = 111_320 * cos((a.latitude+b.latitude) * .pi / 360)
                let x = (b.longitude-a.longitude)*scale, y = (b.latitude-a.latitude)*111_320
                let length = hypot(x,y)
                guard length > 0 else { continue }
                let ux = x/length, uy = y/length
                var spans: [(Double, Double)] = []
                for i in index.query(expanded(MapBounds(points: [a,b]))) {
                    let s = segments[i], named = !s.keys.isEmpty
                    guard s.category == category, named ? !keys.isDisjoint(with: s.keys) : network == s.network else { continue }
                    let ax = (s.a.longitude-a.longitude)*scale, ay = (s.a.latitude-a.latitude)*111_320
                    let bx = (s.b.longitude-a.longitude)*scale, by = (s.b.latitude-a.latitude)*111_320
                    let start = ax*ux+ay*uy, end = bx*ux+by*uy, along = end-start
                    guard abs(along) > hypot(bx-ax,by-ay) * (named ? 0.45 : 0.90) else { continue }
                    let cross = ay*ux-ax*uy, slope = (by-ay)*ux-(bx-ax)*uy
                    var lo = 0.0, hi = 1.0
                    if abs(slope) < 1e-8 { if abs(cross) > Self.tolerance { continue } }
                    else {
                        let l = (-Self.tolerance-cross)/slope, h = (Self.tolerance-cross)/slope
                        lo = max(0,min(l,h)); hi = min(1,max(l,h))
                    }
                    guard lo <= hi else { continue }
                    let p = start+lo*along, q = start+hi*along
                    let left = max(0,min(p,q)), right = min(length,max(p,q))
                    if right > left { spans.append((left,right)) }
                }
                func point(_ d: Double) -> Coordinate {
                    if d <= 0 { return a }; if d >= length { return b }
                    return Coordinate(a.latitude+(b.latitude-a.latitude)*d/length,
                                      a.longitude+(b.longitude-a.longitude)*d/length)
                }
                func keep(_ l: Double, _ r: Double) {
                    if part.isEmpty { part.append(point(l)) }; part.append(point(r))
                }
                var cursor = 0.0
                for (l,r) in spans.sorted(by: { $0.0 < $1.0 }) where r > cursor {
                    changed = true
                    if l > cursor + 0.05 { keep(cursor,l) }
                    finish(); cursor = r
                }
                if cursor == 0 || length-cursor > 0.05 { keep(cursor,length) }
            }
            finish()
            return changed ? output : nil
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
