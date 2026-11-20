import Foundation

/// Dates in archives are civil dates, never dates in the device's time zone.
public enum RailCivilDate {
    public static func addingDays(_ days: Int, to value: String) -> String? {
        guard valid(value) else { return nil }
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value),
              let next = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return formatter.string(from: next)
    }
    public static func valid(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1800...2200).contains(parts[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: c) else { return false }
        let roundtrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundtrip.year == parts[0] && roundtrip.month == parts[1] && roundtrip.day == parts[2]
    }

    public static func minute(_ value: String) -> Int? {
        guard value.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let p = value.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    public static func validHistorical(_ value: String) -> Bool {
        if valid(value) { return true }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard (1800...2200).contains(parts.first ?? 0) else { return false }
        if parts.count == 1 { return value.count == 4 }
        guard parts.count == 2, value.count == 7, (1...12).contains(parts[1]) else { return false }
        return true
    }
}

public struct RailEvidence: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var retrievedOn: String
    public var note: String

    public init(title: String, url: String, retrievedOn: String, note: String = "") {
        self.title = title; self.url = url; self.retrievedOn = retrievedOn; self.note = note
    }

    public func validate() throws {
        guard !title.isEmpty, title.count <= 300, note.count <= 4000,
              let value = URL(string: url), ["https", "http"].contains(value.scheme),
              value.host != nil, url.count <= 2048, RailCivilDate.valid(retrievedOn) else {
            throw DataError.invalid("来源的名称、网址或查阅日期无效")
        }
    }
}

public struct RailTimetable: Codable, Equatable, Identifiable, Sendable {
    public struct Stop: Codable, Equatable, Sendable {
        public var station: String
        /// Minutes since 00:00 on serviceDate. Day two 01:20 is 1520.
        public var arrival: Int?
        public var departure: Int?
        public init(_ station: String, arrival: Int?, departure: Int?) {
            self.station = station; self.arrival = arrival; self.departure = departure
        }
    }

    public var id: String
    public var train: String
    public var serviceDate: String
    public var timeZone: String
    public var source: RailEvidence
    public var stops: [Stop]
    public var routing: LuluRoutePlan? = nil
    public var routingIssue: String? = nil

    public init(id: String, train: String, serviceDate: String, timeZone: String = "Asia/Shanghai",
                source: RailEvidence, stops: [Stop]) {
        self.id = id; self.train = train; self.serviceDate = serviceDate
        self.timeZone = timeZone; self.source = source; self.stops = stops
    }

    public var start: Int { stops.first?.departure ?? 0 }
    public var end: Int { stops.last?.arrival ?? start }
    public var hasCompleteDwellTimes: Bool {
        stops.dropFirst().dropLast().allSatisfy { $0.arrival != nil && $0.departure != nil }
    }

    public func validate() throws {
        try source.validate()
        try routing?.validate(for: self)
        guard !id.isEmpty, id.count <= 200, !train.isEmpty, train.count <= 40,
              RailCivilDate.valid(serviceDate), TimeZone(identifier: timeZone) != nil,
              (2...250).contains(stops.count), stops.first?.departure != nil,
              stops.last?.arrival != nil, (0..<1440).contains(start), end > start else {
            throw DataError.invalid("车次、始发日期、时区或首末站时刻无效")
        }
        var previous = -1
        for (i, stop) in stops.enumerated() {
            guard !stop.station.isEmpty, stop.station.count <= 80,
                  stop.arrival != nil || stop.departure != nil else {
                throw DataError.invalid("第 \(i + 1) 站缺少站名或时刻")
            }
            for time in [stop.arrival, stop.departure].compactMap({ $0 }) {
                guard time >= previous, (0...14 * 1440).contains(time) else {
                    throw DataError.invalid("时刻倒退或超限；跨日请使用从始发日零点累计的分钟数")
                }
                previous = time
            }
            if i > 0, let depart = stops[i - 1].departure, let arrive = stop.arrival, arrive <= depart {
                throw DataError.invalid("相邻车站的运行时间必须大于零")
            }
        }
    }

