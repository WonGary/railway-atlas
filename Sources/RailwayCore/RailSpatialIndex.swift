import Foundation

/// Immutable bounding-volume tree. Build once when data changes; camera
/// movement visits intersecting branches instead of scanning the loaded world.
public struct RailSpatialIndex: Sendable {
    private struct Entry: Sendable { let index: Int; let bounds: MapBounds }
    private struct Node: Sendable {
        let bounds: MapBounds
        let range: Range<Int>
        let left: Int
        let right: Int
    }
    private var entries: [Entry] = []
    private var nodes: [Node] = []

    public init(bounds: [MapBounds]) {
        entries = bounds.enumerated().map { Entry(index: $0.offset, bounds: $0.element) }
        guard !entries.isEmpty else { return }
        nodes.reserveCapacity(bounds.count / 4)
        _ = build(0..<entries.count)
    }

    private mutating func build(_ range: Range<Int>) -> Int {
        var bounds = entries[range.lowerBound].bounds
        for i in range.dropFirst() { bounds = bounds.union(entries[i].bounds) }
        let position = nodes.count
        nodes.append(Node(bounds: bounds, range: range, left: -1, right: -1))
        guard range.count > 12 else { return position }
        let longitude = bounds.east - bounds.west > bounds.north - bounds.south
        let middle = range.lowerBound + range.count / 2
        // Median partition avoids repeatedly sorting the complete subtree.
        func value(_ entry: Entry) -> Double {
            longitude ? entry.bounds.west + entry.bounds.east : entry.bounds.south + entry.bounds.north
        }
        var lo = range.lowerBound, hi = range.upperBound - 1
        while lo < hi {
            let pivot = value(entries[(lo + hi) / 2])
            var i = lo, j = hi
            while i <= j {
                while value(entries[i]) < pivot { i += 1 }
                while value(entries[j]) > pivot { j -= 1 }
                if i <= j { entries.swapAt(i, j); i += 1; j -= 1 }
            }
            if middle <= j { hi = j }
            else if middle >= i { lo = i }
            else { break }
        }
        let left = build(range.lowerBound..<middle), right = build(middle..<range.upperBound)
        nodes[position] = Node(bounds: bounds, range: range, left: left, right: right)
        return position
    }

    public func query(_ bounds: MapBounds) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var pending = [0], result: [Int] = []
        while let position = pending.popLast() {
            let node = nodes[position]
            guard node.bounds.intersects(bounds) else { continue }
            if node.left >= 0 { pending.append(node.left); pending.append(node.right) }
            else {
                for entry in entries[node.range] where entry.bounds.intersects(bounds) { result.append(entry.index) }
            }
        }
        // Preserve source ordering for deterministic colour/overlap handling.
        return result.sorted()
    }
}

extension MapBounds {
    public init(points: [Coordinate]) {
        let first = points.first ?? Coordinate(0, 0)
        self.init(south: first.latitude, west: first.longitude, north: first.latitude, east: first.longitude)
        for point in points.dropFirst() {
            south = min(south, point.latitude); north = max(north, point.latitude)
            west = min(west, point.longitude); east = max(east, point.longitude)
        }
    }
    public func union(_ other: Self) -> Self {
        Self(south: min(south, other.south), west: min(west, other.west),
             north: max(north, other.north), east: max(east, other.east))
    }
    public func contains(_ other: Self) -> Bool {
        south <= other.south && west <= other.west && north >= other.north && east >= other.east
    }
    /// Fraction of the visible span on each edge, e.g. 20% gives a 1.4× box.
    public func expanded(by fraction: Double) -> Self {
        let lat = (north - south) * fraction, lon = (east - west) * fraction
        return Self(south: max(-85, south - lat), west: max(-180, west - lon),
                    north: min(85, north + lat), east: min(180, east + lon))
    }
}

public enum RailGeometryClip {
    /// Liang–Barsky clipping retains crossings with both endpoints outside
    /// and splits exit/re-entry gaps. It never joins disjoint pieces.
    public static func segments(_ points: [Coordinate], inside bounds: MapBounds) -> [[Coordinate]] {
        guard points.count > 1 else { return [] }
        var result: [[Coordinate]] = [], part: [Coordinate] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
            var lower = 0.0, upper = 1.0
            var accepted = true
            for (p, q) in [(-dx, a.longitude - bounds.west), (dx, bounds.east - a.longitude),
                           (-dy, a.latitude - bounds.south), (dy, bounds.north - a.latitude)] {
                if p == 0 { if q < 0 { accepted = false; break } }
                else {
                    let t = q / p
                    if p < 0 { lower = max(lower, t) } else { upper = min(upper, t) }
                    if lower > upper { accepted = false; break }
                }
            }
            if !accepted {
                if part.count > 1 { result.append(part) }
                part = []; continue
            }
            func point(_ t: Double) -> Coordinate {
                t == 0 ? a : t == 1 ? b : Coordinate(a.latitude + t * dy, a.longitude + t * dx)
            }
            let start = point(lower), end = point(upper)
            if part.last != start {
                if part.count > 1 { result.append(part) }
                part = [start]
            }
            if part.last != end { part.append(end) }
            if upper < 1 {
                if part.count > 1 { result.append(part) }
                part = []
            }
        }
        if part.count > 1 { result.append(part) }
        return result
    }
}
