import Foundation

/// Provider line topology and train-specific routings, separate from map geometry.
public struct LuluRouteDatabase: Codable, Equatable, Sendable {
    public struct Station: Codable, Equatable, Sendable {
        public var name: String
        public var code: String
        public var kilometre: Int
    }
    public struct Line: Codable, Equatable, Sendable {
        public var id: Int
        public var name: String
        public var stations: [Station]
    }
    public struct Part: Codable, Equatable, Sendable {
        public var from: String
        public var lineID: Int
    }
    public struct Route: Codable, Equatable, Sendable {
        public var id: String
        public var end: String
        public var parts: [Part]
        public var train: String { String(id.dropFirst(5).prefix(5).drop(while: { $0 == "0" })) }
    }
    public var lines: [Line]
    public var routes: [Route]

    public static func recognizes(_ data: Data) -> Bool {
        data.count > 18 && String(data: data.subdata(in: 9..<18), encoding: .utf8) == "线路名"
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8_000_000, recognizes(data) else { throw invalid("线路资源标识无效") }
        var reader = Reader(bytes: [UInt8](data))
        let count = try reader.count(1...5000)
        var lines: [Line] = []
        for _ in 0..<count {
            let id = try reader.integer(), name = try reader.string(), n = try reader.count(1...5000)
            var stations: [Station] = []
            for _ in 0..<n {
                let name = try reader.string(), code = try reader.string()
                _ = try reader.integer() // Reserved field, commonly 0xffffffff.
                stations.append(.init(name: name, code: code, kilometre: try reader.integer()))
            }
            if id != 0 { lines.append(.init(id: id, name: name, stations: stations)) }
        }
        var routes: [Route] = []
        for _ in 0..<(try reader.count(1...100_000)) {
            let id = try reader.string(), end = try reader.string(), n = try reader.count(1...1000)
            var parts: [Part] = []
            for _ in 0..<n { parts.append(.init(from: try reader.string(), lineID: try reader.integer())) }
            routes.append(.init(id: id, end: end, parts: parts))
        }
        guard reader.offset == reader.bytes.count else { throw invalid("线路资源有未识别尾部") }
        let result = Self(lines: lines, routes: routes)
        try result.validate()
        return result
    }