    public struct Position: Equatable, Sendable {
        public enum Phase: String, Sendable { case waiting, dwelling, running, arrived, unknown }
        public let phase: Phase
        public let from: Int
        public let to: Int
        public let fraction: Double
        /// This is station-order space, never a geographical or live position.
        public var stationPosition: Double { Double(from) + Double(to - from) * fraction }
    }

    public func position(at seconds: Double) -> Position {
        guard stops.count >= 2, seconds.isFinite else { return .init(phase: .unknown, from: 0, to: 0, fraction: 0) }
        if seconds < Double(start * 60) { return .init(phase: .waiting, from: 0, to: 0, fraction: 0) }
        if seconds >= Double(end * 60) {
            return .init(phase: .arrived, from: stops.count - 1, to: stops.count - 1, fraction: 0)
        }
        for i in stops.indices {
            if let arrival = stops[i].arrival, let departure = stops[i].departure,
               seconds >= Double(arrival * 60), seconds < Double(departure * 60) {
                return .init(phase: .dwelling, from: i, to: i, fraction: 0)
            }
            if i + 1 < stops.count, let departure = stops[i].departure, let arrival = stops[i + 1].arrival,
               arrival > departure, seconds >= Double(departure * 60), seconds < Double(arrival * 60) {
                let fraction = (seconds - Double(departure * 60)) / Double((arrival - departure) * 60)
                return .init(phase: .running, from: i, to: i + 1, fraction: fraction)
            }
        }
        // Incomplete published tables must not silently invent dwell times.
        let index = stops.indices.last { Double((stops[$0].arrival ?? stops[$0].departure ?? 0) * 60) <= seconds } ?? 0
        return .init(phase: .unknown, from: index, to: index, fraction: 0)
    }

    public static func clock(_ seconds: Double, includeSeconds: Bool = true) -> String {
        guard seconds.isFinite else { return "—" }
        let t = Int(max(0, min(14 * 86400, seconds)))
        let day = t / 86400
        let time = includeSeconds
            ? String(format: "%02d:%02d:%02d", (t / 3600) % 24, (t / 60) % 60, t % 60)
            : String(format: "%02d:%02d", (t / 3600) % 24, (t / 60) % 60)
        return day == 0 ? time : "D+\(day) \(time)"
    }
}

public struct RailTimetableArchive: Codable, Sendable {
    public var version: Int = 1
    public var timetables: [RailTimetable]
    public init(timetables: [RailTimetable]) { self.timetables = timetables }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 5_000_000 else { throw DataError.invalid("时刻包超过 5 MB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, (1...100).contains(value.timetables.count),
              Set(value.timetables.map(\.id)).count == value.timetables.count else {
            throw DataError.invalid("时刻包版本或车次标识无效")
        }
        try value.timetables.forEach { try $0.validate() }
        return value
    }
}

public struct RailJourney: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case needsReview, travelled, cancelled
        public var title: String {
            switch self { case .needsReview: "待核对"; case .travelled: "已乘坐"; case .cancelled: "未乘坐" }
        }
    }
    public var id: UUID
    public var date: String
    public var train: String
    public var from: String
    public var to: String
    public var departure: String
    public var status: Status
    public var source: String
    public var note: String
    /// Preserve the selected dated service and its routing when the library updates.
    public var timetable: RailTimetable? = nil

    public init(id: UUID = UUID(), date: String = "", train: String = "", from: String = "", to: String = "",
                departure: String = "", status: Status = .needsReview, source: String = "手动录入", note: String = "") {
        self.id = id; self.date = date; self.train = train; self.from = from; self.to = to
        self.departure = departure; self.status = status; self.source = source; self.note = note
    }

    public var validationMessage: String? {
        if !RailCivilDate.valid(date) { return "日期须为有效的 YYYY-MM-DD；不知道的年份请先核对" }
        if from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请补全出发站和到达站" }
        if from == to { return "出发站与到达站相同，请核对" }
        if !departure.isEmpty && RailCivilDate.minute(departure) == nil { return "发车时间须为 24 小时制 HH:mm，或留空" }
        if from.count > 80 || to.count > 80 || train.count > 40 || source.count > 120 || note.count > 2000 {
            return "记录文字过长"
        }
        return nil
    }

    /// Conservative candidate matching. Unknown times are not merged with known
    /// times; repeated journeys with no identifying time remain reviewable.
    public var duplicateKey: String {
        [date, train.uppercased(), from, to, departure].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }.joined(separator: "\u{1f}")
    }
}

