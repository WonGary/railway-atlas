import Foundation
import RailwayCore

struct InspectionLine: Sendable, Identifiable, Decodable {
    struct Stop: Sendable, Decodable {
        let name: String
        let kilometre: Int?
        let note: String?

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            name = try row.decode(String.self)
            kilometre = try? row.decodeIfPresent(Int.self)
            note = try? row.decodeIfPresent(String.self)
        }

        init(_ stop: LuluRouteDatabase.Station) {
            name = stop.name
            kilometre = stop.kilometre
            note = nil
        }
    }

    let title: String
    let stops: [Stop]
    var id: String { title }

    init(from decoder: Decoder) throws {
        var row = try decoder.unkeyedContainer()
        title = try row.decode(String.self)
        stops = try row.decode([Stop].self)
    }

    init(_ line: LuluRouteDatabase.Line) {
        title = line.name
        stops = line.stations.map(Stop.init)
    }
}

struct InspectionDirectory: Sendable {
    let byTitle: [String: InspectionLine]
    let atStation: [String: Set<String>]

    init(_ lines: [InspectionLine]) {
        byTitle = Dictionary(lines.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        var stations: [String: Set<String>] = [:]
        for line in lines {
            for stop in line.stops { stations[stop.name, default: []].insert(line.title) }
        }
        atStation = stations
    }

    static let bundled: Result<Self, Error> = Result {
        struct Contents: Decodable { let lines: [InspectionLine] }
        return Self(try read(Contents.self).lines)
    }

    static func read<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try Data(contentsOf: MapContextFiles.directory.appendingPathComponent("national.js"))
        let prefix = Data("globalThis.atlasRailDirectory = ".utf8)
        guard data.starts(with: prefix), let end = data.lastIndex(of: 125) else {
            throw DataError.invalid("车站目录格式无法识别")
        }
        return try JSONDecoder().decode(type, from: data[prefix.count...end])
    }
}

struct InspectionLeg: Identifiable, Sendable {
    let id: Int
    let from, to, source: String
    let points: [Coordinate]
    let metres: Double
    let fareKilometres: Int?
    let issue: String?
    let joinGap: Double?
    let viaStations: [String]
    let viaLines: [InspectionLine]
    let planned: Bool
    var drawable: Bool { issue == nil }
    var status: String {
        if let issue { return issue }
        if let joinGap { return "\(from)站内衔接相距 \(Int(joinGap.rounded())) m" }
        return "轨迹连续"
    }
}

struct JourneyInspection: Sendable {
    let table: RailTimetable
    let legs: [InspectionLeg]
    let notice: String?
    var paths: [[Coordinate]] { legs.filter(\.drawable).map(\.points) }
    var complete: Bool { !legs.isEmpty && legs.allSatisfy { $0.drawable && $0.joinGap == nil } }

    func betweenEndpoints(of first: RailTimetable) throws -> Self {
        let names = table.stops.map(\.station)
        guard let a = first.stops.first?.station, let b = first.stops.last?.station, a != b,
              names.filter({ $0 == a }).count == 1, names.filter({ $0 == b }).count == 1,
              let i = names.firstIndex(of: a), let j = names.firstIndex(of: b) else {
            throw DataError.invalid("另一趟车没有唯一对应的起终点，请改为比较全程")
        }
        let lo = min(i, j), hi = max(i, j)
        return try Self(table: table.passengerSection(indices: lo...hi), legs: Array(legs[lo..<hi]), notice: notice)
    }

    struct Trace: Sendable {
        var points: [Coordinate] = []
        var source = "缺少轨迹"
        var issue: String?
        var imported = false
    }

