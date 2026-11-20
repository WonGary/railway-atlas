import Foundation

/// OSM and the cache always use WGS84. Apply this only at the MapKit boundary.
public enum MapAlignment: String, CaseIterable, Identifiable, Sendable {
    // Keep the persisted default key so existing GCJ users receive the fix.
    case mainlandGCJ, mainlandOnlyGCJ, wgs84
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mainlandGCJ: "GCJ-02 · 大陆及港澳"
        case .mainlandOnlyGCJ: "GCJ-02 · 仅大陆"
        case .wgs84: "原始坐标 · WGS84"
        }
    }
    private var includesSAR: Bool { self == .mainlandGCJ }
    private func needsOffset(_ point: Coordinate) -> Bool {
        self != .wgs84 && ChinaCoordinateMask.contains(point, includingSAR: includesSAR)
    }

    public func display(_ point: Coordinate) -> Coordinate {
        guard needsOffset(point) else { return point }
        return Self.offset(point)
    }

    public func original(_ point: Coordinate, near reference: Coordinate? = nil) -> Coordinate {
        guard self != .wgs84,
              (0...56).contains(point.latitude), (72...136).contains(point.longitude) else { return point }
        var estimate = point
        for _ in 0..<6 {
            let projected = Self.offset(estimate)
            estimate.latitude -= projected.latitude - point.latitude
            estimate.longitude -= projected.longitude - point.longitude
        }
        // Classify the unshifted candidate, not the display coordinate. Near
        // a border both coordinate domains can overlap; the camera's previous
        // WGS84 position resolves that ambiguity. Hit-testing uses display space.
        guard needsOffset(estimate) else { return point }
        if !needsOffset(point), let reference,
           !needsOffset(reference) { return point }
        return estimate
    }

    /// A GCJ/WGS boundary is a discontinuity. Split there instead of drawing a
    /// false diagonal between differently projected vertices. Even a segment
    /// with both endpoints on the same side can cross a narrow border twice.
    public func displaySegments(_ points: [Coordinate]) -> [[Coordinate]] {
        guard points.count > 1 else { return [] }
        guard self != .wgs84 else { return [points] }
        var result: [[Coordinate]] = [], current: [Coordinate] = []
        var previousDomain: Bool?
        for (a, b) in zip(points, points.dropFirst()) {
            let cuts = [0.0] + ChinaCoordinateMask.crossings(a, b, includingSAR: includesSAR) + [1.0]
            for (lo, hi) in zip(cuts, cuts.dropFirst()) where hi - lo > 1e-10 {
                func point(_ t: Double) -> Coordinate {
                    Coordinate(a.latitude + (b.latitude - a.latitude) * t,
                               a.longitude + (b.longitude - a.longitude) * t)
                }
                let shifted = needsOffset(point((lo + hi) / 2))
                let start = shifted ? Self.offset(point(lo)) : point(lo)
                let end = shifted ? Self.offset(point(hi)) : point(hi)
                if previousDomain != shifted {
                    if current.count > 1 { result.append(current) }
                    current = [start]
                } else if current.last != start { current.append(start) }
                if current.last != end { current.append(end) }
                previousDomain = shifted
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    /// Mathematical projection only. Call `display` for the selected mask;
    /// this unmasked form is also used to compare basemap coordinate domains.
    public static func gcj02Projection(_ point: Coordinate) -> Coordinate { offset(point) }

    private static func offset(_ point: Coordinate) -> Coordinate {
        let x = point.longitude - 105, y = point.latitude - 35
        var lat = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        var lon = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        lat += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        lat += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        lat += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        lon += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        lon += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        lon += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        let a = 6378245.0, ee = 0.00669342162296594323
        let radians = point.latitude / 180 * .pi
        let magic = 1 - ee * pow(sin(radians), 2), root = sqrt(magic)
        return Coordinate(point.latitude + lat * 180 / ((a * (1 - ee) / (magic * root)) * .pi),
                          point.longitude + lon * 180 / (a / root * cos(radians) * .pi))
    }

    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat = (a.latitude + b.latitude) / 2 * .pi / 180
        return hypot((a.latitude - b.latitude) * 111_195,
                     (a.longitude - b.longitude) * 111_195 * cos(lat))
    }
}

/// Immutable OSM boundary index. The China-region Apple basemap observed in QA
/// uses GCJ across the mainland, Hong Kong and Macao. The optional mainland-only
/// policy retains the administrative exclusions for other basemap deployments.
/// Whole-degree interior cells are O(1). Only boundary cells use exact polygons.
/// Geometry is reused by the renderer across pan/zoom and never fetched per point.
enum ChinaCoordinateMask {
    private struct Document: Decodable {
        let include: [[[[Double]]]]
        let exclude: [[[[Double]]]]
    }
    private struct Edge: Sendable {
        let ax: Double, ay: Double, bx: Double, by: Double
    }
    private struct Ring: Sendable {
        let edges: [Int: [Edge]]
        let segments: [Edge]
        let bounds: MapBounds
        init(_ points: [[Double]]) {
            bounds = MapBounds(south: points.map { $0[1] }.min() ?? 0,
                               west: points.map { $0[0] }.min() ?? 0,
                               north: points.map { $0[1] }.max() ?? 0,
                               east: points.map { $0[0] }.max() ?? 0)
            var buckets: [Int: [Edge]] = [:]
            var segments: [Edge] = []
            for (a, b) in zip(points, points.dropFirst() + points.prefix(1)) where a != b {
                let edge = Edge(ax: a[0], ay: a[1], bx: b[0], by: b[1])
                segments.append(edge)
                guard a[1] != b[1] else { continue }
                for bucket in Int(floor(min(a[1], b[1]) * 20))...Int(floor(max(a[1], b[1]) * 20)) {
                    buckets[bucket, default: []].append(edge)
                }
            }
            edges = buckets
            self.segments = segments
        }
        func contains(_ p: Coordinate) -> Bool {
            guard p.latitude >= bounds.south, p.latitude <= bounds.north,
                  p.longitude >= bounds.west, p.longitude <= bounds.east else { return false }
            var inside = false
            for e in edges[Int(floor(p.latitude * 20)), default: []] {
                if (e.ay > p.latitude) != (e.by > p.latitude),
                   p.longitude < (e.bx - e.ax) * (p.latitude - e.ay) / (e.by - e.ay) + e.ax {
                    inside.toggle()
                }
            }
            return inside
        }
    }
    private struct Index: Sendable {
        let included: [[Ring]]
        let excluded: [[Ring]]
        let segments: [Edge]
        let edgeCells: [Int: [Int]]
        let interior: [Int: Bool]
        private let cells = CellCache()
        init(_ document: Document) {
            included = document.include.map { $0.map(Ring.init) }
            excluded = document.exclude.map { $0.map(Ring.init) }
            segments = (included + excluded).flatMap { $0.flatMap(\.segments) }
            var cells: [Int: [Int]] = [:]
            var boundaryCells = Set<Int>()
            for (id, edge) in segments.enumerated() {
                for y in Int(floor(min(edge.ay, edge.by)))...Int(floor(max(edge.ay, edge.by))) {
                    for x in Int(floor(min(edge.ax, edge.bx)))...Int(floor(max(edge.ax, edge.bx))) {
                        boundaryCells.insert(Self.key(x, y))
                    }
                }
                for y in Int(floor(min(edge.ay, edge.by) * 20))...Int(floor(max(edge.ay, edge.by) * 20)) {
                    for x in Int(floor(min(edge.ax, edge.bx) * 20))...Int(floor(max(edge.ax, edge.bx) * 20)) {
                        cells[Self.key(x, y), default: []].append(id)
                    }
                }
            }
            edgeCells = cells
            var interiors: [Int: Bool] = [:]
            for y in 0...55 {
                for x in 72...135 where !boundaryCells.contains(Self.key(x, y)) {
                    let p = Coordinate(Double(y) + 0.5, Double(x) + 0.5)
                    interiors[Self.key(x, y)] = Self.inside(p, included) && !Self.inside(p, excluded)
                }
            }
            interior = interiors
        }
        static func key(_ x: Int, _ y: Int) -> Int { y * 65536 + x }
        static func inside(_ p: Coordinate, _ polygons: [[Ring]]) -> Bool {
            polygons.contains { $0.first?.contains(p) == true && !$0.dropFirst().contains { $0.contains(p) } }
        }
        func contains(_ p: Coordinate) -> Bool {
            if let result = interior[Self.key(Int(floor(p.longitude)), Int(floor(p.latitude)))] { return result }
            let x = Int(floor(p.longitude * 256)), y = Int(floor(p.latitude * 256))
            let key = Self.key(x, y)
            let cell: Cell
            if let saved = cells.read(key) { cell = saved }
            else {
                // An off-centre anchor avoids the common case of an exact
                // integer-coordinate boundary going through a cell centre.
                let anchor = Coordinate((Double(y) + 0.61803398875) / 256, (Double(x) + 0.38196601125) / 256)
                let west = Double(x) / 256, east = Double(x + 1) / 256
                let south = Double(y) / 256, north = Double(y + 1) / 256
                var boundary = false
                for cy in Int(floor(south * 20))...Int(floor(north * 20)) {
                    for cx in Int(floor(west * 20))...Int(floor(east * 20)) {
                        if edgeCells[Self.key(cx, cy), default: []].contains(where: { id in
                            let e = segments[id]
                            return max(e.ax, e.bx) >= west && min(e.ax, e.bx) <= east
                                && max(e.ay, e.by) >= south && min(e.ay, e.by) <= north
                        }) { boundary = true }
                    }
                }
                cell = Cell(inside: boundary ? false : Self.inside(anchor, included),
                            excluded: boundary ? false : Self.inside(anchor, excluded), boundary: boundary)
                cells.save(cell, key)
            }
            // Never approximate a border cell. Polygon union semantics also
            // preserve overlapping administrative enclaves in the OSM source.
            return cell.boundary ? Self.inside(p, included) && !Self.inside(p, excluded)
                : cell.inside && !cell.excluded
        }
    }
    private struct Cell: Sendable { let inside: Bool; let excluded: Bool; let boundary: Bool }
    private final class CellCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Cell] = [:]
        func read(_ key: Int) -> Cell? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        func save(_ value: Cell, _ key: Int) {
            lock.lock(); defer { lock.unlock() }
            if values.count >= 20_000 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }
    private static let document: Document? = {
        guard let url = Bundle.main.url(forResource: "mainland-osm-mask", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "mainland-osm-mask", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return document
    }()
    private static let mainlandIndex: Index? = document.map(Index.init)
    private static let chinaBasemapIndex: Index? = document.map {
        Index(Document(include: $0.include + $0.exclude, exclude: []))
    }
    private static func index(includingSAR: Bool) -> Index? { includingSAR ? chinaBasemapIndex : mainlandIndex }
    static func contains(_ p: Coordinate, includingSAR: Bool) -> Bool {
        guard p.latitude.isFinite, p.longitude.isFinite,
              (0..<56).contains(p.latitude), (72..<136).contains(p.longitude) else { return false }
        return index(includingSAR: includingSAR)?.contains(p) ?? false
    }
    static func crossings(_ a: Coordinate, _ b: Coordinate, includingSAR: Bool) -> [Double] {
        let west = max(72, min(a.longitude, b.longitude)), east = min(135.9999, max(a.longitude, b.longitude))
        let south = max(0, min(a.latitude, b.latitude)), north = min(55.9999, max(a.latitude, b.latitude))
        guard west <= east, south <= north, let index = index(includingSAR: includingSAR) else { return [] }
        var seen = Set<Int>(), cuts: [Double] = []
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        for y in Int(floor(south * 20))...Int(floor(north * 20)) {
            for x in Int(floor(west * 20))...Int(floor(east * 20)) {
                for id in index.edgeCells[Index.key(x, y), default: []] where seen.insert(id).inserted {
                    let edge = index.segments[id]
                    guard max(edge.ax, edge.bx) >= west, min(edge.ax, edge.bx) <= east,
                          max(edge.ay, edge.by) >= south, min(edge.ay, edge.by) <= north else { continue }
                    let ex = edge.bx - edge.ax, ey = edge.by - edge.ay
                    let denominator = dx * ey - dy * ex
                    guard abs(denominator) > 1e-18 else { continue }
                    let qx = edge.ax - a.longitude, qy = edge.ay - a.latitude
                    let t = (qx * ey - qy * ex) / denominator
                    let u = (qx * dy - qy * dx) / denominator
                    if t > 1e-9, t < 1 - 1e-9, u >= 0, u <= 1 { cuts.append(t) }
                }
            }
        }
        return cuts.sorted().reduce(into: []) { result, cut in
            if result.last.map({ abs($0 - cut) > 1e-9 }) ?? true { result.append(cut) }
        }
    }
}