    public func validate() throws {
        let ids = Set(lines.map(\.id))
        guard (1...5000).contains(lines.count), ids.count == lines.count,
              (1...100_000).contains(routes.count),
              Set(routes.map(\.id)).count == routes.count else { throw Self.invalid("线路或径路编号重复") }
        for line in lines {
            guard !line.name.isEmpty, line.name.count <= 100, (1...5000).contains(line.stations.count),
                  line.stations.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 80 && $0.code.count <= 20
                    && (0...100_000).contains($0.kilometre) }) else { throw Self.invalid("线路站表无效") }
        }
        for route in routes {
            guard route.id.utf8.count == 12, route.id.utf8.allSatisfy({ $0 < 128 }), !route.train.isEmpty,
                  !route.end.isEmpty, (1...1000).contains(route.parts.count),
                  route.parts.allSatisfy({ ids.contains($0.lineID) && !$0.from.isEmpty }) else {
                throw Self.invalid("列车径路引用无效")
            }
        }
    }

    public static func trainNames(_ value: String) -> Set<String> {
        let pieces = value.uppercased().split(separator: "/").map(String.init)
        guard let first = pieces.first else { return [] }
        var result: Set<String> = [first]
        for part in pieces.dropFirst() {
            if part.first?.isLetter == true { result.insert(part) }
            else { result.insert(String(first.dropLast(part.count)) + part) }
        }
        return result
    }

    /// Stop order AND every cumulative mileage must agree. A matching train
    /// number alone never authorizes borrowing another revision's routing.
    public func plan(for service: LuluTimetableSnapshot.Service, edition: String) throws -> LuluRoutePlan {
        let names = Self.trainNames(service.train)
        let candidates = routes.filter { names.contains($0.train) }.sorted { $0.id < $1.id }
        var plans: [LuluRoutePlan] = []
        for candidate in candidates {
            guard let plan = try? expand(candidate, edition: edition),
                  plan.nodes.first?.station == service.stops.first?.station,
                  plan.nodes.last?.station == service.stops.last?.station else { continue }
            var selected = plan, cursor = 0, indices: [Int] = []
            for (i, stop) in service.stops.enumerated() {
                let km = service.kilometreMarks[i] - (service.kilometreMarks.first ?? 0)
                guard let index = selected.nodes.indices.dropFirst(cursor).first(where: {
                    selected.nodes[$0].station == stop.station && abs(selected.nodes[$0].kilometre - km) <= 1
                }) else { indices = []; break }
                indices.append(index); cursor = index + 1
            }
            guard indices.count == service.stops.count, indices.first == 0, indices.last == selected.nodes.count - 1 else { continue }
            selected.stopIndices = indices
            if !plans.contains(where: { $0.nodes == selected.nodes && $0.edges == selected.edges }) { plans.append(selected) }
        }
        guard plans.count == 1 else {
            throw Self.invalid(plans.isEmpty ? "该车次尚无与停站及里程一致的径路，请同步或核对日期"
                               : "该车次存在多个不同径路，需核对版本后再绘图")
        }
        return plans[0]
    }

    private func expand(_ route: Route, edition: String) throws -> LuluRoutePlan {
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        var nodes: [LuluRoutePlan.Node] = [], edges: [LuluRoutePlan.Edge] = [], cumulative = 0
        for (i, part) in route.parts.enumerated() {
            guard let line = byID[part.lineID] else { throw Self.invalid("线路不存在") }
            let to = i + 1 < route.parts.count ? route.parts[i + 1].from : route.end
            guard let a = line.stations.firstIndex(where: { $0.name == part.from }),
                  let b = line.stations.firstIndex(where: { $0.name == to }), a != b else {
                throw Self.invalid("\(line.name)缺少\(part.from)或\(to)")
            }
            let ordered = a < b ? Array(line.stations[a...b]) : Array(line.stations[b...a].reversed())
            var previous = ordered[0]
            if nodes.isEmpty { nodes.append(.init(station: previous.name, code: previous.code, kilometre: 0)) }
            for station in ordered.dropFirst() {
                let distance = abs(station.kilometre - previous.kilometre)
                if station.name == previous.name && distance == 0 { previous = station; continue }
                // A shared physical section may be named for either constituent
                // line by OSM (e.g. the shared Nanguang/Guiguang approach).
                let aliases = lines.filter { alternative in
                    guard let start = alternative.stations.first(where: { $0.name == previous.name }),
                          let end = alternative.stations.first(where: { $0.name == station.name }) else { return false }
                    return abs(abs(end.kilometre - start.kilometre) - distance) <= 1
                }.map(\.name).sorted()
                edges.append(.init(lineID: line.id, lineName: line.name, aliases: aliases))
                cumulative += distance
                nodes.append(.init(station: station.name, code: station.code, kilometre: cumulative))
                previous = station
            }
        }
        return .init(providerID: route.id, edition: edition, nodes: nodes, edges: edges, stopIndices: [])
    }

    private static func invalid(_ message: String) -> DataError { .invalid("路路通径路：" + message) }
    private struct Reader {
        var bytes: [UInt8]
        var offset = 0
        mutating func integer() throws -> Int {
            guard offset + 4 <= bytes.count else { throw LuluRouteDatabase.invalid("资源被截断") }
            defer { offset += 4 }
            return (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
        }
        mutating func count(_ range: ClosedRange<Int>) throws -> Int {
            let n = try integer()
            guard range.contains(n) else { throw LuluRouteDatabase.invalid("记录数超限") }
            return n
        }
        mutating func string() throws -> String {
            guard offset < bytes.count else { throw LuluRouteDatabase.invalid("字符串被截断") }
            let n = Int(bytes[offset]); offset += 1
            guard n > 0, offset + n <= bytes.count,
                  let text = String(bytes: bytes[offset..<offset + n], encoding: .utf8),
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw LuluRouteDatabase.invalid("字符串无效")
            }
            offset += n; return text
        }
    }
}

