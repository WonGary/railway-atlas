import Foundation
import RailwayCore

enum SpatialChecks {
    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        let box = MapBounds(south: -1, west: -1, north: 1, east: 1)
        let expanded = box.expanded(by: 0.2)
        try check(abs(expanded.east - 1.4) < 1e-10 && expanded.contains(box),
                  "20 percent buffer extends each viewport edge")
        let interior = [Coordinate(0, 0), Coordinate(0.5, 0.5)]
        try check(RailGeometryClip.segments(interior, inside: box) == [interior],
                  "clipping preserves all original interior vertices")
        try check(RailGeometryClip.segments([Coordinate(0, -3), Coordinate(0, 3)], inside: box)
                  == [[Coordinate(0, -1), Coordinate(0, 1)]],
                  "crossing survives when both endpoints are outside")
        let split = RailGeometryClip.segments([Coordinate(0, 0), Coordinate(0, 2),
            Coordinate(2, 2), Coordinate(0.5, 0)], inside: box)
        try check(split.count == 2 && split[0].last == Coordinate(0, 1) && split[1].last == Coordinate(0.5, 0),
                  "exit and reentry remain separate paths without a false bridge")
        try check(RailGeometryClip.segments([Coordinate(2, 0), Coordinate(2, 1)], inside: box).isEmpty,
                  "parallel outside segment is excluded")
        try check(RailGeometryClip.segments([Coordinate(1, -2), Coordinate(1, 2)], inside: box)
                  == [[Coordinate(1, -1), Coordinate(1, 1)]],
                  "line along a viewport boundary is retained")
        try check(RailSpatialIndex(bounds: []).query(box).isEmpty, "empty spatial index is safe")
        let bounds = (0..<7000).map { i -> MapBounds in
            let x = Double((i * 73) % 1000) / 10 - 50, y = Double((i * 151) % 700) / 10 - 35
            return MapBounds(south: y, west: x, north: y + Double(i % 13) / 7, east: x + Double(i % 17) / 5)
        }
        let index = RailSpatialIndex(bounds: bounds)
        let matches = (0..<100).allSatisfy { i -> Bool in
            let x = Double(i - 50), y = Double(i % 60 - 30)
            let query = MapBounds(south: y, west: x, north: y + 3, east: x + 4)
            return index.query(query) == bounds.indices.filter { bounds[$0].intersects(query) }
        }
        try check(matches, "spatial tree agrees with 100 brute-force viewport queries over 7000 bounds")
        let identical = RailSpatialIndex(bounds: Array(repeating: box, count: 300))
        try check(identical.query(box) == Array(0..<300), "equal bounds partition safely with stable source order")
        print("\(count) viewport geometry checks passed.")
    }
}