    static func make(_ table: RailTimetable, traces: [Trace], library: LuluRouteDatabase?, notice: String?) throws -> Self {
        let catalog = try? InspectionDirectory.bundled.get()
        let localLines = library?.lines ?? []
        let plan = table.routing.flatMap { (try? $0.validate(for: table)) != nil ? $0 : nil }
        var legs: [InspectionLeg] = []
        for i in table.stops.indices.dropLast() {
            try Task.checkCancellation()
            let from = table.stops[i].station, to = table.stops[i + 1].station
            let span = plan.map { $0.stopIndices[i]..<$0.stopIndices[i + 1] }
            var fare: Int?, via: [String] = [], lines: [InspectionLine] = []
            if let span, let plan {
                via = plan.nodes[span.lowerBound...span.upperBound].map(\.station)
                fare = plan.nodes[span.upperBound].kilometre - plan.nodes[span.lowerBound].kilometre
                var seen = Set<String>()
                for edge in plan.edges[span] where seen.insert(edge.lineName).inserted {
                    if let local = localLines.first(where: { $0.id == edge.lineID && $0.name == edge.lineName }) {
                        lines.append(InspectionLine(local))
                    } else if let entry = catalog?.byTitle[edge.lineName] { lines.append(entry) }
                }
            } else if let catalog {
                let candidates = (catalog.atStation[from] ?? []).intersection(catalog.atStation[to] ?? [])
                lines = candidates.sorted().compactMap { catalog.byTitle[$0] }
            }
            let trace = traces.indices.contains(i) ? traces[i] : Trace()
            let valid = trace.points.count >= 2 && trace.points.allSatisfy(\.isValid)
            var length = 0.0, longest = 0.0
            if valid {
                for (a, b) in zip(trace.points, trace.points.dropFirst()) {
                    let distance = RailTrackJourney.metres(a, b)
                    length += distance
                    longest = max(longest, distance)
                }
            }
            var issue = trace.issue
            if issue == nil {
                if !valid {
                    issue = trace.points.count >= 2 ? "坐标无效" : (fare == nil ? "缺少区间轨迹" : "只有经由与计价里程")
                } else if length < 0.1 { issue = "轨道长度为零" }
                else if longest > 32_000 || (trace.imported && trace.points.count == 2 && length > 8_000) {
                    issue = "轨迹顶点过疏，走向待核"
                }
            }
            var gap: Double?
            if issue == nil, let previous = legs.last, previous.drawable, let a = previous.points.last, let b = trace.points.first {
                let distance = RailTrackJourney.metres(a, b)
                if distance > 120 { gap = distance }
            }
            legs.append(.init(id: i, from: from, to: to, source: trace.source, points: trace.points, metres: length,
                              fareKilometres: fare, issue: issue, joinGap: gap, viaStations: via, viaLines: lines,
                              planned: plan != nil))
        }
        let message = [notice, table.routingIssue, catalog == nil ? "随包线路站表读取失败" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Self(table: table, legs: legs, notice: message.isEmpty ? nil : message)
    }
}

extension ExperienceStore {
    /// A selected local variant keeps its stop order and route fingerprint.
    func inspectionTimetable(train: String, date: String) async throws -> RailTimetable {
        let names = LuluRouteDatabase.trainNames(train.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !names.isEmpty, RailCivilDate.valid(date) else { throw DataError.invalid("请输入车次和始发日期") }
        func matches(_ table: RailTimetable) -> Bool {
            table.serviceDate == date && !names.isDisjoint(with: LuluRouteDatabase.trainNames(table.train))
        }
        let pool = timetables.filter(matches) + (library.archive?.timetables.filter(matches) ?? [])
        var variants: [RailTimetable] = []
        for table in pool where !variants.contains(where: { $0.stops == table.stops && $0.routing == table.routing }) {
            variants.append(table)
        }
        if variants.count == 1 { return variants[0] }
        guard variants.isEmpty else { throw DataError.invalid("本机有多份同日排图，请从车次列表选择") }
        if let table = try await NationalJourneyPaths.shared.timetable(train: train, date: date) { return table }
        if let lulu = library.lulu {
            let rows = lulu.services.filter { $0.validFrom <= date && date <= $0.validThrough &&
                !names.isDisjoint(with: LuluRouteDatabase.trainNames($0.train)) }
            if rows.count == 1 { return try lulu.timetable(rows[0], on: date) }
            if rows.count > 1 { throw DataError.invalid("路路通有多份同日排图，请从离线库选择") }
        }
        throw DataError.invalid("本机没有 \(date) 始发的 \(train)")
    }

    func inspectJourney(_ input: RailTimetable) async throws -> JourneyInspection {
        try input.validate()
        let table = try await routedTimetable(input, allowNetwork: false)
        var traces = Array(repeating: JourneyInspection.Trace(), count: table.stops.count - 1)
        var notice: String?
        do {
            if let national = try await NationalJourneyPaths.shared.inspectionLegs(table) {
                traces = national.map { leg in
                    let source: String
                    switch leg.kind {
                    case 1: source = "本车次 GTFS 轨迹"
                    case 2: source = "同线路、站序和里程匹配"
                    case 3: source = "OSM 轨道或渡轮航道匹配"
                    default: source = leg.points.isEmpty ? "缺少轨迹" : "全国车次径路"
                    }
                    return .init(points: leg.points, source: source, issue: leg.issue)
                }
            }
        } catch {
            try Task.checkCancellation()
            notice = error.localizedDescription
        }
        if traces.contains(where: { $0.points.isEmpty }) {
            let known = table.routing == nil && table.routingIssue == nil ? trackJourneys.first(where: {
                $0.train == table.train && $0.serviceDate == table.serviceDate && $0.stations == table.stops.map(\.station)
                        && (try? $0.validate(for: table)) != nil
            }) : nil
            let saved = await routeRepository.savedRoute(table)
            for i in traces.indices where traces[i].points.isEmpty {
                try Task.checkCancellation()
                if let route = saved ?? known, route.legs.indices.contains(i) {
                    traces[i] = .init(points: route.legs[i], source: route.source.title, imported: saved == nil)
                } else if let section = try? table.passengerSection(indices: i...(i + 1)),
                          let route = await routeRepository.savedRoute(section), let points = route.legs.first {
                    traces[i] = .init(points: points, source: route.source.title)
                }
            }
        }
        let local = library.lulu?.routing
        return try await Self.buildInspection(table, traces: traces, library: local, notice: notice)
    }

    nonisolated private static func buildInspection(_ table: RailTimetable, traces: [JourneyInspection.Trace],
                       library: LuluRouteDatabase?, notice: String?) async throws -> JourneyInspection {
        try JourneyInspection.make(table, traces: traces, library: library, notice: notice)
    }
}