public struct LuluRoutePlan: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var station: String
        public var code: String
        public var kilometre: Int
    }
    public struct Edge: Codable, Equatable, Sendable {
        public var lineID: Int
        public var lineName: String
        public var aliases: [String]
    }
    public var providerID: String
    public var edition: String
    public var nodes: [Node]
    public var edges: [Edge]
    public var stopIndices: [Int]
    public func validate(for timetable: RailTimetable) throws {
        guard (2...5000).contains(nodes.count), edges.count == nodes.count - 1,
              stopIndices.count == timetable.stops.count, stopIndices.first == 0, stopIndices.last == nodes.count - 1,
              zip(stopIndices, stopIndices.dropFirst()).allSatisfy({ $0 < $1 }),
              stopIndices.allSatisfy({ nodes.indices.contains($0) }),
              zip(stopIndices, timetable.stops).allSatisfy({ nodes[$0].station == $1.station }),
              nodes.allSatisfy({ !$0.station.isEmpty && (0...100_000).contains($0.kilometre) }),
              zip(nodes, nodes.dropFirst()).allSatisfy({ $0.kilometre <= $1.kilometre }),
              edges.allSatisfy({ !$0.lineName.isEmpty && !$0.aliases.isEmpty }),
              RailCivilDate.valid(edition) else { throw DataError.invalid("车次径路与时刻快照不一致") }
    }
}

extension RailTrackJourney {
    /// Slice in train travel order; never reverse a wrong-direction ticket or
    /// substitute a direct line between the passenger's two station names.
    public func slice(from: String, to: String) throws -> Self {
        let starts = stations.indices.filter { stations[$0] == from }
        let ends = stations.indices.filter { stations[$0] == to }
        let pairs = starts.flatMap { a in ends.filter { $0 > a }.map { (a, $0) } }
        guard pairs.count == 1, legs.count == stations.count - 1 else {
            throw DataError.invalid("乘车起终点不在该车次的顺序径路上，或同名站重复，请核对")
        }
        let (a, b) = pairs[0]
        var result = self
        result.id += "/slice/\(a)-\(b)"
        result.stations = Array(stations[a...b]); result.legs = Array(legs[a..<b])
        return result
    }
}

extension RailJourney {
    public mutating func updateBoardingTime() {
        guard let timetable, !LuluRouteDatabase.trainNames(train).isDisjoint(with: LuluRouteDatabase.trainNames(timetable.train)),
              let minute = timetable.stops.first(where: { $0.station == from })?.departure,
              let boardingDate = RailCivilDate.addingDays(minute / 1440, to: timetable.serviceDate) else { return }
        date = boardingDate
        departure = String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
    }
}

extension RailTimetable {
    public func passengerSection(from: String, to: String) throws -> Self {
        let pairs = stops.indices.filter { stops[$0].station == from }.flatMap { a in
            stops.indices.filter { $0 > a && stops[$0].station == to }.map { (a, $0) }
        }
        guard pairs.count == 1 else { throw DataError.invalid("乘车起终点未按顺序出现在该车次中，或同名停站有歧义") }
        let (a, b) = pairs[0]
        guard let departure = stops[a].departure, stops[b].arrival != nil else {
            throw DataError.invalid("乘车起终点缺少到发时刻")
        }
        let days = departure / 1440, offset = days * 1440
        guard let date = RailCivilDate.addingDays(days, to: serviceDate) else { throw DataError.invalid("乘车日期无效") }
        var result = self
        result.id += "/section/\(a)-\(b)"; result.serviceDate = date
        result.stops = Array(stops[a...b]).map { stop in
            .init(stop.station, arrival: stop.arrival.map { $0 - offset }, departure: stop.departure.map { $0 - offset })
        }
        result.stops[0].arrival = nil; result.stops[result.stops.count - 1].departure = nil
        if var plan = routing {
            try plan.validate(for: self)
            let start = plan.stopIndices[a], end = plan.stopIndices[b], km = plan.nodes[start].kilometre
            plan.nodes = Array(plan.nodes[start...end]).map { node in
                var value = node; value.kilometre -= km; return value
            }
            plan.edges = Array(plan.edges[start..<end])
            plan.stopIndices = plan.stopIndices[a...b].map { $0 - start }
            result.routing = plan
        }
        try result.validate()
        return result
    }
}
