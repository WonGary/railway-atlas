import Foundation
import RailwayCore

/// Fill holes in the named line atlas only from dated train shapes that agree with
/// the directory's mileage, station positions and order. Keep disjoint parts separate.
actor InspectionLineAtlas {
    static let shared = InspectionLineAtlas()
    struct Drawing: Sendable {
        var parts: [[Coordinate]] = []
        var covered = Set<Int>()
        var supplemented = false
        func note(for line: InspectionLine) -> String {
            let total = max(0, line.stops.count - 1)
            var text = "已绘 \(covered.count)/\(total) 个相邻站所区间"
            if supplemented { text += "，含同日车次轨迹" }
            return text
        }
    }
    private struct Train: Decodable {
        let number: String, calendar: Int, calls: [Int]
        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            number = try row.decode(String.self)
            calendar = try row.decode(Int.self)
            calls = try row.decode([[Int?]].self).compactMap { $0.first ?? nil }
        }
    }
    private struct Boards: Decodable {
        let names: [String], trains: [Train], calendars: [[String]]
    }
    private var boards: Boards?

    func drawing(_ line: InspectionLine, report: JourneyInspection) async throws -> Drawing {
        let names = line.stops.map(\.name)
        let indices = Dictionary(grouping: names.indices, by: { names[$0] })
        let directory = try? InspectionDirectory.bundled.get()
        func range(_ a: String, _ b: String) -> Range<Int>? {
            guard let ai = indices[a], let bi = indices[b], ai.count == 1, bi.count == 1, ai[0] != bi[0] else { return nil }
            return min(ai[0], bi[0])..<max(ai[0], bi[0])
        }
        var drawing = Drawing()
        for row in MapContextFiles.sections(line.title, stops: Set(names)) {
            guard let span = range(row.from, row.to) else { continue }
            drawing.parts.append(row.points); drawing.covered.formUnion(span)
        }

        func offer(_ from: String, _ to: String, points: [Coordinate], planned: Bool) {
            guard let span = range(from, to), !span.allSatisfy(drawing.covered.contains), points.count > 1,
                  let km1 = line.stops[span.lowerBound].kilometre, let km2 = line.stops[span.upperBound].kilometre else { return }
            if !planned {
                let common = (directory?.atStation[from] ?? []).intersection(directory?.atStation[to] ?? [])
                guard common == [line.title] else { return }
            }
            let expected = Double(abs(km2-km1))*1000
            guard expected > 0, abs(RailTrackJourney.length(points) - expected) <= max(2_500, expected*0.18),
                  Self.orderedAnchors(line: line, span: span, points: points, from: from, to: to) else { return }
            drawing.parts.append(points); drawing.covered.formUnion(span); drawing.supplemented = true
        }
        for leg in report.legs where leg.drawable {
            let known = leg.planned && leg.viaLines.map(\.title) == [line.title]
            if !leg.planned || known { offer(leg.from, leg.to, points: leg.points, planned: known) }
        }
        if drawing.covered.count == names.count - 1 { return drawing }
        if boards == nil { boards = try? InspectionDirectory.read(Boards.self) }
        guard let boards else { return drawing }
        let day = report.table.serviceDate.replacingOccurrences(of: "-", with: "")
        let calendars = Set(boards.calendars.indices.filter { boards.calendars[$0].contains(day) })
        let stationCodes = Set(boards.names.indices.filter { indices[boards.names[$0]] != nil })
        var choices: [String: Set<Int>] = [:]
        for train in boards.trains where calendars.contains(train.calendar) {
            for (a,b) in zip(train.calls, train.calls.dropFirst()) where stationCodes.contains(a) && stationCodes.contains(b) {
                guard let span = range(boards.names[a], boards.names[b]) else { continue }
                choices[train.number, default: []].formUnion(span)
            }
        }
        choices.removeValue(forKey: report.table.train)
        for _ in 0..<16 {
            try Task.checkCancellation()
            let ranked = choices.map { ($0.key, $0.value.subtracting(drawing.covered).count) }
            guard let best = ranked.max(by: { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 < $1.1 }), best.1 > 0 else { break }
            choices.removeValue(forKey: best.0)
            let paths = NationalJourneyPaths.shared
            guard let table = try? await paths.timetable(train: best.0, date: report.table.serviceDate),
                  let legs = try? await paths.inspectionLegs(table) else { continue }
            for (i, leg) in legs.enumerated() where leg.issue == nil && leg.points.count >= 2 {
                guard zip(leg.points, leg.points.dropFirst()).allSatisfy({ RailTrackJourney.metres($0, $1) <= 32_000 }) else { continue }
                offer(table.stops[i].station, table.stops[i+1].station, points: leg.points, planned: false)
            }
        }
        return drawing
    }

    private static func orderedAnchors(line: InspectionLine, span: Range<Int>, points: [Coordinate],
                                       from: String, to: String) -> Bool {
        guard let a = NationalDirectoryPins.byName[from]?.coordinate, let b = NationalDirectoryPins.byName[to]?.coordinate,
              let start = points.first, let end = points.last,
              RailTrackJourney.metres(a, start) <= 1_400, RailTrackJourney.metres(b, end) <= 1_400 else { return false }
        var inside = Array(line.stops[(span.lowerBound+1)..<span.upperBound])
        if line.stops[span.lowerBound].name != from { inside.reverse() }
        var cursor = 0.0
        for stop in inside {
            guard let pin = NationalDirectoryPins.byName[stop.name]?.coordinate else { continue }
            let scale = cos(pin.latitude * .pi / 180), tolerance = 1_400.0 / 111_195
            var nearest = tolerance * tolerance, next: Double?
            for i in Int(cursor)..<(points.count-1) {
                let a = points[i], b = points[i+1]
                let x = (a.longitude-pin.longitude)*scale, y = a.latitude-pin.latitude
                let dx = (b.longitude-a.longitude)*scale, dy = b.latitude-a.latitude
                let norm = dx*dx + dy*dy
                let t = norm == 0 ? 0 : min(1, max(0, -(x*dx+y*dy)/norm))
                let progress = Double(i) + t
                guard progress >= cursor else { continue }
                let d = (x+t*dx)*(x+t*dx) + (y+t*dy)*(y+t*dy)
                if d <= nearest { nearest = d; next = progress }
            }
            guard let next else { return false }
            cursor = next
        }
        return true
    }
}
