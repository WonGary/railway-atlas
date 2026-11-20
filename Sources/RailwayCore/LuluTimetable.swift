import Foundation
import zlib

/// Interoperability reader for the public Android download. Does not execute
/// package code, read accounts, or ship the provider's database with the app.
public struct LuluTimetableSnapshot: Codable, Sendable {
    public struct Service: Codable, Identifiable, Sendable {
        public var id: Int
        public var train: String
        public var validFrom: String
        public var validThrough: String
        public var flags: [Int]
        public var stops: [RailTimetable.Stop]
        public var kilometreMarks: [Int]
        public var conditional: Bool { flags[2] != 0 || flags[4] != 0 || flags[0] >= 48 }
        public func timetable(on date: String, edition: String, retrievedOn: String? = nil) throws -> RailTimetable {
            guard RailCivilDate.valid(date), validFrom <= date, date <= validThrough else {
                throw DataError.invalid("所选日期不在这条排图记录的有效范围内")
            }
            let value = RailTimetable(id: "llt-\(edition)-\(id)-\(date)", train: train, serviceDate: date,
                source: RailEvidence(title: "路路通公开离线库 · \(edition)", url: LuluTimetableClient.downloadURL.absoluteString,
                    retrievedOn: retrievedOn ?? edition,
                    note: "版本日期不等于开行确认。排图有效期 \(validFrom) — \(validThrough)。"
                        + (conditional ? "含条件开行/状态标记 \(flags)，具体运行日仍需核对。"
                           : "未核验临时停运、晚点及当前可售状态。")),
                stops: stops)
            try value.validate()
            return value
        }
    }
    public var version = 1
    public var edition: String
    public var retrievedOn: String
    public var stationCount: Int
    public var services: [Service]
    public var packageETag: String
    public var routing: LuluRouteDatabase? = nil
    public var stopCount: Int { services.reduce(0) { $0 + $1.stops.count } }

    public func timetable(_ service: Service, on date: String) throws -> RailTimetable {
        var result = try service.timetable(on: date, edition: edition, retrievedOn: retrievedOn)
        do { result.routing = try routing?.plan(for: service, edition: edition) }
        catch { result.routingIssue = error.localizedDescription }
        try result.validate()
        return result
    }

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 80_000_000 else { throw DataError.invalid("路路通转换库超限") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, RailCivilDate.valid(value.edition), RailCivilDate.valid(value.retrievedOn),
              (1...100_000).contains(value.services.count), (1...30_000).contains(value.stationCount),
              Set(value.services.map(\.id)).count == value.services.count else { throw invalid() }
        for service in value.services {
            guard service.id >= 0, service.flags.count == 5,
                  service.flags.allSatisfy({ (0...255).contains($0) }),
                  service.stops.count == service.kilometreMarks.count,
                  service.kilometreMarks.allSatisfy({ (0...65_535).contains($0) }),
                  RailCivilDate.valid(service.validFrom), RailCivilDate.valid(service.validThrough),
                  service.validFrom <= service.validThrough else { throw invalid() }
            _ = try service.timetable(on: service.validFrom, edition: value.edition, retrievedOn: value.retrievedOn)
        }
        try value.routing?.validate()
        return value
    }