public struct RailJourneyArchive: Codable, Sendable {
    public var version: Int = 1
    public var journeys: [RailJourney]
    public init(journeys: [RailJourney]) { self.journeys = journeys }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 10_000_000 else { throw DataError.invalid("护照文件超过 10 MB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.journeys.count <= 10_000,
              Set(value.journeys.map(\.id)).count == value.journeys.count else {
            throw DataError.invalid("护照版本、记录数或标识无效")
        }
        for journey in value.journeys {
            if let message = journey.validationMessage { throw DataError.invalid(message) }
            try journey.timetable?.validate()
        }
        return value
    }
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum JourneyImport {
    /// RFC 4180 subset with UTF-8 BOM, CRLF, quoted newlines and escaped quotes.
    /// A malformed row aborts the parse instead of shifting columns silently.
    public static func csv(_ text: String) throws -> [RailJourney] {
        guard text.utf8.count <= 5_000_000 else { throw DataError.invalid("CSV 超过 5 MB") }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        let characters = Array(text.replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        func finishField() { row.append(field); field = ""; closed = false }
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "\"" {
                guard field.isEmpty, !closed else { throw DataError.invalid("CSV 引号位置无效") }
                quoted = true
            } else if c == "," { finishField() }
            else if c == "\n" {
                finishField()
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                guard rows.count <= 10_001 else { throw DataError.invalid("CSV 超过 10,000 条") }
            } else {
                guard !closed else { throw DataError.invalid("CSV 引号后应为逗号或换行") }
                field.append(c)
            }
            index += 1
        }
        guard !quoted else { throw DataError.invalid("CSV 的引号未闭合") }
        finishField()
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        guard let header = rows.first, rows.count >= 2 else { throw DataError.invalid("CSV 需要表头和至少一条记录") }
        let aliases = ["日期": "date", "乘车日期": "date", "车次": "train", "出发站": "from",
                       "到达站": "to", "发车时间": "departure", "备注": "note"]
        let keys = header.map { let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return aliases[key] ?? key }
        guard Set(keys).count == keys.count, ["date", "from", "to"].allSatisfy(keys.contains) else {
            throw DataError.invalid("CSV 至少需要 date,from,to（或 日期,出发站,到达站），且表头不能重复")
        }
        return try rows.dropFirst().enumerated().map { number, values in
            guard values.count == keys.count else { throw DataError.invalid("CSV 第 \(number + 2) 行列数不一致") }
            let v = Dictionary(uniqueKeysWithValues: zip(keys, values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            return RailJourney(date: v["date"] ?? "", train: v["train"] ?? "",
                               from: v["from"] ?? "", to: v["to"] ?? "", departure: v["departure"] ?? "",
                               source: "CSV 导入", note: v["note"] ?? "")
        }
    }

    /// Extraction is deliberately tentative. Neither a ticket nor an email
    /// proves travel, and incomplete OCR is never completed with today's date.
    public static func text(_ input: String, source: String = "文字导入") -> [RailJourney] {
        guard input.utf8.count <= 2_000_000 else { return [] }
        let lines = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let datedLines = lines.filter { first(#"(\d{4})[-年/.](\d{1,2})[-月/.](\d{1,2})日?"#, in: $0) != nil }
        let blocks = datedLines.count > 1 ? datedLines : [lines.joined(separator: " ")]
        return blocks.prefix(500).filter { !$0.isEmpty }.map { block in
            let date = first(#"(\d{4})[-年/.](\d{1,2})[-月/.](\d{1,2})日?"#, in: block)
            let normalizedDate: String
            if let date, let y = Int(date[1]), let m = Int(date[2]), let d = Int(date[3]) {
                normalizedDate = String(format: "%04d-%02d-%02d", y, m, d)
            } else { normalizedDate = "" }
            let route = first(#"([\p{Han}A-Za-z·]{1,24})\s*(?:→|至|到|—|－|-)\s*([\p{Han}A-Za-z·]{1,24})"#, in: block)
            let train = first(#"(?i)(?<![A-Z0-9])([GDCZTKYSLNVX]\s?\d{1,5}(?:/\d{1,5})?)(?:次|车|[\s,，]|$)"#, in: block)
            let time = first(#"(?<!\d)([012]?\d)[:：]([0-5]\d)(?!\d)"#, in: block)
            let departure = time.flatMap { t -> String? in
                guard let h = Int(t[1]), let m = Int(t[2]), h < 24 else { return nil }
                return String(format: "%02d:%02d", h, m)
            } ?? ""
            return RailJourney(date: normalizedDate, train: train?[1].replacingOccurrences(of: " ", with: "").uppercased() ?? "",
                               from: cleanStation(route?[1] ?? ""), to: cleanStation(route?[2] ?? ""),
                               departure: departure, source: source)
        }
    }

    private static func cleanStation(_ value: String) -> String {
        var text = value
        for prefix in ["从", "由"] where text.hasPrefix(prefix) { text.removeFirst() }
        if text.hasSuffix("站") { text.removeLast() }
        return text
    }
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

/// The drawing boundary for the guessing game contains no strings, source IDs,
/// geographic coordinates, route colours or answer metadata.
public struct RailSilhouette: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public let paths: [[Point]]

    public init(coordinates: [[Coordinate]], rotation: Double = 0) {
        let all = coordinates.flatMap { $0 }.filter(\.isValid)
        guard let first = all.first else { paths = []; return }
        let latitude = all.map(\.latitude).reduce(0, +) / Double(all.count)
        let longitudeScale = cos(latitude * .pi / 180)
        let angle = rotation.isFinite ? rotation : 0
        let transformed = coordinates.compactMap { part -> [Point]? in
            guard part.count >= 2, part.allSatisfy(\.isValid) else { return nil }
            return part.map {
                let x = ($0.longitude - first.longitude) * longitudeScale
                let y = -($0.latitude - first.latitude)
                return Point(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
            }
        }
        let points = transformed.flatMap { $0 }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
        let scale = max(maxX - minX, maxY - minY, 0.000001)
        paths = transformed.map { part in
            part.map { Point(x: ($0.x - (minX + maxX) / 2) / scale + 0.5,
                             y: ($0.y - (minY + maxY) / 2) / scale + 0.5) }
        }
    }
}

public struct RailHistoryEvent: Codable, Identifiable, Sendable {
    public var id: String
    public var date: String
    public var title: String
    public var detail: String
    /// Editorial city-centre links; explicitly NOT historical track geometry.
    public var places: [Place]
    public var source: RailEvidence
    public struct Place: Codable, Sendable {
        public var name: String
        public var latitude: Double
        public var longitude: Double
    }
}

public struct RailHistoryArchive: Codable, Sendable {
    public var version: Int
    public var events: [RailHistoryEvent]
    public init(events: [RailHistoryEvent]) { version = 1; self.events = events }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count < 2_000_000 else { throw DataError.invalid("历史节点包过大") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.events.isEmpty, value.events.count <= 1000,
              Set(value.events.map(\.id)).count == value.events.count else { throw DataError.invalid("历史节点包无效") }
        for event in value.events {
            try event.source.validate()
            guard RailCivilDate.validHistorical(event.date), !event.id.isEmpty, !event.title.isEmpty,
                  (1...50).contains(event.places.count), event.places.allSatisfy({
                      !$0.name.isEmpty && Coordinate($0.latitude, $0.longitude).isValid
                  }) else { throw DataError.invalid("历史节点的日期、名称或位置无效") }
        }
        return value
    }
}

public enum RailExperienceCatalog {
    public static func timetables() throws -> [RailTimetable] {
        try RailTimetableArchive.decode(resource("railway-experience-timetables")).timetables
    }
    public static func history() throws -> [RailHistoryEvent] {
        try RailHistoryArchive.decode(resource("railway-experience-history")).events.sorted { $0.date < $1.date }
    }
    private static func resource(_ name: String) throws -> Data {
        let urls = [Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources"),
                    Bundle.module.url(forResource: name, withExtension: "json")].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url) { return data }
        }
        throw DataError.invalid("缺少漫游资源：\(name)")
    }
}
