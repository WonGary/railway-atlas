import Foundation
import RailwayCore

enum BorderChecks {
    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: \(label)") }
            count += 1; print("PASS \(label)")
        }
        let mainland = [
            ("深圳罗湖", Coordinate(22.5315, 114.1138)),
            ("福田口岸", Coordinate(22.5185, 114.0658)),
            ("珠海拱北", Coordinate(22.2179, 113.5501)),
            ("横琴", Coordinate(22.1378, 113.543))
        ]
        let outside = [
            ("香港罗湖", Coordinate(22.5284, 114.1133)),
            ("落马洲", Coordinate(22.5145, 114.0655)),
            ("香港西九龙", Coordinate(22.3045, 114.1655)),
            ("澳门关闸", Coordinate(22.2144, 113.5493)),
            ("澳门路氹", Coordinate(22.135, 113.555))
        ]
        let alignment = MapAlignment.mainlandOnlyGCJ
        let cold = Date()
        _ = alignment.display(mainland[0].1)
        let startup = Date().timeIntervalSince(cold)
        for (name, p) in mainland {
            let shown = alignment.display(p)
            try check(MapAlignment.distance(p, shown) > 400, "\(name) belongs to mainland coordinate domain")
            try check(MapAlignment.distance(p, alignment.original(shown, near: p)) < 0.01,
                      "\(name) inverse checks original coordinate, <1 cm round trip")
        }
        for (name, p) in outside {
            try check(alignment.display(p) == p && alignment.original(p, near: p) == p,
                      "\(name) remains WGS84 in both directions")
        }
        for index in 0..<2 {
            let a = mainland[index].1, b = outside[index].1
            let parts = alignment.displaySegments([a, b])
            try check(parts.count == 2 && parts.first?.first == alignment.display(a) && parts.last?.last == b,
                      "border crossing \(index) splits domains without a false diagonal")
            let reverse = alignment.displaySegments([b, a])
            try check(reverse.count == 2 && reverse.first?.first == b && reverse.last?.last == alignment.display(a),
                      "border crossing \(index) is direction-independent")
            try check(alignment.displaySegments([a, b, a]).count == 3,
                      "leaving and re-entering mainland retains three separate pieces")
        }
        try check(MapAlignment.wgs84.displaySegments(mainland.map(\.1)) == [mainland.map(\.1)],
                  "raw WGS84 mode never splits or shifts data")
        let europe = [Coordinate(48.8566, 2.3522), Coordinate(52.52, 13.405)]
        try check(alignment.displaySegments(europe) == [europe], "European lines bypass China geometry")
        let inclusive = MapAlignment.mainlandGCJ
        for (name, point) in mainland + outside {
            let shown = inclusive.display(point)
            try check(MapAlignment.distance(point, shown) > 400
                      && MapAlignment.distance(point, inclusive.original(shown, near: point)) < 0.01,
                      "\(name) follows the observed China-region Apple basemap, reversible within 1 cm")
        }
        for (a, b) in [
            (mainland[0].1, outside[0].1), (mainland[1].1, outside[1].1),
            (mainland[2].1, outside[3].1), (mainland[3].1, outside[4].1)
        ] {
            for points in [[a, b], [b, a], [a, b, a]] {
                let parts = inclusive.displaySegments(points)
                try check(parts.count == 1 && parts.first?.first == inclusive.display(points[0])
                          && parts.first?.last == inclusive.display(points.last!),
                          "China-region basemap keeps mainland/SAR crossings continuous in both directions")
            }
        }
        for p in [Coordinate(25.03, 121.56), Coordinate(21.03, 105.85), Coordinate(27.70, 85.32)] {
            try check(inclusive.display(p) == p,
                      "inclusive policy respects actual polygon coverage \(p.latitude), \(p.longitude)")
        }
        // A deterministic dense boundary workload. No timing threshold in tests:
        // report measurements for release QA without flaky machine-speed gates.
        let start = Date()
        var shifted = 0
        for i in 0..<100_000 {
            let p = Coordinate(22.50 + Double(i % 500) * 0.0001, 114.03 + Double(i / 500) * 0.0005)
            if alignment.display(p) != p { shifted += 1 }
        }
        try check(shifted == 54_324, "indexed boundary checks agree with the full-polygon 100,000-point baseline")
        let inclusiveStart = Date()
        var inclusiveShifted = 0
        for i in 0..<100_000 {
            let p = Coordinate(22.50 + Double(i % 500) * 0.0001, 114.03 + Double(i / 500) * 0.0005)
            if inclusive.display(p) != p { inclusiveShifted += 1 }
        }
        try check(inclusiveShifted == 100_000, "one consistent coordinate domain covers both sides of Shenzhen/Hong Kong")
        print(String(format: "INCLUSIVE PERFORMANCE: 100,000 points %.3fs.", Date().timeIntervalSince(inclusiveStart)))
        print(String(format: "BORDER PERFORMANCE: index %.3fs; 100,000 near-border points %.3fs; %d shifted.",
                     startup, Date().timeIntervalSince(start), shifted))
        print("\(count) border coordinate checks passed.")
    }
}
