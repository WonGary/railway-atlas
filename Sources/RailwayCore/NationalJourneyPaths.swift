import CryptoKit
import Foundation

/// A release contains dated timetable variants and immutable groups of encoded WGS84 paths.
public actor NationalJourneyPaths {
    public static let shared = NationalJourneyPaths()
    private struct Index: Decodable {
        let version: Int
        let edition: String
        let names: [String]
        let calendars: [[String]]
        let groups: [String: String]
        let lookup: [String: [String]]
    }
    private struct Alias: Decodable {
        let names: [String], start: String, end: String
        init(from decoder: Decoder) throws {
            var items = try decoder.unkeyedContainer()
            names = try items.decode([String].self)
            start = try items.decode(String.self)
            end = try items.decode(String.self)
        }
    }
    private struct Row: Decodable {
        let id: String, c: Int, s: [[Int?]], p: [Int], a: [Alias], r: String?
    }
    private struct Group: Decodable {
        let paths: [String]
        let byNumber: [String: [(String, Row)]]
        private enum CodingKeys: String, CodingKey { case paths, trains }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paths = try container.decode([String].self, forKey: .paths)
            let trains = try container.decode([String: [Row]].self, forKey: .trains)
            var byNumber = [String: [(String, Row)]]()
            for (primary, rows) in trains {
                for row in rows {
                    for alias in Set([primary] + row.a.flatMap(\.names)) {
                        byNumber[alias, default: []].append((primary, row))
                    }
                }
            }
            self.byNumber = byNumber
        }
    }
    private let directory: URL
    private var index: Index?
    private var groups: [String: Group] = [:]
    public init(directory: URL? = nil) {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web/station-directory/paths")
        self.directory = directory ?? Bundle.main.resourceURL?.appendingPathComponent("station-directory/paths")
            .flatMapIfExists ?? checkout
    }
    private func loadIndex() throws -> Index {
        if let index { return index }
        let item = try JSONDecoder().decode(Index.self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        guard item.version == 1 else { throw DataError.invalid("请更新全国铁路路线资料") }
        index = item
        return item
    }
    private struct Match {
        let row: Row, timetable: RailTimetable, group: Group, first: Int, last: Int
    }
    private func matching(_ train: String, date: String, expected: RailTimetable?, from: String?, to: String?,
                          boarding: Bool, departure: String?) throws -> Match? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path) else { return nil }
        let index = try loadIndex(), numbers = LuluRouteDatabase.trainNames(train)
        let keys = Set(numbers.flatMap { index.lookup[$0] ?? [] })
        var matches: [Match] = []
        var signature: String?
        if let timetable = expected, let plan = timetable.routing {
            try plan.validate(for: timetable)
            let text = plan.nodes.enumerated().map { i,n in
                "\(n.station)\t\(n.kilometre)\t\(i < plan.edges.count ? plan.edges[i].lineName : "")"
            }.joined(separator: "\n")
            signature = SHA256.hash(data: Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
        }
        for key in keys {
            guard let file = index.groups[key] else { continue }
            let group: Group
            if let cached = groups[key] { group = cached }
            else {
                group = try JSONDecoder().decode(Group.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
                if groups.count >= 24, let oldest = groups.keys.first { groups.removeValue(forKey: oldest) }
                groups[key] = group
            }
            var seen = Set<String>()
            for number in numbers {
                for (primary, row) in group.byNumber[number] ?? [] where seen.insert(row.id).inserted {
                    if let signature, row.r != signature { continue }
                    let stops: [RailTimetable.Stop] = row.s.compactMap { call in
                        guard call.count == 3, let i = call[0], index.names.indices.contains(i) else { return nil }
                        return .init(index.names[i], arrival: call[1], departure: call[2])
                    }
                    guard stops.count >= 2, stops.count == row.s.count, row.p.count == stops.count-1,
                          expected == nil || expected?.stops == stops else { continue }
                    let pairs = stops.indices.filter { from == nil ? $0 == 0 : stops[$0].station == from }.flatMap { a in
                        stops.indices.filter { $0 > a && (to == nil ? $0 == stops.count-1 : stops[$0].station == to) }.map { (a,$0) }
                    }
                    guard pairs.count == 1, let (a,b) = pairs.first, let minute = stops[a].departure else { continue }
                    if let departure, !departure.isEmpty, RailCivilDate.minute(departure) != minute % 1440 { continue }
                    let origin = boarding ? RailCivilDate.addingDays(-(minute/1440), to: date) : date
                    guard let origin, index.calendars.indices.contains(row.c),
                          index.calendars[row.c].contains(origin.replacingOccurrences(of:"-",with:"")),
                          numbers.contains(primary) || row.a.contains(where: { $0.start <= origin && origin <= $0.end && !numbers.isDisjoint(with:$0.names) }) else { continue }
                    let tt = expected ?? RailTimetable(id:"national:\(row.id):\(origin)",train:train,serviceDate:origin,
                        source:.init(title:"中国铁路 GTFS · Jeremy Gao",url:"https://github.com/wensimehrp/chinese-railway-gtfs",
                                     retrievedOn:index.edition),stops:stops)
                    matches.append(Match(row:row,timetable:tt,group:group,first:a,last:b))
                }
            }
        }
        guard matches.count <= 1 else { throw DataError.invalid("该日期有多个时刻版本，请选择具体车次") }
        return matches.first
    }
    public func timetable(train: String, date: String, from: String? = nil, to: String? = nil,
                          boarding: Bool = false, departure: String? = nil) throws -> RailTimetable? {
        try matching(train, date:date, expected:nil, from:from, to:to, boarding:boarding, departure:departure)?.timetable
    }
    public func journey(_ input: RailTimetable, from: String? = nil, to: String? = nil) throws -> RailTrackJourney? {
        guard let match = try matching(input.train,date:input.serviceDate,expected:input,from:from,to:to,boarding:false,departure:nil) else { return nil }
        let table = try (from != nil && to != nil) ? input.passengerSection(from:from!,to:to!) : input
        var legs: [[Coordinate]] = []
        for i in match.first..<match.last {
            try Task.checkCancellation()
            let path = match.row.p[i]
            guard match.group.paths.indices.contains(path) else {
                throw DataError.invalid("缺少连续轨迹：\(input.stops[i].station) → \(input.stops[i+1].station)")
            }
            let leg = try Self.decode(match.group.paths[path])
            if let prev = legs.last?.last, let next = leg.first, RailTrackJourney.metres(prev,next) > 120 {
                throw DataError.invalid("\(input.stops[i].station)站内的两段轨迹尚未衔接")
            }
            legs.append(leg)
        }
        let result = RailTrackJourney(id:"atlas-path/\(table.id)",train:input.train,serviceDate:table.serviceDate,
            stations:table.stops.map(\.station),legs:legs,source:.init(title:"全国车次径路 · 中国铁路 GTFS / OpenStreetMap",
            url:"https://github.com/wensimehrp/chinese-railway-gtfs",retrievedOn:try loadIndex().edition,
            note:"车次轨迹或同线路、同站序和里程的轨道。Jeremy Gao · CC BY 4.0，© OpenStreetMap contributors · ODbL。站内股道为近似位置。"))
        try result.validate(for:table)
        return result
    }
    public static func decode(_ text: String, densify: Bool = true) throws -> [Coordinate] {
        let bytes = Array(text.utf8)
        var at = 0, lon = 0, lat = 0, points: [Coordinate] = []
        func delta() throws -> Int {
            var bits = 0, shift = 0
            while at < bytes.count && shift <= 30 {
                let v = Int(bytes[at])-63; at += 1
                guard (0...63).contains(v) else { break }
                bits |= (v & 31) << shift
                if v < 32 { return (bits >> 1) ^ -(bits & 1) }
                shift += 5
            }
            throw DataError.invalid("全国铁路路线坐标无效")
        }
        while at < bytes.count {
            lon += try delta(); lat += try delta()
            let p = Coordinate(Double(lat)/100000,Double(lon)/100000)
            guard p.isValid else { throw DataError.invalid("全国铁路路线坐标越界") }
            if let prev=points.last {
                let distance=RailTrackJourney.metres(prev,p)
                guard distance<33_000 else { throw DataError.invalid("原始轨迹有缺口") }
                // Preserve the published shape, interpolating along its own straight
                // segments for the existing kilometre-scale playback validator.
                let count=densify ? max(1,Int(ceil(distance/1800))) : 1
                for j in 1..<count {
                    let f=Double(j)/Double(count)
                    points.append(.init(prev.latitude+(p.latitude-prev.latitude)*f,prev.longitude+(p.longitude-prev.longitude)*f))
                }
            }
            points.append(p)
        }
        return points
    }
}

private extension URL {
    var flatMapIfExists: URL? { FileManager.default.fileExists(atPath: path) ? self : nil }
}