    public static func decodeResources(_ resources: [String: Data], retrievedOn: String, etag: String = "") throws -> Self {
        var names: [String]?, stations: [String]?, edition: String?
        for (name, data) in resources {
            if name.hasSuffix(".txt"), let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.count == 8, let date = civil(Int(text) ?? 0) { edition = date }
            if let dictionary = dictionary(data), dictionary.count > 100 {
                if dictionary.prefix(50).allSatisfy({ $0.range(of: #"^[A-Z0-9/]+$"#, options: .regularExpression) != nil }) {
                    guard names == nil else { throw invalid() }; names = dictionary
                } else if dictionary.prefix(50).allSatisfy({ $0.range(of: #"^[\p{Han}]+$"#, options: .regularExpression) != nil }) {
                    guard stations == nil else { throw invalid() }; stations = dictionary
                }
            }
        }
        guard let names, let stations, let edition else { throw invalid() }
        var all: [Int: Service] = [:]
        for (name, data) in resources where name.hasSuffix(".dat") {
            guard let records = block(data, trains: names, stations: stations) else { continue }
            for item in records {
                guard all[item.id] == nil else { throw invalid() }
                all[item.id] = item
            }
        }
        guard all.count == names.count, Set(all.keys) == Set(names.indices) else {
            throw DataError.invalid("离线库格式变化或记录缺失：解析 \(all.count) / \(names.count)；原库保留")
        }
        var value = Self(edition: edition, retrievedOn: retrievedOn, stationCount: stations.count,
                         services: all.values.sorted { $0.id < $1.id }, packageETag: etag)
        let routing = resources.values.filter(LuluRouteDatabase.recognizes)
        guard routing.count <= 1 else { throw invalid() }
        if let data = routing.first { value.routing = try LuluRouteDatabase.decode(data) }
        // Complete validation happens before the caller can replace a library.
        return try read(JSONEncoder().encode(value))
    }

    private static func dictionary(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let n = Int(b[0]) * 256 + Int(b[1])
        guard (100...30_000).contains(n) else { return nil }
        var p = 2, result: [String] = []
        for _ in 0..<n {
            guard p + 2 <= b.count else { return nil }
            let length = Int(b[p]) * 256 + Int(b[p + 1]); p += 2
            guard (1...120).contains(length), p + length <= b.count,
                  let text = String(bytes: b[p..<p + length], encoding: .utf8),
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            result.append(text); p += length
        }
        return p == b.count ? result : nil
    }
    private static func civil(_ value: Int) -> String? {
        let result = String(format: "%04d-%02d-%02d", value / 10_000, (value / 100) % 100, value % 100)
        return RailCivilDate.valid(result) ? result : nil
    }
    private static func block(_ data: Data, trains: [String], stations: [String]) -> [Service]? {
        let b = [UInt8](data)
        guard b.count >= 31 else { return nil }
        func base255(_ p: Int) -> Int { Int(b[p]) * 255 + Int(b[p + 1]) }
        func date(_ p: Int) -> String? {
            guard b[p..<p + 4].allSatisfy({ $0 < 128 }) else { return nil }
            return civil((0..<4).reduce(0) { $0 + (Int(b[p + $1]) << (7 * $1)) })
        }
        var p = 0, result: [Service] = []
        while p < b.count {
            guard p + 17 <= b.count else { return nil }
            let id = base255(p), n = base255(p + 15)
            guard trains.indices.contains(id), (2...250).contains(n), p + 17 + n * 7 <= b.count,
                  let from = date(p + 5), let through = date(p + 9), from <= through else { return nil }
            var stops: [RailTimetable.Stop] = [], kilometres: [Int] = [], previous = -1
            for i in 0..<n {
                let offset = p + 17 + i * 7, station = base255(offset)
                let hour = Int(b[offset + 2]), minute = Int(b[offset + 3]), dwell = Int(b[offset + 4])
                guard stations.indices.contains(station), hour < 24, minute < 60 else { return nil }
                var arrival = hour * 60 + minute
                while arrival < previous { arrival += 1440 }
                let departure = arrival + dwell
                stops.append(.init(stations[station], arrival: i == 0 ? nil : arrival,
                                   departure: i == n - 1 ? nil : departure))
                kilometres.append(base255(offset + 5)); previous = departure
            }
            let flags = [2, 3, 4, 13, 14].map { Int(b[p + $0]) }
            result.append(.init(id: id, train: trains[id], validFrom: from, validThrough: through,
                                flags: flags, stops: stops, kilometreMarks: kilometres))
            p += 17 + n * 7
        }
        return result
    }
    private static func invalid() -> DataError { .invalid("路路通离线库格式不受支持或校验失败，原库保留") }
}

public enum LuluTimetableClient {
    public static let downloadURL = URL(string: "http://down.lltskb.com/lulutong.apk")!
    public struct Entry: Sendable {
        public var name: String
        public var method: Int
        public var compressed: Int
        public var uncompressed: Int
        public var offset: Int
        public var crc: UInt32
    }
    public static func download() async throws -> LuluTimetableSnapshot {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (tail, response) = try await request("bytes=-262144", session: session)
        let end = [UInt8](tail)
        guard end.count >= 22 else { throw error() }
        guard let eocd = stride(from: end.count - 22, through: max(0, end.count - 65_557), by: -1)
            .first(where: { end[$0..<$0 + 4].elementsEqual([80, 75, 5, 6]) }) else { throw error() }
        let size = le(end, eocd + 12, 4), offset = le(end, eocd + 16, 4)
        guard (1...4_000_000).contains(size), (1...100_000_000).contains(offset) else { throw error() }
        let etag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let (directory, _) = try await request("bytes=\(offset)-\(offset + size - 1)", session: session, etag: etag)
        let entries = try central(directory).filter { item in
            item.name.hasPrefix("res/") && (item.name.hasSuffix(".dat") || item.name.hasSuffix(".txt")
                || !item.name.split(separator: "/").last!.contains("."))
        }
        guard (20...200).contains(entries.count) else { throw error() }
        var resources: [String: Data] = [:]
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var index = 0
            func enqueue(_ entry: Entry) {
                group.addTask {
                    let (data, _) = try await request("bytes=\(entry.offset)-\(entry.offset + entry.compressed + entry.name.utf8.count + 512)",
                                                     session: session, etag: etag)
                    return (entry.name, try extract(data, entry: entry))
                }
            }
            for _ in 0..<min(3, entries.count) { enqueue(entries[index]); index += 1 }
            for try await (name, data) in group {
                resources[name] = data
                if index < entries.count { enqueue(entries[index]); index += 1 }
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let value = try LuluTimetableSnapshot.decodeResources(resources,
            retrievedOn: String(formatter.string(from: .now).prefix(10)), etag: etag)
        guard value.routing != nil else { throw error() }
        return value
    }
    private static func request(_ range: String, session: URLSession, etag: String = "") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: downloadURL)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              http.url?.host == downloadURL.host,
              etag.isEmpty || http.value(forHTTPHeaderField: "ETag") == etag,
              http.expectedContentLength <= 5_000_000 else { throw error() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 5_000_000 else { throw error() }
        }
        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes "), let interval = contentRange.split(separator: " ").last?.split(separator: "/").first,
              let start = Int(interval.split(separator: "-").first ?? ""),
              let end = Int(interval.split(separator: "-").last ?? ""), end - start + 1 == data.count else { throw error() }
        if !range.hasPrefix("bytes=-") {
            let requested = range.dropFirst(6).split(separator: "-")
            guard start == Int(requested[0]), end == Int(requested[1]) else { throw error() }
        }
        return (data, http)
    }
    public static func central(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data); var p = 0, result: [Entry] = []
        while p < b.count {
            guard p + 46 <= b.count, le(b, p, 4) == 0x02014b50 else { throw error() }
            let n = le(b, p + 28, 2), extra = le(b, p + 30, 2), comment = le(b, p + 32, 2)
            guard n > 0, p + 46 + n + extra + comment <= b.count,
                  let name = String(bytes: b[p + 46..<p + 46 + n], encoding: .utf8),
                  le(b, p + 8, 2) & 1 == 0 else { throw error() }
            result.append(.init(name: name, method: le(b, p + 10, 2),
                compressed: le(b, p + 20, 4), uncompressed: le(b, p + 24, 4),
                offset: le(b, p + 42, 4), crc: UInt32(le(b, p + 16, 4))))
            p += 46 + n + extra + comment
            guard result.count <= 30_000 else { throw error() }
        }
        return result
    }
    public static func extract(_ data: Data, entry: Entry) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 30, le(b, 0, 4) == 0x04034b50,
              le(b, 8, 2) == entry.method, le(b, 6, 2) & 1 == 0,
              (0...4_000_000).contains(entry.compressed), (0...8_000_000).contains(entry.uncompressed) else { throw error() }
        let n = le(b, 26, 2), extra = le(b, 28, 2), start = 30 + n + extra
        guard start + entry.compressed <= b.count,
              String(bytes: b[30..<30 + n], encoding: .utf8) == entry.name else { throw error() }
        var input = Array(b[start..<start + entry.compressed]), output = [UInt8](repeating: 0, count: max(1, entry.uncompressed))
        if entry.method == 0 { output = input }
        else if entry.method == 8 {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw error() }
            defer { inflateEnd(&stream) }
            let status = input.withUnsafeMutableBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    stream.next_in = source.baseAddress; stream.avail_in = UInt32(source.count)
                    stream.next_out = target.baseAddress; stream.avail_out = UInt32(target.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.uncompressed, stream.total_in == entry.compressed else { throw error() }
            if entry.uncompressed == 0 { output = [] }
        } else { throw error() }
        guard output.count == entry.uncompressed else { throw error() }
        let checksum = output.withUnsafeBufferPointer { crc32(0, $0.baseAddress, UInt32($0.count)) }
        guard UInt32(checksum) == entry.crc else { throw error() }
        return Data(output)
    }
    private static func le(_ b: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | (Int(b[offset + $1]) << (8 * $1)) }
    }
    private static func error() -> DataError { .invalid("路路通下载包不完整、版本变化或格式不受支持；未替换原库") }
}
