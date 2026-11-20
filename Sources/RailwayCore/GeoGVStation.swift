import Foundation

/// Reads the public pages' station, line diagram and timetable feeds on demand.
/// Coordinates in GeoGV's schematic belong to that map and are never used for routing.
public actor GeoGVStations {
    public static let shared = GeoGVStations()
    public static let website = URL(string: "http://cnrail.geogv.org/zhcn/")!
    public struct Choice: Decodable, Identifiable, Sendable {
        public let name: String, query: String
        public var id: String { String(query.dropFirst(4)) }
    }
    public struct Line: Decodable, Identifiable, Sendable {
        public let eid: String?, linename: String
        public var id: String { eid ?? linename }
    }
    public struct Station: Sendable {
        public let name: String, code: String?, lines: [Line]
    }
    public struct Stop: Sendable {
        public let name: String, mileage: String, note: String
    }
    public struct Train: Sendable {
        public let number: String, from: String, to: String, arrival: String, departure: String
    }
    public struct Board: Sendable {
        public let update: String, trains: [Train]
    }
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 0, diskPath: nil)
        session = URLSession(configuration: config)
    }
    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public func search(_ name: String) async throws -> [Choice] {
        let key = RailJourneyMatcher.normalized(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let data = try await get("search/", keyword: key)
        return try JSONDecoder().decode([Choice].self, from: data).filter {
            $0.query.hasPrefix("geo/") && Self.validID($0.id)
        }
    }
    public func station(_ id: String) async throws -> Station {
        struct POI: Decodable {
            struct Extra: Decodable {
                struct Fields: Decodable { var connection: [Line]?; var tele_code: String? }
                var view: String?
                var data: Fields?
            }
            var name: String; var exd: [Extra]?
        }
        let poi = try JSONDecoder().decode(POI.self, from: try await get("poi", id: id))
        guard let info = poi.exd?.first(where: { $0.view == nil || $0.view == "station" })?.data else {
            throw DataError.invalid("这个地图要素没有铁路车站资料。")
        }
        return Station(name: poi.name, code: info.tele_code, lines: info.connection ?? [])
    }
    public func line(_ id: String) async throws -> [Stop] {
        let data = try await get("feature", id: id)
        guard let feature = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any] else {
            throw DataError.invalid("未读到这条线路的站序。")
        }
        // The diagram can include junctions and branch labels missing from the compact station table.
        let diagram = (feature["diagram"] as? [[Any]] ?? []).compactMap { row -> Stop? in
            guard row.count >= 3, let node = row[1] as? [String: Any] else { return nil }
            let name = (node["station"] as? String) ?? (node["poi"] as? String) ?? (node["info"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let note = [node["poi"] as? String, node["info"] as? String].compactMap { $0 }.filter { $0 != name }.joined(separator: " · ")
            return Stop(name: name, mileage: Self.text(row[2]), note: note)
        }
        if !diagram.isEmpty { return diagram }
        return (feature["stations"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return Stop(name: name, mileage: Self.text($0["mileage"]), note: "")
        }
    }
    public func board(_ id: String) async throws -> Board {
        struct Response: Decodable {
            struct Endpoint: Decodable { var kid: String?; var name: String }
            struct Call: Decodable {
                var from: Int; var to: Int; var arr: String?; var dep: String?; var opid: String
            }
            var hash: [Endpoint]; var list: [Call]; var update: String?
        }
        let board = try JSONDecoder().decode(Response.self, from: try await get("stationroute", id: id))
        let trains = try board.list.map { row in
            guard board.hash.indices.contains(row.from), board.hash.indices.contains(row.to) else {
                throw DataError.invalid("原站时刻表有一条记录缺少起终点，请在原网页查看。")
            }
            let a = board.hash[row.from], b = board.hash[row.to]
            return Train(number: row.opid, from: a.name, to: b.name,
                         arrival: a.kid == id ? "始发" : row.arr ?? "—",
                         departure: b.kid == id ? "终到" : row.dep ?? "—")
        }
        return Board(update: board.update ?? "未注明", trains: trains)
    }
    private static func text(_ value: Any?) -> String {
        value as? String ?? (value as? NSNumber)?.stringValue ?? ""
    }
    private func get(_ resource: String, id: String? = nil, keyword: String? = nil) async throws -> Data {
        if let id, !Self.validID(id) { throw DataError.invalid("原站要素编号无效。") }
        var parts = URLComponents(string: "http://cnrail.geogv.org/api/" + resource + (id.map { "/" + $0 } ?? ""))!
        parts.queryItems = [URLQueryItem(name: "locale", value: "zhcn")]
        if let keyword { parts.queryItems?.append(URLQueryItem(name: "keyword", value: keyword)) }
        let (bytes, response) = try await session.bytes(from: parts.url!)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "cnrail.geogv.org",
              http.expectedContentLength <= 4_000_000 else { throw DataError.invalid("中国铁路地图暂时无法提供这份资料。") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 4_000_000 { throw DataError.invalid("原站返回的单页资料过大。") }
        }
        // Some first-party feeds wrap their JSON in a string of UTF-16 code units.
        if let encoded = try? JSONDecoder().decode(String.self, from: data) {
            let units = Array(encoded.utf16)
            guard let first = units.first, first > 0, Int(first) + 1 < units.count else { throw DataError.invalid("原站资料格式有变。") }
            let length = Int(first)
            let decoded = units.dropFirst(length + 1).enumerated().map { $0.element &- units[1 + $0.offset % length] }
            return Data(String(decoding: decoded, as: UTF16.self).utf8)
        }
        return data
    }
}
