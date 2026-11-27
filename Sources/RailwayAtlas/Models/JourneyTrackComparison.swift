import Foundation
import RailwayCore

enum InspectionInk: String, Sendable {
    case first, second, shared
    var stroke: RailStroke {
        switch self {
        case .first: return RailStroke(color: RailColor("#087cba")!, width: 4.6)
        case .second: return RailStroke(color: RailColor("#c03977")!, width: 4.6, dash: [8, 4])
        case .shared: return RailStroke(color: RailColor("#17805a")!, width: 4.6)
        }
    }
}

struct InspectionLayer: Sendable {
    let ink: InspectionInk
    let parts: [[Coordinate]]
}

struct JourneyTrackComparison: Sendable {
    struct Side: Sendable {
        var shared = [[Coordinate]](), unique = [[Coordinate]]()
        var sharedMetres = 0.0, uniqueMetres = 0.0
    }
    let a, b: Side
    var layers: [InspectionLayer] {
        guard a.sharedMetres + a.uniqueMetres > 0, b.sharedMetres + b.uniqueMetres > 0 else { return [] }
        return [InspectionLayer(ink: .first, parts: a.unique), .init(ink: .second, parts: b.unique),
                .init(ink: .shared, parts: a.shared.isEmpty ? b.shared : a.shared)].filter { !$0.parts.isEmpty }
    }

    // Same grid, midpoint spacing, distance and unsigned heading test as Web/route-inspector.js.
    // Index each edge independently, including across passenger stops and in reverse travel order.
    private static let cell = 300.0, spacing = 90.0, tolerance = 45.0
    private static let cosine = cos(25 * Double.pi / 180), scale = 111_195.0
    private struct Cell: Hashable { let x, y: Int }
    private struct Point { let x, y: Double }
    private struct Edge {
        let start: Point
        let dx, dy, length: Double
    }
    private struct Projection {
        let origin: Coordinate, longitudeScale: Double
        func point(_ c: Coordinate) -> Point {
            let lon = (c.longitude - origin.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            return Point(x: lon * longitudeScale, y: (c.latitude - origin.latitude) * scale)
        }
    }
    private struct Grid {
        let edges: [Cell: [Edge]]
        init(_ parts: [[Coordinate]], projection: Projection) throws {
            var edges = [Cell: [Edge]]()
            for part in parts {
                try Task.checkCancellation()
                for (a, b) in zip(part, part.dropFirst()) {
                    let start = projection.point(a), end = projection.point(b)
                    let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    let edge = Edge(start: start, dx: dx, dy: dy, length: length)
                    let count = max(1, Int(ceil(length / (cell / 2))))
                    var previous: Cell?
                    for i in 0...count {
                        let t = Double(i) / Double(count)
                        let key = Cell(x: Int(floor((start.x + t * dx) / cell)), y: Int(floor((start.y + t * dy) / cell)))
                        if key != previous { edges[key, default: []].append(edge); previous = key }
                    }
                }
            }
            self.edges = edges
        }
        func matches(x: Double, y: Double, ux: Double, uy: Double) -> Bool {
            let gx = Int(floor(x / cell)), gy = Int(floor(y / cell))
            for ix in (gx-1)...(gx+1) {
                for iy in (gy-1)...(gy+1) {
                    guard let bucket = edges[Cell(x: ix, y: iy)] else { continue }
                    for e in bucket where abs(ux * e.dx + uy * e.dy) >= cosine * e.length {
                        let x0 = x - e.start.x, y0 = y - e.start.y
                        let t = min(1, max(0, (x0 * e.dx + y0 * e.dy) / (e.length * e.length)))
                        let offsetX = x0 - t * e.dx, offsetY = y0 - t * e.dy
                        if offsetX * offsetX + offsetY * offsetY <= tolerance * tolerance { return true }
                    }
                }
            }
            return false
        }
    }

    static func compare(_ a: [[Coordinate]], _ b: [[Coordinate]]) async throws -> Self {
        let origin = a.first?.first ?? b.first?.first ?? Coordinate(0, 0)
        let projection = Projection(origin: origin, longitudeScale: scale * cos(origin.latitude * .pi / 180))
        func classify(_ parts: [[Coordinate]], against other: [[Coordinate]]) throws -> Side {
            let grid = try Grid(other, projection: projection)
            var result = Side()
            for part in parts {
                var shared: Bool?, run: [Coordinate] = []
                func finish() {
                    guard run.count >= 2 else { return }
                    if shared == true { result.shared.append(run) } else { result.unique.append(run) }
                }
                for (a, b) in zip(part, part.dropFirst()) {
                    try Task.checkCancellation()
                    let start = projection.point(a), end = projection.point(b)
                    let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    let lon = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
                    let ground = scale * hypot(b.latitude - a.latitude, lon * cos((a.latitude + b.latitude) * .pi / 360))
                    let n = max(1, Int(ceil(ground / spacing)))
                    for i in 0..<n {
                        let t = (Double(i) + 0.5) / Double(n)
                        let match = grid.matches(x: start.x + t * dx, y: start.y + t * dy, ux: dx / length, uy: dy / length)
                        if match != shared {
                            let f = Double(i) / Double(n)
                            let split = i == 0 ? a : Coordinate(a.latitude + (b.latitude-a.latitude)*f,
                                (a.longitude + lon*f + 540).truncatingRemainder(dividingBy: 360) - 180)
                            if run.last != split { run.append(split) }
                            finish()
                            run = [split]; shared = match
                        }
                        if match { result.sharedMetres += ground / Double(n) }
                        else { result.uniqueMetres += ground / Double(n) }
                    }
                    run.append(b)
                }
                finish()
            }
            return result
        }
        return try Self(a: classify(a, against: b), b: classify(b, against: a))
    }
}
